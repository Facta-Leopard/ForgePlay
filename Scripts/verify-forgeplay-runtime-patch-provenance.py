#!/usr/bin/env python3
"""Verify ForgePlay's reviewed runtime patch inventory without claiming authorship proof."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path, PurePosixPath
from typing import Any


EXPECTED_DEVELOPMENT_MODEL = "forgeplay-project-owned-reviewed-provenance"
EXPECTED_UPSTREAM_SOURCE_BASE = {
    "project": "Wine",
    "version": "11.12",
    "archiveURL": "https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz",
    "archiveSHA256": "d3bc091192d985846c9f20065cc81f21331f01e22b736b131e3449e1306671bc",
    "releaseKeyFingerprint": "DA23579A74D4AD9AF9D3F945CEFAC8EAAF17519D",
}
EXPECTED_SOURCE_IDENTITY_UPSTREAM = {
    "archiveSHA256": EXPECTED_UPSTREAM_SOURCE_BASE["archiveSHA256"],
    "project": "Wine",
    "version": "11.12",
}
EXPECTED_PATCH_ORDER = [
    "wine-11.12-steam-cef-other-process-opengl-surface.patch",
    "wine-11.12-forgeplay-d3dmetal-bridge.patch",
    "wine-11.12-forgeplay-metal-window-surface-contract.patch",
    "wine-11.12-moltenvk-portability-enumeration.patch",
    "wine-11.12-prefix-scoped-wineserver-root.patch",
    "wine-11.12-app-group-mach-service.patch",
    "wine-11.12-app-sandbox-server-lock.patch",
    "wine-11.12-app-sandbox-executable-mappings.patch",
    "wine-11.12-macos-bundled-runtime-loading.patch",
    "wine-11.12-executable-scoped-process-observation.patch",
    "wine-11.12-steam-game-renderer-process-policy.patch",
    "wine-11.12-d3dmetal-native-thread-context.patch",
    "wine-11.12-d3dmetal-native-thread-state-sync.patch",
    "wine-11.12-game-mode-process-host-routing.patch",
    "wine-11.12-game-mode-direct-target-scope.patch",
    "wine-11.12-external-storage-grant-activation.patch",
    "wine-11.12-manual-steam-renderer-selection.patch",
    "wine-11.12-steam-renderer-control-plane-persistence.patch",
    "wine-11.12-managed-darwin-process-journal.patch",
    "wine-11.12-forced-font-family-replacements.patch",
    "wine-11.12-steam-game-cef-browser-process-policy.patch",
    "wine-11.12-steam-session-compatibility-controls.patch",
    "wine-11.12-helldivers2-process-policy.patch",
    "wine-11.12-heap-zero-memory.patch",
    "wine-11.12-media-foundation-video-output-negotiation.patch",
]
EXPECTED_CONTRACT_ORDER = [
    "wine-11.12-forgeplay-d3dmetal-bridge-contract.md",
]
EXPECTED_LICENSE_SIDECARS = [
    {
        "path": "wine-11.12-helldivers2-process-policy.patch.license",
        "sha256": "669ea7f1207d1c156f0af7cbb994e46e21986bd7484084fa99491d73afbfa64e",
        "patchPath": "wine-11.12-helldivers2-process-policy.patch",
        "classification": "forgeplay-authored-approved-derivative",
        "license": "LGPL-2.1-or-later",
    },
    {
        "path": "wine-11.12-heap-zero-memory.patch.license",
        "sha256": "dc7a66cee5b4e0b32ee770aa22094594509c165a4fc807235ffbb5b657e02383",
        "patchPath": "wine-11.12-heap-zero-memory.patch",
        "classification": "approved-derivative",
        "license": "LGPL-2.1-or-later",
    },
]
EXPECTED_EXPORT_LICENSE_SIDECARS = [
    {
        "path": "wine-11.12-game-mode-process-host-routing.patch.license",
        "sha256": "479efa2903cd8e63fcde50b441cbf2fba316cdd840c190a3df3d7c5e6311e8cf",
        "patchPath": "wine-11.12-game-mode-process-host-routing.patch",
        "classification": "lgpl-section-3-gpl-conversion-notice",
        "license": "GPL-3.0-only",
    },
    {
        "path": "wine-11.12-game-mode-direct-target-scope.patch.license",
        "sha256": "479efa2903cd8e63fcde50b441cbf2fba316cdd840c190a3df3d7c5e6311e8cf",
        "patchPath": "wine-11.12-game-mode-direct-target-scope.patch",
        "classification": "lgpl-section-3-gpl-conversion-notice",
        "license": "GPL-3.0-only",
    },
]
EXPECTED_INPUT_CLASSES = {
    "official-upstream-source",
    "public-platform-interface-contracts",
    "project-authored-behavior-contracts",
    "project-requirements",
    "repository-observation",
}
EXPECTED_OWNERSHIP = "ForgePlay project"
READ_CHUNK_BYTES = 1024 * 1024
MAX_PROVENANCE_LOCK_BYTES = 4 * 1024 * 1024
MAX_PATCH_BYTES = 64 * 1024 * 1024
MAX_BEHAVIOR_CONTRACT_BYTES = 4 * 1024 * 1024
MAX_LICENSE_SIDECAR_BYTES = 1024 * 1024
SAFE_BASENAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class VerificationError(RuntimeError):
    pass


def stable_file_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def read_stable_regular_file(
    path: Path | str,
    label: str,
    *,
    maximum_bytes: int,
    directory_fd: int | None = None,
) -> bytes:
    """Read one descriptor-bound file without following a final symlink."""

    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        descriptor = os.open(os.fspath(path), flags, dir_fd=directory_fd)
    except (FileNotFoundError, NotADirectoryError) as error:
        raise VerificationError(f"{label} is missing: {path}") from error
    except OSError as error:
        raise VerificationError(
            f"{label} could not be opened without following symlinks: {path}: {error}"
        ) from error

    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise VerificationError(f"{label} must be a non-symlink regular file: {path}")
        if before.st_nlink != 1:
            raise VerificationError(f"{label} must not be hardlinked: {path}")
        if before.st_size < 0 or before.st_size > maximum_bytes:
            raise VerificationError(
                f"{label} exceeds the {maximum_bytes}-byte review bound: {path}"
            )

        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(READ_CHUNK_BYTES, maximum_bytes - total + 1))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum_bytes:
                raise VerificationError(
                    f"{label} exceeded the {maximum_bytes}-byte review bound while reading: {path}"
                )

        after = os.fstat(descriptor)
        if stable_file_identity(before) != stable_file_identity(after) or total != before.st_size:
            raise VerificationError(f"{label} changed while it was being read: {path}")
        return b"".join(chunks)
    except OSError as error:
        raise VerificationError(f"{label} could not be read stably: {path}: {error}") from error
    finally:
        os.close(descriptor)


def open_stable_directory(path: Path, label: str) -> tuple[int, tuple[int, ...]]:
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise VerificationError(
            f"{label} must be an accessible non-symlink directory: {path}: {error}"
        ) from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(metadata.st_mode):
            raise VerificationError(f"{label} must be a non-symlink directory: {path}")
        identity = stable_file_identity(metadata)
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor, identity


def load_lock(path: Path) -> dict[str, Any]:
    try:
        payload = read_stable_regular_file(
            path,
            "runtime patch provenance lock",
            maximum_bytes=MAX_PROVENANCE_LOCK_BYTES,
        )
        value = json.loads(payload.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"runtime patch provenance lock is unreadable: {error}") from error
    if not isinstance(value, dict):
        raise VerificationError("runtime patch provenance lock must be a JSON object")
    return value


def validate_source_identity_lock(path: Path, provenance_lock: dict[str, Any]) -> None:
    try:
        value = json.loads(
            read_stable_regular_file(
                path,
                "runtime source identity lock",
                maximum_bytes=MAX_PROVENANCE_LOCK_BYTES,
            ).decode("utf-8")
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"runtime source identity lock is unreadable: {error}") from error
    if not isinstance(value, dict) or set(value) != {
        "currentFinalPatchedSourceTree",
        "schemaVersion",
        "upstreamSource",
    }:
        raise VerificationError("runtime source identity lock schema is invalid")
    if value["schemaVersion"] != 2 or value["upstreamSource"] != EXPECTED_SOURCE_IDENTITY_UPSTREAM:
        raise VerificationError("runtime source identity authority changed without review")
    current = value["currentFinalPatchedSourceTree"]
    upstream = provenance_lock.get("upstreamSource")
    current_digest = upstream.get("patchedSourceTreeSHA256") if isinstance(upstream, dict) else None
    if not isinstance(current_digest, str) or re.fullmatch(r"[0-9a-f]{64}", current_digest) is None:
        raise VerificationError("provenance lock current source identity is invalid")
    if current != {
        "hashAlgorithm": "forgeplay-source-tree-sha256-v1",
        "sha256": current_digest,
    }:
        raise VerificationError("current final patched source identity changed without review")
    if upstream.get("patchedSourceTreeSHA256") != current["sha256"]:
        raise VerificationError("provenance lock does not bind the current source identity")


def stable_sha256_at(
    directory_fd: int,
    name: str,
    label: str,
    *,
    maximum_bytes: int,
) -> str:
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    try:
        descriptor = os.open(name, flags, dir_fd=directory_fd)
    except OSError as error:
        raise VerificationError(
            f"{label} could not be descriptor-bound: {name}: {error}"
        ) from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise VerificationError(
                f"{label} must be a single-link regular file: {name}"
            )
        if before.st_size < 0 or before.st_size > maximum_bytes:
            raise VerificationError(
                f"{label} exceeds the {maximum_bytes}-byte review bound: {name}"
            )
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(
                descriptor,
                min(READ_CHUNK_BYTES, maximum_bytes - total + 1),
            )
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise VerificationError(
                    f"{label} exceeded its review bound while hashing: {name}"
                )
            digest.update(chunk)
        after = os.fstat(descriptor)
        if total != before.st_size or stable_file_identity(before) != stable_file_identity(after):
            raise VerificationError(
                f"{label} changed during descriptor-bound hashing: {name}"
            )
        return digest.hexdigest()
    except OSError as error:
        raise VerificationError(
            f"{label} could not be hashed stably: {name}: {error}"
        ) from error
    finally:
        os.close(descriptor)


def safe_basename(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise VerificationError(f"{label} path must be a non-empty string")
    parsed = PurePosixPath(value)
    if (
        parsed.is_absolute()
        or len(parsed.parts) != 1
        or parsed.name != value
        or value in {".", ".."}
        or SAFE_BASENAME_PATTERN.fullmatch(value) is None
    ):
        raise VerificationError(f"{label} path must be a safe basename: {value!r}")
    return value


def validate_entry(
    raw_entry: Any,
    *,
    patch_root_fd: int,
    patch_root: Path,
    label: str,
    expected_suffix: str,
    approved_input_classes: set[str],
) -> str:
    if not isinstance(raw_entry, dict):
        raise VerificationError(f"{label} entry must be an object")
    expected_keys = {
        "path",
        "sha256",
        "responsibility",
        "implementationOwnership",
        "approvedInputs",
    }
    if set(raw_entry) != expected_keys:
        raise VerificationError(f"{label} entry keys do not match the reviewed schema")

    name = safe_basename(raw_entry["path"], label)
    if not name.endswith(expected_suffix):
        raise VerificationError(f"{label} has the wrong file suffix: {name}")
    expected_digest = raw_entry["sha256"]
    if (
        not isinstance(expected_digest, str)
        or len(expected_digest) != 64
        or any(character not in "0123456789abcdef" for character in expected_digest)
    ):
        raise VerificationError(f"{label} has an invalid SHA-256: {name}")
    responsibility = raw_entry["responsibility"]
    if not isinstance(responsibility, str) or not responsibility.strip():
        raise VerificationError(f"{label} responsibility must be non-empty: {name}")
    if raw_entry["implementationOwnership"] != EXPECTED_OWNERSHIP:
        raise VerificationError(f"{label} has unreviewed implementation ownership: {name}")
    entry_inputs = raw_entry["approvedInputs"]
    if not isinstance(entry_inputs, list) or not entry_inputs:
        raise VerificationError(f"{label} must declare at least one approved input: {name}")
    if any(not isinstance(item, str) for item in entry_inputs):
        raise VerificationError(f"{label} approved inputs must be strings: {name}")
    if len(entry_inputs) != len(set(entry_inputs)):
        raise VerificationError(f"{label} approved inputs must be unique: {name}")
    if not set(entry_inputs).issubset(approved_input_classes):
        raise VerificationError(f"{label} uses an unapproved input class: {name}")

    path = patch_root / name
    maximum_bytes = (
        MAX_PATCH_BYTES if expected_suffix == ".patch" else MAX_BEHAVIOR_CONTRACT_BYTES
    )
    actual_digest = stable_sha256_at(
        patch_root_fd,
        name,
        label,
        maximum_bytes=maximum_bytes,
    )
    if actual_digest != expected_digest:
        raise VerificationError(
            f"{label} changed without provenance review: {name}; "
            f"expected {expected_digest}, found {actual_digest}"
        )
    return name


def validate_inventory(
    lock: dict[str, Any],
    patch_root: Path,
    *,
    include_export_license_inventory: bool,
) -> None:
    expected_top_level_keys = {
        "schemaVersion",
        "developmentModel",
        "reviewLimitation",
        "upstreamSource",
        "approvedInputClasses",
        "prohibitedInputPolicy",
        "patches",
        "patchLicenseSidecars",
        "behaviorContracts",
    }
    if set(lock) != expected_top_level_keys:
        raise VerificationError("runtime patch provenance lock keys do not match schema version 1")
    if lock["schemaVersion"] != 1:
        raise VerificationError("runtime patch provenance lock schemaVersion must be 1")
    if lock["developmentModel"] != EXPECTED_DEVELOPMENT_MODEL:
        raise VerificationError("runtime patch development model is not the reviewed provenance model")
    review_limitation = lock["reviewLimitation"]
    if not isinstance(review_limitation, str) or "does not independently prove" not in review_limitation:
        raise VerificationError("runtime patch provenance lock must state its proof limitation")
    upstream_source = lock["upstreamSource"]
    if not isinstance(upstream_source, dict) or set(upstream_source) != {
        *EXPECTED_UPSTREAM_SOURCE_BASE.keys(),
        "patchedSourceTreeSHA256",
    }:
        raise VerificationError("runtime patch upstream source schema has changed")
    if any(upstream_source.get(key) != value for key, value in EXPECTED_UPSTREAM_SOURCE_BASE.items()):
        raise VerificationError("runtime patch upstream source identity has changed without review")
    if re.fullmatch(r"[0-9a-f]{64}", upstream_source["patchedSourceTreeSHA256"]) is None:
        raise VerificationError("runtime patch current source tree identity is invalid")

    raw_input_classes = lock["approvedInputClasses"]
    if not isinstance(raw_input_classes, list) or set(raw_input_classes) != EXPECTED_INPUT_CLASSES:
        raise VerificationError("runtime patch approved input classes have changed without review")
    if len(raw_input_classes) != len(EXPECTED_INPUT_CLASSES):
        raise VerificationError("runtime patch approved input classes must be unique")
    prohibited_policy = lock["prohibitedInputPolicy"]
    if not isinstance(prohibited_policy, str) or not prohibited_policy.strip():
        raise VerificationError("runtime patch prohibited-input policy must be non-empty")

    patch_root_fd, patch_root_identity = open_stable_directory(
        patch_root, "runtime patch root"
    )
    try:
        directory_names = os.listdir(patch_root_fd)
    except OSError as error:
        os.close(patch_root_fd)
        raise VerificationError(f"runtime patch root could not be listed: {patch_root}: {error}") from error
    try:
        raw_patches = lock["patches"]
        raw_sidecars = lock["patchLicenseSidecars"]
        raw_contracts = lock["behaviorContracts"]
        if not all(
            isinstance(value, list) for value in (raw_patches, raw_sidecars, raw_contracts)
        ):
            raise VerificationError(
                "runtime patches, patchLicenseSidecars, and behaviorContracts must be arrays"
            )

        patch_names = [
            validate_entry(
                entry,
                patch_root_fd=patch_root_fd,
                patch_root=patch_root,
                label="runtime patch",
                expected_suffix=".patch",
                approved_input_classes=EXPECTED_INPUT_CLASSES,
            )
            for entry in raw_patches
        ]
        contract_names = [
            validate_entry(
                entry,
                patch_root_fd=patch_root_fd,
                patch_root=patch_root,
                label="runtime behavior contract",
                expected_suffix="-contract.md",
                approved_input_classes=EXPECTED_INPUT_CLASSES,
            )
            for entry in raw_contracts
        ]
        if patch_names != EXPECTED_PATCH_ORDER:
            raise VerificationError("runtime patch order or inventory has changed without review")

        expected_sidecar_keys = {
            "path",
            "sha256",
            "patchPath",
            "classification",
            "license",
        }
        for sidecar in raw_sidecars:
            if not isinstance(sidecar, dict) or set(sidecar) != expected_sidecar_keys:
                raise VerificationError(
                    "runtime patch license sidecar keys do not match the reviewed schema"
                )
            name = safe_basename(sidecar["path"], "runtime patch license sidecar")
            patch_name = safe_basename(
                sidecar["patchPath"], "runtime patch license sidecar patch"
            )
            if not patch_name.endswith(".patch") or name != f"{patch_name}.license":
                raise VerificationError(
                    f"runtime patch license sidecar must use the bound .patch.license basename: {name}"
                )
            if patch_name not in patch_names:
                raise VerificationError(
                    f"runtime patch license sidecar targets an unknown patch: {name}"
                )
        if raw_sidecars != EXPECTED_LICENSE_SIDECARS:
            raise VerificationError("runtime patch license sidecar bindings changed without review")
        for sidecar in raw_sidecars:
            name = sidecar["path"]
            actual_digest = stable_sha256_at(
                patch_root_fd,
                name,
                "runtime patch license sidecar",
                maximum_bytes=MAX_LICENSE_SIDECAR_BYTES,
            )
            if actual_digest != sidecar["sha256"]:
                raise VerificationError(
                    f"runtime patch license sidecar changed without review: {name}; "
                    f"expected {sidecar['sha256']}, found {actual_digest}"
                )
        export_sidecars = (
            EXPECTED_EXPORT_LICENSE_SIDECARS
            if include_export_license_inventory
            else []
        )
        for sidecar in export_sidecars:
            if sidecar["patchPath"] not in patch_names:
                raise VerificationError(
                    "export license sidecar targets an unknown patch: "
                    f"{sidecar['path']}"
                )
            actual_digest = stable_sha256_at(
                patch_root_fd,
                sidecar["path"],
                "export patch license sidecar",
                maximum_bytes=MAX_LICENSE_SIDECAR_BYTES,
            )
            if actual_digest != sidecar["sha256"]:
                raise VerificationError(
                    "export patch license sidecar changed without license review: "
                    f"{sidecar['path']}"
                )
        if contract_names != EXPECTED_CONTRACT_ORDER:
            raise VerificationError("runtime behavior-contract inventory has changed without review")

        actual_patch_names = sorted(name for name in directory_names if name.endswith(".patch"))
        actual_sidecar_names = sorted(
            name for name in directory_names if name.endswith(".patch.license")
        )
        actual_contract_names = sorted(
            name for name in directory_names if name.endswith("-contract.md")
        )
        if actual_patch_names != sorted(EXPECTED_PATCH_ORDER):
            raise VerificationError("runtime patch directory contains an unreviewed patch inventory")
        exact_sidecar_inventory = [
            *EXPECTED_LICENSE_SIDECARS,
            *export_sidecars,
        ]
        if actual_sidecar_names != sorted(entry["path"] for entry in exact_sidecar_inventory):
            raise VerificationError(
                "runtime patch directory contains an unreviewed patch license sidecar inventory"
            )
        if actual_contract_names != sorted(EXPECTED_CONTRACT_ORDER):
            raise VerificationError(
                "runtime patch directory contains an unreviewed behavior-contract inventory"
            )

        if stable_file_identity(os.fstat(patch_root_fd)) != patch_root_identity:
            raise VerificationError("runtime patch directory changed during provenance verification")
    except OSError as error:
        raise VerificationError(
            f"runtime patch directory could not be verified stably: {patch_root}: {error}"
        ) from error
    finally:
        os.close(patch_root_fd)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--source-identity-lock", required=True, type=Path)
    parser.add_argument("--patch-root", required=True, type=Path)
    parser.add_argument("--export-license-inventory", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        lock = load_lock(arguments.lock)
        validate_source_identity_lock(arguments.source_identity_lock, lock)
        validate_inventory(
            lock,
            arguments.patch_root,
            include_export_license_inventory=arguments.export_license_inventory,
        )
    except VerificationError as error:
        print(f"error: invalid ForgePlay runtime patch provenance: {error}", file=sys.stderr)
        return 1
    print(
        "verified ForgePlay runtime patch/license inventory and current source identity; "
        "this check does not independently prove authorship"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
