#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import errno
import hashlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FREEZER = ROOT / "Scripts" / "freeze-public-source-export.py"
WINE_PATH = "CorrespondingSource/Wine/wine-11.12.tar.xz"
EXPECTED_GRAPH_PATHS = [
    "project.yml",
    "Config/ForgePlayApp.xcconfig",
    "Config/ForgePlayCopyleftSourcePackages.json",
    "Config/ForgePlayDefaults.xcconfig",
    "Config/ForgePlayDirectRelease.xcconfig",
    "Config/ForgePlayDistribution.xcconfig",
    "Config/ForgePlayD3DMetalFrameGenerationProxy.xcconfig",
    "Config/ForgePlayExternalStorageAccessBridge.xcconfig",
    "Config/ForgePlayGameModeProcessHost.xcconfig",
    "Config/ForgePlayGameModeProcessHostDistribution.xcconfig",
    "Config/ForgePlayGameModeProcessHostRelease.xcconfig",
    "Config/ForgePlayPublicDistributionSourceGraph.json",
    "Sources/ForgePlay/ForgePlay-Distribution.entitlements",
    "Sources/ForgePlay/ForgePlay-DirectRelease.entitlements",
    "Sources/ForgePlay/ForgePlay-Runtime-Direct.entitlements",
    "Sources/ForgePlay/ForgePlay-Runtime-Inherit.entitlements",
    "Native/D3DMetalFrameGenerationProxy/ForgePlayD3DMetalFrameGenerationProxy.m",
    "Native/D3DMetalFrameGenerationProxy/ForgePlayD3DMetalFrameGenerationProxy.h",
    "Native/D3DMetalFrameGenerationProxy/FrameGenerationStateMachine.c",
    "Native/D3DMetalFrameGenerationProxy/FrameGenerationStateMachine.h",
    "Native/D3DMetalFrameGenerationProxy/ForgePlayD3DMetalFrameGenerationProxy.exports",
    "Native/GameModeProcessHost/GameModeProcessHost-Distribution.entitlements",
    "Native/GameModeProcessHost/GameModeProcessHost-Release.entitlements",
    "Scripts/build-commercial-release.sh",
    "Scripts/build-forgeplay-wine-runtime.sh",
    "Scripts/build-public-forgeplay-runtime.sh",
    "Scripts/build-public-distribution-archive.sh",
    "Scripts/check-project-build-warnings.sh",
    "Scripts/export-open-source.sh",
    "Scripts/freeze-public-source-export.py",
    "Scripts/generate-compatibility-db-signing-key.swift",
    "Scripts/generate-xcode-project.sh",
    "Scripts/materialize-forgeplay-wine-11.12-source.sh",
    "Scripts/materialize-locked-gstreamer-runtime.py",
    "Scripts/materialize-locked-renderer.py",
    "Scripts/materialize-locked-runtime-dependencies.py",
    "Scripts/open-source-export-transaction.py",
    "Scripts/package-forgeplay-runtime.sh",
    "Scripts/prepare-app-store-runtime-payload.sh",
    "Scripts/prepare-clean-build-root.sh",
    "Scripts/prepare-dmg-output-path.sh",
    "Scripts/prepare-game-mode-host-build-identity.sh",
    "Scripts/public-runtime-release-attestation.py",
    "Scripts/public-release-set-transaction.py",
    "Scripts/quarantine-owned-directory.py",
    "Scripts/restore-preserved-apple-d3dmetal-signatures.sh",
    "Scripts/runtime-core-payload-identity.py",
    "Scripts/runtime-sbom.py",
    "Scripts/sign-app-store-runtime-code.sh",
    "Scripts/sign-compatibility-db-feed.swift",
    "Scripts/test-wine-session-compatibility.sh",
    "Scripts/validate-compatibility-db-public-key.swift",
    "Scripts/validate-product-identity.sh",
    "Scripts/verify-app-store-app-security.sh",
    "Scripts/verify-app-store-controller-permissions.py",
    "Scripts/verify-bundled-runtime-capability.sh",
    "Scripts/verify-clean-wine-runtime-markers.py",
    "Scripts/verify-copyleft-source-packages.py",
    "Scripts/verify-dmg-contents.sh",
    "Scripts/verify-forgeplay-runtime-patch-provenance.py",
    "Scripts/verify-game-mode-source-licenses.py",
    "Scripts/verify-legal-documents.sh",
    "Scripts/verify-license-documents.sh",
    "Scripts/verify-macho-runtime-closure.py",
    "Scripts/verify-notary-submit-json.sh",
    "Scripts/verify-open-source-export.sh",
    "Scripts/verify-privacy-manifest.sh",
    "Scripts/verify-project-documents.sh",
    "Scripts/verify-public-release-assets.sh",
    "Scripts/verify-public-release-license-policy.sh",
    "Scripts/verify-public-runtime-build-receipt.py",
    "Scripts/verify-release-app-info.sh",
    "Scripts/verify-release-app-localizations.sh",
    "Scripts/verify-release-app-security.sh",
    "Scripts/verify-release-bundle-privacy.sh",
    "Scripts/verify-release-evidence.sh",
    "Scripts/verify-wine-runtime-build-paths.py",
]


