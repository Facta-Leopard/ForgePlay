#!/usr/bin/env python3
"""Quarantine one bound directory inode before recursively deleting it."""

from __future__ import annotations

import argparse
import ctypes
import errno
import os
import secrets
import stat
import sys
from collections.abc import Callable


class QuarantineError(RuntimeError):
    pass


Identity = tuple[int, int]


def identity(metadata: os.stat_result) -> Identity:
    return metadata.st_dev, metadata.st_ino


def parse_identity(value: str, label: str) -> Identity:
    fields = value.split(":")
    if len(fields) != 2 or any(not field.isdigit() for field in fields):
        raise QuarantineError(f"{label} identity is invalid")
    return int(fields[0]), int(fields[1])


def rename_noreplace(
    source_fd: int,
    source_name: str,
    destination_fd: int,
    destination_name: str,
) -> None:
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        operation = library.renameatx_np
        flag = 0x00000004  # RENAME_EXCL
    elif hasattr(library, "renameat2"):
        operation = library.renameat2
        flag = 0x00000001  # RENAME_NOREPLACE
    else:
        raise QuarantineError("platform lacks an atomic no-replace rename primitive")
    operation.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    operation.restype = ctypes.c_int
    result = operation(
        source_fd,
        os.fsencode(source_name),
        destination_fd,
        os.fsencode(destination_name),
        flag,
    )
    if result == 0:
        return
    error_number = ctypes.get_errno()
    if error_number == errno.EEXIST:
        raise QuarantineError("quarantine destination appeared concurrently")
    if error_number == errno.EXDEV:
        raise QuarantineError("quarantine move crossed filesystems")
    raise QuarantineError(
        f"atomic quarantine move failed with errno {error_number}"
    )


def create_private_quarantine(parent_fd: int) -> tuple[str, int]:
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
    for _ in range(128):
        name = f".forgeplay-delete-quarantine.{secrets.token_hex(16)}"
        try:
            os.mkdir(name, 0o700, dir_fd=parent_fd)
        except FileExistsError:
            continue
        descriptor = os.open(name, flags, dir_fd=parent_fd)
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or stat.S_IMODE(metadata.st_mode) != 0o700
            or metadata.st_uid != os.geteuid()
        ):
            os.close(descriptor)
            raise QuarantineError("private quarantine metadata is invalid")
        return name, descriptor
    raise QuarantineError("could not allocate a private quarantine directory")


