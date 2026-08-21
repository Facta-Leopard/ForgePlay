#!/usr/bin/env python3
"""Create or verify an external Developer ID release attestation for a Runtime app."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


CODESIGN = "/usr/bin/codesign"
HASH = re.compile(r"^[0-9a-f]{64}$")
MAXIMUM_JSON_BYTES = 16 * 1024 * 1024
ATTESTATION_KIND = "forgeplay-public-runtime-developer-id-release-v1"


class AttestationError(RuntimeError):
    pass


@dataclass(frozen=True)
class CommandOutput:
    returncode: int
    stdout: str
    stderr: str


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def compact_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_regular_file(path: Path, label: str) -> bytes:
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        initial = os.fstat(descriptor)
        if not stat.S_ISREG(initial.st_mode) or initial.st_nlink != 1:
            raise AttestationError(f"{label} must be a single-link regular file")
        if initial.st_size > MAXIMUM_JSON_BYTES:
            raise AttestationError(f"{label} exceeds the size policy")
        parts: list[bytes] = []
        remaining = initial.st_size
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                raise AttestationError(f"{label} became incomplete while it was read")
            parts.append(chunk)
            remaining -= len(chunk)
        final = os.fstat(descriptor)
        if (initial.st_dev, initial.st_ino, initial.st_size, initial.st_mtime_ns) != (
            final.st_dev,
            final.st_ino,
            final.st_size,
            final.st_mtime_ns,
        ):
            raise AttestationError(f"{label} changed while it was read")
        return b"".join(parts)
    finally:
        os.close(descriptor)


def read_canonical_json(path: Path, label: str) -> tuple[dict, bytes]:
    raw = read_regular_file(path, label)
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AttestationError(f"{label} is invalid JSON") from error
    if not isinstance(value, dict):
        raise AttestationError(f"{label} must be a JSON object")
    if raw != canonical_json(value):
        raise AttestationError(f"{label} is not canonical JSON")
    return value, raw


def run_command(argv: Sequence[str]) -> CommandOutput:
    result = subprocess.run(argv, check=False, capture_output=True, text=True)
    return CommandOutput(result.returncode, result.stdout, result.stderr)


def require_command(argv: Sequence[str], label: str) -> CommandOutput:
    result = run_command(argv)
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise AttestationError(f"{label} failed" + (f": {detail}" if detail else ""))
    return result


def signed_app_metadata(app: Path) -> dict:
    if not app.is_absolute() or app.suffix != ".app" or app.is_symlink() or not app.is_dir():
        raise AttestationError("app must be an absolute non-symlink .app directory")
    require_command((CODESIGN, "--verify", "--strict", "--deep", "--verbose=4", os.fspath(app)), "strict deep codesign verification")
    details = require_command((CODESIGN, "-d", "--verbose=4", os.fspath(app)), "codesign metadata inspection")
    requirement = require_command((CODESIGN, "-d", "-r-", os.fspath(app)), "designated requirement inspection")
    metadata = details.stdout + "\n" + details.stderr
    authorities = re.findall(r"^Authority=(.+)$", metadata, flags=re.MULTILINE)
    identifier = re.search(r"^Identifier=(.+)$", metadata, flags=re.MULTILINE)
    team = re.search(r"^TeamIdentifier=(.+)$", metadata, flags=re.MULTILINE)
    cdhash = re.search(r"^CDHash=([0-9a-fA-F]+)$", metadata, flags=re.MULTILINE)
    runtime = re.search(r"^Runtime Version=(.+)$", metadata, flags=re.MULTILINE)
    designated = re.search(r"^designated => (.+)$", requirement.stdout + "\n" + requirement.stderr, flags=re.MULTILINE)
    if (
        identifier is None
        or not identifier.group(1).strip()
        or team is None
        or not team.group(1).strip()
        or cdhash is None
        or runtime is None
        or not runtime.group(1).strip()
        or designated is None
        or not designated.group(1).strip()
    ):
        raise AttestationError("codesign metadata lacks an identifier, TeamIdentifier, hardened runtime, CDHash, or designated requirement")
    cdhash_value = cdhash.group(1).lower()
    if re.fullmatch(r"[0-9a-f]{40,64}", cdhash_value) is None:
        raise AttestationError("codesign CDHash is invalid")
    if (
        not authorities
        or not authorities[0].startswith("Developer ID Application:")
        or "Developer ID Certification Authority" not in authorities
        or "Apple Root CA" not in authorities
    ):
        raise AttestationError("app is not signed with a Developer ID Application authority chain")
    return {
        "authorities": authorities,
        "bundleIdentifier": identifier.group(1).strip(),
        "cdHash": cdhash_value,
        "designatedRequirement": designated.group(1).strip(),
        "teamIdentifier": team.group(1).strip(),
    }


def require_hash(value: object, label: str) -> str:
    if not isinstance(value, str) or HASH.fullmatch(value) is None:
        raise AttestationError(f"{label} must be a lowercase SHA-256")
    return value


def runtime_fingerprint_root(subjects: dict[str, str]) -> str:
    return sha256(b"forgeplay-public-runtime-release-fingerprint-v1\n" + compact_json(subjects))


def runtime_artifacts(app: Path) -> dict:
    runtime = app / "Contents/Resources/Runners/ForgePlayRuntime"
    claim, claim_raw = read_canonical_json(runtime / "PublicRuntimeBuildClaim.json", "unsigned Runtime build claim")
    manifest, manifest_raw = read_canonical_json(runtime / "RuntimeManifest.json", "Runtime manifest")
    receipt = claim.get("runtimeBuildReceipt")
    if not isinstance(receipt, dict):
        raise AttestationError("unsigned Runtime build claim has no embedded build receipt")
    if (
        claim.get("schemaVersion") != 2
        or claim.get("claimStatus") != "unsigned build claim awaiting release attestation"
    ):
        raise AttestationError("unsigned Runtime build claim status is invalid")
    if (
        receipt.get("schemaVersion") != 2
        or receipt.get("claimStatus") != "unsigned build claim awaiting release attestation"
    ):
        raise AttestationError("embedded Runtime build receipt schema or status is invalid")
    outputs = receipt.get("runtimeOutputs")
    if not isinstance(outputs, dict):
        raise AttestationError("embedded Runtime build receipt has no output subjects")
    subject_pairs = (
        ("corePayloadFingerprint", "corePayloadFingerprint"),
        ("hostSupportPayloadFingerprint", "hostSupportPayloadFingerprint"),
        ("patchSetSHA256", "patchSetSHA256"),
        ("runnerBuildFingerprint", "runnerBuildFingerprint"),
        ("runtimeManifestSHA256", "runtimeManifestSHA256"),
        ("sourceTreeSHA256", "currentFinalPatchedSourceTreeSHA256"),
    )
    subjects: dict[str, str] = {}
    for manifest_key, claim_key in subject_pairs:
        expected = sha256(manifest_raw) if manifest_key == "runtimeManifestSHA256" else manifest.get(manifest_key)
        actual = outputs.get(manifest_key)
        require_hash(expected, f"Runtime manifest {manifest_key}")
        if actual != expected:
            raise AttestationError(f"embedded Runtime build receipt {manifest_key} differs from Runtime manifest")
        if claim_key is not None and claim.get(claim_key) != expected:
            raise AttestationError(f"unsigned Runtime build claim {claim_key} differs from Runtime manifest")
        subjects[manifest_key] = expected
    receipt_raw = canonical_json(receipt)
    return {
        "buildReceiptSHA256": sha256(receipt_raw),
        "fingerprintRoot": runtime_fingerprint_root(subjects),
        "runtimeManifestSHA256": sha256(manifest_raw),
        "subjects": subjects,
        "unsignedBuildClaimSHA256": sha256(claim_raw),
    }


def expected_attestation(app: Path) -> dict:
    app_metadata = signed_app_metadata(app)
    runtime = runtime_artifacts(app)
    return {
        "app": {
            **app_metadata,
            "designatedRequirementSHA256": sha256(app_metadata["designatedRequirement"].encode("utf-8")),
        },
        "attestationKind": ATTESTATION_KIND,
        "runtime": runtime,
        "schemaVersion": 1,
    }


def write_exclusive_canonical_json(path: Path, value: dict) -> None:
    if not path.is_absolute() or path.is_symlink() or path.parent.is_symlink() or not path.parent.is_dir():
        raise AttestationError("attestation must be an absolute non-symlink path")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, 0o644)
    try:
        payload = canonical_json(value)
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise AttestationError("attestation write made no progress")
            offset += written
        os.fchmod(descriptor, 0o644)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def create_attestation(app: Path, attestation: Path) -> None:
    if app in attestation.parents:
        raise AttestationError("attestation must remain external to the app bundle")
    write_exclusive_canonical_json(attestation, expected_attestation(app))


def verify_attestation(app: Path, attestation: Path) -> None:
    if app in attestation.parents:
        raise AttestationError("attestation must remain external to the app bundle")
    recorded, _ = read_canonical_json(attestation, "external release attestation")
    expected = expected_attestation(app)
    if recorded != expected:
        raise AttestationError("external release attestation does not match the signed app and Runtime subjects")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("create", "verify"):
        command = commands.add_parser(name)
        command.add_argument("--app", type=Path, required=True)
        command.add_argument("--attestation", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        app = arguments.app
        if arguments.command == "create":
            create_attestation(app, arguments.attestation)
        else:
            verify_attestation(app, arguments.attestation)
    except (AttestationError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
