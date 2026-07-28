#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Facta-Leopard
# SPDX-License-Identifier: GPL-3.0-only
#
# ForgePlay Game Mode
# Original source: https://github.com/Facta-Leopard/ForgePlay

"""Verify the path-exact ForgePlay Game Mode source-license boundary."""

from __future__ import annotations

import hashlib
import json
import stat
import sys
from pathlib import Path
from typing import Any


LICENSE_EXPRESSION = "GPL-3.0-only"
COPYRIGHT_NOTICE = "Copyright (C) 2026 Facta-Leopard"
SPDX_COPYRIGHT = "SPDX-FileCopyrightText: 2026 Facta-Leopard"
SPDX_LICENSE = "SPDX-License-Identifier: GPL-3.0-only"
ORIGINAL_SOURCE = "https://github.com/Facta-Leopard/ForgePlay"
MIXED_NOTICE = "This notice does not apply GPL-3.0-only to unrelated"

EXPECTED_WHOLE_FILE_PATHS = {
    "Sources/ForgePlay/Models/GameModeEvidence.swift",
    "Sources/ForgePlay/Services/GameModeHostCapability.swift",
    "Sources/ForgePlay/Services/GameModeLaunchRequestStore.swift",
    "Tests/ForgePlayTests/GameModeHostCapabilityTests.swift",
    "Tests/ForgePlayTests/GameModeLaunchRequestStoreTests.swift",
    "Native/GameModeProcessHost/GameModeApplicationGroup.h",
    "Native/GameModeProcessHost/GameModeApplicationGroup.m",
    "Native/GameModeProcessHost/GameModeBuildIdentity.h",
    "Native/GameModeProcessHost/GameModeInheritedExecution.h",
    "Native/GameModeProcessHost/GameModeInheritedExecution.m",
    "Native/GameModeProcessHost/GameModeProcessHost-AppStore.entitlements",
    "Native/GameModeProcessHost/GameModeProcessHost-Development.entitlements",
    "Native/GameModeProcessHost/GameModeProcessHost-Distribution.entitlements",
    "Native/GameModeProcessHost/GameModeProcessHost.entitlements.in",
    "Native/GameModeProcessHost/GameModeProcessHost.m",
    "Native/GameModeProcessHost/GameModeRuntimeIdentity.h",
    "Native/GameModeProcessHost/GameModeRuntimeIdentity.m",
    "Native/GameModeProcessHost/Info.plist",
    "Native/GameModeProcessHost/Info.plist.in",
    "Native/GameModeProcessHost/PrefixExecutionLease.h",
    "Native/GameModeProcessHost/PrefixExecutionLease.m",
    "Native/GameModeProcessHost/README.md",
    "Native/GameModeProcessHost/SOURCE-CONTRACT.md",
    "Native/GameModeProcessHost/build-game-mode-process-host.sh",
    "Config/ForgePlayGameModeProcessHost.xcconfig",
    "Config/ForgePlayGameModeProcessHostAppStore.xcconfig",
    "Config/ForgePlayGameModeProcessHostDistribution.xcconfig",
    "Scripts/prepare-game-mode-host-build-identity.sh",
    "Scripts/verify-game-mode-source-licenses.py",
    "Scripts/tests/test-wine-game-mode-process-host-routing.sh",
}

EXPECTED_MIXED_PATHS = {
    "Sources/ForgePlay/Services/SafeProcessRunner.swift",
    "Sources/ForgePlay/UI/SteamLaunchView.swift",
    "Sources/ForgePlay/Services/SteamManager.swift",
    "Sources/ForgePlay/Services/SteamPrefixService.swift",
    "Sources/ForgePlay/Services/SupportBundleService.swift",
    "Sources/ForgePlay/App/AppServices.swift",
    "Sources/ForgePlay/Services/PrefixExecutionLease.swift",
    "project.yml",
}