def load_freezer_implementation():
    specification = importlib.util.spec_from_file_location(
        "forgeplay_freeze_public_source_export_under_test", FREEZER
    )
    if specification is None or specification.loader is None:
        raise RuntimeError("freezer test module could not be loaded")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def inventory_digest(entries: list[dict], release_commit: str) -> str:
    lines = [
        "forgeplay-public-source-inventory-v2",
        f"releaseCommit={release_commit}",
        "gitObjectFormat=sha1",
        *(
            f"{row['path']}\0{row['mode']}\0{row['byteLength']}\0{row['sha256']}\0"
            + json.dumps(row["origin"], sort_keys=True, separators=(",", ":"))
            for row in entries
        ),
    ]
    return hashlib.sha256(("\n".join(lines) + "\n").encode("utf-8")).hexdigest()


def run_freezer(*arguments: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["python3", str(FREEZER), *(str(argument) for argument in arguments)],
        check=False,
        text=True,
        capture_output=True,
    )


class PublicSourceExportFreezerTests(unittest.TestCase):
    def create_fixture(self, root: Path) -> tuple[Path, Path]:
        source = root / "OpenSourceFixture"
        source.mkdir()
        wine_bytes = b"ForgePlay Wine 11.12 source fixture\n"
        wine = root / "wine-11.12.tar.xz"
        wine.write_bytes(wine_bytes)
        wine_sha256 = hashlib.sha256(wine_bytes).hexdigest()
        identity = {
            "currentFinalPatchedSourceTree": {"sha256": "1" * 64},
            "schemaVersion": 2,
            "upstreamSource": {
                "archiveSHA256": wine_sha256,
                "project": "Wine",
                "version": "11.12",
            },
        }
        files = {
            "Config/ForgePlayRuntimeSourceIdentity.lock.json": canonical_json(identity),
            "README.md": b"ForgePlay public source fixture\n",
            "Scripts/fixture-tool.sh": b"#!/bin/sh\nexit 0\n",
        }
        entries = []
        for relative, payload in sorted(files.items()):
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
            mode = "100755" if relative.endswith(".sh") else "100644"
            path.chmod(int(mode[-3:], 8))
            entries.append({
                "byteLength": len(payload),
                "mode": mode,
                "origin": {"classification": "fixture"},
                "path": relative,
                "sha256": hashlib.sha256(payload).hexdigest(),
            })
        release_commit = "a" * 40
        inventory = {
            "entries": entries,
            "gitObjectFormat": "sha1",
            "hashAlgorithm": "sha256",
            "inventoryGenerator": {"classification": "fixture"},
            "inventorySHA256": inventory_digest(entries, release_commit),
            "releaseCommit": release_commit,
            "schemaVersion": 2,
        }
        (source / "SOURCE-INVENTORY.json").write_bytes(canonical_json(inventory))
        return source, wine

    def create_asset(
        self,
        root: Path,
        source: Path,
        wine: Path,
        stem: str,
        additional_path: str = WINE_PATH,
    ) -> tuple[Path, Path, subprocess.CompletedProcess[str]]:
        archive = root / f"{stem}.tar"
        binding = root / f"{stem}.json"
        result = run_freezer(
            "create",
            "--source-export", source,
            "--archive-out", archive,
            "--binding-out", binding,
            "--additional-file", wine,
            "--additional-path", additional_path,
        )
        return archive, binding, result

    def test_create_is_deterministic_and_verify_preserves_modes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, wine = self.create_fixture(root)
            first_archive, first_binding, first = self.create_asset(
                root, source, wine, "OpenSource-first"
            )
            second_archive, second_binding, second = self.create_asset(
                root, source, wine, "OpenSource-second"
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertEqual(first_archive.read_bytes(), second_archive.read_bytes())
            for archive, binding in (
                (first_archive, first_binding),
                (second_archive, second_binding),
            ):
                verified = run_freezer("verify", "--archive", archive, "--binding", binding)
                self.assertEqual(verified.returncode, 0, verified.stderr)
            with tarfile.open(first_archive, mode="r:") as archive:
                modes = {member.name: member.mode for member in archive.getmembers()}
            self.assertEqual(modes["OpenSource/Scripts/fixture-tool.sh"], 0o755)
            self.assertEqual(modes["OpenSource/README.md"], 0o644)
            self.assertEqual(modes[WINE_PATH], 0o644)
            binding_value = json.loads(first_binding.read_text(encoding="utf-8"))
            self.assertEqual(
                binding_value["additionalEntries"],
                [{
                    "byteCount": wine.stat().st_size,
                    "path": WINE_PATH,
                    "sha256": hashlib.sha256(wine.read_bytes()).hexdigest(),
                }],
            )
            private_path = str(root).encode("utf-8")
            self.assertNotIn(private_path, first_archive.read_bytes())
            self.assertNotIn(private_path, first_binding.read_bytes())

    def test_source_mutation_symlink_hardlink_and_extra_are_rejected(self) -> None:
        for unsafe_kind in ("mutation", "mode", "symlink", "hardlink", "extra"):
            with self.subTest(unsafe_kind=unsafe_kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                source, wine = self.create_fixture(root)
                readme = source / "README.md"
                if unsafe_kind == "mutation":
                    readme.write_text("mutated\n", encoding="utf-8")
                elif unsafe_kind == "mode":
                    readme.chmod(0o755)
                elif unsafe_kind == "symlink":
                    readme.unlink()
                    readme.symlink_to(wine)
                elif unsafe_kind == "hardlink":
                    os.link(readme, source / "README-hardlink.md")
                else:
                    (source / "unexpected.txt").write_text("unexpected\n", encoding="utf-8")
                _, _, failed = self.create_asset(root, source, wine, "unsafe")
                self.assertNotEqual(failed.returncode, 0)

    def test_additional_mutation_path_traversal_and_duplicate_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, wine = self.create_fixture(root)
            wine.write_bytes(b"wrong Wine archive bytes\n")
            _, _, mutation = self.create_asset(root, source, wine, "mutation")
            self.assertNotEqual(mutation.returncode, 0)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, wine = self.create_fixture(root)
            _, _, traversal = self.create_asset(
                root, source, wine, "traversal", "../wine-11.12.tar.xz"
            )
            self.assertNotEqual(traversal.returncode, 0)
            archive = root / "duplicate.tar"
            binding = root / "duplicate.json"
            duplicate = run_freezer(
                "create",
                "--source-export", source,
                "--archive-out", archive,
                "--binding-out", binding,
                "--additional-file", wine,
                "--additional-path", WINE_PATH,
                "--additional-file", wine,
                "--additional-path", WINE_PATH,
            )
            self.assertNotEqual(duplicate.returncode, 0)
            relative = run_freezer(
                "create",
                "--source-export", source,
                "--archive-out", root / "relative.tar",
                "--binding-out", root / "relative.json",
                "--additional-file", os.path.relpath(wine, ROOT),
                "--additional-path", WINE_PATH,
            )
            self.assertNotEqual(relative.returncode, 0)

    def test_arbitrary_symlink_ancestors_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            physical = root / "physical"
            physical.mkdir()
            source, wine = self.create_fixture(physical)
            alias = root / "input-alias"
            alias.symlink_to(physical, target_is_directory=True)
            archive, binding, input_failure = self.create_asset(
                root, alias / source.name, wine, "input-ancestor"
            )
            self.assertNotEqual(input_failure.returncode, 0)
            self.assertFalse(archive.exists())
            self.assertFalse(binding.exists())

            output = root / "output"
            output.mkdir()
            output_alias = root / "output-alias"
            output_alias.symlink_to(output, target_is_directory=True)
            output_failure = run_freezer(
                "create",
                "--source-export", source,
                "--archive-out", output_alias / "asset.tar",
                "--binding-out", output_alias / "asset.json",
                "--additional-file", wine,
                "--additional-path", WINE_PATH,
            )
            self.assertNotEqual(output_failure.returncode, 0)
            self.assertEqual(list(output.iterdir()), [])

            if sys.platform == "darwin" and str(root).startswith("/private/var/"):
                alias_root = Path("/var" + str(root)[len("/private/var"):])
                allowed = run_freezer(
                    "create",
                    "--source-export", alias_root / "physical" / source.name,
                    "--archive-out", alias_root / "allowed-alias.tar",
                    "--binding-out", alias_root / "allowed-alias.json",
                    "--additional-file", alias_root / "physical" / wine.name,
                    "--additional-path", WINE_PATH,
                )
                self.assertEqual(allowed.returncode, 0, allowed.stderr)
                verified = run_freezer(
                    "verify",
                    "--archive", root / "allowed-alias.tar",
                    "--binding", root / "allowed-alias.json",
                )
                self.assertEqual(verified.returncode, 0, verified.stderr)

    def test_same_parent_replacement_is_rejected(self) -> None:
        freezer = load_freezer_implementation()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            inputs = root / "inputs"
            inputs.mkdir()
            source, wine = self.create_fixture(inputs)
            output = root / "output"
            output.mkdir()
            displaced = root / "displaced-output"
            archive = output / "pair.tar"
            binding = output / "pair.json"
            original_init = freezer.OutputTarget.__init__

            def swap_before_binding(target, path):
                if Path(path).name == binding.name:
                    output.rename(displaced)
                    output.mkdir()
                original_init(target, path)

            with mock.patch.object(freezer.OutputTarget, "__init__", swap_before_binding):
                with self.assertRaises(freezer.FreezeError):
                    freezer.create_asset(
                        source, archive, binding, [wine], [WINE_PATH]
                    )
            self.assertEqual(list(output.iterdir()), [])
            self.assertEqual(list(displaced.iterdir()), [])

    def test_binding_link_failure_rolls_archive_back_without_residue(self) -> None:
        freezer = load_freezer_implementation()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, wine = self.create_fixture(root)
            output = root / "output"
            output.mkdir()
            archive = output / "pair.tar"
            binding = output / "pair.json"
            real_link = freezer.os.link

            def fail_binding_link(source_name, destination_name, **keywords):
                if destination_name == binding.name:
                    raise OSError(errno.EIO, "fixture binding link failure")
                return real_link(source_name, destination_name, **keywords)

            with mock.patch.object(freezer.os, "link", side_effect=fail_binding_link):
                with self.assertRaises(OSError):
                    freezer.create_asset(
                        source, archive, binding, [wine], [WINE_PATH]
                    )
            self.assertEqual(list(output.iterdir()), [])

    def test_postcommit_cleanup_failure_warns_and_preserves_valid_pair(self) -> None:
        freezer = load_freezer_implementation()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, wine = self.create_fixture(root)
            archive = root / "pair.tar"
            binding = root / "pair.json"
            original_close = freezer.OutputTarget.close

            def close_then_report_failure(target):
                original_close(target)
                if target.name == binding.name:
                    raise OSError(errno.EIO, "fixture postcommit cleanup failure")

            diagnostics = io.StringIO()
            with mock.patch.object(freezer.OutputTarget, "close", close_then_report_failure):
                with contextlib.redirect_stderr(diagnostics):
                    freezer.create_asset(
                        source, archive, binding, [wine], [WINE_PATH]
                    )
            self.assertIn("committed and valid", diagnostics.getvalue())
            freezer.verify_asset(archive, binding)
            self.assertFalse(any("forgeplay-private" in path.name for path in root.iterdir()))

    def test_public_distribution_graph_is_the_exact_full_allowlist(self) -> None:
        graph = json.loads(
            (ROOT / "Config/ForgePlayPublicDistributionSourceGraph.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertEqual(graph["requiredReleaseCommitPaths"], EXPECTED_GRAPH_PATHS)

    def test_archive_and_binding_tampering_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, wine = self.create_fixture(root)
            archive, binding, created = self.create_asset(root, source, wine, "tamper")
            self.assertEqual(created.returncode, 0, created.stderr)
            archive_bytes = bytearray(archive.read_bytes())
            archive_bytes[600] ^= 1
            archive.write_bytes(archive_bytes)
            archive_failure = run_freezer(
                "verify", "--archive", archive, "--binding", binding
            )
            self.assertNotEqual(archive_failure.returncode, 0)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, wine = self.create_fixture(root)
            archive, binding, created = self.create_asset(root, source, wine, "binding")
            self.assertEqual(created.returncode, 0, created.stderr)
            value = json.loads(binding.read_text(encoding="utf-8"))
            value["additionalEntries"][0]["sha256"] = "0" * 64
            binding.write_bytes(canonical_json(value))
            binding_failure = run_freezer(
                "verify", "--archive", archive, "--binding", binding
            )
            self.assertNotEqual(binding_failure.returncode, 0)

    def test_create_never_overwrites_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source, wine = self.create_fixture(root)
            archive = root / "existing.tar"
            binding = root / "existing.json"
            archive.write_bytes(b"keep archive\n")
            binding.write_bytes(b"keep binding\n")
            failed = run_freezer(
                "create",
                "--source-export", source,
                "--archive-out", archive,
                "--binding-out", binding,
                "--additional-file", wine,
                "--additional-path", WINE_PATH,
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(archive.read_bytes(), b"keep archive\n")
            self.assertEqual(binding.read_bytes(), b"keep binding\n")


if __name__ == "__main__":
    unittest.main()
