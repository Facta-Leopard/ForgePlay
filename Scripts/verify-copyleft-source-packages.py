#!/usr/bin/env python3
"""Verify source-package delivery for bundled dynamic GPL/LGPL libraries.

This verifier intentionally uses only project-owned lock/SBOM metadata and the
source-package bytes supplied for release. It does not inspect shipped binaries.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import stat
import sys
import tarfile
from pathlib import Path, PurePosixPath


COPYLEFT_PATTERN = re.compile(r"(?:^|[^A-Z])L?GPL-")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
MATERIAL_CLASSES = {"corresponding-source", "build-recipe", "relinking-materials"}
RECEIPT_KIND = "forgeplay-copyleft-source-package-v1"
RECEIPT_KEYS = {
    "receiptKind",
    "inventorySHA256",
    "runtimeSBOMSHA256",
    "dependencyLockSHA256",
    "gstreamerLockSHA256",
    "hostSupportPayloadFingerprint",
    "sourceTree",
    "archive",
}


class VerificationError(Exception):
    pass


def _publication_precommit_seam(
    _event: str, _parent_descriptor: int, _receipt_name: str
) -> None:
    """Deterministic no-op seam for publication race regression tests."""


def stable_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def open_path_without_symlinks(path: Path, *, directory: bool) -> int:
    requested = Path(os.path.abspath(path))
    if requested == Path("/"):
        if directory:
            return os.open("/", os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY)
        raise OSError("the filesystem root is not a regular file")
    parts = requested.parts[1:]
    aliases = {
        "tmp": ("/tmp", {"private/tmp", "/private/tmp"}, ("private", "tmp")),
        "var": ("/var", {"private/var", "/private/var"}, ("private", "var")),
    }
    if parts and parts[0] in aliases:
        alias_path, allowed_targets, physical_prefix = aliases[parts[0]]
        try:
            alias_metadata = os.lstat(alias_path)
        except OSError as error:
            raise OSError(f"trusted {alias_path} path is unavailable: {error}") from error
        if stat.S_ISLNK(alias_metadata.st_mode):
            alias_target = os.readlink(alias_path)
            if alias_target not in allowed_targets:
                raise OSError(
                    f"{alias_path} is not the exact trusted macOS /private/{parts[0]} alias"
                )
            parts = (*physical_prefix, *parts[1:])
        elif not stat.S_ISDIR(alias_metadata.st_mode):
            raise OSError(f"trusted {alias_path} path is not a directory")
    descriptor = os.open("/", os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY)
    try:
        for index, part in enumerate(parts):
            final = index == len(parts) - 1
            flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
            if not final or directory:
                flags |= os.O_DIRECTORY
            next_descriptor = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def stable_read(path: Path, label: str) -> bytes:
    try:
        descriptor = open_path_without_symlinks(path, directory=False)
    except OSError as error:
        raise VerificationError(f"{label} is unavailable: {path}: {error}") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise VerificationError(
                f"{label} must be a single-link non-symlink regular file: {path}"
            )
        chunks: list[bytes] = []
        total = 0
        while chunk := os.read(descriptor, 1024 * 1024):
            chunks.append(chunk)
            total += len(chunk)
        after = os.fstat(descriptor)
        if stable_identity(before) != stable_identity(after) or total != before.st_size:
            raise VerificationError(f"{label} changed while being read: {path}")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def load_json_with_raw(path: Path, label: str) -> tuple[dict, bytes]:
    raw = stable_read(path, label)
    try:
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"{label} is not valid UTF-8 JSON: {path}: {error}") from error
    if not isinstance(value, dict):
        raise VerificationError(f"{label} root must be an object")
    return value, raw


def load_json(path: Path, label: str) -> dict:
    return load_json_with_raw(path, label)[0]


def sha256_descriptor(descriptor: int, relative_path: str) -> str:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise VerificationError(
            f"required material is not a single-link regular file: {relative_path}"
        )
    digest = hashlib.sha256()
    total = 0
    while chunk := os.read(descriptor, 1024 * 1024):
        digest.update(chunk)
        total += len(chunk)
    after = os.fstat(descriptor)
    if stable_identity(before) != stable_identity(after) or total != before.st_size:
        raise VerificationError(f"required material changed while hashing: {relative_path}")
    return digest.hexdigest()


def verify_source_tree(
    source_root: Path,
    expected_sha256: dict[str, str],
) -> list[str]:
    expected_files = set(expected_sha256)
    expected_directories = {
        PurePosixPath(*PurePosixPath(relative).parts[:index]).as_posix()
        for relative in expected_files
        for index in range(1, len(PurePosixPath(relative).parts))
    }
    actual_files: set[str] = set()
    failures: list[str] = []
    try:
        root_descriptor = open_path_without_symlinks(source_root, directory=True)
    except OSError as error:
        raise VerificationError(f"source-package root is unavailable: {source_root}: {error}") from error

    def walk(directory_descriptor: int, parent_parts: tuple[str, ...]) -> None:
        before_directory = os.fstat(directory_descriptor)
        if not stat.S_ISDIR(before_directory.st_mode):
            raise VerificationError("source-package traversal left its directory root")
        try:
            names = sorted(os.listdir(directory_descriptor))
        except OSError as error:
            raise VerificationError(f"source-package directory is unreadable: {error}") from error
        for name in names:
            relative_parts = (*parent_parts, name)
            relative = PurePosixPath(*relative_parts).as_posix()
            try:
                metadata = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            except OSError as error:
                raise VerificationError(
                    f"source-package entry changed during traversal: {relative}: {error}"
                ) from error
            if stat.S_ISLNK(metadata.st_mode):
                raise VerificationError(f"source-package tree contains a symlink: {relative}")
            if stat.S_ISDIR(metadata.st_mode):
                if relative not in expected_directories:
                    raise VerificationError(f"source-package tree contains an unlisted directory: {relative}")
                try:
                    child_descriptor = os.open(
                        name,
                        os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=directory_descriptor,
                    )
                except OSError as error:
                    raise VerificationError(
                        f"source-package directory is unsafe: {relative}: {error}"
                    ) from error
                try:
                    opened = os.fstat(child_descriptor)
                    if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                        raise VerificationError(
                            f"source-package directory changed during open: {relative}"
                        )
                    walk(child_descriptor, relative_parts)
                finally:
                    os.close(child_descriptor)
                continue
            if not stat.S_ISREG(metadata.st_mode):
                raise VerificationError(f"source-package tree contains a special file: {relative}")
            if metadata.st_nlink != 1:
                raise VerificationError(f"source-package tree contains a hardlink: {relative}")
            if relative not in expected_files:
                raise VerificationError(f"source-package tree contains an unlisted file: {relative}")
            try:
                file_descriptor = os.open(
                    name,
                    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                    dir_fd=directory_descriptor,
                )
            except OSError as error:
                raise VerificationError(
                    f"required material is unsafe: {relative}: {error}"
                ) from error
            try:
                opened = os.fstat(file_descriptor)
                if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                    raise VerificationError(f"required material changed during open: {relative}")
                actual_sha256 = sha256_descriptor(file_descriptor, relative)
            finally:
                os.close(file_descriptor)
            actual_files.add(relative)
            if actual_sha256 != expected_sha256[relative]:
                failures.append(
                    "required material SHA-256 differs: "
                    f"{relative}: expected={expected_sha256[relative]} actual={actual_sha256}"
                )
        after_directory = os.fstat(directory_descriptor)
        if stable_identity(before_directory) != stable_identity(after_directory):
            raise VerificationError(
                "source-package directory changed during traversal: "
                + (PurePosixPath(*parent_parts).as_posix() if parent_parts else ".")
            )

    try:
        walk(root_descriptor, ())
    finally:
        os.close(root_descriptor)
    for relative in sorted(expected_files - actual_files):
        failures.append(f"required material is absent: {relative}")
    return failures


class DescriptorReader:
    def __init__(self, descriptor: int) -> None:
        self.descriptor = descriptor
        self.digest = hashlib.sha256()
        self.byte_count = 0

    def read(self, size: int = -1) -> bytes:
        if size is None or size < 0:
            size = 1024 * 1024
        chunk = os.read(self.descriptor, size)
        self.digest.update(chunk)
        self.byte_count += len(chunk)
        return chunk


def source_tree_projection(entries: list[dict]) -> dict:
    ordered = sorted(entries, key=lambda entry: entry["path"])
    return {
        "entries": ordered,
        "fileCount": len(ordered),
        "byteCount": sum(entry["byteCount"] for entry in ordered),
        "treeSHA256": hashlib.sha256(canonical_json(ordered)).hexdigest(),
    }


def expected_tree_paths(expected_sha256: dict[str, str]) -> tuple[set[str], set[str]]:
    files = set(expected_sha256)
    directories = {
        PurePosixPath(*PurePosixPath(relative).parts[:index]).as_posix()
        for relative in files
        for index in range(1, len(PurePosixPath(relative).parts))
    }
    return files, directories


def open_output_parent(path: Path, label: str) -> tuple[int, str]:
    absolute = Path(os.path.abspath(path))
    name = absolute.name
    if not name or name in {".", ".."}:
        raise VerificationError(f"{label} has no safe final filename: {path}")
    try:
        parent_descriptor = open_path_without_symlinks(absolute.parent, directory=True)
    except OSError as error:
        raise VerificationError(f"{label} parent is unavailable: {absolute.parent}: {error}") from error
    try:
        try:
            os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        except FileNotFoundError:
            return parent_descriptor, name
        raise VerificationError(f"{label} final path must be absent: {absolute}")
    except Exception:
        os.close(parent_descriptor)
        raise


def revalidate_output_parent(path: Path, descriptor: int, label: str) -> None:
    absolute = Path(os.path.abspath(path))
    try:
        rebound = open_path_without_symlinks(absolute.parent, directory=True)
    except OSError as error:
        raise VerificationError(f"{label} parent path is unavailable: {error}") from error
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
            raise VerificationError(f"{label} parent path identity changed before commit")
    finally:
        os.close(rebound)


def create_output_temp(parent_descriptor: int, final_name: str, label: str) -> tuple[int, str]:
    for _ in range(32):
        temp_name = f".{final_name}.tmp.{secrets.token_hex(12)}"
        try:
            descriptor = os.open(
                temp_name,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
                dir_fd=parent_descriptor,
            )
            return descriptor, temp_name
        except FileExistsError:
            continue
    raise VerificationError(f"{label} temporary output name could not be allocated")


def publish_output(
    parent_descriptor: int,
    temp_name: str,
    final_name: str,
    descriptor: int,
    label: str,
) -> None:
    os.fchmod(descriptor, 0o644)
    os.fsync(descriptor)
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise VerificationError(f"{label} temporary output is not a single-link regular file")
    try:
        os.link(
            temp_name,
            final_name,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    except FileExistsError as error:
        raise VerificationError(f"{label} final path appeared during publication") from error
    os.unlink(temp_name, dir_fd=parent_descriptor)
    os.fsync(parent_descriptor)
    final_metadata = os.stat(final_name, dir_fd=parent_descriptor, follow_symlinks=False)
    if not stat.S_ISREG(final_metadata.st_mode) or final_metadata.st_nlink != 1:
        raise VerificationError(f"{label} published output is not a single-link regular file")


def rollback_published_output(
    parent_descriptor: int,
    final_name: str,
    expected: tuple[int, int],
) -> bool:
    try:
        metadata = os.stat(final_name, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return True
    if (metadata.st_dev, metadata.st_ino) != expected:
        return False
    os.unlink(final_name, dir_fd=parent_descriptor)
    return True


def hash_descriptor(descriptor: int, label: str) -> tuple[int, str]:
    os.lseek(descriptor, 0, os.SEEK_SET)
    before = os.fstat(descriptor)
    digest = hashlib.sha256()
    byte_count = 0
    while chunk := os.read(descriptor, 1024 * 1024):
        digest.update(chunk)
        byte_count += len(chunk)
    after = os.fstat(descriptor)
    if stable_identity(before) != stable_identity(after) or byte_count != before.st_size:
        raise VerificationError(f"{label} changed while hashing")
    return byte_count, digest.hexdigest()


def create_source_archive(
    source_root: Path,
    expected_sha256: dict[str, str],
    archive_out: Path,
    receipt_out: Path,
    receipt_inputs: dict[str, str],
    host_support_payload_fingerprint: str,
) -> dict:
    archive_parent, archive_name = open_output_parent(archive_out, "source archive")
    try:
        receipt_parent, receipt_name = open_output_parent(receipt_out, "source receipt")
    except Exception:
        os.close(archive_parent)
        raise
    archive_parent_metadata = os.fstat(archive_parent)
    receipt_parent_metadata = os.fstat(receipt_parent)
    if (archive_parent_metadata.st_dev, archive_parent_metadata.st_ino) != (
        receipt_parent_metadata.st_dev, receipt_parent_metadata.st_ino
    ):
        os.close(archive_parent)
        os.close(receipt_parent)
        raise VerificationError("source archive and receipt outputs must share one exact parent")
    if archive_name == receipt_name:
        os.close(archive_parent)
        os.close(receipt_parent)
        raise VerificationError("source archive and receipt outputs must be distinct")

    archive_descriptor = -1
    receipt_descriptor = -1
    archive_temp = ""
    receipt_temp = ""
    committed = False
    try:
        archive_descriptor, archive_temp = create_output_temp(
            archive_parent, archive_name, "source archive"
        )
        try:
            root_descriptor = open_path_without_symlinks(source_root, directory=True)
        except OSError as error:
            raise VerificationError(f"source-package root is unavailable: {source_root}: {error}") from error
        expected_files, expected_directories = expected_tree_paths(expected_sha256)
        actual_files: set[str] = set()
        entries: list[dict] = []
        pending_files: list[tuple[str, int, os.stat_result]] = []
        try:
            def walk(directory_descriptor: int, parent_parts: tuple[str, ...]) -> None:
                before_directory = os.fstat(directory_descriptor)
                names = sorted(os.listdir(directory_descriptor))
                for name in names:
                    relative_parts = (*parent_parts, name)
                    relative = PurePosixPath(*relative_parts).as_posix()
                    metadata = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
                    if stat.S_ISLNK(metadata.st_mode):
                        raise VerificationError(f"source-package tree contains a symlink: {relative}")
                    if stat.S_ISDIR(metadata.st_mode):
                        if relative not in expected_directories:
                            raise VerificationError(f"source-package tree contains an unlisted directory: {relative}")
                        child = os.open(
                            name,
                            os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=directory_descriptor,
                        )
                        try:
                            opened = os.fstat(child)
                            if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                                raise VerificationError(f"source-package directory changed during open: {relative}")
                            walk(child, relative_parts)
                        finally:
                            os.close(child)
                        continue
                    if not stat.S_ISREG(metadata.st_mode):
                        raise VerificationError(f"source-package tree contains a special file: {relative}")
                    if metadata.st_nlink != 1:
                        raise VerificationError(f"source-package tree contains a hardlink: {relative}")
                    if relative not in expected_files:
                        raise VerificationError(f"source-package tree contains an unlisted file: {relative}")
                    file_descriptor = os.open(
                        name,
                        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                        dir_fd=directory_descriptor,
                    )
                    try:
                        opened = os.fstat(file_descriptor)
                        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                            raise VerificationError(f"required material changed during open: {relative}")
                        pending_files.append((relative, file_descriptor, opened))
                        file_descriptor = -1
                        actual_files.add(relative)
                    finally:
                        if file_descriptor >= 0:
                            os.close(file_descriptor)
                after_directory = os.fstat(directory_descriptor)
                if stable_identity(before_directory) != stable_identity(after_directory):
                    current = PurePosixPath(*parent_parts).as_posix() if parent_parts else "."
                    raise VerificationError(f"source-package directory changed during traversal: {current}")

            walk(root_descriptor, ())
            missing = sorted(expected_files - actual_files)
            if missing:
                raise VerificationError(f"required material is absent: {missing}")
            archive_file = os.fdopen(os.dup(archive_descriptor), "wb")
            try:
                with tarfile.open(fileobj=archive_file, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                    for relative, file_descriptor, opened in sorted(
                        pending_files, key=lambda value: value[0]
                    ):
                            os.lseek(file_descriptor, 0, os.SEEK_SET)
                            reader = DescriptorReader(file_descriptor)
                            member = tarfile.TarInfo(relative)
                            member.size = opened.st_size
                            member.mode = 0o644
                            member.uid = 0
                            member.gid = 0
                            member.uname = ""
                            member.gname = ""
                            member.mtime = 0
                            archive.addfile(member, reader)
                            after = os.fstat(file_descriptor)
                            if stable_identity(opened) != stable_identity(after) or reader.byte_count != opened.st_size:
                                raise VerificationError(f"required material changed while archiving: {relative}")
                            actual_sha256 = reader.digest.hexdigest()
                            if actual_sha256 != expected_sha256[relative]:
                                raise VerificationError(
                                    f"required material SHA-256 differs: {relative}: "
                                    f"expected={expected_sha256[relative]} actual={actual_sha256}"
                                )
                            entries.append({
                                "path": relative,
                                "byteCount": reader.byte_count,
                                "sha256": actual_sha256,
                            })
            finally:
                archive_file.close()
        finally:
            os.close(root_descriptor)
            for _, file_descriptor, _ in pending_files:
                os.close(file_descriptor)
        archive_size, archive_sha256 = hash_descriptor(archive_descriptor, "source archive")
        source_tree = source_tree_projection(entries)
        receipt = {
            "receiptKind": RECEIPT_KIND,
            **receipt_inputs,
            "hostSupportPayloadFingerprint": host_support_payload_fingerprint,
            "sourceTree": source_tree,
            "archive": {
                "fileName": archive_name,
                "format": "ustar",
                "byteCount": archive_size,
                "sha256": archive_sha256,
            },
        }
        receipt_descriptor, receipt_temp = create_output_temp(
            receipt_parent, receipt_name, "source receipt"
        )
        receipt_raw = canonical_json(receipt)
        written = 0
        while written < len(receipt_raw):
            count = os.write(receipt_descriptor, receipt_raw[written:])
            if count <= 0:
                raise VerificationError("source receipt could not be written completely")
            written += count
        os.fchmod(archive_descriptor, 0o644)
        os.fchmod(receipt_descriptor, 0o644)
        os.fsync(archive_descriptor)
        os.fsync(receipt_descriptor)
        archive_metadata = os.fstat(archive_descriptor)
        receipt_metadata = os.fstat(receipt_descriptor)
        archive_identity = (archive_metadata.st_dev, archive_metadata.st_ino)
        receipt_identity = (receipt_metadata.st_dev, receipt_metadata.st_ino)
        archive_published = False
        receipt_published = False
        try:
            os.link(
                archive_temp,
                archive_name,
                src_dir_fd=archive_parent,
                dst_dir_fd=archive_parent,
                follow_symlinks=False,
            )
            archive_published = True
            final_archive = os.stat(
                archive_name, dir_fd=archive_parent, follow_symlinks=False
            )
            if (final_archive.st_dev, final_archive.st_ino) != archive_identity:
                raise VerificationError("source archive final identity differs before commit")
            os.unlink(archive_temp, dir_fd=archive_parent)
            archive_temp = ""
            os.fsync(archive_parent)
            final_archive = os.stat(
                archive_name, dir_fd=archive_parent, follow_symlinks=False
            )
            if (final_archive.st_dev, final_archive.st_ino) != archive_identity:
                raise VerificationError("source archive was replaced before receipt commit")
            os.link(
                receipt_temp,
                receipt_name,
                src_dir_fd=receipt_parent,
                dst_dir_fd=receipt_parent,
                follow_symlinks=False,
            )
            receipt_published = True
            _publication_precommit_seam("receipt-linked", receipt_parent, receipt_name)
            final_receipt = os.stat(
                receipt_name, dir_fd=receipt_parent, follow_symlinks=False
            )
            if (final_receipt.st_dev, final_receipt.st_ino) != receipt_identity:
                raise VerificationError("source receipt final identity differs before commit")
            receipt_temp_name = receipt_temp
            os.unlink(receipt_temp_name, dir_fd=receipt_parent)
            try:
                os.stat(receipt_temp_name, dir_fd=receipt_parent, follow_symlinks=False)
            except FileNotFoundError:
                receipt_temp = ""
            else:
                raise VerificationError("source receipt staging hardlink remains before commit")
            final_receipt = os.stat(
                receipt_name, dir_fd=receipt_parent, follow_symlinks=False
            )
            final_archive = os.stat(
                archive_name, dir_fd=archive_parent, follow_symlinks=False
            )
            if (
                not stat.S_ISREG(final_receipt.st_mode)
                or final_receipt.st_nlink != 1
                or (final_receipt.st_dev, final_receipt.st_ino) != receipt_identity
            ):
                raise VerificationError("source receipt is not the expected single-link final before commit")
            if (
                not stat.S_ISREG(final_archive.st_mode)
                or final_archive.st_nlink != 1
                or (final_archive.st_dev, final_archive.st_ino) != archive_identity
            ):
                raise VerificationError("source archive is not the expected single-link final before commit")
            _publication_precommit_seam("before-parent-fsync", receipt_parent, receipt_name)
            revalidate_output_parent(archive_out, archive_parent, "source archive")
            revalidate_output_parent(receipt_out, receipt_parent, "source receipt")
            os.fsync(receipt_parent)
            revalidate_output_parent(archive_out, archive_parent, "source archive")
            revalidate_output_parent(receipt_out, receipt_parent, "source receipt")
            committed = True
        except Exception:
            if not committed:
                rollback_failures = []
                for published, name, expected in (
                    (receipt_published, receipt_name, receipt_identity),
                    (archive_published, archive_name, archive_identity),
                ):
                    if not published:
                        continue
                    try:
                        if not rollback_published_output(receipt_parent, name, expected):
                            rollback_failures.append(name)
                    except OSError:
                        rollback_failures.append(name)
                try:
                    os.fsync(receipt_parent)
                except OSError:
                    rollback_failures.append("<parent-fsync>")
                if rollback_failures:
                    raise VerificationError(
                        "source publication failed before receipt commit and exact-inode rollback was incomplete: "
                        + ", ".join(rollback_failures)
                    )
            raise
        return receipt
    finally:
        if archive_descriptor >= 0:
            os.close(archive_descriptor)
        if receipt_descriptor >= 0:
            os.close(receipt_descriptor)
        if archive_temp and not committed:
            try:
                os.unlink(archive_temp, dir_fd=archive_parent)
            except FileNotFoundError:
                pass
        if receipt_temp and not committed:
            try:
                os.unlink(receipt_temp, dir_fd=receipt_parent)
            except FileNotFoundError:
                pass
        os.close(archive_parent)
        os.close(receipt_parent)


def parse_ustar_octal(field: bytes, label: str) -> int:
    if field and field[0] & 0x80:
        raise VerificationError(f"USTAR {label} uses base-256 encoding")
    value = field.rstrip(b"\0 ").lstrip(b" ")
    if not value:
        return 0
    if any(byte not in b"01234567" for byte in value):
        raise VerificationError(f"USTAR {label} is not canonical octal")
    return int(value, 8)


def decode_ustar_text(field: bytes, label: str) -> str:
    raw = field.split(b"\0", 1)[0]
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError(f"USTAR {label} is not UTF-8") from error


def parse_exact_ustar(descriptor: int, expected_size: int) -> list[dict]:
    if expected_size <= 0 or expected_size % 10240 != 0:
        raise VerificationError("source archive size is not canonical USTAR blocking")
    os.lseek(descriptor, 0, os.SEEK_SET)
    entries: list[dict] = []
    names: list[str] = []
    zero_blocks = 0
    ended = False
    consumed = 0
    while consumed < expected_size:
        header = os.read(descriptor, 512)
        if len(header) != 512:
            raise VerificationError("source archive has a truncated 512-byte block")
        consumed += 512
        if header == b"\0" * 512:
            zero_blocks += 1
            if zero_blocks >= 2:
                ended = True
            continue
        if zero_blocks or ended:
            raise VerificationError("source archive contains data after its end marker")
        if header[257:263] != b"ustar\0" or header[263:265] != b"00":
            raise VerificationError("source archive is not canonical USTAR")
        expected_checksum = parse_ustar_octal(header[148:156], "checksum")
        checksum_header = header[:148] + b" " * 8 + header[156:]
        if sum(checksum_header) != expected_checksum:
            raise VerificationError("source archive header checksum is invalid")
        name = decode_ustar_text(header[0:100], "name")
        prefix = decode_ustar_text(header[345:500], "prefix")
        full_name = f"{prefix}/{name}" if prefix else name
        if not valid_delivery_path(full_name):
            raise VerificationError(f"source archive path is unsafe: {full_name}")
        if full_name in names:
            raise VerificationError(f"source archive contains a duplicate entry: {full_name}")
        if header[156:157] != b"0":
            raise VerificationError(
                f"source archive contains a link, directory, special, GNU, or PAX entry: {full_name}"
            )
        if any(
            header[start:end].strip(b"\0 ")
            for start, end in ((157, 257), (329, 337), (337, 345))
        ):
            raise VerificationError(f"source archive contains link/device metadata: {full_name}")
        mode = parse_ustar_octal(header[100:108], "mode")
        uid = parse_ustar_octal(header[108:116], "uid")
        gid = parse_ustar_octal(header[116:124], "gid")
        size = parse_ustar_octal(header[124:136], "size")
        mtime = parse_ustar_octal(header[136:148], "mtime")
        uname = decode_ustar_text(header[265:297], "uname")
        gname = decode_ustar_text(header[297:329], "gname")
        if mode != 0o644 or uid != 0 or gid != 0 or mtime != 0 or uname or gname:
            raise VerificationError(f"source archive metadata is not normalized: {full_name}")
        digest = hashlib.sha256()
        remaining = size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise VerificationError(f"source archive payload is truncated: {full_name}")
            remaining -= len(chunk)
            consumed += len(chunk)
            digest.update(chunk)
        padding = (-size) % 512
        if padding:
            padding_bytes = os.read(descriptor, padding)
            consumed += len(padding_bytes)
            if len(padding_bytes) != padding or padding_bytes != b"\0" * padding:
                raise VerificationError(f"source archive payload padding is invalid: {full_name}")
        names.append(full_name)
        entries.append({"path": full_name, "byteCount": size, "sha256": digest.hexdigest()})
    if consumed != expected_size or not ended or zero_blocks < 2:
        raise VerificationError("source archive lacks an exact two-zero-block end marker")
    if names != sorted(names):
        raise VerificationError("source archive entries are not in canonical global path order")
    return entries


def verify_archive_against_receipt(archive_path: Path, receipt: dict) -> None:
    archive_binding = receipt["archive"]
    if archive_binding.get("fileName") != archive_path.name:
        raise VerificationError("source archive filename differs from receipt")
    try:
        descriptor = open_path_without_symlinks(archive_path, directory=False)
    except OSError as error:
        raise VerificationError(f"source archive is unavailable: {archive_path}: {error}") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise VerificationError("source archive must be a single-link regular file")
        byte_count, sha256 = hash_descriptor(descriptor, "source archive")
        if byte_count != archive_binding.get("byteCount") or sha256 != archive_binding.get("sha256"):
            raise VerificationError("source archive byte identity differs from receipt")
        expected_entries = receipt["sourceTree"]["entries"]
        actual_entries = parse_exact_ustar(descriptor, byte_count)
        if actual_entries != expected_entries:
            raise VerificationError("source archive entries differ from receipt")
        if source_tree_projection(actual_entries) != receipt["sourceTree"]:
            raise VerificationError("source archive tree identity differs from receipt")
        after = os.fstat(descriptor)
        if stable_identity(before) != stable_identity(after):
            raise VerificationError("source archive changed during verification")
    finally:
        os.close(descriptor)


def copyleft(expression: object) -> bool:
    return isinstance(expression, str) and COPYLEFT_PATTERN.search(expression) is not None


def lock_consumers(dependency_lock: dict, gstreamer_lock: dict) -> dict[str, dict]:
    consumers: dict[str, dict] = {}
    for authority, lock, name_key, version_key in (
        ("homebrew", dependency_lock, "formula", "formulaVersion"),
        ("gstreamer", gstreamer_lock, "component", "componentVersion"),
    ):
        artifacts = lock.get("artifacts")
        if not isinstance(artifacts, list):
            raise VerificationError(f"{authority} lock artifacts must be an array")
        for artifact in artifacts:
            if not isinstance(artifact, dict) or not copyleft(artifact.get("licenseExpression")):
                continue
            name = artifact.get(name_key)
            version = artifact.get(version_key)
            target_path = artifact.get("targetPath")
            license_expression = artifact.get("licenseExpression")
            if not all(isinstance(value, str) and value for value in (name, version, target_path)):
                raise VerificationError(f"{authority} copyleft artifact identity is incomplete")
            key = f"{authority}:{name}@{version}"
            row = consumers.setdefault(
                key,
                {"licenseExpressions": set(), "artifactPaths": set(), "authority": authority},
            )
            row["licenseExpressions"].add(license_expression)
            row["artifactPaths"].add(target_path)
    return consumers


def verify_sbom(runtime_sbom: dict, consumers: dict[str, dict]) -> None:
    entries = runtime_sbom.get("hostSupportPayload")
    if not isinstance(entries, list):
        raise VerificationError("Runtime SBOM hostSupportPayload must be an array")
    by_path = {
        entry.get("path"): entry
        for entry in entries
        if isinstance(entry, dict) and isinstance(entry.get("path"), str)
    }
    expected_paths: set[str] = set()
    for key, consumer in consumers.items():
        authority, identity = key.split(":", 1)
        name, version = identity.rsplit("@", 1)
        expected_source_kind = {
            "gstreamer": "gstreamer-official-macos-universal-sdk",
            "homebrew": "homebrew-core-prebuilt-package",
        }[authority]
        for target_path in consumer["artifactPaths"]:
            expected_paths.add(target_path)
            entry = by_path.get(target_path)
            if not isinstance(entry, dict):
                raise VerificationError(f"Runtime SBOM lacks locked copyleft artifact: {target_path}")
            if (
                entry.get("component") != name
                or entry.get("version") != version
                or entry.get("licenseExpression") not in consumer["licenseExpressions"]
                or entry.get("sourceKind") != expected_source_kind
                or not isinstance(entry.get("contentSHA256"), str)
            ):
                raise VerificationError(f"Runtime SBOM copyleft identity differs from lock: {target_path}")
    sbom_copyleft_binaries = {
        entry.get("path")
        for entry in entries
        if isinstance(entry, dict)
        and copyleft(entry.get("licenseExpression"))
        and isinstance(entry.get("path"), str)
        and entry["path"].endswith(".dylib")
    }
    if sbom_copyleft_binaries != expected_paths:
        raise VerificationError(
            "Runtime SBOM/lock copyleft dynamic artifact set differs: "
            f"missing={sorted(expected_paths - sbom_copyleft_binaries)}, "
            f"unexpected={sorted(sbom_copyleft_binaries - expected_paths)}"
        )


def valid_delivery_path(value: object) -> bool:
    if not isinstance(value, str) or not value or "\\" in value:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and all(part not in {"", ".", ".."} for part in path.parts)


def verify_inventory(inventory: dict, consumers: dict[str, dict]) -> dict[str, str]:
    if set(inventory) != {"schemaVersion", "deliveryContract", "consumers", "requirements"}:
        raise VerificationError("source-package inventory top-level schema is invalid")
    if inventory.get("schemaVersion") != 1:
        raise VerificationError("source-package inventory schemaVersion must be 1")
    contract = inventory.get("deliveryContract")
    if not isinstance(contract, dict) or contract != {
        "defaultSiblingSourceRoot": "ThirdPartyCorrespondingSource",
        "distributionMode": "simultaneous-source-package",
        "linkageEvidence": "declared-dynamic-library-paths-from-locks-and-runtime-sbom",
        "releaseStatus": "fail-closed-until-all-required-materials-are-pinned-and-present",
    }:
        raise VerificationError("source-package delivery contract is invalid")

    requirements = inventory.get("requirements")
    consumer_rows = inventory.get("consumers")
    if not isinstance(requirements, list) or not isinstance(consumer_rows, list):
        raise VerificationError("inventory consumers and requirements must be arrays")

    requirements_by_id: dict[str, dict] = {}
    requirement_consumers: dict[str, set[str]] = {}
    delivery_paths: set[str] = set()
    for requirement in requirements:
        if not isinstance(requirement, dict) or set(requirement) != {
            "id", "materialClass", "sourceKind", "version", "deliveryPath",
            "sourceURL", "sha256", "status", "consumerBindings",
        }:
            raise VerificationError("source-package requirement schema is invalid")
        identifier = requirement.get("id")
        if not isinstance(identifier, str) or not identifier or identifier in requirements_by_id:
            raise VerificationError(f"source-package requirement id is invalid or duplicated: {identifier}")
        if requirement.get("materialClass") not in MATERIAL_CLASSES:
            raise VerificationError(f"source-package material class is invalid: {identifier}")
        if not valid_delivery_path(requirement.get("deliveryPath")):
            raise VerificationError(f"source-package delivery path is unsafe: {identifier}")
        if requirement["deliveryPath"] in delivery_paths:
            raise VerificationError(
                f"source-package delivery path is duplicated: {requirement['deliveryPath']}"
            )
        delivery_paths.add(requirement["deliveryPath"])
        if not isinstance(requirement.get("sourceKind"), str) or not requirement["sourceKind"]:
            raise VerificationError(f"source-package source kind is missing: {identifier}")
        if not isinstance(requirement.get("version"), str) or not requirement["version"]:
            raise VerificationError(f"source-package version is missing: {identifier}")
        bindings = requirement.get("consumerBindings")
        if not isinstance(bindings, list) or not bindings:
            raise VerificationError(f"source-package consumer bindings are missing: {identifier}")
        binding_keys: set[str] = set()
        for binding in bindings:
            if not isinstance(binding, dict) or set(binding) != {
                "authority", "component", "version"
            }:
                raise VerificationError(
                    f"source-package consumer binding schema is invalid: {identifier}"
                )
            authority = binding.get("authority")
            component = binding.get("component")
            version = binding.get("version")
            if not all(
                isinstance(value, str) and value
                for value in (authority, component, version)
            ):
                raise VerificationError(
                    f"source-package consumer binding identity is incomplete: {identifier}"
                )
            key = f"{authority}:{component}@{version}"
            if key in binding_keys:
                raise VerificationError(
                    f"source-package consumer binding is duplicated: {identifier}: {key}"
                )
            binding_keys.add(key)
        requirement_consumers[identifier] = binding_keys
        requirements_by_id[identifier] = requirement

    declared_consumers: dict[str, list[str]] = {}
    for consumer in consumer_rows:
        if not isinstance(consumer, dict) or set(consumer) != {"key", "requiredRequirementIds"}:
            raise VerificationError("source-package consumer schema is invalid")
        key = consumer.get("key")
        required_ids = consumer.get("requiredRequirementIds")
        if (
            not isinstance(key, str)
            or key in declared_consumers
            or not isinstance(required_ids, list)
            or not required_ids
            or any(not isinstance(value, str) or not value for value in required_ids)
            or len(set(required_ids)) != len(required_ids)
        ):
            raise VerificationError(f"source-package consumer requirement list is invalid: {key}")
        missing_ids = sorted(set(required_ids) - set(requirements_by_id))
        if missing_ids:
            raise VerificationError(f"source-package consumer references unknown requirements: {key}: {missing_ids}")
        classes = {requirements_by_id[value]["materialClass"] for value in required_ids}
        if classes != MATERIAL_CLASSES:
            raise VerificationError(f"source-package consumer lacks source/build/relinking closure: {key}")
        mismatched_ids = sorted(
            value for value in required_ids
            if key not in requirement_consumers[value]
        )
        if mismatched_ids:
            raise VerificationError(
                f"source-package consumer references material bound to another identity: "
                f"{key}: {mismatched_ids}"
            )
        declared_consumers[key] = required_ids

    if set(declared_consumers) != set(consumers):
        raise VerificationError(
            "source-package consumer coverage differs from copyleft locks: "
            f"missing={sorted(set(consumers) - set(declared_consumers))}, "
            f"unexpected={sorted(set(declared_consumers) - set(consumers))}"
        )
    referenced_ids = {value for values in declared_consumers.values() for value in values}
    if referenced_ids != set(requirements_by_id):
        raise VerificationError(
            f"source-package requirements must be used exactly; unused={sorted(set(requirements_by_id) - referenced_ids)}"
        )

    for identifier, binding_keys in requirement_consumers.items():
        unknown = sorted(binding_keys - set(consumers))
        actual = {
            key for key, required_ids in declared_consumers.items()
            if identifier in required_ids
        }
        if unknown or actual != binding_keys:
            raise VerificationError(
                f"source-package requirement consumer binding differs: {identifier}: "
                f"unknown={unknown}, missing={sorted(binding_keys - actual)}, "
                f"unexpected={sorted(actual - binding_keys)}"
            )

    failures: list[str] = []
    pinned_materials: dict[str, str] = {}
    for identifier, requirement in requirements_by_id.items():
        if requirement.get("status") != "pinned":
            failures.append(f"required material is unresolved: {identifier}")
            continue
        sha256 = requirement.get("sha256")
        source_url = requirement.get("sourceURL")
        if not isinstance(sha256, str) or SHA256_PATTERN.fullmatch(sha256) is None:
            failures.append(f"required material lacks a pinned SHA-256: {identifier}")
            continue
        if not isinstance(source_url, str) or not source_url.startswith("https://"):
            failures.append(f"required material lacks an HTTPS authority URL: {identifier}")
            continue
        pinned_materials[requirement["deliveryPath"]] = sha256
    if failures:
        raise VerificationError("; ".join(failures))
    return pinned_materials


def validate_receipt(
    receipt: dict,
    receipt_raw: bytes,
    receipt_inputs: dict[str, str],
    host_support_payload_fingerprint: str,
) -> None:
    if receipt_raw != canonical_json(receipt):
        raise VerificationError("source receipt must be canonical indent-2 sorted JSON plus LF")
    if set(receipt) != RECEIPT_KEYS or receipt.get("receiptKind") != RECEIPT_KIND:
        raise VerificationError("source receipt top-level schema is invalid")
    for key, expected in receipt_inputs.items():
        if receipt.get(key) != expected:
            raise VerificationError(f"source receipt {key} differs from current verified input")
    if receipt.get("hostSupportPayloadFingerprint") != host_support_payload_fingerprint:
        raise VerificationError("source receipt hostSupportPayloadFingerprint differs from Runtime SBOM")
    source_tree = receipt.get("sourceTree")
    if not isinstance(source_tree, dict) or set(source_tree) != {
        "entries", "fileCount", "byteCount", "treeSHA256"
    }:
        raise VerificationError("source receipt sourceTree schema is invalid")
    entries = source_tree.get("entries")
    if not isinstance(entries, list):
        raise VerificationError("source receipt sourceTree entries must be an array")
    previous = None
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"path", "byteCount", "sha256"}:
            raise VerificationError("source receipt entry schema is invalid")
        path = entry.get("path")
        if (
            not valid_delivery_path(path)
            or (previous is not None and path <= previous)
            or not isinstance(entry.get("byteCount"), int)
            or isinstance(entry.get("byteCount"), bool)
            or entry["byteCount"] < 0
            or not isinstance(entry.get("sha256"), str)
            or SHA256_PATTERN.fullmatch(entry["sha256"]) is None
        ):
            raise VerificationError(f"source receipt entry value is invalid: {path}")
        previous = path
    if source_tree_projection(entries) != source_tree:
        raise VerificationError("source receipt sourceTree counters or digest are invalid")
    archive = receipt.get("archive")
    if not isinstance(archive, dict) or set(archive) != {
        "fileName", "format", "byteCount", "sha256"
    }:
        raise VerificationError("source receipt archive schema is invalid")
    if (
        not isinstance(archive.get("fileName"), str)
        or Path(archive["fileName"]).name != archive["fileName"]
        or archive.get("format") != "ustar"
        or not isinstance(archive.get("byteCount"), int)
        or isinstance(archive.get("byteCount"), bool)
        or archive["byteCount"] <= 0
        or not isinstance(archive.get("sha256"), str)
        or SHA256_PATTERN.fullmatch(archive["sha256"]) is None
    ):
        raise VerificationError("source receipt archive value is invalid")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--runtime-sbom", required=True, type=Path)
    parser.add_argument("--dependency-lock", required=True, type=Path)
    parser.add_argument("--gstreamer-lock", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--source-root", type=Path)
    mode.add_argument("--archive", type=Path)
    parser.add_argument("--archive-out", type=Path)
    parser.add_argument("--receipt-out", type=Path)
    parser.add_argument("--receipt", type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.source_root is not None:
            if arguments.archive_out is None or arguments.receipt_out is None or arguments.receipt is not None:
                raise VerificationError(
                    "freeze mode requires --source-root, --archive-out, and --receipt-out only"
                )
        elif arguments.receipt is None or arguments.archive_out is not None or arguments.receipt_out is not None:
            raise VerificationError("verify mode requires --archive and --receipt only")
        inventory, inventory_raw = load_json_with_raw(arguments.inventory, "source-package inventory")
        dependency_lock, dependency_lock_raw = load_json_with_raw(
            arguments.dependency_lock, "runtime dependency lock"
        )
        gstreamer_lock, gstreamer_lock_raw = load_json_with_raw(
            arguments.gstreamer_lock, "GStreamer payload lock"
        )
        runtime_sbom, runtime_sbom_raw = load_json_with_raw(arguments.runtime_sbom, "Runtime SBOM")
        consumers = lock_consumers(dependency_lock, gstreamer_lock)
        verify_sbom(runtime_sbom, consumers)
        expected_sha256 = verify_inventory(inventory, consumers)
        host_support_payload_fingerprint = runtime_sbom.get("payloadFingerprint")
        if (
            not isinstance(host_support_payload_fingerprint, str)
            or SHA256_PATTERN.fullmatch(host_support_payload_fingerprint) is None
        ):
            raise VerificationError("Runtime SBOM payloadFingerprint is invalid")
        receipt_inputs = {
            "inventorySHA256": hashlib.sha256(inventory_raw).hexdigest(),
            "runtimeSBOMSHA256": hashlib.sha256(runtime_sbom_raw).hexdigest(),
            "dependencyLockSHA256": hashlib.sha256(dependency_lock_raw).hexdigest(),
            "gstreamerLockSHA256": hashlib.sha256(gstreamer_lock_raw).hexdigest(),
        }
        if arguments.source_root is not None:
            create_source_archive(
                arguments.source_root,
                expected_sha256,
                arguments.archive_out,
                arguments.receipt_out,
                receipt_inputs,
                host_support_payload_fingerprint,
            )
        else:
            receipt, receipt_raw = load_json_with_raw(arguments.receipt, "source receipt")
            validate_receipt(
                receipt,
                receipt_raw,
                receipt_inputs,
                host_support_payload_fingerprint,
            )
            expected_entries = {
                path: sha256 for path, sha256 in expected_sha256.items()
            }
            receipt_entries = {
                entry["path"]: entry["sha256"] for entry in receipt["sourceTree"]["entries"]
            }
            if receipt_entries != expected_entries:
                raise VerificationError("source receipt file set differs from current inventory")
            verify_archive_against_receipt(arguments.archive, receipt)
    except (OSError, VerificationError) as error:
        print(f"error: invalid copyleft source-package delivery: {error}", file=sys.stderr)
        return 1
    operation = "frozen" if arguments.source_root is not None else "verified"
    print(f"ForgePlay copyleft source-package delivery {operation}: {len(consumers)} consumers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
