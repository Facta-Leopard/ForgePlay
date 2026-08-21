#!/usr/bin/env python3
"""Freeze and verify one deterministic ForgePlay Corresponding Source asset."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import secrets
import stat
import sys
import tarfile
from pathlib import Path, PurePosixPath
from typing import Optional


BLOCK_SIZE = 512
BINDING_KIND = "forgeplay-project-corresponding-source-v1"
WINE_IDENTITY_PATH = "Config/ForgePlayRuntimeSourceIdentity.lock.json"
WINE_ARCHIVE_PATH = "CorrespondingSource/Wine/wine-11.12.tar.xz"
SHA256_PATTERN = __import__("re").compile(r"[0-9a-f]{64}")
COMMIT_PATTERN = __import__("re").compile(r"[0-9a-f]{40,64}")


class FreezeError(Exception):
    pass


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


def safe_relative(value: object) -> bool:
    if not isinstance(value, str) or not value or "\\" in value:
        return False
    parsed = PurePosixPath(value)
    return (
        not parsed.is_absolute()
        and value == parsed.as_posix()
        and all(part not in {"", ".", ".."} for part in parsed.parts)
        and all(0x20 <= ord(character) < 0x7F for character in value)
    )


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def normalized_absolute_path(path: Path) -> Path:
    absolute = os.path.abspath(os.fspath(path))
    if sys.platform == "darwin":
        for alias, physical in (("/tmp", "/private/tmp"), ("/var", "/private/var")):
            if absolute == alias or absolute.startswith(alias + "/"):
                absolute = physical + absolute[len(alias):]
                break
    return Path(absolute)


def open_directory_without_symlink_ancestors(path: Path) -> int:
    absolute = normalized_absolute_path(path)
    descriptor = os.open("/", os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY)
    try:
        for part in absolute.parts[1:]:
            next_descriptor = os.open(
                part,
                os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except OSError as error:
        os.close(descriptor)
        raise FreezeError(f"directory or ancestor is unavailable or unsafe: {path}: {error}") from error


def open_final_without_symlinks(path: Path, *, directory: bool) -> int:
    requested = normalized_absolute_path(path)
    if requested == Path("/"):
        if directory:
            return open_directory_without_symlink_ancestors(requested)
        raise FreezeError("the filesystem root is not a regular file")
    parent_descriptor = open_directory_without_symlink_ancestors(requested.parent)
    try:
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
        if directory:
            flags |= os.O_DIRECTORY
        return os.open(requested.name, flags, dir_fd=parent_descriptor)
    except OSError as error:
        raise FreezeError(f"path is unavailable or unsafe: {path}: {error}") from error
    finally:
        os.close(parent_descriptor)


def hash_descriptor(descriptor: int, *, expected_size: Optional[int] = None) -> tuple[str, int]:
    os.lseek(descriptor, 0, os.SEEK_SET)
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise FreezeError("file must be a single-link regular file")
    digest = hashlib.sha256()
    total = 0
    while chunk := os.read(descriptor, 1024 * 1024):
        digest.update(chunk)
        total += len(chunk)
    after = os.fstat(descriptor)
    if (
        stable_identity(before) != stable_identity(after)
        or total != before.st_size
        or (expected_size is not None and total != expected_size)
    ):
        raise FreezeError("file changed while hashing")
    return digest.hexdigest(), total


def read_descriptor(descriptor: int, label: str) -> bytes:
    os.lseek(descriptor, 0, os.SEEK_SET)
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise FreezeError(f"{label} must be a single-link regular file")
    chunks: list[bytes] = []
    total = 0
    while chunk := os.read(descriptor, 1024 * 1024):
        chunks.append(chunk)
        total += len(chunk)
    after = os.fstat(descriptor)
    if stable_identity(before) != stable_identity(after) or total != before.st_size:
        raise FreezeError(f"{label} changed while being read")
    return b"".join(chunks)


def write_all(descriptor: int, data: bytes) -> None:
    offset = 0
    while offset < len(data):
        written = os.write(descriptor, data[offset:])
        if written <= 0:
            raise FreezeError("output write made no progress")
        offset += written


def parse_inventory(raw: bytes) -> tuple[dict, dict[str, dict]]:
    try:
        inventory = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise FreezeError(f"SOURCE-INVENTORY.json is invalid UTF-8 JSON: {error}") from error
    if not isinstance(inventory, dict) or set(inventory) != {
        "entries", "gitObjectFormat", "hashAlgorithm", "inventoryGenerator",
        "inventorySHA256", "releaseCommit", "schemaVersion",
    }:
        raise FreezeError("SOURCE-INVENTORY.json schema is invalid")
    if inventory["schemaVersion"] != 2 or inventory["hashAlgorithm"] != "sha256":
        raise FreezeError("SOURCE-INVENTORY.json policy is unsupported")
    if not isinstance(inventory["inventoryGenerator"], dict):
        raise FreezeError("SOURCE-INVENTORY.json inventoryGenerator must be an object")
    git_format = inventory["gitObjectFormat"]
    release_commit = inventory["releaseCommit"]
    if git_format not in {"sha1", "sha256"}:
        raise FreezeError("SOURCE-INVENTORY.json Git object format is invalid")
    if (
        not isinstance(release_commit, str)
        or COMMIT_PATTERN.fullmatch(release_commit) is None
        or len(release_commit) != (40 if git_format == "sha1" else 64)
    ):
        raise FreezeError("SOURCE-INVENTORY.json release commit is invalid")
    entries = inventory["entries"]
    if not isinstance(entries, list):
        raise FreezeError("SOURCE-INVENTORY.json entries must be an array")
    rows: dict[str, dict] = {}
    for row in entries:
        if not isinstance(row, dict) or set(row) != {
            "byteLength", "mode", "origin", "path", "sha256"
        }:
            raise FreezeError("SOURCE-INVENTORY.json entry schema is invalid")
        relative = row["path"]
        if not safe_relative(relative) or relative == "SOURCE-INVENTORY.json" or relative in rows:
            raise FreezeError("SOURCE-INVENTORY.json contains an unsafe or duplicate path")
        if (
            not isinstance(row["byteLength"], int)
            or isinstance(row["byteLength"], bool)
            or row["byteLength"] < 0
            or row["mode"] not in {"100644", "100755"}
            or not isinstance(row["sha256"], str)
            or SHA256_PATTERN.fullmatch(row["sha256"]) is None
            or not isinstance(row["origin"], dict)
        ):
            raise FreezeError(f"SOURCE-INVENTORY.json entry metadata is invalid: {relative}")
        rows[relative] = row
    if list(rows) != sorted(rows):
        raise FreezeError("SOURCE-INVENTORY.json entries are not path-sorted")
    canonical_lines = [
        "forgeplay-public-source-inventory-v2",
        f"releaseCommit={release_commit}",
        f"gitObjectFormat={git_format}",
        *(
            f"{row['path']}\0{row['mode']}\0{row['byteLength']}\0{row['sha256']}\0"
            + json.dumps(row["origin"], sort_keys=True, separators=(",", ":"))
            for row in entries
        ),
    ]
    expected_digest = hashlib.sha256(
        ("\n".join(canonical_lines) + "\n").encode("utf-8")
    ).hexdigest()
    if inventory["inventorySHA256"] != expected_digest:
        raise FreezeError("SOURCE-INVENTORY.json inventory digest is invalid")
    if raw != canonical_json(inventory):
        raise FreezeError("SOURCE-INVENTORY.json is not canonical JSON")
    return inventory, rows


def wine_archive_identity(raw: bytes) -> str:
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise FreezeError(f"Runtime source-identity lock is invalid UTF-8 JSON: {error}") from error
    if not isinstance(value, dict):
        raise FreezeError("Runtime source-identity lock must be a JSON object")
    upstream = value.get("upstreamSource")
    if (
        value.get("schemaVersion") != 2
        or not isinstance(upstream, dict)
        or set(upstream) != {"archiveSHA256", "project", "version"}
        or upstream.get("project") != "Wine"
        or upstream.get("version") != "11.12"
        or not isinstance(upstream.get("archiveSHA256"), str)
        or SHA256_PATTERN.fullmatch(upstream["archiveSHA256"]) is None
    ):
        raise FreezeError("Runtime source-identity lock lacks the exact Wine 11.12 archive identity")
    return upstream["archiveSHA256"]


def expected_directories(files: set[str]) -> set[str]:
    return {
        PurePosixPath(*PurePosixPath(relative).parts[:index]).as_posix()
        for relative in files
        for index in range(1, len(PurePosixPath(relative).parts))
    }


class SourceExport:
    def __init__(self, root: Path):
        self.root_path = root
        self.root_descriptor = open_directory_without_symlink_ancestors(root)
        try:
            root_metadata = os.fstat(self.root_descriptor)
            if not stat.S_ISDIR(root_metadata.st_mode):
                raise FreezeError("source export root must be a directory")
            self.root_identity = stable_identity(root_metadata)
            inventory_descriptor = self.open_file("SOURCE-INVENTORY.json")
            try:
                self.inventory_raw = read_descriptor(inventory_descriptor, "SOURCE-INVENTORY.json")
            finally:
                os.close(inventory_descriptor)
            self.inventory, self.rows = parse_inventory(self.inventory_raw)
            self.files = set(self.rows) | {"SOURCE-INVENTORY.json"}
            self.directories = expected_directories(self.files)
            if WINE_IDENTITY_PATH not in self.rows:
                raise FreezeError("SOURCE-INVENTORY.json lacks the Runtime source-identity lock")
            identity_descriptor = self.open_file(WINE_IDENTITY_PATH)
            try:
                identity_raw = read_descriptor(identity_descriptor, "Runtime source-identity lock")
            finally:
                os.close(identity_descriptor)
            identity_row = self.rows[WINE_IDENTITY_PATH]
            if (
                len(identity_raw) != identity_row["byteLength"]
                or hashlib.sha256(identity_raw).hexdigest() != identity_row["sha256"]
            ):
                raise FreezeError("Runtime source-identity lock differs from SOURCE-INVENTORY.json")
            self.wine_archive_sha256 = wine_archive_identity(identity_raw)
        except Exception:
            self.close()
            raise

    def close(self) -> None:
        descriptor = getattr(self, "root_descriptor", -1)
        if descriptor >= 0:
            os.close(descriptor)
            self.root_descriptor = -1

    def __enter__(self) -> "SourceExport":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()

    def open_file(self, relative: str) -> int:
        if not safe_relative(relative):
            raise FreezeError(f"unsafe source-export path: {relative}")
        descriptor = os.dup(self.root_descriptor)
        try:
            parts = PurePosixPath(relative).parts
            for index, part in enumerate(parts):
                final = index == len(parts) - 1
                flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
                if not final:
                    flags |= os.O_DIRECTORY
                next_descriptor = os.open(part, flags, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = next_descriptor
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise FreezeError(f"source-export file is not single-link regular: {relative}")
            return descriptor
        except Exception:
            os.close(descriptor)
            raise

    def verify_closure(self) -> None:
        actual_files: set[str] = set()

        def walk(directory_descriptor: int, parent: tuple[str, ...]) -> None:
            before = os.fstat(directory_descriptor)
            for name in sorted(os.listdir(directory_descriptor)):
                parts = (*parent, name)
                relative = PurePosixPath(*parts).as_posix()
                metadata = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
                if stat.S_ISLNK(metadata.st_mode):
                    raise FreezeError(f"source export contains a symlink: {relative}")
                if stat.S_ISDIR(metadata.st_mode):
                    if relative not in self.directories:
                        raise FreezeError(f"source export contains an unlisted directory: {relative}")
                    child = os.open(
                        name,
                        os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=directory_descriptor,
                    )
                    try:
                        opened = os.fstat(child)
                        if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                            raise FreezeError(f"source-export directory changed during open: {relative}")
                        if stat.S_IMODE(opened.st_mode) != 0o755:
                            raise FreezeError(f"source-export directory mode is not 0755: {relative}")
                        walk(child, parts)
                    finally:
                        os.close(child)
                    continue
                if not stat.S_ISREG(metadata.st_mode):
                    raise FreezeError(f"source export contains a special file: {relative}")
                if metadata.st_nlink != 1:
                    raise FreezeError(f"source export contains a hardlink: {relative}")
                if relative not in self.files:
                    raise FreezeError(f"source export contains an unlisted file: {relative}")
                descriptor = os.open(
                    name,
                    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
                    dir_fd=directory_descriptor,
                )
                try:
                    opened = os.fstat(descriptor)
                    if (opened.st_dev, opened.st_ino) != (metadata.st_dev, metadata.st_ino):
                        raise FreezeError(f"source-export file changed during open: {relative}")
                    expected_mode = (
                        0o644
                        if relative == "SOURCE-INVENTORY.json"
                        else int(self.rows[relative]["mode"][-3:], 8)
                    )
                    if stat.S_IMODE(opened.st_mode) != expected_mode:
                        raise FreezeError(f"source-export file mode differs from inventory: {relative}")
                    digest, byte_count = hash_descriptor(descriptor)
                finally:
                    os.close(descriptor)
                actual_files.add(relative)
                if relative == "SOURCE-INVENTORY.json":
                    if digest != hashlib.sha256(self.inventory_raw).hexdigest() or byte_count != len(self.inventory_raw):
                        raise FreezeError("SOURCE-INVENTORY.json changed after it was parsed")
                else:
                    row = self.rows[relative]
                    if digest != row["sha256"] or byte_count != row["byteLength"]:
                        raise FreezeError(f"source export differs from inventory: {relative}")
            after = os.fstat(directory_descriptor)
            if stable_identity(before) != stable_identity(after):
                raise FreezeError(
                    "source-export directory changed during traversal: "
                    + (PurePosixPath(*parent).as_posix() if parent else ".")
                )

        walk(self.root_descriptor, ())
        missing = sorted(self.files - actual_files)
        if missing:
            raise FreezeError(f"source export is missing inventory entries: {missing}")
        if stable_identity(os.fstat(self.root_descriptor)) != self.root_identity:
            raise FreezeError("source export root changed during verification")

    def source_tree_sha256(self, additional_entries: list[dict]) -> str:
        inventory_sha = hashlib.sha256(self.inventory_raw).hexdigest()
        lines = [
            BINDING_KIND,
            f"SOURCE-INVENTORY.json\x00100644\x00{len(self.inventory_raw)}\x00{inventory_sha}",
            *(
                f"{row['path']}\0{row['mode']}\0{row['byteLength']}\0{row['sha256']}"
                for row in self.inventory["entries"]
            ),
            *(
                f"additional\x00{row['path']}\x00100644\x00{row['byteCount']}\x00{row['sha256']}"
                for row in additional_entries
            ),
        ]
        return hashlib.sha256(("\n".join(lines) + "\n").encode("utf-8")).hexdigest()


class DescriptorReader:
    def __init__(self, descriptor: int, expected_size: int, expected_sha256: str):
        self.descriptor = descriptor
        self.before = os.fstat(descriptor)
        self.expected_size = expected_size
        self.expected_sha256 = expected_sha256
        self.digest = hashlib.sha256()
        self.total = 0

    def read(self, size: int = -1) -> bytes:
        data = os.read(self.descriptor, size if size >= 0 else 1024 * 1024)
        self.digest.update(data)
        self.total += len(data)
        return data

    def verify(self) -> None:
        after = os.fstat(self.descriptor)
        if (
            stable_identity(self.before) != stable_identity(after)
            or self.total != self.expected_size
            or self.digest.hexdigest() != self.expected_sha256
        ):
            raise FreezeError("source-export file changed while archiving")


def tar_info(name: str, *, mode: int, size: int = 0, directory: bool = False) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name + ("/" if directory and not name.endswith("/") else ""))
    info.type = tarfile.DIRTYPE if directory else tarfile.REGTYPE
    info.mode = mode
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    info.size = 0 if directory else size
    return info


def write_archive(
    source: SourceExport,
    descriptor: int,
    additional_descriptor: int,
    additional_size: int,
    additional_sha256: str,
) -> None:
    source_archive_files = {f"OpenSource/{relative}" for relative in source.files}
    archive_files = source_archive_files | {WINE_ARCHIVE_PATH}
    archive_directories = expected_directories(archive_files)
    with os.fdopen(os.dup(descriptor), "wb", closefd=True) as output:
        with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for relative in sorted(archive_directories):
                archive.addfile(tar_info(relative, mode=0o755, directory=True))
            for archive_path in sorted(archive_files):
                if archive_path == WINE_ARCHIVE_PATH:
                    os.lseek(additional_descriptor, 0, os.SEEK_SET)
                    reader = DescriptorReader(
                        additional_descriptor,
                        additional_size,
                        additional_sha256,
                    )
                    archive.addfile(
                        tar_info(archive_path, mode=0o644, size=additional_size),
                        reader,
                    )
                    reader.verify()
                    continue
                relative = archive_path.removeprefix("OpenSource/")
                if relative == "SOURCE-INVENTORY.json":
                    data = source.inventory_raw
                    archive.addfile(
                        tar_info(archive_path, mode=0o644, size=len(data)),
                        io.BytesIO(data),
                    )
                    continue
                row = source.rows[relative]
                source_descriptor = source.open_file(relative)
                reader = DescriptorReader(
                    source_descriptor,
                    row["byteLength"],
                    row["sha256"],
                )
                try:
                    archive.addfile(
                        tar_info(
                            archive_path,
                            mode=int(row["mode"][-3:], 8),
                            size=row["byteLength"],
                        ),
                        reader,
                    )
                    reader.verify()
                finally:
                    os.close(source_descriptor)
        output.flush()
        os.fsync(output.fileno())


class OutputTarget:
    def __init__(self, path: Path):
        self.path = normalized_absolute_path(path)
        self.parent_path = self.path.parent
        self.parent_descriptor = -1
        self.descriptor = -1
        self.temp_name = ""
        self.temp_present = False
        self.final_identity: Optional[tuple[int, int]] = None
        self.final_may_exist = False
        self.published = False
        self.name = self.path.name
        if (
            not self.name
            or self.name in {".", ".."}
            or any(not (0x20 <= ord(character) < 0x7F) for character in self.name)
        ):
            raise FreezeError(f"output path is invalid: {path}")
        self.parent_descriptor = open_directory_without_symlink_ancestors(self.parent_path)
        parent_metadata = os.fstat(self.parent_descriptor)
        self.parent_identity = (parent_metadata.st_dev, parent_metadata.st_ino)
        try:
            try:
                os.stat(self.name, dir_fd=self.parent_descriptor, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise FreezeError(f"output already exists: {self.path}")
            self.temp_name = f".{self.name}.forgeplay-private-{secrets.token_hex(16)}"
            self.descriptor = os.open(
                self.temp_name,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
                dir_fd=self.parent_descriptor,
            )
            self.temp_present = True
        except Exception:
            self.close()
            raise

    def validate_parent_boundary(self) -> None:
        descriptor = open_directory_without_symlink_ancestors(self.parent_path)
        try:
            metadata = os.fstat(descriptor)
            if (metadata.st_dev, metadata.st_ino) != self.parent_identity:
                raise FreezeError(f"output parent was replaced: {self.parent_path}")
        finally:
            os.close(descriptor)

    def publish(self) -> None:
        self.validate_parent_boundary()
        os.fchmod(self.descriptor, 0o644)
        os.fsync(self.descriptor)
        current = os.fstat(self.descriptor)
        if not stat.S_ISREG(current.st_mode) or current.st_nlink != 1:
            raise FreezeError(f"private output identity is invalid: {self.path}")
        self.final_identity = (current.st_dev, current.st_ino)
        # Set the rollback identity before link(2): even a wrapper that reports
        # an error after creating the link can only remove this exact inode.
        self.final_may_exist = True
        os.link(
            self.temp_name,
            self.name,
            src_dir_fd=self.parent_descriptor,
            dst_dir_fd=self.parent_descriptor,
            follow_symlinks=False,
        )
        linked = os.stat(self.name, dir_fd=self.parent_descriptor, follow_symlinks=False)
        if (linked.st_dev, linked.st_ino) != self.final_identity:
            raise FreezeError(f"published output link identity is invalid: {self.path}")
        os.unlink(self.temp_name, dir_fd=self.parent_descriptor)
        self.temp_present = False
        os.fsync(self.parent_descriptor)
        final = os.stat(self.name, dir_fd=self.parent_descriptor, follow_symlinks=False)
        if (
            not stat.S_ISREG(final.st_mode)
            or final.st_nlink != 1
            or (final.st_dev, final.st_ino) != self.final_identity
        ):
            raise FreezeError(f"published output identity is invalid: {self.path}")
        self.validate_parent_boundary()
        self.published = True

    def rollback(self) -> None:
        if not self.final_may_exist or self.final_identity is None:
            return
        try:
            final = os.stat(self.name, dir_fd=self.parent_descriptor, follow_symlinks=False)
            if (final.st_dev, final.st_ino) == self.final_identity:
                os.unlink(self.name, dir_fd=self.parent_descriptor)
                os.fsync(self.parent_descriptor)
        except FileNotFoundError:
            pass
        self.final_may_exist = False
        self.published = False

    def close(self) -> None:
        errors: list[OSError] = []
        descriptor = self.descriptor
        parent_descriptor = self.parent_descriptor
        temp_name = self.temp_name
        temp_present = self.temp_present
        if temp_name and temp_present and parent_descriptor >= 0:
            try:
                os.unlink(temp_name, dir_fd=parent_descriptor)
                self.temp_present = False
            except FileNotFoundError:
                self.temp_present = False
            except OSError as error:
                errors.append(error)
        if descriptor >= 0:
            try:
                os.close(descriptor)
                self.descriptor = -1
            except OSError as error:
                errors.append(error)
        if parent_descriptor >= 0:
            try:
                os.close(parent_descriptor)
                self.parent_descriptor = -1
            except OSError as error:
                errors.append(error)
        if errors:
            raise errors[0]


def create_asset(
    source_export: Path,
    archive_out: Path,
    binding_out: Path,
    additional_files: list[Path],
    additional_paths: list[str],
) -> None:
    if len(additional_files) != len(additional_paths):
        raise FreezeError("--additional-file and --additional-path counts must match")
    if len(additional_files) != 1 or additional_paths != [WINE_ARCHIVE_PATH]:
        raise FreezeError(
            "this release requires exactly one additional Wine archive at " + WINE_ARCHIVE_PATH
        )
    if not additional_files[0].is_absolute():
        raise FreezeError("--additional-file must be an absolute path")
    if normalized_absolute_path(archive_out) == normalized_absolute_path(binding_out):
        raise FreezeError("archive and binding outputs must be distinct")
    additional_descriptor = open_final_without_symlinks(additional_files[0], directory=False)
    additional_before = os.fstat(additional_descriptor)
    if not stat.S_ISREG(additional_before.st_mode) or additional_before.st_nlink != 1:
        os.close(additional_descriptor)
        raise FreezeError("additional Wine archive must be a single-link regular file")
    archive_target: Optional[OutputTarget] = None
    binding_target: Optional[OutputTarget] = None
    committed = False
    try:
        archive_target = OutputTarget(archive_out)
        binding_target = OutputTarget(binding_out)
        if (
            archive_target.parent_path == binding_target.parent_path
            and archive_target.parent_identity != binding_target.parent_identity
        ):
            raise FreezeError("archive and binding observed different identities for one output parent")
        with SourceExport(source_export) as source:
            source.verify_closure()
            if additional_before.st_size < 0:
                raise FreezeError("additional Wine archive size is invalid")
            write_archive(
                source,
                archive_target.descriptor,
                additional_descriptor,
                additional_before.st_size,
                source.wine_archive_sha256,
            )
            if stable_identity(additional_before) != stable_identity(os.fstat(additional_descriptor)):
                raise FreezeError("additional Wine archive changed while archiving")
            archive_sha256, archive_size = hash_descriptor(archive_target.descriptor)
            source.verify_closure()
            additional_entries = [{
                "byteCount": additional_before.st_size,
                "path": WINE_ARCHIVE_PATH,
                "sha256": source.wine_archive_sha256,
            }]
            binding = {
                "additionalEntries": additional_entries,
                "archive": {
                    "byteCount": archive_size,
                    "fileName": archive_target.name,
                    "format": "ustar",
                    "sha256": archive_sha256,
                },
                "bindingKind": BINDING_KIND,
                "schemaVersion": 1,
                "sourceInventory": {
                    "byteCount": len(source.inventory_raw),
                    "entryCount": len(source.rows),
                    "gitObjectFormat": source.inventory["gitObjectFormat"],
                    "inventorySHA256": source.inventory["inventorySHA256"],
                    "releaseCommit": source.inventory["releaseCommit"],
                    "sha256": hashlib.sha256(source.inventory_raw).hexdigest(),
                },
                "sourceTreeSHA256": source.source_tree_sha256(additional_entries),
            }
            binding_bytes = canonical_json(binding)
            write_all(binding_target.descriptor, binding_bytes)
            os.fsync(binding_target.descriptor)
        archive_target.publish()
        binding_target.publish()
        # The binding is intentionally the last published path and therefore
        # the pair's commit marker. No later failure may roll either path back.
        committed = True
    except BaseException as error:
        if committed:
            print(
                "warning: public source export is committed and valid; "
                f"postcommit operation failed: {error}",
                file=sys.stderr,
            )
        else:
            rollback_errors: list[str] = []
            for target in (binding_target, archive_target):
                if target is None:
                    continue
                try:
                    target.rollback()
                except OSError as rollback_error:
                    rollback_errors.append(f"{target.path}: {rollback_error}")
            if rollback_errors:
                raise FreezeError(
                    "precommit output rollback failed: " + "; ".join(rollback_errors)
                ) from error
            raise
    finally:
        cleanup_errors: list[str] = []
        for target in (binding_target, archive_target):
            if target is None:
                continue
            try:
                target.close()
            except OSError as cleanup_error:
                cleanup_errors.append(f"{target.path}: {cleanup_error}")
        try:
            os.close(additional_descriptor)
        except OSError as cleanup_error:
            cleanup_errors.append(f"additional Wine archive: {cleanup_error}")
        if cleanup_errors:
            message = "output cleanup failed: " + "; ".join(cleanup_errors)
            if committed:
                print(
                    "warning: public source export is committed and valid; " + message,
                    file=sys.stderr,
                )
            elif sys.exc_info()[0] is None:
                raise FreezeError(message)
            else:
                print("warning: " + message, file=sys.stderr)


def parse_octal(field: bytes, label: str) -> int:
    if field and field[0] & 0x80:
        raise FreezeError(f"tar {label} uses unsupported base-256 encoding")
    value = field.rstrip(b"\0 ").lstrip(b" ")
    if not value:
        return 0
    if any(character not in b"01234567" for character in value):
        raise FreezeError(f"tar {label} is not canonical octal")
    return int(value, 8)


def decode_ustar_text(field: bytes, label: str) -> str:
    raw = field.split(b"\0", 1)[0]
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise FreezeError(f"tar {label} is not UTF-8") from error


def parse_archive(descriptor: int) -> tuple[dict[str, bytes], list[dict]]:
    os.lseek(descriptor, 0, os.SEEK_SET)
    rows: list[dict] = []
    retained_payloads: dict[str, bytes] = {}
    seen: set[str] = set()
    zero_blocks = 0
    while True:
        header = os.read(descriptor, BLOCK_SIZE)
        if not header:
            break
        if len(header) != BLOCK_SIZE:
            raise FreezeError("tar has a truncated header block")
        if header == b"\0" * BLOCK_SIZE:
            zero_blocks += 1
            continue
        if zero_blocks:
            raise FreezeError("tar contains data after its end marker")
        if header[257:263] != b"ustar\0" or header[263:265] != b"00":
            raise FreezeError("archive is not canonical USTAR")
        expected_checksum = parse_octal(header[148:156], "checksum")
        checksum_header = header[:148] + (b" " * 8) + header[156:]
        if sum(checksum_header) != expected_checksum:
            raise FreezeError("tar header checksum is invalid")
        name = decode_ustar_text(header[0:100], "name")
        prefix = decode_ustar_text(header[345:500], "prefix")
        full_name = f"{prefix}/{name}" if prefix else name
        if full_name in seen:
            raise FreezeError(f"tar contains a duplicate entry: {full_name}")
        seen.add(full_name)
        type_flag = header[156:157]
        if type_flag not in {b"0", b"5"}:
            raise FreezeError(f"tar contains a link, special, GNU, or PAX entry: {full_name}")
        if any(header[start:end].strip(b"\0 ") for start, end in ((157, 257), (329, 337), (337, 345))):
            raise FreezeError(f"tar entry contains link/device metadata: {full_name}")
        mode = parse_octal(header[100:108], "mode")
        uid = parse_octal(header[108:116], "uid")
        gid = parse_octal(header[116:124], "gid")
        size = parse_octal(header[124:136], "size")
        mtime = parse_octal(header[136:148], "mtime")
        uname = decode_ustar_text(header[265:297], "uname")
        gname = decode_ustar_text(header[297:329], "gname")
        if uid != 0 or gid != 0 or mtime != 0 or uname or gname:
            raise FreezeError(f"tar entry metadata is not normalized: {full_name}")
        directory = type_flag == b"5"
        if directory and (size != 0 or mode != 0o755 or not full_name.endswith("/")):
            raise FreezeError(f"tar directory metadata is invalid: {full_name}")
        if not directory and full_name.endswith("/"):
            raise FreezeError(f"tar regular-file path is invalid: {full_name}")
        payload_digest = hashlib.sha256()
        retain = full_name in {
            "OpenSource/SOURCE-INVENTORY.json",
            f"OpenSource/{WINE_IDENTITY_PATH}",
        }
        payload = bytearray() if retain else None
        remaining = size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise FreezeError(f"tar payload is truncated: {full_name}")
            remaining -= len(chunk)
            payload_digest.update(chunk)
            if payload is not None:
                payload.extend(chunk)
        padding = (-size) % BLOCK_SIZE
        if padding and os.read(descriptor, padding) != b"\0" * padding:
            raise FreezeError(f"tar payload padding is nonzero: {full_name}")
        if payload is not None:
            retained_payloads[full_name] = bytes(payload)
        rows.append({
            "directory": directory,
            "mode": mode,
            "name": full_name,
            "sha256": payload_digest.hexdigest(),
            "size": size,
        })
    if zero_blocks < 2:
        raise FreezeError("tar lacks its canonical end marker")
    if "OpenSource/SOURCE-INVENTORY.json" not in retained_payloads:
        raise FreezeError("tar lacks OpenSource/SOURCE-INVENTORY.json")
    return retained_payloads, rows


def load_binding(path: Path) -> tuple[dict, int]:
    descriptor = open_final_without_symlinks(path, directory=False)
    try:
        raw = read_descriptor(descriptor, "binding")
    finally:
        os.close(descriptor)
    try:
        binding = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise FreezeError(f"binding is invalid UTF-8 JSON: {error}") from error
    if raw != canonical_json(binding):
        raise FreezeError("binding is not canonical JSON")
    if not isinstance(binding, dict) or set(binding) != {
        "additionalEntries", "archive", "bindingKind", "schemaVersion",
        "sourceInventory", "sourceTreeSHA256"
    }:
        raise FreezeError("binding schema is invalid")
    if binding["schemaVersion"] != 1 or binding["bindingKind"] != BINDING_KIND:
        raise FreezeError("binding policy is invalid")
    return binding, len(raw)


def verify_asset(archive_path: Path, binding_path: Path) -> None:
    binding, _ = load_binding(binding_path)
    archive_binding = binding["archive"]
    additional_entries = binding["additionalEntries"]
    inventory_binding = binding["sourceInventory"]
    if not isinstance(archive_binding, dict) or set(archive_binding) != {
        "byteCount", "fileName", "format", "sha256"
    }:
        raise FreezeError("binding archive schema is invalid")
    if not isinstance(inventory_binding, dict) or set(inventory_binding) != {
        "byteCount", "entryCount", "gitObjectFormat", "inventorySHA256",
        "releaseCommit", "sha256",
    }:
        raise FreezeError("binding sourceInventory schema is invalid")
    if (
        not isinstance(additional_entries, list)
        or len(additional_entries) != 1
        or not isinstance(additional_entries[0], dict)
        or set(additional_entries[0]) != {"byteCount", "path", "sha256"}
        or additional_entries[0].get("path") != WINE_ARCHIVE_PATH
        or not isinstance(additional_entries[0].get("byteCount"), int)
        or isinstance(additional_entries[0].get("byteCount"), bool)
        or additional_entries[0]["byteCount"] < 0
        or not isinstance(additional_entries[0].get("sha256"), str)
        or SHA256_PATTERN.fullmatch(additional_entries[0]["sha256"]) is None
    ):
        raise FreezeError("binding additionalEntries schema is invalid")
    if (
        archive_binding["fileName"] != archive_path.name
        or archive_binding["format"] != "ustar"
        or not isinstance(archive_binding["byteCount"], int)
        or isinstance(archive_binding["byteCount"], bool)
        or archive_binding["byteCount"] < 0
        or not isinstance(archive_binding["sha256"], str)
        or SHA256_PATTERN.fullmatch(archive_binding["sha256"]) is None
        or not isinstance(binding["sourceTreeSHA256"], str)
        or SHA256_PATTERN.fullmatch(binding["sourceTreeSHA256"]) is None
    ):
        raise FreezeError("binding archive identity is invalid")
    archive_descriptor = open_final_without_symlinks(archive_path, directory=False)
    try:
        before = os.fstat(archive_descriptor)
        archive_sha256, archive_size = hash_descriptor(archive_descriptor)
        if (
            archive_sha256 != archive_binding["sha256"]
            or archive_size != archive_binding["byteCount"]
        ):
            raise FreezeError("archive bytes differ from binding")
        retained_payloads, tar_rows = parse_archive(archive_descriptor)
        if stable_identity(before) != stable_identity(os.fstat(archive_descriptor)):
            raise FreezeError("archive changed during verification")
    finally:
        os.close(archive_descriptor)
    inventory_raw = retained_payloads["OpenSource/SOURCE-INVENTORY.json"]
    identity_raw = retained_payloads.get(f"OpenSource/{WINE_IDENTITY_PATH}")
    if identity_raw is None:
        raise FreezeError("tar lacks the Runtime source-identity lock")
    inventory, inventory_rows = parse_inventory(inventory_raw)
    wine_sha256 = wine_archive_identity(identity_raw)
    identity_row = inventory_rows.get(WINE_IDENTITY_PATH)
    if (
        not isinstance(identity_row, dict)
        or len(identity_raw) != identity_row["byteLength"]
        or hashlib.sha256(identity_raw).hexdigest() != identity_row["sha256"]
        or additional_entries[0]["sha256"] != wine_sha256
    ):
        raise FreezeError("Wine archive binding differs from the embedded source-identity lock")
    inventory_sha256 = hashlib.sha256(inventory_raw).hexdigest()
    expected_inventory_binding = {
        "byteCount": len(inventory_raw),
        "entryCount": len(inventory_rows),
        "gitObjectFormat": inventory["gitObjectFormat"],
        "inventorySHA256": inventory["inventorySHA256"],
        "releaseCommit": inventory["releaseCommit"],
        "sha256": inventory_sha256,
    }
    if inventory_binding != expected_inventory_binding:
        raise FreezeError("archive inventory differs from binding")
    source_files = {f"OpenSource/{relative}" for relative in inventory_rows} | {
        "OpenSource/SOURCE-INVENTORY.json"
    }
    archive_files = source_files | {WINE_ARCHIVE_PATH}
    directories = expected_directories(archive_files)
    expected_names = [f"{relative}/" for relative in sorted(directories)] + sorted(archive_files)
    if [row["name"] for row in tar_rows] != expected_names:
        raise FreezeError("tar entry order or closure differs from SOURCE-INVENTORY.json")
    for row in tar_rows:
        name = row["name"]
        if name == "OpenSource/":
            continue
        relative = name.removesuffix("/")
        if not safe_relative(relative):
            raise FreezeError(f"tar contains an unsafe path: {name}")
        if row["directory"]:
            continue
        if relative == WINE_ARCHIVE_PATH:
            expected_mode = 0o644
            expected_size = additional_entries[0]["byteCount"]
            expected_sha = wine_sha256
        elif relative == "OpenSource/SOURCE-INVENTORY.json":
            expected_mode, expected_size, expected_sha = 0o644, len(inventory_raw), inventory_sha256
        else:
            source_relative = relative.removeprefix("OpenSource/")
            source_row = inventory_rows[source_relative]
            expected_mode = int(source_row["mode"][-3:], 8)
            expected_size = source_row["byteLength"]
            expected_sha = source_row["sha256"]
        if (
            row["mode"] != expected_mode
            or row["size"] != expected_size
            or row["sha256"] != expected_sha
        ):
            raise FreezeError(f"tar entry differs from SOURCE-INVENTORY.json: {name}")
    tree_lines = [
        BINDING_KIND,
        f"SOURCE-INVENTORY.json\x00100644\x00{len(inventory_raw)}\x00{inventory_sha256}",
        *(
            f"{row['path']}\0{row['mode']}\0{row['byteLength']}\0{row['sha256']}"
            for row in inventory["entries"]
        ),
        *(
            f"additional\x00{row['path']}\x00100644\x00{row['byteCount']}\x00{row['sha256']}"
            for row in additional_entries
        ),
    ]
    source_tree_sha256 = hashlib.sha256(
        ("\n".join(tree_lines) + "\n").encode("utf-8")
    ).hexdigest()
    if binding["sourceTreeSHA256"] != source_tree_sha256:
        raise FreezeError("source tree identity differs from binding")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--source-export", required=True, type=Path)
    create.add_argument("--archive-out", required=True, type=Path)
    create.add_argument("--binding-out", required=True, type=Path)
    create.add_argument("--additional-file", action="append", default=[], type=Path)
    create.add_argument("--additional-path", action="append", default=[])
    verify = subparsers.add_parser("verify")
    verify.add_argument("--archive", required=True, type=Path)
    verify.add_argument("--binding", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.command == "create":
            create_asset(
                arguments.source_export,
                arguments.archive_out,
                arguments.binding_out,
                arguments.additional_file,
                arguments.additional_path,
            )
            print(f"ForgePlay public source export frozen: {arguments.archive_out}")
        else:
            verify_asset(arguments.archive, arguments.binding)
            print(f"ForgePlay public source export verified: {arguments.archive}")
    except (FreezeError, OSError, tarfile.TarError, ValueError) as error:
        print(f"error: public source export freeze failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
