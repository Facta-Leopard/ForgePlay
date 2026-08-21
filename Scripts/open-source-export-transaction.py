#!/usr/bin/env python3
"""Materialize release Git objects and atomically publish a source export."""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path, PurePosixPath


class ExportTransactionError(RuntimeError):
    pass


SAFE_OID = re.compile(r"^[0-9a-f]{40,64}$")
ALLOWED_BLOB_MODES = {"100644": 0o644, "100755": 0o755}


def file_identity(metadata: os.stat_result) -> tuple[int, int]:
    return metadata.st_dev, metadata.st_ino


def identity_token(metadata: os.stat_result) -> str:
    return f"{metadata.st_dev}:{metadata.st_ino}"


def parse_identity(value: str, label: str) -> tuple[int, int]:
    fields = value.split(":")
    if len(fields) != 2 or any(not field.isdigit() for field in fields):
        raise ExportTransactionError(f"{label} identity is invalid")
    return int(fields[0]), int(fields[1])


def safe_relative(value: str, label: str) -> PurePosixPath:
    candidate = PurePosixPath(value)
    if (
        not value
        or candidate.is_absolute()
        or value != candidate.as_posix()
        or any(part in {"", ".", ".."} for part in candidate.parts)
        or any(ord(character) < 0x20 or character == "\x7f" for character in value)
    ):
        raise ExportTransactionError(f"{label} is not a safe relative path: {value!r}")
    return candidate


