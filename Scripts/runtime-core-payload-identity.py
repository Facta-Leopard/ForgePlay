#!/usr/bin/env python3

import hashlib
import json
import os
import stat
import struct
import sys
from pathlib import Path


HASH_ALGORITHM = "sha256-macho-signature-independent-v1"
FINGERPRINT_DOMAIN = "forgeplay-runtime-core-payload-v2"
MAXIMUM_PAYLOAD_BYTES = 512 * 1024 * 1024
MAXIMUM_MANIFEST_BYTES = 2 * 1024 * 1024
MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D

REQUIRED_PATHS = (
    "wine/bin/wine",
    "wine/bin/wine.bin",
    "wine/bin/wineserver",
    "wine/bin/wineserver.bin",
    "wine/lib/wine/i386-windows/kernelbase.dll",
    "wine/lib/wine/i386-windows/ntdll.dll",
    "wine/lib/wine/i386-windows/winegstreamer.dll",
    "wine/lib/wine/i386-windows/winemac.drv",
    "wine/lib/wine/i386-windows/winevulkan.dll",
    "wine/lib/wine/x86_64-unix/ntdll.so",
    "wine/lib/wine/x86_64-unix/wine",
    "wine/lib/wine/x86_64-unix/winegstreamer.so",
    "wine/lib/wine/x86_64-unix/winemac.so",
    "wine/lib/wine/x86_64-unix/winevulkan.so",
    "wine/lib/wine/x86_64-windows/forgeplay-steam-launcher.exe",
    "wine/lib/wine/x86_64-windows/kernelbase.dll",
    "wine/lib/wine/x86_64-windows/ntdll.dll",
    "wine/lib/wine/x86_64-windows/winegstreamer.dll",
    "wine/lib/wine/x86_64-windows/winemac.drv",
    "wine/lib/wine/x86_64-windows/winevulkan.dll",
)


class CoreIdentityError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise CoreIdentityError(message)


def read_stable_regular_file(
    path: Path,
    label: str,
    maximum_bytes: int = MAXIMUM_PAYLOAD_BYTES,
) -> bytes:
    flags = os.O_RDONLY | os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(f"{label} could not be opened safely: {path}: {error}")

    try:
        initial = os.fstat(descriptor)
        if not stat.S_ISREG(initial.st_mode):
            fail(f"{label} must be a non-symlink regular file: {path}")
        if initial.st_nlink != 1:
            fail(f"{label} must not be hardlinked: {path}")
        if initial.st_size < 0 or initial.st_size > maximum_bytes:
            fail(f"{label} exceeds the identity size policy: {path}")

        data = bytearray()
        offset = 0
        while offset < initial.st_size:
            try:
                chunk = os.pread(
                    descriptor,
                    min(1024 * 1024, initial.st_size - offset),
                    offset,
                )
            except InterruptedError:
                continue
            if not chunk:
                fail(f"{label} became incomplete while it was read: {path}")
            data.extend(chunk)
            offset += len(chunk)

        final = os.fstat(descriptor)
        identity_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns")
        if any(getattr(initial, field) != getattr(final, field) for field in identity_fields):
            fail(f"{label} changed while it was read: {path}")
        return bytes(data)
    except OSError as error:
        fail(f"{label} could not be read: {path}: {error}")
    finally:
        os.close(descriptor)