def delete_directory_contents(directory_fd: int, filesystem_device: int) -> None:
    os.fchmod(directory_fd, 0o700)
    for name in os.listdir(directory_fd):
        if name in {".", ".."}:
            raise QuarantineError("quarantine traversal returned an invalid name")
        metadata = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        if stat.S_ISDIR(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
            if metadata.st_dev != filesystem_device:
                raise QuarantineError(
                    f"quarantined tree contains a cross-filesystem directory: {name}"
                )
            child_fd = os.open(
                name,
                os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY,
                dir_fd=directory_fd,
            )
            try:
                if identity(os.fstat(child_fd)) != identity(metadata):
                    raise QuarantineError(
                        f"quarantined directory rebound during deletion: {name}"
                    )
                delete_directory_contents(child_fd, filesystem_device)
                rebound = os.stat(
                    name,
                    dir_fd=directory_fd,
                    follow_symlinks=False,
                )
                if identity(rebound) != identity(os.fstat(child_fd)):
                    raise QuarantineError(
                        f"quarantined directory changed before removal: {name}"
                    )
            finally:
                os.close(child_fd)
            os.rmdir(name, dir_fd=directory_fd)
        else:
            os.unlink(name, dir_fd=directory_fd)


def quarantine_and_delete(
    tree_root: str,
    expected_tree: Identity,
    tree_parent: str,
    expected_parent: Identity,
    label: str,
    *,
    before_commit: Callable[[], None] | None = None,
) -> str:
    if (
        not os.path.isabs(tree_root)
        or not os.path.isabs(tree_parent)
        or os.path.normpath(tree_root) != tree_root
        or os.path.normpath(tree_parent) != tree_parent
        or os.path.dirname(tree_root) != tree_parent
        or os.path.basename(tree_root) in {"", ".", ".."}
    ):
        raise QuarantineError(f"{label} paths do not form an exact parent/child")

    directory_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
    parent_fd = os.open(tree_parent, directory_flags)
    quarantine_name = ""
    quarantine_fd = -1
    tree_fd = -1
    committed = False
    try:
        parent_metadata = os.fstat(parent_fd)
        if identity(parent_metadata) != expected_parent:
            raise QuarantineError(f"{label} parent identity changed")
        tree_name = os.path.basename(tree_root)
        tree_fd = os.open(tree_name, directory_flags, dir_fd=parent_fd)
        tree_metadata = os.fstat(tree_fd)
        if (
            not stat.S_ISDIR(tree_metadata.st_mode)
            or identity(tree_metadata) != expected_tree
            or tree_metadata.st_uid != os.geteuid()
        ):
            raise QuarantineError(f"{label} identity or ownership changed")
        if tree_metadata.st_dev != parent_metadata.st_dev:
            raise QuarantineError(f"{label} is not on its parent filesystem")

        quarantine_name, quarantine_fd = create_private_quarantine(parent_fd)
        if before_commit is not None:
            before_commit()

        rebound = os.stat(tree_name, dir_fd=parent_fd, follow_symlinks=False)
        parent_rebound = os.stat(tree_parent, follow_symlinks=False)
        if identity(rebound) != expected_tree or identity(os.fstat(tree_fd)) != expected_tree:
            raise QuarantineError(f"{label} path rebound before quarantine")
        if (
            identity(os.fstat(parent_fd)) != expected_parent
            or not stat.S_ISDIR(parent_rebound.st_mode)
            or identity(parent_rebound) != expected_parent
        ):
            raise QuarantineError(f"{label} parent rebound before quarantine")

        # Darwin requires search/write access on a directory whose parent is
        # changed by renameatx_np. Harden only the already bound, owned inode;
        # pathname revalidation above ensures a substitute is never thawed.
        os.fchmod(tree_fd, 0o700)
        rename_noreplace(parent_fd, tree_name, quarantine_fd, "owned")
        committed = True
        moved = os.stat("owned", dir_fd=quarantine_fd, follow_symlinks=False)
        if (
            not stat.S_ISDIR(moved.st_mode)
            or identity(moved) != expected_tree
            or identity(os.fstat(tree_fd)) != expected_tree
        ):
            raise QuarantineError(f"{label} moved inode verification failed")

        delete_directory_contents(tree_fd, tree_metadata.st_dev)
        moved = os.stat("owned", dir_fd=quarantine_fd, follow_symlinks=False)
        if identity(moved) != expected_tree or identity(os.fstat(tree_fd)) != expected_tree:
            raise QuarantineError(f"{label} changed after quarantine deletion")
        os.rmdir("owned", dir_fd=quarantine_fd)
        os.close(tree_fd)
        tree_fd = -1
        os.close(quarantine_fd)
        quarantine_fd = -1
        os.rmdir(quarantine_name, dir_fd=parent_fd)
        return quarantine_name
    except BaseException:
        if committed and quarantine_name:
            print(
                "warning: bound directory was isolated before cleanup failed; "
                f"quarantine={tree_parent}/{quarantine_name}/owned",
                file=sys.stderr,
            )
        if quarantine_fd >= 0:
            os.close(quarantine_fd)
            quarantine_fd = -1
        if quarantine_name and not committed:
            try:
                os.rmdir(quarantine_name, dir_fd=parent_fd)
            except OSError:
                pass
        raise
    finally:
        if tree_fd >= 0:
            os.close(tree_fd)
        os.close(parent_fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tree", required=True)
    parser.add_argument("--tree-identity", required=True)
    parser.add_argument("--parent", required=True)
    parser.add_argument("--parent-identity", required=True)
    parser.add_argument("--label", required=True)
    arguments = parser.parse_args()
    try:
        quarantine_and_delete(
            arguments.tree,
            parse_identity(arguments.tree_identity, arguments.label),
            arguments.parent,
            parse_identity(arguments.parent_identity, f"{arguments.label} parent"),
            arguments.label,
        )
    except (OSError, QuarantineError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