def git(repository: Path, arguments: list[str], *, stdout=None) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        ["git", "-C", os.fspath(repository), *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE if stdout is None else stdout,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise ExportTransactionError(
            f"Git object operation failed ({' '.join(arguments)}): {detail}"
        )
    return result


def parse_tree_records(payload: bytes) -> list[tuple[str, str, str, str]]:
    records: list[tuple[str, str, str, str]] = []
    for raw in payload.split(b"\0"):
        if not raw:
            continue
        try:
            header, raw_path = raw.split(b"\t", 1)
            mode, object_type, object_id = header.decode("ascii").split(" ")
            source_path = raw_path.decode("utf-8")
        except (UnicodeDecodeError, ValueError) as error:
            raise ExportTransactionError("Git tree contains an unsupported path record") from error
        safe_relative(source_path, "Git tree path")
        if SAFE_OID.fullmatch(object_id) is None:
            raise ExportTransactionError(f"Git tree object id is invalid: {object_id}")
        records.append((mode, object_type, object_id, source_path))
    return records


def exact_tree_entry(
    repository: Path,
    commit: str,
    source: str,
) -> tuple[str, str, str, str]:
    payload = git(
        repository,
        ["ls-tree", "-z", "--full-tree", commit, "--", source],
    ).stdout
    records = parse_tree_records(payload)
    if len(records) != 1 or records[0][3] != source:
        raise ExportTransactionError(
            f"release commit does not contain one exact entry: {source}"
        )
    return records[0]


def append_origin(record_path: Path, value: dict[str, object]) -> None:
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW
    descriptor = os.open(record_path, flags, 0o600)
    try:
        payload = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode(
            "utf-8"
        )
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise ExportTransactionError("origin-record write made no progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def materialize_blob(
    repository: Path,
    object_id: str,
    destination: Path,
    output_mode: int,
) -> tuple[int, str]:
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(
        destination,
        os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    try:
        result = git(repository, ["cat-file", "blob", object_id], stdout=descriptor)
        if result.returncode != 0:
            raise ExportTransactionError(f"Git blob could not be materialized: {object_id}")
        os.fsync(descriptor)
        os.fchmod(descriptor, output_mode)
        os.lseek(descriptor, 0, os.SEEK_SET)
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            digest.update(chunk)
        metadata = os.fstat(descriptor)
        if total != metadata.st_size or stat.S_IMODE(metadata.st_mode) != output_mode:
            raise ExportTransactionError(f"materialized Git blob metadata is invalid: {destination}")
        return total, digest.hexdigest()
    finally:
        os.close(descriptor)


def materialize_entry(
    repository: Path,
    commit: str,
    export_root: Path,
    source: str,
    destination: str,
    classification: str,
    origin_records: Path,
    *,
    recursive: bool,
) -> None:
    source_path = safe_relative(source, "materialization source")
    destination_path = safe_relative(destination, "materialization destination")
    mode, object_type, object_id, _ = exact_tree_entry(repository, commit, source)
    if recursive:
        if object_type != "tree" or mode != "040000":
            raise ExportTransactionError(f"recursive materialization source is not a tree: {source}")
        payload = git(
            repository,
            ["ls-tree", "-rz", "--full-tree", commit, "--", source],
        ).stdout
        records = parse_tree_records(payload)
        prefix = source_path.parts
        if not records:
            raise ExportTransactionError(f"release tree is empty: {source}")
        for blob_mode, blob_type, blob_id, blob_source in records:
            if blob_type != "blob" or blob_mode not in ALLOWED_BLOB_MODES:
                raise ExportTransactionError(
                    f"release tree contains a non-regular or unsupported mode: {blob_source}"
                )
            parsed_source = safe_relative(blob_source, "release tree blob")
            if parsed_source.parts[: len(prefix)] != prefix:
                raise ExportTransactionError(f"release tree escaped its source prefix: {blob_source}")
            suffix = parsed_source.parts[len(prefix) :]
            blob_destination = PurePosixPath(destination_path, *suffix).as_posix()
            _, sha256 = materialize_blob(
                repository,
                blob_id,
                export_root / blob_destination,
                ALLOWED_BLOB_MODES[blob_mode],
            )
            append_origin(
                origin_records,
                {
                    "classification": classification,
                    "destinationPath": blob_destination,
                    "gitMode": blob_mode,
                    "gitObjectID": blob_id,
                    "sha256": sha256,
                    "sourcePath": blob_source,
                },
            )
        return

    if object_type != "blob" or mode not in ALLOWED_BLOB_MODES:
        raise ExportTransactionError(
            f"release entry is not a supported regular blob: {source}"
        )
    _, sha256 = materialize_blob(
        repository,
        object_id,
        export_root / destination_path,
        ALLOWED_BLOB_MODES[mode],
    )
    append_origin(
        origin_records,
        {
            "classification": classification,
            "destinationPath": destination_path.as_posix(),
            "gitMode": mode,
            "gitObjectID": object_id,
            "sha256": sha256,
            "sourcePath": source_path.as_posix(),
        },
    )


def rename_atomic(
    parent_fd: int,
    source_name: str,
    destination_name: str,
    flag: int,
) -> None:
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        operation = library.renameatx_np
    elif hasattr(library, "renameat2"):
        operation = library.renameat2
    else:
        raise ExportTransactionError("platform lacks an approved atomic rename primitive")
    operation.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    operation.restype = ctypes.c_int
    result = operation(
        parent_fd,
        os.fsencode(source_name),
        parent_fd,
        os.fsencode(destination_name),
        flag,
    )
    if result == 0:
        return
    error_number = ctypes.get_errno()
    if error_number == errno.EEXIST:
        raise ExportTransactionError("OpenSource destination appeared concurrently")
    if error_number == errno.EXDEV:
        raise ExportTransactionError("OpenSource publication crossed filesystems")
    raise ExportTransactionError(
        f"atomic OpenSource publication failed with errno {error_number}"
    )


def read_regular_at(directory_fd: int, name: str, maximum: int) -> bytes:
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        dir_fd=directory_fd,
    )
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise ExportTransactionError(f"managed marker is unsafe: {name}")
        if metadata.st_size < 0 or metadata.st_size > maximum:
            raise ExportTransactionError(f"managed marker exceeds its bound: {name}")
        payload = b""
        while len(payload) <= maximum:
            chunk = os.read(descriptor, min(65536, maximum - len(payload) + 1))
            if not chunk:
                break
            payload += chunk
        if len(payload) != metadata.st_size or len(payload) > maximum:
            raise ExportTransactionError(f"managed marker read is unstable: {name}")
        return payload
    finally:
        os.close(descriptor)


def atomic_publish(
    staged: str,
    destination: str,
    expected_stage: tuple[int, int],
    expected_parent: tuple[int, int],
    marker_sha256: str,
    *,
    before_commit: Callable[[], None] | None = None,
) -> tuple[str, tuple[int, int] | None]:
    if (
        not os.path.isabs(staged)
        or not os.path.isabs(destination)
        or os.path.normpath(staged) != staged
        or os.path.normpath(destination) != destination
        or os.path.dirname(staged) != os.path.dirname(destination)
        or os.path.basename(staged) in {"", ".", ".."}
        or os.path.basename(destination) in {"", ".", ".."}
    ):
        raise ExportTransactionError(
            "OpenSource staging and destination must be exact adjacent sibling paths"
        )
    if re.fullmatch(r"[0-9a-f]{64}", marker_sha256) is None:
        raise ExportTransactionError("managed marker SHA-256 is invalid")

    parent = os.path.dirname(destination)
    stage_name = os.path.basename(staged)
    destination_name = os.path.basename(destination)
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
    parent_fd = os.open(parent, flags)
    stage_fd = -1
    destination_fd = -1
    try:
        parent_metadata = os.fstat(parent_fd)
        if file_identity(parent_metadata) != expected_parent:
            raise ExportTransactionError("OpenSource destination parent identity changed")
        stage_fd = os.open(stage_name, flags, dir_fd=parent_fd)
        stage_metadata = os.fstat(stage_fd)
        if (
            not stat.S_ISDIR(stage_metadata.st_mode)
            or file_identity(stage_metadata) != expected_stage
            or stat.S_IMODE(stage_metadata.st_mode) != 0o700
            or stage_metadata.st_uid != os.geteuid()
        ):
            raise ExportTransactionError("OpenSource staging identity or mode changed")
        if stage_metadata.st_dev != parent_metadata.st_dev:
            raise ExportTransactionError("OpenSource staging is on a different filesystem")

        old_identity: tuple[int, int] | None = None
        try:
            destination_fd = os.open(destination_name, flags, dir_fd=parent_fd)
        except FileNotFoundError:
            destination_fd = -1
        else:
            destination_metadata = os.fstat(destination_fd)
            if not stat.S_ISDIR(destination_metadata.st_mode):
                raise ExportTransactionError("existing OpenSource output is not a directory")
            marker = read_regular_at(destination_fd, ".forgeplay-source-export", 65536)
            if hashlib.sha256(marker).hexdigest() != marker_sha256:
                raise ExportTransactionError("existing OpenSource output is not a managed export")
            old_identity = file_identity(destination_metadata)

        if before_commit is not None:
            before_commit()
        stage_path_metadata = os.stat(
            stage_name, dir_fd=parent_fd, follow_symlinks=False
        )
        parent_path_metadata = os.stat(parent, follow_symlinks=False)
        if (
            file_identity(stage_path_metadata) != expected_stage
            or file_identity(os.fstat(stage_fd)) != expected_stage
            or file_identity(os.fstat(parent_fd)) != expected_parent
            or not stat.S_ISDIR(parent_path_metadata.st_mode)
            or file_identity(parent_path_metadata) != expected_parent
        ):
            raise ExportTransactionError(
                "OpenSource destination parent or staging rebound before publication"
            )

        if destination_fd < 0:
            rename_atomic(
                parent_fd,
                stage_name,
                destination_name,
                0x00000004 if sys.platform == "darwin" else 0x00000001,
            )
            return "created", None

        destination_path_metadata = os.stat(
            destination_name, dir_fd=parent_fd, follow_symlinks=False
        )
        if (
            file_identity(destination_path_metadata) != old_identity
            or file_identity(os.fstat(destination_fd)) != old_identity
        ):
            raise ExportTransactionError("existing OpenSource output rebound before swap")
        rename_atomic(parent_fd, stage_name, destination_name, 0x00000002)
        # Successful atomic swap is the commit point. Nothing after this line
        # may report a pre-commit publication failure or imply rollback. The
        # old export now has the private adjacent staging name and all cleanup
        # is an independently recoverable post-commit operation.
        try:
            os.fchmod(destination_fd, 0o700)
        except OSError as error:
            print(
                "warning: OpenSource publication committed; previous export "
                f"mode hardening failed: {error}",
                file=sys.stderr,
            )
        try:
            moved_old = os.stat(stage_name, dir_fd=parent_fd, follow_symlinks=False)
            if file_identity(moved_old) != old_identity:
                raise ExportTransactionError(
                    "committed previous OpenSource inode has an unexpected staging identity"
                )
        except (OSError, ExportTransactionError) as error:
            print(
                "warning: OpenSource publication committed; previous export "
                f"requires manual quarantine recovery: {error}",
                file=sys.stderr,
            )
        return "replaced", old_identity
    finally:
        if destination_fd >= 0:
            os.close(destination_fd)
        if stage_fd >= 0:
            os.close(stage_fd)
        os.close(parent_fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    materialize = subparsers.add_parser("materialize")
    materialize.add_argument("--repository", required=True, type=Path)
    materialize.add_argument("--commit", required=True)
    materialize.add_argument("--export-root", required=True, type=Path)
    materialize.add_argument("--source", required=True)
    materialize.add_argument("--destination", required=True)
    materialize.add_argument("--classification", required=True)
    materialize.add_argument("--origin-records", required=True, type=Path)
    materialize.add_argument("--recursive", action="store_true")

    publish = subparsers.add_parser("publish")
    publish.add_argument("--staged", required=True)
    publish.add_argument("--destination", required=True)
    publish.add_argument("--stage-identity", required=True)
    publish.add_argument("--parent-identity", required=True)
    publish.add_argument("--managed-marker-sha256", required=True)

    arguments = parser.parse_args()
    try:
        if arguments.command == "materialize":
            materialize_entry(
                arguments.repository.resolve(strict=True),
                arguments.commit,
                arguments.export_root.resolve(strict=True),
                arguments.source,
                arguments.destination,
                arguments.classification,
                arguments.origin_records,
                recursive=arguments.recursive,
            )
        else:
            state, old_identity = atomic_publish(
                arguments.staged,
                arguments.destination,
                parse_identity(arguments.stage_identity, "OpenSource staging"),
                parse_identity(arguments.parent_identity, "OpenSource destination parent"),
                arguments.managed_marker_sha256,
            )
            print(
                json.dumps(
                    {
                        "oldIdentity": (
                            None
                            if old_identity is None
                            else f"{old_identity[0]}:{old_identity[1]}"
                        ),
                        "state": state,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                )
            )
    except (OSError, ExportTransactionError, subprocess.SubprocessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
