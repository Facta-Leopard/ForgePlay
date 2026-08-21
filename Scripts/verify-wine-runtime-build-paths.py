#!/usr/bin/env python3
"""Reject developer-machine paths embedded in ForgePlay release payloads."""

from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path


FORBIDDEN_ROOTS = (
    ("/Users/<account>", "/Users/", "account"),
    ("/Volumes/<volume>", "/Volumes/", "volume"),
)
ENCODINGS = (
    ("ASCII", "ascii", 1, "little"),
    ("UTF-16LE", "utf-16le", 2, "little"),
    ("UTF-16BE", "utf-16be", 2, "big"),
)
ACCOUNT_COMPONENT_UNITS = frozenset(
    b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
)
VOLUME_COMPONENT_UNITS = ACCOUNT_COMPONENT_UNITS | {ord(" ")}
TERMINATOR_UNITS = frozenset(b"\0\r\n\t \"'`<>()[]{};,=:!?")
MAX_COMPONENT_UNITS = 255
MAX_MARKER_BYTES = max(
    (len(root) + MAX_COMPONENT_UNITS + 1) * unit_width
    for _, root, _ in FORBIDDEN_ROOTS
    for _, _, unit_width, _ in ENCODINGS
)
CHUNK_SIZE = 1024 * 1024
REVIEWED_DXMT_APP_RELATIVE_PATH = Path(
    "Contents/Resources/Runners/ForgePlayRuntime/Frameworks/renderer/"
    "dxmt/wine/x86_64-unix/winemetal.so"
)
REVIEWED_GITHUB_ACTIONS_PREFIX = "/Users/runner/work/"
REVIEWED_DXMT_ALLOW_FLAG = "--allow-inventory-verified-dxmt-github-actions-paths"


@dataclass(frozen=True)
class ForbiddenMarker:
    label: str
    has_reviewed_github_actions_prefix: bool


def fail(message: str) -> None:
    raise SystemExit(f"error: Wine Runtime build-path hygiene failed: {message}")


def code_unit_at(
    data: bytes,
    offset: int,
    unit_width: int,
    byte_order: str,
) -> tuple[int, int] | None:
    end = offset + unit_width
    if end > len(data):
        return None
    if unit_width == 1:
        return data[offset], end
    return int.from_bytes(data[offset:end], byte_order), end


def component_is_valid(component: list[int], kind: str) -> bool:
    if not component or component in ([ord(".")], [ord("."), ord(".")]):
        return False
    if kind == "volume" and (component[0] == ord(" ") or component[-1] == ord(" ")):
        return False
    return any(
        ord("0") <= unit <= ord("9")
        or ord("A") <= unit <= ord("Z")
        or ord("a") <= unit <= ord("z")
        for unit in component
    )


def marker_matches(
    data: bytes,
    component_offset: int,
    kind: str,
    unit_width: int,
    byte_order: str,
    *,
    at_end_of_file: bool,
) -> bool:
    allowed_units = (
        ACCOUNT_COMPONENT_UNITS if kind == "account" else VOLUME_COMPONENT_UNITS
    )
    component: list[int] = []
    offset = component_offset
    while True:
        decoded = code_unit_at(data, offset, unit_width, byte_order)
        if decoded is None:
            return at_end_of_file and component_is_valid(component, kind)
        unit, next_offset = decoded
        if unit == ord("/"):
            return component_is_valid(component, kind)
        if unit not in allowed_units:
            return component_is_valid(component, kind) and unit in TERMINATOR_UNITS
        component.append(unit)
        if len(component) > MAX_COMPONENT_UNITS:
            # A component longer than the platform limit is still an unmistakable
            # path-shaped leak and must not become a length-based bypass.
            return True
        offset = next_offset


