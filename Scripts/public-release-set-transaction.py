#!/usr/bin/env python3
"""Snapshot and transactionally publish ForgePlay release asset sets."""

from __future__ import annotations

import argparse
import errno
import json
import os
import re
import secrets
import stat
import sys
from pathlib import Path


DMG_PATTERN = re.compile(r"ForgePlay-[A-Za-z0-9._-]+-[A-Za-z0-9._-]+\.dmg")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
WINE_SOURCE_PATH = "CorrespondingSource/Wine/wine-11.12.tar.xz"
STAGE_PATTERN = re.compile(
    r"\.ForgePlay-[A-Za-z0-9._-]+-[A-Za-z0-9._-]+\.dmg\.release-stage-[0-9a-f]{32}"
)


class TransactionError(Exception):
    pass


def _publication_precommit_seam(
    _event: str, _destination_descriptor: int, _manifest_name: str
) -> None:
    """Deterministic no-op seam for publication race regression tests."""


def identity(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def trusted_alias_components(path: Path) -> tuple[str, ...]:
    requested = Path(os.path.abspath(path))
    parts = requested.parts[1:]
    aliases = {
        "tmp": ("/tmp", {"private/tmp", "/private/tmp"}, ("private", "tmp")),
        "var": ("/var", {"private/var", "/private/var"}, ("private", "var")),
    }
    if parts and parts[0] in aliases:
        alias_path, allowed_targets, physical_prefix = aliases[parts[0]]
        try:
            metadata = os.lstat(alias_path)
        except OSError as error:
            raise TransactionError(f"trusted {alias_path} path is unavailable: {error}") from error
        if stat.S_ISLNK(metadata.st_mode):
            target = os.readlink(alias_path)
            if target not in allowed_targets:
                raise TransactionError(
                    f"{alias_path} is not the exact trusted macOS /private/{parts[0]} alias"
                )
            parts = (*physical_prefix, *parts[1:])
        elif not stat.S_ISDIR(metadata.st_mode):
            raise TransactionError(f"trusted {alias_path} path is not a directory")
    return tuple(parts)


def open_directory(path: Path) -> int:
    descriptor = os.open("/", os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY)
    try:
        for component in trusted_alias_components(path):
            next_descriptor = os.open(
                component,
                os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def open_parent(path: Path) -> tuple[int, str]:
    absolute = Path(os.path.abspath(path))
    if not absolute.name or absolute.name in {".", ".."}:
        raise TransactionError(f"path has no safe final component: {path}")
    return open_directory(absolute.parent), absolute.name


def revalidate_open_directory_path(path: Path, descriptor: int, label: str) -> None:
    rebound = open_directory(path)
    try:
        expected = os.fstat(descriptor)
        observed = os.fstat(rebound)
        if not stat.S_ISDIR(expected.st_mode) or (
            expected.st_dev,
            expected.st_ino,
        ) != (
            observed.st_dev,
            observed.st_ino,
        ):
            raise TransactionError(f"{label} path identity changed")
    finally:
        os.close(rebound)


def expected_names(dmg_name: str, commercial: bool) -> set[str]:
    base = dmg_name.removesuffix(".dmg")
    common = {dmg_name, f"{dmg_name}.sha256", f"{dmg_name}.release.json"}
    if not commercial:
        return common
    return common | {
        f"{base}-OpenSource.tar",
        f"{base}-ThirdPartyCorrespondingSource.tar",
        f"{base}-ThirdPartyCorrespondingSource.receipt.json",
    }


def enumerate_release_set(directory_descriptor: int) -> tuple[str, list[str], bool]:
    names = sorted(os.listdir(directory_descriptor))
    dmg_names = [name for name in names if DMG_PATTERN.fullmatch(name)]
    if len(dmg_names) != 1:
        raise TransactionError(f"release set must contain exactly one ForgePlay DMG; found {dmg_names}")
    dmg_name = dmg_names[0]
    actual = set(names)
    local = expected_names(dmg_name, False)
    commercial = expected_names(dmg_name, True)
    if actual == commercial:
        return dmg_name, names, True
    if actual == local:
        return dmg_name, names, False
    raise TransactionError(
        "release set membership must be exactly the commercial six-file or local three-file set: "
        f"actual={names}"
    )


def open_set_files(directory_descriptor: int, names: list[str]) -> dict[str, tuple[int, os.stat_result]]:
    opened: dict[str, tuple[int, os.stat_result]] = {}
    try:
        for name in names:
            path_metadata = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            if not stat.S_ISREG(path_metadata.st_mode) or path_metadata.st_nlink != 1:
                raise TransactionError(f"release asset must be a single-link regular file: {name}")
            descriptor = os.open(
                name,
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                dir_fd=directory_descriptor,
            )
            opened_metadata = os.fstat(descriptor)
            if identity(opened_metadata) != identity(path_metadata):
                os.close(descriptor)
                raise TransactionError(f"release asset changed while being opened: {name}")
            opened[name] = (descriptor, opened_metadata)
        return opened
    except Exception:
        for descriptor, _ in opened.values():
            os.close(descriptor)
        raise


def stable_read(descriptor: int, expected: os.stat_result, label: str) -> bytes:
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks: list[bytes] = []
    total = 0
    while chunk := os.read(descriptor, 1024 * 1024):
        chunks.append(chunk)
        total += len(chunk)
    after = os.fstat(descriptor)
    if identity(expected) != identity(after) or total != expected.st_size:
        raise TransactionError(f"release asset changed while being read: {label}")
    return b"".join(chunks)


def release_kind_from_manifest(raw: bytes, commercial: bool) -> None:
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise TransactionError(f"release manifest is invalid UTF-8 JSON: {error}") from error
    expected = "commercial-notarized-dmg" if commercial else "local-unnotarized-dmg"
    if not isinstance(value, dict) or value.get("schemaVersion") != 3 or value.get("releaseKind") != expected:
        raise TransactionError(f"release manifest must use schemaVersion 3 and releaseKind {expected}")
    attestation_binding = value.get("publicRuntimeReleaseAttestation")
    copyleft_binding = value.get("copyleftSourcePackage")
    project_binding = value.get("projectCorrespondingSource")
    if not commercial:
        if any(binding is not None for binding in (attestation_binding, copyleft_binding, project_binding)):
            raise TransactionError("local release manifest must use null source and Runtime bindings")
        return
    try:
        host_support = attestation_binding["value"]["runtime"]["subjects"][
            "hostSupportPayloadFingerprint"
        ]
        copyleft_host_support = copyleft_binding["receipt"]["value"][
            "hostSupportPayloadFingerprint"
        ]
        additional_entries = project_binding["value"]["additionalEntries"]
    except (KeyError, TypeError) as error:
        raise TransactionError("commercial release manifest source/Runtime binding is incomplete") from error
    if (
        not isinstance(host_support, str)
        or SHA256_PATTERN.fullmatch(host_support) is None
        or copyleft_host_support != host_support
    ):
        raise TransactionError("commercial release copyleft host support binding is invalid")
    if (
        not isinstance(additional_entries, list)
        or len(additional_entries) != 1
        or not isinstance(additional_entries[0], dict)
        or additional_entries[0].get("path") != WINE_SOURCE_PATH
        or not isinstance(additional_entries[0].get("sha256"), str)
        or SHA256_PATTERN.fullmatch(additional_entries[0]["sha256"]) is None
    ):
        raise TransactionError("commercial release Wine source binding is invalid")


def inode_bound_unlink(directory_descriptor: int, name: str, expected: tuple[int, int]) -> bool:
    try:
        current = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return True
    if (current.st_dev, current.st_ino) != expected:
        return False
    os.unlink(name, dir_fd=directory_descriptor)
    return True


def snapshot(input_path: Path, snapshot_dir: Path) -> Path:
    absolute_input = Path(os.path.abspath(input_path))
    if DMG_PATTERN.fullmatch(absolute_input.name):
        source_directory, requested_name = open_parent(absolute_input)
        try:
            metadata = os.stat(requested_name, dir_fd=source_directory, follow_symlinks=False)
        except OSError:
            os.close(source_directory)
            raise
        if not stat.S_ISREG(metadata.st_mode):
            os.close(source_directory)
            raise TransactionError("release input must be a directory or regular DMG")
    else:
        source_directory = open_directory(absolute_input)
    snapshot_directory = open_directory(snapshot_dir)
    created: list[tuple[str, tuple[int, int]]] = []
    opened: dict[str, tuple[int, os.stat_result]] = {}
    try:
        snapshot_metadata = os.fstat(snapshot_directory)
        if snapshot_metadata.st_mode & 0o077 or os.listdir(snapshot_directory):
            raise TransactionError("snapshot directory must be empty and private (mode 0700)")
        source_before = os.fstat(source_directory)
        dmg_name, names, commercial = enumerate_release_set(source_directory)
        opened = open_set_files(source_directory, names)
        if sorted(os.listdir(source_directory)) != names:
            raise TransactionError("release set changed while files were opened")
        manifest_name = f"{dmg_name}.release.json"
        manifest_descriptor, manifest_metadata = opened[manifest_name]
        release_kind_from_manifest(
            stable_read(manifest_descriptor, manifest_metadata, manifest_name), commercial
        )
        for name in names:
            source_descriptor, source_metadata = opened[name]
            os.lseek(source_descriptor, 0, os.SEEK_SET)
            output = os.open(
                name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
                dir_fd=snapshot_directory,
            )
            try:
                output_metadata = os.fstat(output)
                created.append((name, (output_metadata.st_dev, output_metadata.st_ino)))
                total = 0
                while chunk := os.read(source_descriptor, 1024 * 1024):
                    view = memoryview(chunk)
                    while view:
                        count = os.write(output, view)
                        if count <= 0:
                            raise TransactionError(f"snapshot write stopped: {name}")
                        view = view[count:]
                    total += len(chunk)
                os.fsync(output)
                if total != source_metadata.st_size or identity(os.fstat(source_descriptor)) != identity(source_metadata):
                    raise TransactionError(f"release asset changed while snapshotting: {name}")
            finally:
                os.close(output)
        if identity(os.fstat(source_directory)) != identity(source_before):
            raise TransactionError("release set directory changed while snapshotting")
        os.fsync(snapshot_directory)
        return Path(os.path.abspath(snapshot_dir)) / dmg_name
    except Exception:
        for name, expected in reversed(created):
            try:
                inode_bound_unlink(snapshot_directory, name, expected)
            except OSError:
                pass
        raise
    finally:
        for descriptor, _ in opened.values():
            os.close(descriptor)
        os.close(source_directory)
        os.close(snapshot_directory)


def create_stage(destination_dmg: Path) -> Path:
    parent_descriptor, dmg_name = open_parent(destination_dmg)
    try:
        if DMG_PATTERN.fullmatch(dmg_name) is None:
            raise TransactionError("destination DMG filename is invalid")
        for name in expected_names(dmg_name, True):
            try:
                os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise TransactionError(f"release final path must be absent before staging: {name}")
        stage_name = f".{dmg_name}.release-stage-{secrets.token_hex(16)}"
        os.mkdir(stage_name, 0o700, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
        return Path(os.path.abspath(destination_dmg)).parent / stage_name
    finally:
        os.close(parent_descriptor)


def publish(stage_dir: Path, destination_dmg: Path) -> str:
    stage_parent_descriptor, stage_name = open_parent(stage_dir)
    stage_descriptor = os.open(
        stage_name,
        os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW,
        dir_fd=stage_parent_descriptor,
    )
    destination_descriptor, dmg_name = open_parent(destination_dmg)
    opened: dict[str, tuple[int, os.stat_result]] = {}
    published: list[tuple[str, tuple[int, int]]] = []
    committed = False
    try:
        if STAGE_PATTERN.fullmatch(stage_name) is None:
            raise TransactionError("stage directory is outside the private release-stage namespace")
        stage_parent_metadata = os.fstat(stage_parent_descriptor)
        destination_metadata = os.fstat(destination_descriptor)
        if (stage_parent_metadata.st_dev, stage_parent_metadata.st_ino) != (
            destination_metadata.st_dev, destination_metadata.st_ino
        ):
            raise TransactionError("release stage must be adjacent to its destination")
        if DMG_PATTERN.fullmatch(dmg_name) is None:
            raise TransactionError("destination DMG filename is invalid")
        stage_before = os.fstat(stage_descriptor)
        actual_dmg, names, commercial = enumerate_release_set(stage_descriptor)
        if actual_dmg != dmg_name:
            raise TransactionError("staged and destination DMG filenames differ")
        opened = open_set_files(stage_descriptor, names)
        manifest_name = f"{dmg_name}.release.json"
        manifest_descriptor, manifest_metadata = opened[manifest_name]
        release_kind_from_manifest(
            stable_read(manifest_descriptor, manifest_metadata, manifest_name), commercial
        )
        if sorted(os.listdir(destination_descriptor)) != [stage_name]:
            raise TransactionError("release destination must contain only its private stage before publication")
        for name in names:
            try:
                os.stat(name, dir_fd=destination_descriptor, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise TransactionError(f"release final path already exists: {name}")
        order = sorted(name for name in names if name != manifest_name)
        for name in order:
            source_metadata = opened[name][1]
            os.link(
                name,
                name,
                src_dir_fd=stage_descriptor,
                dst_dir_fd=destination_descriptor,
                follow_symlinks=False,
            )
            published.append((name, (source_metadata.st_dev, source_metadata.st_ino)))
            final = os.stat(name, dir_fd=destination_descriptor, follow_symlinks=False)
            if (final.st_dev, final.st_ino) != published[-1][1]:
                raise TransactionError(f"published release asset identity differs: {name}")
        os.fsync(destination_descriptor)
        for name, expected in published:
            final = os.stat(name, dir_fd=destination_descriptor, follow_symlinks=False)
            if (final.st_dev, final.st_ino) != expected:
                raise TransactionError(f"published release asset was replaced before commit: {name}")
        if set(os.listdir(destination_descriptor)) != {stage_name, *order}:
            raise TransactionError("release destination membership changed before commit")
        manifest_source = opened[manifest_name][1]
        os.link(
            manifest_name,
            manifest_name,
            src_dir_fd=stage_descriptor,
            dst_dir_fd=destination_descriptor,
            follow_symlinks=False,
        )
        published.append((manifest_name, (manifest_source.st_dev, manifest_source.st_ino)))
        _publication_precommit_seam("manifest-linked", destination_descriptor, manifest_name)
        if not inode_bound_unlink(
            stage_descriptor,
            manifest_name,
            published[-1][1],
        ):
            raise TransactionError("staged release manifest identity changed before commit")
        os.fsync(stage_descriptor)
        for name, expected in published:
            final = os.stat(name, dir_fd=destination_descriptor, follow_symlinks=False)
            expected_links = 1 if name == manifest_name else 2
            if (
                not stat.S_ISREG(final.st_mode)
                or final.st_nlink != expected_links
                or (final.st_dev, final.st_ino) != expected
            ):
                raise TransactionError(f"published release asset is not exact before commit: {name}")
        if set(os.listdir(destination_descriptor)) != {stage_name, *names}:
            raise TransactionError("release destination membership changed before manifest commit")
        stage_path = os.stat(stage_name, dir_fd=stage_parent_descriptor, follow_symlinks=False)
        if (stage_path.st_dev, stage_path.st_ino) != (
            stage_before.st_dev,
            stage_before.st_ino,
        ):
            raise TransactionError("release stage path changed before commit")
        destination_path = Path(os.path.abspath(destination_dmg)).parent
        revalidate_open_directory_path(
            destination_path,
            destination_descriptor,
            "release destination",
        )
        _publication_precommit_seam("before-destination-fsync", destination_descriptor, manifest_name)
        os.fsync(destination_descriptor)
        revalidate_open_directory_path(
            destination_path,
            destination_descriptor,
            "release destination",
        )
        committed = True
        warning = ""
        try:
            for name, expected in published:
                if name == manifest_name:
                    continue
                if not inode_bound_unlink(stage_descriptor, name, expected):
                    raise TransactionError(f"staged asset identity changed after commit: {name}")
            os.fsync(stage_descriptor)
            if identity(os.fstat(stage_descriptor)) == identity(stage_before):
                # Entry removal necessarily changes the directory identity.
                raise TransactionError("stage directory did not record committed entry removal")
            path_metadata = os.stat(stage_name, dir_fd=stage_parent_descriptor, follow_symlinks=False)
            opened_metadata = os.fstat(stage_descriptor)
            if (path_metadata.st_dev, path_metadata.st_ino) != (
                opened_metadata.st_dev, opened_metadata.st_ino
            ):
                raise TransactionError("stage directory path changed after commit")
            os.rmdir(stage_name, dir_fd=stage_parent_descriptor)
            os.fsync(stage_parent_descriptor)
            if set(os.listdir(destination_descriptor)) != set(names):
                raise TransactionError("release destination membership differs after stage cleanup")
            for name, expected in published:
                final = os.stat(name, dir_fd=destination_descriptor, follow_symlinks=False)
                if (
                    not stat.S_ISREG(final.st_mode)
                    or final.st_nlink != 1
                    or (final.st_dev, final.st_ino) != expected
                ):
                    raise TransactionError(
                        f"published release asset differs after stage cleanup: {name}"
                    )
        except Exception as error:
            warning = f": retained stage cleanup required: {error}"
        return "COMMITTED" + warning
    except Exception:
        if not committed:
            rollback_failures = []
            for name, expected in reversed(published):
                try:
                    if not inode_bound_unlink(destination_descriptor, name, expected):
                        rollback_failures.append(name)
                except OSError:
                    rollback_failures.append(name)
            try:
                os.fsync(destination_descriptor)
            except OSError:
                rollback_failures.append("<directory-fsync>")
            if rollback_failures:
                raise TransactionError(
                    "publication failed before commit and exact-inode rollback was incomplete: "
                    + ", ".join(rollback_failures)
                )
        raise
    finally:
        for descriptor, _ in opened.values():
            os.close(descriptor)
        os.close(stage_descriptor)
        os.close(stage_parent_descriptor)
        os.close(destination_descriptor)


def discard_stage(stage_dir: Path) -> None:
    parent_descriptor, stage_name = open_parent(stage_dir)
    stage_descriptor = -1
    opened: dict[str, tuple[int, os.stat_result]] = {}
    try:
        if STAGE_PATTERN.fullmatch(stage_name) is None:
            raise TransactionError("refusing to discard a path outside the private release-stage namespace")
        stage_descriptor = os.open(
            stage_name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=parent_descriptor,
        )
        stage_identity = os.fstat(stage_descriptor)
        names = sorted(os.listdir(stage_descriptor))
        opened = open_set_files(stage_descriptor, names)
        for name in names:
            expected = opened[name][1]
            if not inode_bound_unlink(
                stage_descriptor, name, (expected.st_dev, expected.st_ino)
            ):
                raise TransactionError(f"staged path changed during discard: {name}")
        os.fsync(stage_descriptor)
        path_identity = os.stat(stage_name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (path_identity.st_dev, path_identity.st_ino) != (
            stage_identity.st_dev, stage_identity.st_ino
        ):
            raise TransactionError("stage directory path changed during discard")
        os.rmdir(stage_name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)
    finally:
        for descriptor, _ in opened.values():
            os.close(descriptor)
        if stage_descriptor >= 0:
            os.close(stage_descriptor)
        os.close(parent_descriptor)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="operation", required=True)
    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument("--input", required=True, type=Path)
    snapshot_parser.add_argument("--snapshot-dir", required=True, type=Path)
    stage_parser = subparsers.add_parser("create-stage")
    stage_parser.add_argument("--destination-dmg", required=True, type=Path)
    publish_parser = subparsers.add_parser("publish")
    publish_parser.add_argument("--stage-dir", required=True, type=Path)
    publish_parser.add_argument("--destination-dmg", required=True, type=Path)
    discard_parser = subparsers.add_parser("discard-stage")
    discard_parser.add_argument("--stage-dir", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.operation == "snapshot":
            print(snapshot(arguments.input, arguments.snapshot_dir))
        elif arguments.operation == "create-stage":
            print(create_stage(arguments.destination_dmg))
        elif arguments.operation == "publish":
            result = publish(arguments.stage_dir, arguments.destination_dmg)
            if result == "COMMITTED":
                print(result)
            elif result.startswith("COMMITTED:"):
                print("COMMITTED")
                print(f"warning: public release set committed{result.removeprefix('COMMITTED')}", file=sys.stderr)
            else:
                raise TransactionError(f"unexpected publication result: {result}")
        else:
            discard_stage(arguments.stage_dir)
    except (OSError, TransactionError) as error:
        print(f"error: invalid public release set transaction: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
