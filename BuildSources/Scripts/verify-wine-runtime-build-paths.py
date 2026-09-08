#!/usr/bin/env python3
"""Reject developer-machine paths embedded in ForgePlay's compiled Wine payload."""

from __future__ import annotations

import sys
from pathlib import Path


FORBIDDEN_PREFIXES = tuple(
    (label, encoded)
    for label in ("/Users/", "/Volumes/")
    for encoded in (label.encode("ascii"), label.encode("utf-16le"))
)
CHUNK_SIZE = 1024 * 1024


def fail(message: str) -> None:
    raise SystemExit(f"error: Wine Runtime build-path hygiene failed: {message}")


def contains_forbidden_prefix(file_path: Path) -> str | None:
    overlap = max(len(encoded) for _, encoded in FORBIDDEN_PREFIXES) - 1
    previous = b""
    try:
        with file_path.open("rb") as handle:
            while chunk := handle.read(CHUNK_SIZE):
                data = previous + chunk
                for label, encoded in FORBIDDEN_PREFIXES:
                    if encoded in data:
                        return label
                previous = data[-overlap:]
    except OSError as error:
        fail(f"could not inspect {file_path}: {error}")
    return None


def main(arguments: list[str]) -> None:
    if not arguments:
        fail("usage: verify-wine-runtime-build-paths.py <compiled payload root> [...]")

    violations: list[tuple[Path, str]] = []
    inspected_files = 0
    for argument in arguments:
        root = Path(argument)
        if not root.is_dir() or root.is_symlink():
            fail(f"compiled payload root must be a non-symlink directory: {root}")
        for file_path in sorted(root.rglob("*")):
            if file_path.is_symlink() or not file_path.is_file():
                continue
            inspected_files += 1
            if forbidden_prefix := contains_forbidden_prefix(file_path):
                violations.append((file_path, forbidden_prefix))
                if len(violations) >= 20:
                    break
        if len(violations) >= 20:
            break

    if violations:
        details = ", ".join(
            f"{file_path} ({prefix})"
            for file_path, prefix in violations
        )
        fail(f"developer-machine path embedded in compiled payload: {details}")
    if not inspected_files:
        fail("compiled payload roots contain no regular files")
    print(f"Wine Runtime build-path hygiene passed: files={inspected_files}")


if __name__ == "__main__":
    main(sys.argv[1:])
