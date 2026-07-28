#!/usr/bin/env python3
"""Reject Wine binaries that still expose removed ForgePlay runtime contracts."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ASCII_IDENTIFIER = re.compile(rb"[A-Z][A-Z0-9_]{5,}")
UTF16LE_IDENTIFIER = re.compile(rb"(?:[A-Z0-9_]\x00){6,}")


def identifier_tokens(data: bytes) -> set[bytes]:
    tokens = set(ASCII_IDENTIFIER.findall(data))
    for match in UTF16LE_IDENTIFIER.findall(data):
        tokens.add(match.replace(b"\x00", b""))
    return tokens


def removed_contract_class(token: bytes) -> str | None:
    if token == b"FORGEPLAY_D3DMETAL_NATIVE_THREAD_CONTEXT":
        return None
    if re.fullmatch(rb"WINE[A-Z0-9_]*SYNC[A-Z0-9_]*", token):
        return "out-of-tree synchronization selector"
    if token.startswith(b"FORGEPLAY_") and (b"SYNC" in token or b"NATIVE_" in token):
        return "removed ForgePlay synchronization or thread-state contract"
    if re.fullmatch(rb"[A-Z]{2}_[A-Z0-9_]+", token) and (
        b"GPTK" in token or b"D3D" in token
    ):
        return "foreign renderer-bridge selector"
    return None


def verify(path: Path) -> None:
    if not path.is_file() or path.is_symlink():
        raise ValueError(f"runtime binary is missing or unsafe: {path}")
    findings = {
        contract_class
        for token in identifier_tokens(path.read_bytes())
        if (contract_class := removed_contract_class(token)) is not None
    }
    if findings:
        classes = ", ".join(sorted(findings))
        raise ValueError(f"runtime binary retains removed contract classes ({classes}): {path}")


def main(arguments: list[str]) -> int:
    if not arguments:
        print(
            "usage: verify-clean-wine-runtime-markers.py <runtime binary> [...]",
            file=sys.stderr,
        )
        return 2
    try:
        for argument in arguments:
            verify(Path(argument))
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