def forbidden_markers_in(
    data: bytes,
    *,
    at_end_of_file: bool,
) -> list[ForbiddenMarker]:
    markers: list[ForbiddenMarker] = []
    for label, root, kind in FORBIDDEN_ROOTS:
        for encoding_label, codec, unit_width, byte_order in ENCODINGS:
            encoded_root = root.encode(codec)
            reviewed_prefix = REVIEWED_GITHUB_ACTIONS_PREFIX.encode(codec)
            search_offset = 0
            while True:
                marker_offset = data.find(encoded_root, search_offset)
                if marker_offset < 0:
                    break
                if marker_matches(
                    data,
                    marker_offset + len(encoded_root),
                    kind,
                    unit_width,
                    byte_order,
                    at_end_of_file=at_end_of_file,
                ):
                    # Reconsider a near-boundary match with the next chunk so a
                    # truncated public-CI prefix cannot be misclassified.
                    if (
                        not at_end_of_file
                        and len(data) - marker_offset < len(reviewed_prefix)
                    ):
                        search_offset = marker_offset + 1
                        continue
                    markers.append(
                        ForbiddenMarker(
                            label=f"{label} ({encoding_label})",
                            has_reviewed_github_actions_prefix=(
                                kind == "account"
                                and data.startswith(reviewed_prefix, marker_offset)
                            ),
                        )
                    )
                search_offset = marker_offset + 1
    return markers


def contains_forbidden_path(
    file_path: Path,
    *,
    allow_reviewed_github_actions_prefix: bool,
) -> str | None:
    previous = b""
    try:
        with file_path.open("rb") as handle:
            while chunk := handle.read(CHUNK_SIZE):
                data = previous + chunk
                for marker in forbidden_markers_in(data, at_end_of_file=False):
                    if not (
                        allow_reviewed_github_actions_prefix
                        and marker.has_reviewed_github_actions_prefix
                    ):
                        return marker.label
                previous = data[-MAX_MARKER_BYTES:]
            for marker in forbidden_markers_in(previous, at_end_of_file=True):
                if not (
                    allow_reviewed_github_actions_prefix
                    and marker.has_reviewed_github_actions_prefix
                ):
                    return marker.label
            return None
    except OSError as error:
        fail(f"could not inspect {file_path}: {error}")


def main(arguments: list[str]) -> None:
    allow_reviewed_dxmt_paths = False
    roots: list[Path] = []
    for argument in arguments:
        if argument == REVIEWED_DXMT_ALLOW_FLAG:
            if allow_reviewed_dxmt_paths:
                fail(f"duplicate option: {REVIEWED_DXMT_ALLOW_FLAG}")
            allow_reviewed_dxmt_paths = True
        elif argument.startswith("-"):
            fail(f"unsupported option: {argument}")
        else:
            roots.append(Path(argument))
    if not roots:
        fail(
            "usage: verify-wine-runtime-build-paths.py "
            f"[{REVIEWED_DXMT_ALLOW_FLAG}] <compiled payload root> [...]"
        )

    violations: list[tuple[Path, str]] = []
    inspected_files = 0
    for root in roots:
        if not root.is_dir() or root.is_symlink():
            fail(f"compiled payload root must be a non-symlink directory: {root}")
        for file_path in sorted(root.rglob("*")):
            if file_path.is_symlink() or not file_path.is_file():
                continue
            inspected_files += 1
            relative_path = file_path.relative_to(root)
            allow_reviewed_prefix_for_file = (
                allow_reviewed_dxmt_paths
                and relative_path == REVIEWED_DXMT_APP_RELATIVE_PATH
            )
            if forbidden_marker := contains_forbidden_path(
                file_path,
                allow_reviewed_github_actions_prefix=allow_reviewed_prefix_for_file,
            ):
                violations.append((relative_path, forbidden_marker))
                if len(violations) >= 20:
                    break
        if len(violations) >= 20:
            break

    if violations:
        details = ", ".join(
            f"{relative_path} ({marker})"
            for relative_path, marker in violations
        )
        fail(f"developer-machine path embedded in compiled payload: {details}")
    if not inspected_files:
        fail("compiled payload roots contain no regular files")
    print(f"Wine Runtime build-path hygiene passed: files={inspected_files}")


if __name__ == "__main__":
    main(sys.argv[1:])
