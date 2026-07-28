#!/usr/bin/env python3
"""Verify ForgePlay's reviewed runtime patch inventory without claiming authorship proof."""

from __future__ import annotations

import argparse
import hashlib
import json
import stat
import sys
from pathlib import Path, PurePosixPath
from typing import Any


EXPECTED_DEVELOPMENT_MODEL = "forgeplay-project-owned-clean-room"
EXPECTED_UPSTREAM_SOURCE = {
    "project": "Wine",
    "version": "11.12",
    "archiveURL": "https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz",
    "archiveSHA256": "d3bc091192d985846c9f20065cc81f21331f01e22b736b131e3449e1306671bc",
    "releaseKeyFingerprint": "DA23579A74D4AD9AF9D3F945CEFAC8EAAF17519D",
    "patchedSourceTreeSHA256": "01f174c44664cbc3a4f931b536080facef0a70d6bfa2c5603182abdba18ddc73",
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
    "wine-11.12-executable-scoped-process-arguments.patch",
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
]
EXPECTED_CONTRACT_ORDER = [
    "wine-11.12-forgeplay-d3dmetal-bridge-contract.md",
]
EXPECTED_INPUT_CLASSES = {
    "official-upstream-source",
    "public-platform-interface-contracts",
    "project-authored-behavior-contracts",
    "project-requirements",
    "repository-observation",
}
EXPECTED_OWNERSHIP = "ForgePlay project"


class VerificationError(RuntimeError):
    pass


def require_regular_single_link(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise VerificationError(f"{label} is missing: {path}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise VerificationError(f"{label} must be a non-symlink regular file: {path}")
    if metadata.st_nlink != 1:
        raise VerificationError(f"{label} must not be hardlinked: {path}")


def load_lock(path: Path) -> dict[str, Any]:
    require_regular_single_link(path, "runtime patch provenance lock")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"runtime patch provenance lock is unreadable: {error}") from error
    if not isinstance(value, dict):
        raise VerificationError("runtime patch provenance lock must be a JSON object")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_basename(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise VerificationError(f"{label} path must be a non-empty string")
    parsed = PurePosixPath(value)
    if parsed.is_absolute() or len(parsed.parts) != 1 or parsed.name != value or value in {".", ".."}:
        raise VerificationError(f"{label} path must be a safe basename: {value!r}")
    return value


def validate_entry(
    raw_entry: Any,
    *,
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
    require_regular_single_link(path, label)
    actual_digest = sha256(path)
    if actual_digest != expected_digest:
        raise VerificationError(
            f"{label} changed without provenance review: {name}; "
            f"expected {expected_digest}, found {actual_digest}"
        )
    return name


def validate_inventory(lock: dict[str, Any], patch_root: Path) -> None:
    expected_top_level_keys = {
        "schemaVersion",
        "developmentModel",
        "reviewLimitation",
        "upstreamSource",
        "approvedInputClasses",
        "prohibitedInputPolicy",
        "patches",
        "behaviorContracts",
    }
    if set(lock) != expected_top_level_keys:
        raise VerificationError("runtime patch provenance lock keys do not match schema version 1")
    if lock["schemaVersion"] != 1:
        raise VerificationError("runtime patch provenance lock schemaVersion must be 1")
    if lock["developmentModel"] != EXPECTED_DEVELOPMENT_MODEL:
        raise VerificationError("runtime patch development model is not the reviewed clean-room model")
    review_limitation = lock["reviewLimitation"]
    if not isinstance(review_limitation, str) or "does not independently prove" not in review_limitation:
        raise VerificationError("runtime patch provenance lock must state its proof limitation")
    if lock["upstreamSource"] != EXPECTED_UPSTREAM_SOURCE:
        raise VerificationError("runtime patch upstream source identity has changed without review")

    raw_input_classes = lock["approvedInputClasses"]
    if not isinstance(raw_input_classes, list) or set(raw_input_classes) != EXPECTED_INPUT_CLASSES:
        raise VerificationError("runtime patch approved input classes have changed without review")
    if len(raw_input_classes) != len(EXPECTED_INPUT_CLASSES):
        raise VerificationError("runtime patch approved input classes must be unique")
    prohibited_policy = lock["prohibitedInputPolicy"]
    if not isinstance(prohibited_policy, str) or not prohibited_policy.strip():
        raise VerificationError("runtime patch prohibited-input policy must be non-empty")

    if not patch_root.is_dir() or patch_root.is_symlink():
        raise VerificationError(f"runtime patch root must be a non-symlink directory: {patch_root}")
    raw_patches = lock["patches"]
    raw_contracts = lock["behaviorContracts"]
    if not isinstance(raw_patches, list) or not isinstance(raw_contracts, list):
        raise VerificationError("runtime patches and behaviorContracts must be arrays")

    patch_names = [
        validate_entry(
            entry,
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
            patch_root=patch_root,
            label="runtime behavior contract",
            expected_suffix="-contract.md",
            approved_input_classes=EXPECTED_INPUT_CLASSES,
        )
        for entry in raw_contracts
    ]
    if patch_names != EXPECTED_PATCH_ORDER:
        raise VerificationError("runtime patch order or inventory has changed without review")
    if contract_names != EXPECTED_CONTRACT_ORDER:
        raise VerificationError("runtime behavior-contract inventory has changed without review")

    actual_patch_names = sorted(path.name for path in patch_root.glob("*.patch"))
    actual_contract_names = sorted(path.name for path in patch_root.glob("*-contract.md"))
    if actual_patch_names != sorted(EXPECTED_PATCH_ORDER):
        raise VerificationError("runtime patch directory contains an unreviewed patch inventory")
    if actual_contract_names != sorted(EXPECTED_CONTRACT_ORDER):
        raise VerificationError("runtime patch directory contains an unreviewed behavior-contract inventory")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--patch-root", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        validate_inventory(load_lock(arguments.lock), arguments.patch_root)
    except VerificationError as error:
        print(f"error: invalid ForgePlay runtime patch provenance: {error}", file=sys.stderr)
        return 1
    print(
        "verified ForgePlay runtime patch inventory and reviewed hashes; "
        "this check does not independently prove authorship"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