EXPECTED_PATCH_PATHS = {
    "Resources/Runners/ForgePlayRuntime/Patches/"
    "wine-11.12-game-mode-process-host-routing.patch",
    "Resources/Runners/ForgePlayRuntime/Patches/"
    "wine-11.12-game-mode-direct-target-scope.patch",
}
PATCH_SIDECAR_COMMENT = (
    "SPDX-FileComment: Derived from Wine 11.12; upstream copyrights are "
    "retained. See LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md."
)

REQUIRED_SYMBOL_TOKENS = {
    "Sources/ForgePlay/Services/SafeProcessRunner.swift": {
        "GameModeSteamChildSelectionResolver",
        "GameModeHostLaunchRecord",
        "GameModeHostEvidenceRecord",
        "GameModeHostEvidenceProcessIdentity",
        "registerGameModeHostLaunch",
        "registeredGameModeHostProcessIDs",
        "gameModeHostEvidenceProcessIDs",
        "gameModeHostEvidenceProcessIdentities",
        "gameModePolicy",
        "runtimeCompatibilityDiagnostics",
    },
    "Sources/ForgePlay/UI/SteamLaunchView.swift": {
        "ActiveSteamSessionConfiguration",
        "isExperimentalGameModeEnabledForNextLaunch",
        "experimentalGameModeControl",
        "gameModeStateLabel",
        "launchSteam",
    },
    "Sources/ForgePlay/Services/SteamManager.swift": {
        "gameModePolicy",
        "launchSteam",
        "launchSteamUnfinalized",
    },
    "Sources/ForgePlay/Services/SteamPrefixService.swift": {
        "gameModePolicy",
        "launchSteam",
    },
    "Sources/ForgePlay/Services/SupportBundleService.swift": {
        "GameModeHostCoordinationPaths",
        "game-mode-process-host",
        "createSupportBundle",
    },
    "Sources/ForgePlay/App/AppServices.swift": {
        "ManagedWineSessionRegistry",
        "acquireExclusiveMutation",
        "executeAppTerminationSteamShutdown",
    },
    "Sources/ForgePlay/Services/PrefixExecutionLease.swift": {
        "sharedExecution",
        "acquireSharedExecution",
        "transitionToSharedExecution",
        "transitionToExclusiveMutation",
    },
    "project.yml": {
        "GameModeProcessHost",
        "Contents/Helpers",
        "preBuildScripts",
    },
}


class VerificationError(RuntimeError):
    pass