def raw_digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def signature_independent_digest(path: Path) -> str:
    data = bytearray(read_stable_regular_file(path, "core payload"))
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != MH_MAGIC_64:
        return raw_digest(data)

    command_count, command_bytes = struct.unpack_from("<II", data, 16)
    command_offset = 32
    command_limit = command_offset + command_bytes
    if command_limit > len(data) or command_count > command_bytes // 8:
        fail(f"Mach-O load commands exceed the payload: {path}")

    signature_offset = None
    linkedit_found = False
    for _ in range(command_count):
        if command_offset + 8 > command_limit:
            fail(f"Mach-O load command header is truncated: {path}")
        command, command_size = struct.unpack_from("<II", data, command_offset)
        if command_size < 8 or command_offset + command_size > command_limit:
            fail(f"Mach-O load command is invalid: {path}")

        if command == LC_SEGMENT_64:
            if command_size < 72:
                fail(f"Mach-O segment command is truncated: {path}")
            segment_name = bytes(data[command_offset + 8 : command_offset + 24])
            segment_name = segment_name.split(b"\0", 1)[0]
            if segment_name == b"__LINKEDIT":
                if linkedit_found:
                    fail(f"Mach-O contains duplicate __LINKEDIT segments: {path}")
                linkedit_found = True
                # A replacement signature changes these two size fields even
                # when every executable and link-edit byte is unchanged.
                data[command_offset + 32 : command_offset + 40] = b"\0" * 8
                data[command_offset + 48 : command_offset + 56] = b"\0" * 8
        elif command == LC_CODE_SIGNATURE:
            if command_size != 16 or signature_offset is not None:
                fail(f"Mach-O code-signature command is invalid: {path}")
            data_offset, data_size = struct.unpack_from("<II", data, command_offset + 8)
            if (
                data_offset < command_limit
                or data_offset > len(data)
                or data_size > len(data) - data_offset
                or data_size == 0
                or data_offset + data_size != len(data)
            ):
                fail(f"Mach-O code-signature range is invalid: {path}")
            signature_offset = data_offset
            # Retain the command identity and position, but remove values
            # determined by the signing identity and signature blob size.
            data[command_offset + 8 : command_offset + 16] = b"\0" * 8
        command_offset += command_size

    if command_offset != command_limit:
        fail(f"Mach-O load command accounting is invalid: {path}")
    if signature_offset is None or not linkedit_found:
        fail(f"core Mach-O must carry a replaceable code-signature contract: {path}")
    return raw_digest(data[:signature_offset])


def fingerprint(payloads: dict[str, str]) -> str:
    lines = [FINGERPRINT_DOMAIN]
    lines.extend(f"{path}={payloads[path]}" for path in sorted(payloads))
    return raw_digest(("\n".join(lines) + "\n").encode("utf-8"))


def generate(runtime_root: Path) -> dict[str, object]:
    root = runtime_root.resolve(strict=True)
    payloads = {
        relative: signature_independent_digest(root / relative)
        for relative in REQUIRED_PATHS
    }
    return {
        "corePayloadFingerprint": fingerprint(payloads),
        "corePayloadHashAlgorithm": HASH_ALGORITHM,
        "corePayloadSHA256": payloads,
    }


def load_manifest(path: Path) -> dict[str, object]:
    try:
        data = read_stable_regular_file(
            path,
            "runtime manifest",
            MAXIMUM_MANIFEST_BYTES,
        )
        payload = json.loads(data.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        fail(f"runtime manifest is unreadable: {error}")
    if not isinstance(payload, dict):
        fail("runtime manifest root must be an object")
    return payload


def verify(runtime_root: Path, manifest_path: Path) -> None:
    expected = load_manifest(manifest_path)
    actual = generate(runtime_root)
    if expected.get("corePayloadHashAlgorithm") != HASH_ALGORITHM:
        fail("runtime core payload hash algorithm is invalid")
    if expected.get("corePayloadSHA256") != actual["corePayloadSHA256"]:
        fail("runtime core payload identity does not match the packaged executable payload")
    if expected.get("corePayloadFingerprint") != actual["corePayloadFingerprint"]:
        fail("runtime core payload fingerprint does not match its payload map")


def main(arguments: list[str]) -> int:
    if len(arguments) == 3 and arguments[1] == "generate":
        print(json.dumps(generate(Path(arguments[2])), sort_keys=True, separators=(",", ":")))
        return 0
    if len(arguments) == 4 and arguments[1] == "verify":
        verify(Path(arguments[2]), Path(arguments[3]))
        return 0
    print(
        f"usage: {arguments[0]} generate <runtime-root> | "
        "verify <runtime-root> <RuntimeManifest.json>",
        file=sys.stderr,
    )
    return 64


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except CoreIdentityError as error:
        print(f"runtime core payload identity error: {error}", file=sys.stderr)
        raise SystemExit(1)
