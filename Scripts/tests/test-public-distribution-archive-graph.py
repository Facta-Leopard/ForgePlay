#!/usr/bin/env python3
"""Focused release-authority fixtures for the public source export verifier.

The fixture deliberately uses a separate temporary Git repository as the
release authority.  It never invokes a generator, xcodebuild, or packaging
command: each rejection must happen at the source-export gate.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "Scripts/verify-open-source-export.sh"
BUILDER = ROOT / "Scripts/build-public-distribution-archive.sh"
OFFICIAL_RELEASE_BUILDER = ROOT / "Scripts/build-commercial-release.sh"
EXPORTER = ROOT / "Scripts/export-open-source.sh"
PROJECT_GENERATOR = ROOT / "Scripts/generate-xcode-project.sh"
RUNTIME_RECEIPT_VERIFIER = ROOT / "Scripts/verify-public-runtime-build-receipt.py"
QUARANTINE_TOOL = ROOT / "Scripts/quarantine-owned-directory.py"

SCRIPT_NAMES = {
    "build-commercial-release.sh", "build-forgeplay-wine-runtime.sh",
    "build-public-forgeplay-runtime.sh",
    "build-public-distribution-archive.sh", "check-project-build-warnings.sh",
    "export-open-source.sh", "freeze-public-source-export.py",
    "generate-compatibility-db-signing-key.swift",
    "generate-xcode-project.sh", "materialize-locked-gstreamer-runtime.py",
    "materialize-locked-renderer.py", "materialize-locked-runtime-dependencies.py",
    "materialize-forgeplay-wine-11.12-source.sh", "open-source-export-transaction.py",
    "package-forgeplay-runtime.sh", "prepare-app-store-runtime-payload.sh",
    "prepare-clean-build-root.sh", "prepare-dmg-output-path.sh",
    "prepare-game-mode-host-build-identity.sh", "quarantine-owned-directory.py",
    "public-runtime-release-attestation.py", "public-release-set-transaction.py",
    "restore-preserved-apple-d3dmetal-signatures.sh", "runtime-core-payload-identity.py",
    "runtime-sbom.py", "sign-app-store-runtime-code.sh",
    "sign-compatibility-db-feed.swift", "test-wine-session-compatibility.sh",
    "validate-d3dmetal-ngx-bridge.sh",
    "validate-compatibility-db-public-key.swift", "validate-product-identity.sh",
    "verify-app-store-app-security.sh",
    "verify-app-store-controller-permissions.py", "verify-bundled-runtime-capability.sh",
    "verify-clean-wine-runtime-markers.py", "verify-copyleft-source-packages.py",
    "verify-dmg-contents.sh",
    "verify-forgeplay-runtime-patch-provenance.py",
    "verify-game-mode-source-licenses.py", "verify-legal-documents.sh",
    "verify-license-documents.sh", "verify-macho-runtime-closure.py",
    "verify-notary-submit-json.sh", "verify-open-source-export.sh",
    "verify-privacy-manifest.sh", "verify-project-documents.sh",
    "verify-public-release-assets.sh", "verify-public-release-license-policy.sh",
    "verify-public-runtime-build-receipt.py",
    "verify-release-app-info.sh", "verify-release-app-localizations.sh",
    "verify-release-app-security.sh", "verify-release-bundle-privacy.sh",
    "verify-release-evidence.sh", "verify-wine-runtime-build-paths.py",
}
CONFIG_NAMES = {
    "ForgePlayApp.xcconfig", "ForgePlayAppStore.xcconfig", "ForgePlayDefaults.xcconfig",
    "ForgePlayDirectRelease.xcconfig",
    "ForgePlayCopyleftSourcePackages.json", "ForgePlayDistribution.xcconfig",
    "ForgePlayExternalStorageAccessBridge.xcconfig",
    "ForgePlayGameModeProcessHost.xcconfig", "ForgePlayGameModeProcessHostAppStore.xcconfig",
    "ForgePlayGameModeProcessHostDistribution.xcconfig", "ForgePlayGStreamerPayload.lock.json",
    "ForgePlayGameModeProcessHostRelease.xcconfig",
    "ForgePlayNetworkControlHelper.xcconfig",
    "ForgePlayNetworkControlHelperAppStore.xcconfig",
    "ForgePlayNetworkControlHelperDistribution.xcconfig",
    "ForgePlayPublicDistributionSourceGraph.json", "ForgePlayRendererPayload.lock.json",
    "ForgePlayRuntimeDependencies.lock.json", "ForgePlayRuntimePatchProvenance.lock.json",
    "ForgePlayRuntimeSourceIdentity.lock.json", "ForgePlayTests.xcconfig",
}
SCRIPT_TESTS = {
    "test-copyleft-source-packages.py", "test-freeze-public-source-export.py",
    "test-generate-xcode-project.sh",
    "test-open-source-export-transaction.py", "test-packaging-license-release-contracts.py",
    "test-public-distribution-archive-graph.py", "test-quarantine-owned-directory.py",
    "test-public-release-set-transaction.py", "test-public-runtime-build-receipt.py",
    "test-public-runtime-release-attestation.py",
    "test-wine-game-mode-process-host-routing.sh",
}


def write(path: Path, payload: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)
    path.chmod(mode)


def git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", os.fspath(repository), *arguments],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def canonical_inventory(inventory: dict) -> bytes:
    return (json.dumps(inventory, indent=2, sort_keys=True) + "\n").encode("utf-8")


def inventory_digest(entries: list[dict], release_commit: str) -> str:
    lines = [
        "forgeplay-public-source-inventory-v2",
        f"releaseCommit={release_commit}",
        "gitObjectFormat=sha1",
    ]
    lines.extend(
        f"{row['path']}\0{row['mode']}\0{row['byteLength']}\0{row['sha256']}\0"
        + json.dumps(row["origin"], sort_keys=True, separators=(",", ":"))
        for row in entries
    )
    return hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest()


class PublicDistributionArchiveGraphTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="forgeplay-export-trusted-git.")
        self.root = Path(self.temporary.name).resolve()
        self.authority = self.root / "trusted-release.git"
        self.export = self.root / "OpenSource"
        self.runtime = self.root / "PublicRuntime"
        self.workspace = self.root / "PublicBuild"
        self.archive = self.root / "ForgePlay.xcarchive"
        self.derived = self.root / "DerivedData"
        self.archive_log = self.root / "archive.log"
        self.fake_xcodebuild_arguments = self.root / "fake-xcodebuild-arguments.json"
        self.generator_receipt = self.root / "generator.receipt"
        self.archive_log.touch()
        self.export.mkdir()
        self.authority.mkdir()
        git(self.authority, "init", "-q")
        git(self.authority, "config", "user.name", "Fixture")
        git(self.authority, "config", "user.email", "fixture@example.invalid")
        self._write_release_tree()
        git(self.authority, "add", ".")
        git(self.authority, "commit", "-qm", "public fixture")
        self.release_commit = git(self.authority, "rev-parse", "HEAD")
        self._materialize_export()
        self._write_inventory()
        self._create_runtime_output()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_release_tree(self) -> None:
        project = b'''Distribution: Config/ForgePlayDistribution.xcconfig
Distribution: Config/ForgePlayNetworkControlHelperDistribution.xcconfig
"$SRCROOT/Scripts/sign-app-store-runtime-code.sh"
"$SRCROOT/Scripts/prepare-game-mode-host-build-identity.sh"
Sources/ForgePlay/ForgePlay-Runtime-Inherit.entitlements
Sources/ForgePlay/ForgePlay-Runtime-Direct.entitlements
Resources/PublicDistributionBuildClaim.json
Native/NetworkControlHelper/ForgePlayNetworkControl.plist
Native/NetworkControlHelper/main.swift
/usr/bin/install -m 0444 "$claim_source" "$claim_destination"
'''
        write(self.authority / "project.yml", project)
        write(self.authority / "LICENSE.md", b"fixture license\n")
        for name in CONFIG_NAMES:
            payload = b"fixture config\n"
            if name == "ForgePlayRuntimeSourceIdentity.lock.json":
                payload = b'{"currentFinalPatchedSourceTree":{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"schemaVersion":2}\n'
            elif name == "ForgePlayRuntimePatchProvenance.lock.json":
                payload = b'{"upstreamSource":{"patchedSourceTreeSHA256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n'
            elif name == "ForgePlayPublicDistributionSourceGraph.json":
                required = [
                    "project.yml", "Config/ForgePlayApp.xcconfig",
                    "Config/ForgePlayCopyleftSourcePackages.json",
                    "Config/ForgePlayDefaults.xcconfig",
                    "Config/ForgePlayDirectRelease.xcconfig", "Config/ForgePlayDistribution.xcconfig",
                    "Config/ForgePlayExternalStorageAccessBridge.xcconfig",
                    "Config/ForgePlayGameModeProcessHost.xcconfig",
                    "Config/ForgePlayGameModeProcessHostDistribution.xcconfig",
                    "Config/ForgePlayGameModeProcessHostRelease.xcconfig",
                    "Config/ForgePlayNetworkControlHelper.xcconfig",
                    "Config/ForgePlayNetworkControlHelperDistribution.xcconfig",
                    "Config/ForgePlayPublicDistributionSourceGraph.json",
                    "Sources/ForgePlay/ForgePlay-Distribution.entitlements",
                    "Sources/ForgePlay/ForgePlay-DirectRelease.entitlements",
                    "Sources/ForgePlay/ForgePlay-Runtime-Direct.entitlements",
                    "Sources/ForgePlay/ForgePlay-Runtime-Inherit.entitlements",
                    "Native/GameModeProcessHost/GameModeProcessHost-Distribution.entitlements",
                    "Native/GameModeProcessHost/GameModeProcessHost-Release.entitlements",
                    "Native/NetworkControlHelper/ForgePlayNetworkControl.plist",
                    "Native/NetworkControlHelper/Info.plist",
                    "Native/NetworkControlHelper/main.swift",
                    "Resources/AppIcon.icon/Assets/ForgePlay_ICON_Dark.png",
                    "Resources/AppIcon.icon/Assets/ForgePlay_ICON_Default.png",
                    "Resources/AppIcon.icon/icon.json",
                    *[f"Scripts/{script}" for script in sorted(SCRIPT_NAMES)],
                ]
                payload = canonical_inventory({
                    "archiveCommandPath": "Scripts/build-public-distribution-archive.sh",
                    "buildClaimResourcePath": "Resources/PublicDistributionBuildClaim.json",
                    "excludedThirdPartyPayloadRoots": ["Resources/Runners/ForgePlayRuntime/Frameworks/renderer/d3dmetal"],
                    "requiredReleaseCommitPaths": required,
                    "runtimePayloadInjectionRoot": "Resources/Runners/ForgePlayRuntime",
                    "schemaVersion": 1,
                })
            write(self.authority / "Config" / name, payload)
        for script in SCRIPT_NAMES:
            payload = b"#!/usr/bin/env python3\npass\n" if script in {
                "verify-game-mode-source-licenses.py", "verify-forgeplay-runtime-patch-provenance.py"
            } else b"#!/bin/sh\nexit 0\n"
            if script == "verify-open-source-export.sh":
                payload = VERIFIER.read_bytes()
            elif script == "build-public-distribution-archive.sh":
                payload = BUILDER.read_bytes()
            elif script == "verify-public-runtime-build-receipt.py":
                payload = RUNTIME_RECEIPT_VERIFIER.read_bytes()
            elif script == "generate-xcode-project.sh":
                payload = PROJECT_GENERATOR.read_bytes()
            elif script == "verify-bundled-runtime-capability.sh":
                payload = b'''#!/bin/bash
set -euo pipefail
case "${1:-}" in
  --release-runtime-inventory-only)
    [[ "$#" -eq 2 ]]
    runtime_root="$2"
    ;;
  --verify-runtime-file-inventory)
    [[ "$#" -eq 3 && "$3" == "$2/RuntimeFileInventory.json" ]]
    runtime_root="$2"
    ;;
  *)
    exit 64
    ;;
esac
/usr/bin/python3 - "$runtime_root" "$FORGEPLAY_FAKE_RUNTIME_AUTHORITY" <<'PY'
import hashlib
import os
import stat
import sys
from pathlib import Path


def snapshot(root):
    root = Path(root)
    rows = []
    for candidate in sorted(root.rglob("*")):
        relative = candidate.relative_to(root).as_posix()
        metadata = candidate.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            rows.append((relative, "directory"))
        elif stat.S_ISREG(metadata.st_mode):
            rows.append((
                relative,
                "file",
                bool(metadata.st_mode & 0o111),
                hashlib.sha256(candidate.read_bytes()).hexdigest(),
            ))
        elif stat.S_ISLNK(metadata.st_mode):
            rows.append((relative, "symlink", os.readlink(candidate)))
        else:
            raise SystemExit(f"unsupported fixture Runtime entry: {relative}")
    return rows


if snapshot(sys.argv[1]) != snapshot(sys.argv[2]):
    raise SystemExit("fixture Runtime tree differs from its authority")
PY
'''
            elif script == "quarantine-owned-directory.py":
                payload = QUARANTINE_TOOL.read_bytes()
            if script == "package-forgeplay-runtime.sh":
                payload = b"#!/bin/sh\n# --public-source-package\n# public-source package mode requires FORGEPLAY_RUNTIME_POLICY_SOURCE\n"
            elif script == "materialize-forgeplay-wine-11.12-source.sh":
                payload = b"#!/bin/sh\n# ForgePlayRuntimeSourceIdentity.lock.json\n"
            write(self.authority / "Scripts" / script, payload, 0o755)
        for script_test in SCRIPT_TESTS:
            mode = 0o755 if script_test in {
                "test-copyleft-source-packages.py",
                "test-freeze-public-source-export.py",
                "test-generate-xcode-project.sh",
                "test-public-release-set-transaction.py",
            } else 0o644
            write(self.authority / "Scripts/tests" / script_test, b"fixture test\n", mode)
        write(self.authority / "Scripts/Fixtures/WineSessionCompatibility/session_compatibility_probe.c", b"int main(void) { return 0; }\n")
        for path in [
            "Sources/ForgePlay/ForgePlay-Distribution.entitlements",
            "Sources/ForgePlay/ForgePlay-DirectRelease.entitlements",
            "Sources/ForgePlay/ForgePlay-Runtime-Direct.entitlements",
            "Sources/ForgePlay/ForgePlay-Runtime-Inherit.entitlements",
            "Native/GameModeProcessHost/GameModeProcessHost-Distribution.entitlements",
            "Native/GameModeProcessHost/GameModeProcessHost-Release.entitlements",
            "Native/NetworkControlHelper/ForgePlayNetworkControl.plist",
            "Native/NetworkControlHelper/Info.plist",
            "Native/NetworkControlHelper/main.swift",
            "Tests/ForgePlayTests/GameModeHostCapabilityTests.swift",
            "Tests/ForgePlayTests/GameModeLaunchRequestStoreTests.swift",
            "LICENSES/fixture.txt",
            "site-data/fixture.txt",
            "Resources/CompatibilityDBPublicKey.base64",
            "Resources/AppIcon.icon/Assets/ForgePlay_ICON_Dark.png",
            "Resources/AppIcon.icon/Assets/ForgePlay_ICON_Default.png",
            "Resources/AppIcon.icon/icon.json",
        ]:
            write(self.authority / path, b"fixture\n")
        write(
            self.authority / "Resources/Runners/ForgePlayRuntime/RuntimeManifest.json",
            canonical_inventory({
                "corePayloadFingerprint": "b" * 64,
                "hostSupportPayloadFingerprint": "c" * 64,
                "patchSetSHA256": "d" * 64,
                "runnerBuildFingerprint": "e" * 64,
                "sourceTreeSHA256": "a" * 64,
            }),
        )
        for locale in ("en", "ko", "es", "de", "ja", "zh-Hans", "zh-Hant", "fr"):
            for filename in ("InfoPlist.strings", "Localizable.strings", "ForgePlayLicenseNotice.md"):
                write(self.authority / f"Resources/{locale}.lproj/{filename}", b"fixture\n")
        readme = b"RTL_USER_PROCESS_PARAMETERS.ImagePathName GameModeProcessHost Wine 11.12 steam_api64.dll\n"
        for name in ("README.md", "README_EN.md", "README_KO.md"):
            write(self.authority / name, readme)
        write(self.authority / "SOURCE-LICENSES.md", b"wholeFileSPDX GAME_MODE_SYMBOL_MANIFEST.md adjacent `.license` sidecars does not by itself apply the Game Mode exact release commit SOURCE-INVENTORY.json PublicDistributionBuildClaim.json unsigned build claim awaiting release attestation\n")
        for destination, source in {
            ".forgeplay-source-export": "Scripts/Templates/OpenSource/export-marker",
            ".gitignore": "Scripts/Templates/OpenSource/gitignore",
            "README.md": "Scripts/Templates/OpenSource/README.md",
            "README_EN.md": "Scripts/Templates/OpenSource/README_EN.md",
            "README_KO.md": "Scripts/Templates/OpenSource/README_KO.md",
            "SOURCE-LICENSES.md": "Scripts/Templates/OpenSource/SOURCE-LICENSES.md",
            "Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-process-host-routing.patch.license": "Scripts/Templates/OpenSource/PatchLicenses/wine-11.12-game-mode-process-host-routing.patch.license",
            "Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-direct-target-scope.patch.license": "Scripts/Templates/OpenSource/PatchLicenses/wine-11.12-game-mode-direct-target-scope.patch.license",
        }.items():
            write(self.authority / source, (b"fixture\n" if destination not in {"README.md", "README_EN.md", "README_KO.md", "SOURCE-LICENSES.md"} else (self.authority / destination).read_bytes()))

    def _materialize_export(self) -> None:
        for path in self.authority.rglob("*"):
            if not path.is_file() or ".git" in path.parts or "Scripts/Templates" in path.as_posix():
                continue
            destination = self.export / path.relative_to(self.authority)
            write(destination, path.read_bytes(), stat.S_IMODE(path.stat().st_mode))
        injected = {
            ".forgeplay-source-export": "Scripts/Templates/OpenSource/export-marker",
            ".gitignore": "Scripts/Templates/OpenSource/gitignore",
            "README.md": "Scripts/Templates/OpenSource/README.md",
            "README_EN.md": "Scripts/Templates/OpenSource/README_EN.md",
            "README_KO.md": "Scripts/Templates/OpenSource/README_KO.md",
            "SOURCE-LICENSES.md": "Scripts/Templates/OpenSource/SOURCE-LICENSES.md",
            "Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-process-host-routing.patch.license": "Scripts/Templates/OpenSource/PatchLicenses/wine-11.12-game-mode-process-host-routing.patch.license",
            "Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-direct-target-scope.patch.license": "Scripts/Templates/OpenSource/PatchLicenses/wine-11.12-game-mode-direct-target-scope.patch.license",
        }
        for destination, source in injected.items():
            source_path = self.authority / source
            write(self.export / destination, source_path.read_bytes(), stat.S_IMODE(source_path.stat().st_mode))
        write(self.export / "ForgePlay.xcodeproj/project.pbxproj", b"generated fixture\n")

    def _write_inventory(self) -> None:
        injected = {
            ".forgeplay-source-export": "Scripts/Templates/OpenSource/export-marker",
            ".gitignore": "Scripts/Templates/OpenSource/gitignore",
            "README.md": "Scripts/Templates/OpenSource/README.md",
            "README_EN.md": "Scripts/Templates/OpenSource/README_EN.md",
            "README_KO.md": "Scripts/Templates/OpenSource/README_KO.md",
            "SOURCE-LICENSES.md": "Scripts/Templates/OpenSource/SOURCE-LICENSES.md",
            "Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-process-host-routing.patch.license": "Scripts/Templates/OpenSource/PatchLicenses/wine-11.12-game-mode-process-host-routing.patch.license",
            "Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-direct-target-scope.patch.license": "Scripts/Templates/OpenSource/PatchLicenses/wine-11.12-game-mode-direct-target-scope.patch.license",
        }
        tree = {}
        for line in git(self.authority, "ls-tree", "-r", self.release_commit).splitlines():
            metadata, source = line.split("\t", 1)
            mode, _kind, object_id = metadata.split()
            tree[source] = (mode, object_id)
        generator = self._projection("Scripts/generate-xcode-project.sh", tree)
        project = self._projection("project.yml", tree)
        entries = []
        for path in sorted(self.export.rglob("*")):
            if not path.is_file():
                continue
            relative = path.relative_to(self.export).as_posix()
            payload = path.read_bytes()
            mode = f"100{stat.S_IMODE(path.stat().st_mode):03o}"
            if relative.startswith("ForgePlay.xcodeproj/"):
                origin = {"classification": "generated-xcode-project", "generator": generator, "inputs": [project], "tool": {"name": "xcodegen", "version": "fixture"}}
            else:
                source = injected.get(relative, relative)
                git_mode, object_id = tree[source]
                origin = {"classification": "injected-template-blob" if relative in injected else "release-commit-blob", "destinationPath": relative, "gitMode": git_mode, "gitObjectID": object_id, "sha256": hashlib.sha256(payload).hexdigest(), "sourcePath": source}
            entries.append({"byteLength": len(payload), "mode": mode, "origin": origin, "path": relative, "sha256": hashlib.sha256(payload).hexdigest()})
        inventory = {"entries": entries, "gitObjectFormat": "sha1", "hashAlgorithm": "sha256", "inventoryGenerator": self._projection("Scripts/export-open-source.sh", tree), "inventorySHA256": inventory_digest(entries, self.release_commit), "releaseCommit": self.release_commit, "schemaVersion": 2}
        write(self.export / "SOURCE-INVENTORY.json", canonical_inventory(inventory))

    def _create_runtime_output(self) -> None:
        self.runtime.mkdir()
        manifest = json.loads(
            (
                self.export
                / "Resources/Runners/ForgePlayRuntime/RuntimeManifest.json"
            ).read_text(encoding="utf-8")
        )
        manifest["corePayloadFingerprint"] = "f" * 64
        write(
            self.runtime / "RuntimeManifest.json",
            canonical_inventory(manifest),
            0o444,
        )
        write(self.runtime / "RuntimePayload.txt", b"fresh Runtime only\n", 0o444)
        install_root = self.root / "fresh-runtime-install"
        write(install_root / "payload.txt", b"fresh public runtime fixture\n")
        compiler_manifest = self.root / "compiler-capsule.json"
        build_tool_manifest = self.root / "build-tool-capsule.json"
        write(compiler_manifest, b"fixture compiler capsule\n")
        write(build_tool_manifest, b"fixture build tool capsule\n")
        receipt = self.root / "runtime-prepackage-receipt.json"
        subprocess.run(
            [
                "python3", os.fspath(RUNTIME_RECEIPT_VERIFIER), "create-prepackage",
                "--export-root", os.fspath(self.export),
                "--source-tree-sha256", "a" * 64,
                "--install-root", os.fspath(install_root),
                "--compiler-capsule-manifest", os.fspath(compiler_manifest),
                "--build-tool-capsule-manifest", os.fspath(build_tool_manifest),
                "--receipt", os.fspath(receipt),
            ],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            [
                "python3", os.fspath(RUNTIME_RECEIPT_VERIFIER), "write-claim",
                "--receipt", os.fspath(receipt),
                "--manifest", os.fspath(self.runtime / "RuntimeManifest.json"),
                "--output", os.fspath(self.runtime / "PublicRuntimeBuildClaim.json"),
            ],
            check=True,
            capture_output=True,
        )
        fake_xcodegen = self.root / "xcodegen"
        write(
            fake_xcodegen,
            b'''#!/bin/sh
set -eu
[ "${SWIFT_DETERMINISTIC_HASHING:-}" = "1" ] || exit 91
[ "${SWIFT_HASH_SEED+x}" != "x" ] || exit 92
printf '%s\n' "$*" > "$FORGEPLAY_FAKE_GENERATOR_RECEIPT"
workspace="$(/usr/bin/dirname "$3")"
if [ "${FORGEPLAY_FAKE_MUTATE_PROJECT:-0}" = "1" ]; then
  printf 'mutated generated project\n' > "$workspace/ForgePlay.xcodeproj/project.pbxproj"
else
  printf 'generated fixture\n' > "$workspace/ForgePlay.xcodeproj/project.pbxproj"
fi
if [ "${FORGEPLAY_FAKE_MUTATE_RUNTIME:-0}" = "1" ]; then
  printf 'mutated Runtime\n' > "$workspace/Resources/Runners/ForgePlayRuntime/GeneratorMutation.txt"
fi
if [ "${FORGEPLAY_FAKE_MUTATE_SOURCE:-0}" = "1" ]; then
  printf 'mutated source\n' > "$workspace/LICENSE.md"
fi
if [ "${FORGEPLAY_FAKE_MUTATE_INVENTORY:-0}" = "1" ]; then
  printf '{}\n' > "$workspace/SOURCE-INVENTORY.json"
fi
if [ "${FORGEPLAY_FAKE_ADD_RUNNER:-0}" = "1" ]; then
  /bin/mkdir -p "$workspace/Resources/Runners/UnexpectedRunner"
  printf 'unexpected runner\n' > "$workspace/Resources/Runners/UnexpectedRunner/payload.txt"
fi
if [ "${FORGEPLAY_FAKE_ADD_SPECIAL_ENTRY:-0}" = "1" ]; then
  /usr/bin/mkfifo "$workspace/Unexpected.fifo"
fi
''',
            0o755,
        )
        self.fake_xcodegen = fake_xcodegen
        fake_xcodebuild = self.root / "fake-xcodebuild.py"
        write(
            fake_xcodebuild,
            b'''#!/usr/bin/env python3
import json
import os
import shutil
import sys
from pathlib import Path

arguments = sys.argv[1:]
Path(os.environ["FORGEPLAY_FAKE_XCODEBUILD_ARGUMENTS"]).write_text(json.dumps(arguments), encoding="utf-8")
archive = Path(arguments[arguments.index("-archivePath") + 1])
project = Path(arguments[arguments.index("-project") + 1])
source_root = project.parent
destination = archive / "Products/Applications/ForgePlay.app/Contents/Resources"
destination.mkdir(parents=True)
if os.environ.get("FORGEPLAY_FAKE_MUTATE_DISTRIBUTION_CLAIM") == "1":
    (source_root / "Resources/PublicDistributionBuildClaim.json").write_text(
        '{"mutated":true}\\n',
        encoding="utf-8",
    )
shutil.copyfile(source_root / "Resources/PublicDistributionBuildClaim.json", destination / "PublicDistributionBuildClaim.json")
shutil.copytree(
    source_root / "Resources/Runners/ForgePlayRuntime",
    destination / "Runners/ForgePlayRuntime",
    symlinks=True,
)
if os.environ.get("FORGEPLAY_FAKE_MUTATE_ARCHIVED_RUNTIME") == "1":
    (destination / "Runners/ForgePlayRuntime/ArchiveMutation.txt").write_text(
        "mutated archive Runtime\\n",
        encoding="utf-8",
    )
''',
            0o755,
        )
        self.fake_xcodebuild = fake_xcodebuild

    def _projection(self, path: str, tree: dict[str, tuple[str, str]]) -> dict:
        mode, object_id = tree[path]
        return {"gitMode": mode, "gitObjectID": object_id, "path": path, "sha256": hashlib.sha256((self.authority / path).read_bytes()).hexdigest(), "sourcePath": path}

    def command(self, *options: str) -> list[str]:
        return ["/bin/bash", os.fspath(VERIFIER), "--project-root", os.fspath(self.root), *options, os.fspath(self.export)]

    def verify(self, *options: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(self.command(*options), capture_output=True, text=True, check=False)

    def archive_command(
        self,
        *,
        workspace: Path | None = None,
        archive: Path | None = None,
        development_team: str | None = "ABCDE12345",
        signing_style: str = "Automatic",
        signing_identity: str | None = None,
    ) -> list[str]:
        command = [
            "/bin/bash", os.fspath(BUILDER),
            "--source-export", os.fspath(self.export),
            "--trusted-git-repository", os.fspath(self.authority),
            "--workspace", os.fspath(workspace or self.workspace),
            "--runtime-output", os.fspath(self.runtime),
            "--archive-path", os.fspath(archive or self.archive),
            "--derived-data-path", os.fspath(self.derived),
            "--log", os.fspath(self.archive_log),
            "--scheme", "ForgePlayDMG",
            "--configuration", "Distribution",
            "--signing-style", signing_style,
        ]
        if development_team is not None:
            command.extend(["--development-team", development_team])
        if signing_identity is not None:
            command.extend(["--code-sign-identity", signing_identity])
        return command

    def archive_environment(self) -> dict[str, str]:
        return {
            **os.environ,
            "FORGEPLAY_PUBLIC_ARCHIVE_TEST_MODE": "1",
            "FORGEPLAY_PUBLIC_ARCHIVE_XCODEBUILD": os.fspath(self.fake_xcodebuild),
            "FORGEPLAY_XCODEGEN_PATH": os.fspath(self.fake_xcodegen),
            "FORGEPLAY_FAKE_XCODEBUILD_ARGUMENTS": os.fspath(self.fake_xcodebuild_arguments),
            "FORGEPLAY_FAKE_GENERATOR_RECEIPT": os.fspath(self.generator_receipt),
            "FORGEPLAY_FAKE_RUNTIME_AUTHORITY": os.fspath(self.runtime),
            "SWIFT_DETERMINISTIC_HASHING": "0",
            "SWIFT_HASH_SEED": "untrusted-fixture-seed",
        }

    def rewrite_inventory(self, mutate) -> None:
        inventory_path = self.export / "SOURCE-INVENTORY.json"
        inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
        mutate(inventory)
        inventory["inventorySHA256"] = inventory_digest(inventory["entries"], inventory["releaseCommit"])
        write(inventory_path, canonical_inventory(inventory))

    def test_release_authority_uses_separate_trusted_git_repository(self) -> None:
        result = self.verify("--release-authority", "--trusted-git-repository", os.fspath(self.authority))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("release-authority verification passed", result.stdout)

    def test_archive_uses_trusted_git_and_runtime_receipt_before_generation(self) -> None:
        result = subprocess.run(
            self.archive_command(),
            env=self.archive_environment(),
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.generator_receipt.is_file())
        self.assertEqual(
            self.generator_receipt.read_text(encoding="utf-8").strip(),
            f"generate --spec {self.workspace}/project.yml",
        )
        self.assertTrue(self.fake_xcodebuild_arguments.is_file())
        xcodebuild_arguments = json.loads(
            self.fake_xcodebuild_arguments.read_text(encoding="utf-8")
        )
        for exact_setting in (
            "FORGEPLAY_ALLOW_UNNOTARIZED_DMG=0",
            "FORGEPLAY_APP_BUNDLE_ID=com.forgeplay.client",
            "FORGEPLAY_DISTRIBUTION_BUNDLE_ID=com.forgeplay.client",
            "FORGEPLAY_MARKETING_VERSION=1.1",
            "FORGEPLAY_CURRENT_PROJECT_VERSION=2",
            "MARKETING_VERSION=1.1",
            "CURRENT_PROJECT_VERSION=2",
            "FORGEPLAY_DEVELOPMENT_TEAM=ABCDE12345",
            "DEVELOPMENT_TEAM=ABCDE12345",
            "FORGEPLAY_CODE_SIGN_STYLE=Automatic",
            "CODE_SIGN_STYLE=Automatic",
            "OTHER_CODE_SIGN_FLAGS=--timestamp",
        ):
            self.assertIn(exact_setting, xcodebuild_arguments)
        self.assertFalse(
            any(argument.startswith("PRODUCT_BUNDLE_IDENTIFIER=") for argument in xcodebuild_arguments)
        )
        self.assertFalse((self.workspace / "Config/ForgePlay.local.xcconfig").exists())
        workspace_runtime = self.workspace / "Resources/Runners/ForgePlayRuntime"
        self.assertEqual(
            (workspace_runtime / "RuntimeManifest.json").read_bytes(),
            (self.runtime / "RuntimeManifest.json").read_bytes(),
        )
        self.assertEqual(
            stat.S_IMODE((workspace_runtime / "RuntimeManifest.json").stat().st_mode),
            0o444,
        )
        self.assertEqual(
            (workspace_runtime / "RuntimePayload.txt").read_bytes(),
            b"fresh Runtime only\n",
        )
        for source_only_sidecar in (
            "wine-11.12-game-mode-process-host-routing.patch.license",
            "wine-11.12-game-mode-direct-target-scope.patch.license",
        ):
            self.assertFalse((workspace_runtime / "Patches" / source_only_sidecar).exists())
        authority_path = (
            self.archive
            / "Products/Applications/ForgePlay.app/Contents/Resources/PublicDistributionBuildClaim.json"
        )
        authority = json.loads(authority_path.read_text(encoding="utf-8"))
        self.assertEqual(authority["schemaVersion"], 2)
        self.assertEqual(
            authority["claimStatus"],
            "unsigned build claim awaiting release attestation",
        )
        self.assertEqual(authority["releaseCommit"], self.release_commit)
        self.assertEqual(
            authority["runtimeBuildClaimSHA256"],
            hashlib.sha256((self.runtime / "PublicRuntimeBuildClaim.json").read_bytes()).hexdigest(),
        )

    def test_export_and_archive_share_one_explicit_xcodegen_binary_contract(self) -> None:
        exporter = EXPORTER.read_text(encoding="utf-8")
        generator = PROJECT_GENERATOR.read_text(encoding="utf-8")
        self.assertIn(
            'fail "FORGEPLAY_XCODEGEN_PATH is required under the sanitized release PATH"',
            exporter,
        )
        self.assertIn('export FORGEPLAY_XCODEGEN_PATH="$candidate"', exporter)
        self.assertIn('"$FORGEPLAY_XCODEGEN_PATH" --version', exporter)
        self.assertNotIn("command -v xcodegen", exporter)
        self.assertIn('XCODEGEN_PATH="${FORGEPLAY_XCODEGEN_PATH:-}"', generator)
        self.assertIn('/usr/bin/env -u SWIFT_HASH_SEED', generator)
        self.assertIn('SWIFT_DETERMINISTIC_HASHING=1', generator)
        self.assertIn('"$XCODEGEN_PATH" generate --spec', generator)

    def test_d3dmetal_validator_is_exported_and_snapshotted_in_the_release_graph(self) -> None:
        exporter = EXPORTER.read_text(encoding="utf-8")
        verifier = VERIFIER.read_text(encoding="utf-8")
        packager = (ROOT / "Scripts/package-forgeplay-runtime.sh").read_text(encoding="utf-8")
        graph = json.loads(
            (ROOT / "Config/ForgePlayPublicDistributionSourceGraph.json").read_text(
                encoding="utf-8"
            )
        )

        self.assertIn("validate-d3dmetal-ngx-bridge.sh", exporter)
        self.assertIn('"validate-d3dmetal-ngx-bridge.sh"', verifier)
        self.assertIn(
            "Scripts/validate-d3dmetal-ngx-bridge.sh",
            graph["requiredReleaseCommitPaths"],
        )
        self.assertIn(
            'snapshot_regular_input "$D3DMETAL_NGX_BRIDGE_VALIDATOR"',
            packager,
        )
        self.assertIn(
            'D3DMETAL_NGX_BRIDGE_VALIDATOR="$root/d3dmetal-ngx-bridge-validator.sh"',
            packager,
        )

    def test_archive_requires_exact_team_and_manual_developer_id_identity(self) -> None:
        for label, development_team, expected_error in (
            ("missing", None, "development team are required"),
            ("invalid", "lowercase1", "10-character Apple team identifier"),
        ):
            with self.subTest(label=label):
                workspace = self.root / f"RejectedTeam-{label}"
                archive = self.root / f"RejectedTeam-{label}.xcarchive"
                result = subprocess.run(
                    self.archive_command(
                        workspace=workspace,
                        archive=archive,
                        development_team=development_team,
                    ),
                    env=self.archive_environment(),
                    check=False,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected_error, result.stderr)
                self.assertFalse(workspace.exists())
                self.assertFalse(archive.exists())
                self.assertFalse(self.generator_receipt.exists())
                self.assertFalse(self.fake_xcodebuild_arguments.exists())

        invalid_identity = "Developer ID Application: Fixture (WRONG12345)"
        workspace = self.root / "RejectedIdentity"
        archive = self.root / "RejectedIdentity.xcarchive"
        result = subprocess.run(
            self.archive_command(
                workspace=workspace,
                archive=archive,
                signing_style="Manual",
                signing_identity=invalid_identity,
            ),
            env=self.archive_environment(),
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exact Developer ID Application identity", result.stderr)
        self.assertFalse(workspace.exists())
        self.assertFalse(archive.exists())

        valid_identity = "Developer ID Application: Fixture (ABCDE12345)"
        workspace = self.root / "ManualPublicBuild"
        archive = self.root / "Manual.xcarchive"
        result = subprocess.run(
            self.archive_command(
                workspace=workspace,
                archive=archive,
                signing_style="Manual",
                signing_identity=valid_identity,
            ),
            env=self.archive_environment(),
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        xcodebuild_arguments = json.loads(
            self.fake_xcodebuild_arguments.read_text(encoding="utf-8")
        )
        self.assertIn("FORGEPLAY_CODE_SIGN_STYLE=Manual", xcodebuild_arguments)
        self.assertIn("CODE_SIGN_STYLE=Manual", xcodebuild_arguments)
        self.assertIn(f"CODE_SIGN_IDENTITY={valid_identity}", xcodebuild_arguments)

    def test_public_archive_has_no_private_xcconfig_ingress(self) -> None:
        source = BUILDER.read_text(encoding="utf-8")
        self.assertNotIn("--local-xcconfig", source)
        self.assertNotIn("Config/ForgePlay.local.xcconfig", source)

        workspace = self.root / "RejectedLocalConfig"
        archive = self.root / "RejectedLocalConfig.xcarchive"
        local_config = self.root / "ForgePlay.local.xcconfig"
        write(local_config, b"FORGEPLAY_DEVELOPMENT_TEAM = PRIVATE1234\n")
        result = subprocess.run(
            [
                *self.archive_command(workspace=workspace, archive=archive),
                "--local-xcconfig",
                os.fspath(local_config),
            ],
            env=self.archive_environment(),
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown or incomplete option: --local-xcconfig", result.stderr)
        self.assertFalse(workspace.exists())
        self.assertFalse(archive.exists())

    def test_official_release_projects_only_canonical_signing_metadata(self) -> None:
        source = OFFICIAL_RELEASE_BUILDER.read_text(encoding="utf-8")
        for contract in (
            'CANONICAL_BUNDLE_IDENTIFIER="com.forgeplay.client"',
            'CANONICAL_MARKETING_VERSION="1.1"',
            'CANONICAL_BUILD_NUMBER="2"',
            'RELEASE_DEVELOPMENT_TEAM="${FORGEPLAY_RELEASE_DEVELOPMENT_TEAM:-}"',
            '--development-team "$RELEASE_DEVELOPMENT_TEAM"',
            'Add :teamID string $RELEASE_DEVELOPMENT_TEAM',
            'write_release_evidence "official-notarized-dmg"',
            "Official notarized release artifact:",
        ):
            self.assertIn(contract, source)
        self.assertNotIn("--local-xcconfig", source)

    def test_official_release_kind_is_neutral_and_consistent(self) -> None:
        for relative in (
            "Scripts/build-commercial-release.sh",
            "Scripts/generate-commercial-release-status-report.sh",
            "Scripts/public-release-set-transaction.py",
            "Scripts/verify-commercial-release-status-report.sh",
            "Scripts/verify-direct-release-readiness.sh",
            "Scripts/verify-public-release-assets.sh",
            "Scripts/verify-release-evidence.sh",
            "docs/commercial-release.md",
        ):
            source = (ROOT / relative).read_text(encoding="utf-8")
            self.assertNotIn("commercial-notarized-dmg", source, relative)
        self.assertIn(
            "홈페이지를 통한 무료·비상업 배포물",
            (ROOT / "docs/commercial-release.md").read_text(encoding="utf-8"),
        )

    def test_archive_rejects_runtime_receipt_before_generation(self) -> None:
        write(self.runtime / "PublicRuntimeBuildClaim.json", b"{}\n")
        workspace = self.root / "RejectedPublicBuild"
        archive = self.root / "Rejected.xcarchive"
        result = subprocess.run(
            self.archive_command(workspace=workspace, archive=archive),
            env=self.archive_environment(),
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Runtime output is not bound", result.stderr)
        self.assertFalse(self.generator_receipt.exists())
        self.assertFalse(self.fake_xcodebuild_arguments.exists())
        self.assertFalse(workspace.exists())
        self.assertFalse(archive.exists())

    def test_archive_rejects_runtime_mutation_after_generation(self) -> None:
        environment = self.archive_environment()
        environment["FORGEPLAY_FAKE_MUTATE_RUNTIME"] = "1"
        result = subprocess.run(
            self.archive_command(),
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("public build Runtime differs", result.stderr)
        self.assertTrue(self.generator_receipt.is_file())
        self.assertFalse(self.fake_xcodebuild_arguments.exists())
        self.assertFalse(self.archive.exists())

    def test_archive_rejects_source_mutation_after_generation(self) -> None:
        environment = self.archive_environment()
        environment["FORGEPLAY_FAKE_MUTATE_SOURCE"] = "1"
        result = subprocess.run(
            self.archive_command(),
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("public build input differs from exported source: LICENSE.md", result.stderr)
        self.assertTrue(self.generator_receipt.is_file())
        self.assertFalse(self.fake_xcodebuild_arguments.exists())
        self.assertFalse(self.archive.exists())

    def test_archive_rejects_generated_project_mutation_after_generation(self) -> None:
        environment = self.archive_environment()
        environment["FORGEPLAY_FAKE_MUTATE_PROJECT"] = "1"
        result = subprocess.run(
            self.archive_command(),
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "public build input differs from exported source: "
            "ForgePlay.xcodeproj/project.pbxproj",
            result.stderr,
        )
        self.assertTrue(self.generator_receipt.is_file())
        self.assertFalse(self.fake_xcodebuild_arguments.exists())
        self.assertFalse(self.archive.exists())

    def test_archive_rejects_source_inventory_mutation_after_generation(self) -> None:
        environment = self.archive_environment()
        environment["FORGEPLAY_FAKE_MUTATE_INVENTORY"] = "1"
        result = subprocess.run(
            self.archive_command(),
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source inventory differs from the verified export", result.stderr)
        self.assertTrue(self.generator_receipt.is_file())
        self.assertFalse(self.fake_xcodebuild_arguments.exists())
        self.assertFalse(self.archive.exists())

    def test_archive_rejects_addition_outside_exact_runtime_leaf(self) -> None:
        environment = self.archive_environment()
        environment["FORGEPLAY_FAKE_ADD_RUNNER"] = "1"
        result = subprocess.run(
            self.archive_command(),
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "public build graph contains an unbound addition: "
            "Resources/Runners/UnexpectedRunner/payload.txt",
            result.stderr,
        )
        self.assertTrue(self.generator_receipt.is_file())
        self.assertFalse(self.fake_xcodebuild_arguments.exists())
        self.assertFalse(self.archive.exists())

    def test_archive_rejects_special_entry_outside_runtime_leaf(self) -> None:
        environment = self.archive_environment()
        environment["FORGEPLAY_FAKE_ADD_SPECIAL_ENTRY"] = "1"
        result = subprocess.run(
            self.archive_command(),
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "public build graph contains an unsupported entry: Unexpected.fifo",
            result.stderr,
        )
        self.assertTrue(self.generator_receipt.is_file())
        self.assertFalse(self.fake_xcodebuild_arguments.exists())
        self.assertFalse(self.archive.exists())

    def test_archive_rejects_runtime_mutation_by_xcodebuild(self) -> None:
        environment = self.archive_environment()
        environment["FORGEPLAY_FAKE_MUTATE_ARCHIVED_RUNTIME"] = "1"
        result = subprocess.run(
            self.archive_command(),
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("archive changed the signed-release Runtime", result.stderr)
        self.assertTrue(self.generator_receipt.is_file())
        self.assertTrue(self.fake_xcodebuild_arguments.is_file())
        self.assertTrue(self.archive.exists())

    def test_archive_rejects_matching_workspace_and_archived_claim_mutation(self) -> None:
        environment = self.archive_environment()
        environment["FORGEPLAY_FAKE_MUTATE_DISTRIBUTION_CLAIM"] = "1"
        result = subprocess.run(
            self.archive_command(),
            env=environment,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "public Distribution build claim changed after creation",
            result.stderr,
        )
        self.assertTrue(self.generator_receipt.is_file())
        self.assertTrue(self.fake_xcodebuild_arguments.is_file())
        self.assertTrue(self.archive.exists())
        self.assertEqual(
            (
                self.workspace
                / "Resources/PublicDistributionBuildClaim.json"
            ).read_bytes(),
            (
                self.archive
                / "Products/Applications/ForgePlay.app/Contents/Resources/"
                "PublicDistributionBuildClaim.json"
            ).read_bytes(),
        )

    def test_release_authority_requires_trusted_git_for_gitless_export(self) -> None:
        result = self.verify("--release-authority")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires --trusted-git-repository", result.stderr)

    def test_rejects_forged_commit_before_any_generator_or_xcodebuild(self) -> None:
        self.rewrite_inventory(lambda inventory: inventory.__setitem__("releaseCommit", "0" * 40))
        result = self.verify("--release-authority", "--trusted-git-repository", os.fspath(self.authority))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("trusted release Git verification failed", result.stderr)

    def test_rejects_malformed_origin_blob_mode_and_tree_type(self) -> None:
        def mutate(inventory: dict) -> None:
            row = next(row for row in inventory["entries"] if row["path"] == "LICENSE.md")
            row["origin"]["gitMode"] = "120000"
        self.rewrite_inventory(mutate)
        result = self.verify("--release-authority", "--trusted-git-repository", os.fspath(self.authority))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Git-blob origin does not bind exported bytes", result.stderr)

    def test_rejects_trusted_tree_object_type_mismatch(self) -> None:
        altered = self.root / "wrong-object-type.git"
        subprocess.run(
            ["git", "clone", "-q", os.fspath(self.authority), os.fspath(altered)],
            check=True,
            capture_output=True,
        )
        git(altered, "config", "user.name", "Fixture")
        git(altered, "config", "user.email", "fixture@example.invalid")
        git(
            altered,
            "update-index",
            "--add",
            "--cacheinfo",
            f"160000,{self.release_commit},LICENSE.md",
        )
        git(altered, "commit", "-qm", "replace fixture file with gitlink")
        altered_commit = git(altered, "rev-parse", "HEAD")
        self.rewrite_inventory(
            lambda inventory: inventory.__setitem__("releaseCommit", altered_commit)
        )
        result = self.verify("--release-authority", "--trusted-git-repository", os.fspath(altered))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exact trusted release tree", result.stderr)

    def test_rejects_private_clean_room_and_d3dmetal_source_paths(self) -> None:
        for relative in ("CleanRoom/private.txt", "Resources/Runners/ForgePlayRuntime/Sources/renderer/d3dmetal/source.m"):
            with self.subTest(relative=relative):
                write(self.export / relative, b"private\n")
                result = self.verify("--release-authority", "--trusted-git-repository", os.fspath(self.authority))
                self.assertNotEqual(result.returncode, 0)
                expected = "top-level allowlist mismatch" if relative.startswith("CleanRoom/") else "forbidden development or binary path is present"
                self.assertIn(expected, result.stderr)
                (self.export / relative).unlink()
                if relative.startswith("CleanRoom/"):
                    (self.export / "CleanRoom").rmdir()


if __name__ == "__main__":
    unittest.main(verbosity=2)