def require_regular_file(path: Path, label: str) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError as error:
        raise VerificationError(f"{label} is missing: {path}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise VerificationError(f"{label} must be a non-symlink regular file: {path}")
    if metadata.st_nlink != 1:
        raise VerificationError(f"{label} must not be hardlinked: {path}")


def read_text(root: Path, relative: str, label: str) -> str:
    path = root / relative
    require_regular_file(path, label)
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        raise VerificationError(f"{label} is not readable UTF-8: {path}") from error


def read_json(root: Path, relative: str, label: str) -> dict[str, Any]:
    try:
        value = json.loads(read_text(root, relative, label))
    except json.JSONDecodeError as error:
        raise VerificationError(f"{label} is invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise VerificationError(f"{label} must be a JSON object")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_string_list(value: Any, label: str) -> list[str]:
    if (
        not isinstance(value, list)
        or any(not isinstance(item, str) or not item for item in value)
        or len(value) != len(set(value))
    ):
        raise VerificationError(f"{label} must be a unique non-empty string array")
    return value


def verify_manifest(root: Path) -> tuple[dict[str, Any], str]:
    manifest_relative = (
        "LICENSES/ForgePlayGameMode/GAME_MODE_FILE_LICENSES.json"
    )
    manifest = read_json(root, manifest_relative, "Game Mode file-license manifest")
    expected_keys = {
        "schemaVersion",
        "licenseExpression",
        "copyrightNotice",
        "originalSource",
        "scopeDocument",
        "symbolManifest",
        "wholeFileSPDX",
        "mixedSymbolScope",
        "contentAddressedExternalNotice",
    }
    if set(manifest) != expected_keys:
        raise VerificationError("Game Mode file-license manifest keys changed")
    if manifest["schemaVersion"] != 1:
        raise VerificationError("Game Mode file-license schemaVersion must be 1")
    if manifest["licenseExpression"] != LICENSE_EXPRESSION:
        raise VerificationError("Game Mode file-license expression is not GPL-3.0-only")
    if manifest["copyrightNotice"] != COPYRIGHT_NOTICE:
        raise VerificationError("Game Mode copyright notice changed")
    if manifest["originalSource"] != ORIGINAL_SOURCE:
        raise VerificationError("Game Mode original-source URL changed")
    if manifest["scopeDocument"] != (
        "LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md"
    ):
        raise VerificationError("Game Mode scope-document path changed")
    symbol_relative = manifest["symbolManifest"]
    if symbol_relative != (
        "LICENSES/ForgePlayGameMode/GAME_MODE_SYMBOL_MANIFEST.md"
    ):
        raise VerificationError("Game Mode symbol-manifest path changed")

    whole_paths = set(require_string_list(manifest["wholeFileSPDX"], "wholeFileSPDX"))
    mixed_paths = set(require_string_list(manifest["mixedSymbolScope"], "mixedSymbolScope"))
    if whole_paths != EXPECTED_WHOLE_FILE_PATHS:
        raise VerificationError(
            "whole-file GPL scope changed without verifier review; "
            f"missing={sorted(EXPECTED_WHOLE_FILE_PATHS - whole_paths)}, "
            f"unexpected={sorted(whole_paths - EXPECTED_WHOLE_FILE_PATHS)}"
        )
    if mixed_paths != EXPECTED_MIXED_PATHS:
        raise VerificationError(
            "mixed-file GPL scope changed without verifier review; "
            f"missing={sorted(EXPECTED_MIXED_PATHS - mixed_paths)}, "
            f"unexpected={sorted(mixed_paths - EXPECTED_MIXED_PATHS)}"
        )

    patch_entries = manifest["contentAddressedExternalNotice"]
    if not isinstance(patch_entries, list) or len(patch_entries) != 2:
        raise VerificationError("Game Mode patch license assignments must contain two entries")
    patch_paths: set[str] = set()
    for entry in patch_entries:
        if not isinstance(entry, dict) or set(entry) != {
            "path",
            "conversionBasis",
            "reason",
        }:
            raise VerificationError("Game Mode patch license entry keys changed")
        path = entry["path"]
        if not isinstance(path, str) or not path:
            raise VerificationError("Game Mode patch license path is invalid")
        if entry["conversionBasis"] != "LGPL-2.1 section 3":
            raise VerificationError(f"Game Mode patch conversion basis changed: {path}")
        reason = entry["reason"]
        if not isinstance(reason, str) or "version-matched patch bytes" not in reason:
            raise VerificationError(f"Game Mode patch external-notice reason is incomplete: {path}")
        patch_paths.add(path)
    if patch_paths != EXPECTED_PATCH_PATHS:
        raise VerificationError("Game Mode patch license paths changed")
    return manifest, symbol_relative


def verify_whole_files(root: Path) -> None:
    for relative in sorted(EXPECTED_WHOLE_FILE_PATHS):
        text = read_text(root, relative, "whole-file Game Mode source")
        header_text = "\n".join(text.splitlines()[:24])
        for marker in (SPDX_COPYRIGHT, SPDX_LICENSE, ORIGINAL_SOURCE):
            if marker not in header_text:
                raise VerificationError(
                    f"whole-file GPL notice is incomplete: {relative}: {marker}"
                )
        if "SPDX-License-Identifier: LGPL-2.1-or-later" in header_text:
            raise VerificationError(
                f"converted Game Mode source retains an LGPL SPDX identifier: {relative}"
            )

    native_root = root / "Native/GameModeProcessHost"
    if not native_root.is_dir() or native_root.is_symlink():
        raise VerificationError("GameModeProcessHost source directory is unavailable")
    native_files = {
        path.relative_to(root).as_posix()
        for path in native_root.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    classified_native = {
        path
        for path in EXPECTED_WHOLE_FILE_PATHS
        if path.startswith("Native/GameModeProcessHost/")
    }
    if native_files != classified_native:
        raise VerificationError(
            "GameModeProcessHost contains an unclassified file; "
            f"missing={sorted(classified_native - native_files)}, "
            f"unexpected={sorted(native_files - classified_native)}"
        )

    host_source = read_text(
        root,
        "Native/GameModeProcessHost/GameModeProcessHost.m",
        "Wine-derived Game Mode host",
    )
    for marker in (
        "SPDX-FileCopyrightText: 2000 Alexandre Julliard",
        "Wine 11.12",
        "LGPL 2.1 section 3",
    ):
        if marker not in host_source:
            raise VerificationError(f"Wine-derived host provenance is incomplete: {marker}")

    source_contract = read_text(
        root,
        "Native/GameModeProcessHost/SOURCE-CONTRACT.md",
        "Game Mode host source contract",
    )
    for marker in (
        "SPDX-FileCopyrightText: 2000 Alexandre Julliard",
        "converted to and distributed under `GPL-3.0-only`",
        "LGPL 2.1 section 3",
        "ab7df8fbca3308fba27b7f3e081526ca772ec81b39733d1b16f4374ef720e857",
    ):
        if marker not in source_contract:
            raise VerificationError(f"Game Mode host conversion record is incomplete: {marker}")


def verify_no_unexpected_whole_file_gpl(root: Path) -> None:
    scan_roots = [
        root / "Sources",
        root / "Tests",
        root / "Native",
        root / "Config",
        root / "Scripts",
    ]
    actual_gpl_headers: set[str] = set()
    for scan_root in scan_roots:
        if not scan_root.is_dir() or scan_root.is_symlink():
            continue
        for path in scan_root.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            relative = path.relative_to(root).as_posix()
            if relative.startswith("Scripts/Templates/"):
                continue
            try:
                header_text = "\n".join(
                    path.read_text(encoding="utf-8").splitlines()[:24]
                )
            except (OSError, UnicodeDecodeError):
                continue
            if SPDX_LICENSE in header_text:
                actual_gpl_headers.add(relative)

    project_file = root / "project.yml"
    if project_file.is_file() and not project_file.is_symlink():
        project_header = "\n".join(
            project_file.read_text(encoding="utf-8").splitlines()[:24]
        )
        if SPDX_LICENSE in project_header:
            actual_gpl_headers.add("project.yml")

    if actual_gpl_headers != EXPECTED_WHOLE_FILE_PATHS:
        raise VerificationError(
            "whole-file GPL header scope changed without manifest review; "
            f"missing={sorted(EXPECTED_WHOLE_FILE_PATHS - actual_gpl_headers)}, "
            f"unexpected={sorted(actual_gpl_headers - EXPECTED_WHOLE_FILE_PATHS)}"
        )


def verify_mixed_files(root: Path, symbol_relative: str) -> None:
    symbol_text = read_text(root, symbol_relative, "Game Mode symbol manifest")
    for relative in sorted(EXPECTED_MIXED_PATHS):
        source_text = read_text(root, relative, "mixed Game Mode source")
        if symbol_relative.split("/")[-1] not in source_text:
            raise VerificationError(f"mixed source lacks the symbol-manifest pointer: {relative}")
        if MIXED_NOTICE not in source_text.replace("\n", " "):
            raise VerificationError(f"mixed source lacks the non-spillover notice: {relative}")
        if SPDX_LICENSE in source_text:
            raise VerificationError(
                f"mixed source incorrectly applies GPL to the whole file: {relative}"
            )
        if f"`{relative}`" not in symbol_text:
            raise VerificationError(f"symbol manifest lacks a mixed source section: {relative}")
        for token in sorted(REQUIRED_SYMBOL_TOKENS[relative]):
            if token not in source_text:
                raise VerificationError(
                    f"mixed source no longer contains its declared Game Mode token: "
                    f"{relative}: {token}"
                )
            if token not in symbol_text:
                raise VerificationError(
                    f"symbol manifest lacks a declared Game Mode token: {relative}: {token}"
                )


def verify_content_addressed_patches(root: Path) -> None:
    lock = read_json(
        root,
        "Config/ForgePlayRuntimePatchProvenance.lock.json",
        "Runtime patch provenance lock",
    )
    raw_entries = lock.get("patches")
    if not isinstance(raw_entries, list):
        raise VerificationError("Runtime patch provenance entries are unavailable")
    entries: dict[str, dict[str, Any]] = {}
    for entry in raw_entries:
        if isinstance(entry, dict) and isinstance(entry.get("path"), str):
            entries[entry["path"]] = entry

    for relative in sorted(EXPECTED_PATCH_PATHS):
        patch = root / relative
        require_regular_file(patch, "content-addressed Game Mode patch")
        name = patch.name
        entry = entries.get(name)
        if entry is None:
            raise VerificationError(f"Game Mode patch lacks a provenance entry: {name}")
        expected_digest = entry.get("sha256")
        if not isinstance(expected_digest, str) or sha256(patch) != expected_digest:
            raise VerificationError(f"Game Mode patch differs from its provenance hash: {name}")


def verify_export_patch_sidecars(root: Path) -> None:
    export_marker = root / ".forgeplay-source-export"
    if not export_marker.exists():
        return
    require_regular_file(export_marker, "open-source export marker")

    expected_sidecars = {
        f"{relative}.license"
        for relative in EXPECTED_PATCH_PATHS
    }
    patch_root = root / "Resources/Runners/ForgePlayRuntime/Patches"
    actual_sidecars = {
        path.relative_to(root).as_posix()
        for path in patch_root.glob("*.patch.license")
        if path.is_file() or path.is_symlink()
    }
    if actual_sidecars != expected_sidecars:
        raise VerificationError(
            "Game Mode patch SPDX sidecars changed; "
            f"missing={sorted(expected_sidecars - actual_sidecars)}, "
            f"unexpected={sorted(actual_sidecars - expected_sidecars)}"
        )

    expected_text = "\n".join(
        [
            SPDX_COPYRIGHT,
            SPDX_LICENSE,
            PATCH_SIDECAR_COMMENT,
            "",
        ]
    )
    for relative in sorted(expected_sidecars):
        text = read_text(root, relative, "Game Mode patch SPDX sidecar")
        if text != expected_text:
            raise VerificationError(
                f"Game Mode patch SPDX sidecar is not canonical: {relative}"
            )


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "usage: verify-game-mode-source-licenses.py <source root>",
            file=sys.stderr,
        )
        return 64
    root = Path(sys.argv[1])
    if not root.is_absolute() or not root.is_dir() or root.is_symlink():
        print(
            f"error: source root must be an absolute non-symlink directory: {root}",
            file=sys.stderr,
        )
        return 64
    root = root.resolve(strict=True)
    try:
        _, symbol_relative = verify_manifest(root)
        verify_whole_files(root)
        verify_no_unexpected_whole_file_gpl(root)
        verify_mixed_files(root, symbol_relative)
        verify_content_addressed_patches(root)
        verify_export_patch_sidecars(root)
    except VerificationError as error:
        print(f"error: invalid Game Mode source license scope: {error}", file=sys.stderr)
        return 1
    print(f"ForgePlay Game Mode source license scope verified: {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
