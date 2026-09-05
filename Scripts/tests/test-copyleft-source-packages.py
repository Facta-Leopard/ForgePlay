#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
VERIFIER = ROOT / "Scripts" / "verify-copyleft-source-packages.py"
INVENTORY = ROOT / "Config" / "ForgePlayCopyleftSourcePackages.json"
RUNTIME_SBOM = ROOT / "Resources" / "Runners" / "ForgePlayRuntime" / "RuntimeSBOM.json"
DEPENDENCY_LOCK = ROOT / "Config" / "ForgePlayRuntimeDependencies.lock.json"
GSTREAMER_LOCK = ROOT / "Config" / "ForgePlayGStreamerPayload.lock.json"
SPEC = importlib.util.spec_from_file_location("verify_copyleft_source_packages", VERIFIER)
assert SPEC is not None and SPEC.loader is not None
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)


def run_verifier(inventory: Path, source_root: Path) -> subprocess.CompletedProcess[str]:
    token = uuid.uuid4().hex
    return subprocess.run(
        [
            "python3",
            str(VERIFIER),
            "--inventory",
            str(inventory),
            "--source-root",
            str(source_root),
            "--archive-out",
            str(source_root.parent / f"{token}.tar"),
            "--receipt-out",
            str(source_root.parent / f"{token}.receipt.json"),
            "--runtime-sbom",
            str(RUNTIME_SBOM),
            "--dependency-lock",
            str(DEPENDENCY_LOCK),
            "--gstreamer-lock",
            str(GSTREAMER_LOCK),
        ],
        check=False,
        text=True,
        capture_output=True,
    )


class CopyleftSourcePackageTests(unittest.TestCase):
    def create_minimal_package(self, root: Path) -> tuple[Path, Path, dict]:
        source_root = root / "minimal-source"
        source_root.mkdir()
        payload = b"minimal corresponding source\n"
        (source_root / "material.txt").write_bytes(payload)
        output = root / "output"
        output.mkdir()
        archive = output / "source.tar"
        receipt = output / "source.receipt.json"
        value = TOOL.create_source_archive(
            source_root,
            {"material.txt": hashlib.sha256(payload).hexdigest()},
            archive,
            receipt,
            {
                "inventorySHA256": "1" * 64,
                "runtimeSBOMSHA256": "2" * 64,
                "dependencyLockSHA256": "3" * 64,
                "gstreamerLockSHA256": "4" * 64,
            },
            "5" * 64,
        )
        return archive, receipt, value

    def create_complete_fixture(self, root: Path) -> Path:
        inventory = json.loads(INVENTORY.read_text(encoding="utf-8"))
        source_root = root / "source"
        source_root.mkdir()
        for requirement in inventory["requirements"]:
            relative = Path(requirement["deliveryPath"])
            if requirement["status"] == "unresolved":
                relative = Path("resolved") / f"{requirement['id']}.fixture"
                requirement["deliveryPath"] = relative.as_posix()
                requirement["sourceURL"] = f"https://fixture.invalid/{requirement['id']}"
                requirement["status"] = "pinned"
            payload = f"fixture material for {requirement['id']}\n".encode()
            material_path = source_root / relative
            material_path.parent.mkdir(parents=True, exist_ok=True)
            material_path.write_bytes(payload)
            requirement["sha256"] = hashlib.sha256(payload).hexdigest()
        inventory_path = root / "complete-inventory.json"
        inventory_path.write_text(json.dumps(inventory, indent=2) + "\n", encoding="utf-8")
        return inventory_path

    def write_json(self, path: Path, value: object) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")

    def test_fixture_complete_delivery_passes_and_missing_material_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            inventory_path = self.create_complete_fixture(root)
            source_root = root / "source"
            passed = run_verifier(inventory_path, source_root)
            self.assertEqual(passed.returncode, 0, passed.stderr)
            archive = next(root.glob("*.tar"))
            receipt = next(root.glob("*.receipt.json"))
            verified = subprocess.run(
                [
                    "python3", str(VERIFIER),
                    "--inventory", str(inventory_path),
                    "--runtime-sbom", str(RUNTIME_SBOM),
                    "--dependency-lock", str(DEPENDENCY_LOCK),
                    "--gstreamer-lock", str(GSTREAMER_LOCK),
                    "--archive", str(archive),
                    "--receipt", str(receipt),
                ],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(verified.returncode, 0, verified.stderr)
            inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
            missing = source_root / inventory["requirements"][0]["deliveryPath"]
            missing.unlink()
            failed = run_verifier(inventory_path, source_root)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("required material is absent", failed.stderr)

    def test_source_tree_rejects_intermediate_symlinks_hardlinks_and_extras(self) -> None:
        for unsafe_kind in ("intermediate-symlink", "hardlink", "extra"):
            with self.subTest(unsafe_kind=unsafe_kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                inventory_path = self.create_complete_fixture(root)
                source_root = root / "source"
                inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
                first_material = source_root / inventory["requirements"][0]["deliveryPath"]
                if unsafe_kind == "intermediate-symlink":
                    outside = root / "outside-archives"
                    first_material.parent.rename(outside)
                    first_material.parent.symlink_to(outside, target_is_directory=True)
                    expected = "source-package tree contains a symlink"
                elif unsafe_kind == "hardlink":
                    duplicate = first_material.with_name(first_material.name + ".hardlink")
                    os.link(first_material, duplicate)
                    expected = "source-package tree contains a hardlink"
                else:
                    (source_root / "unexpected.txt").write_text("unexpected\n", encoding="utf-8")
                    expected = "source-package tree contains an unlisted file"
                failed = run_verifier(inventory_path, source_root)
                self.assertNotEqual(failed.returncode, 0)
                self.assertIn(expected, failed.stderr)

    def test_exact_macos_var_alias_reaches_the_same_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            physical = Path(temporary).resolve()
            physical_text = str(physical)
            if not physical_text.startswith("/private/var/"):
                self.skipTest("macOS /var alias is unavailable for this temporary directory")
            alias = Path("/var") / physical.relative_to("/private/var")
            physical_descriptor = TOOL.open_path_without_symlinks(physical, directory=True)
            alias_descriptor = TOOL.open_path_without_symlinks(alias, directory=True)
            try:
                physical_metadata = os.fstat(physical_descriptor)
                alias_metadata = os.fstat(alias_descriptor)
                self.assertEqual(
                    (physical_metadata.st_dev, physical_metadata.st_ino),
                    (alias_metadata.st_dev, alias_metadata.st_ino),
                )
            finally:
                os.close(physical_descriptor)
                os.close(alias_descriptor)

    def test_receipt_publication_rolls_back_after_real_link_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source_root = root / "minimal-source"
            source_root.mkdir()
            payload = b"minimal corresponding source\n"
            (source_root / "material.txt").write_bytes(payload)
            output = root / "output"
            output.mkdir()

            def fail_after_receipt_link(
                event: str, _descriptor: int, _receipt_name: str
            ) -> None:
                if event == "receipt-linked":
                    raise OSError("fixture post-link failure")

            with mock.patch.object(
                TOOL, "_publication_precommit_seam", side_effect=fail_after_receipt_link
            ):
                with self.assertRaises(OSError):
                    TOOL.create_source_archive(
                        source_root,
                        {"material.txt": hashlib.sha256(payload).hexdigest()},
                        output / "source.tar",
                        output / "source.receipt.json",
                        {
                            "inventorySHA256": "1" * 64,
                            "runtimeSBOMSHA256": "2" * 64,
                            "dependencyLockSHA256": "3" * 64,
                            "gstreamerLockSHA256": "4" * 64,
                        },
                        "5" * 64,
                    )
            self.assertEqual(list(output.iterdir()), [])

    def test_receipt_publication_rejects_replacement_and_parent_swap(self) -> None:
        for attack in ("receipt-replacement", "parent-swap"):
            with self.subTest(attack=attack), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                source_root = root / "minimal-source"
                source_root.mkdir()
                payload = b"minimal corresponding source\n"
                (source_root / "material.txt").write_bytes(payload)
                output = root / "output"
                output.mkdir()
                displaced = root / "displaced"
                archive = output / "source.tar"
                receipt = output / "source.receipt.json"

                def attack_before_commit(
                    event: str, _descriptor: int, receipt_name: str
                ) -> None:
                    if attack == "receipt-replacement" and event == "receipt-linked":
                        receipt_path = output / receipt_name
                        receipt_path.unlink()
                        receipt_path.write_text("replacement\n", encoding="utf-8")
                    elif attack == "parent-swap" and event == "before-parent-fsync":
                        output.rename(displaced)
                        output.mkdir()

                with mock.patch.object(
                    TOOL, "_publication_precommit_seam", side_effect=attack_before_commit
                ):
                    with self.assertRaises(TOOL.VerificationError):
                        TOOL.create_source_archive(
                            source_root,
                            {"material.txt": hashlib.sha256(payload).hexdigest()},
                            archive,
                            receipt,
                            {
                                "inventorySHA256": "1" * 64,
                                "runtimeSBOMSHA256": "2" * 64,
                                "dependencyLockSHA256": "3" * 64,
                                "gstreamerLockSHA256": "4" * 64,
                            },
                            "5" * 64,
                        )
                if attack == "receipt-replacement":
                    self.assertEqual(receipt.read_text(encoding="utf-8"), "replacement\n")
                    self.assertFalse(archive.exists())
                else:
                    self.assertEqual(list(output.iterdir()), [])
                    self.assertFalse((displaced / archive.name).exists())
                    self.assertFalse((displaced / receipt.name).exists())

    def test_raw_pax_header_is_rejected_even_with_matching_archive_digest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            archive, _receipt_path, receipt = self.create_minimal_package(root)
            raw = bytearray(archive.read_bytes())
            raw[156] = ord("x")
            raw[148:156] = b" " * 8
            checksum = sum(raw[:512])
            raw[148:156] = f"{checksum:06o}\0 ".encode("ascii")
            archive.write_bytes(raw)
            receipt["archive"]["byteCount"] = len(raw)
            receipt["archive"]["sha256"] = hashlib.sha256(raw).hexdigest()
            with self.assertRaisesRegex(
                TOOL.VerificationError,
                "link, directory, special, GNU, or PAX entry",
            ):
                TOOL.verify_archive_against_receipt(archive, receipt)

    def test_consumer_rejects_source_bound_to_another_component(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            inventory_path = self.create_complete_fixture(root)
            inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
            requirement = next(
                row for row in inventory["requirements"]
                if row["id"] == "homebrew-gmp-source"
            )
            requirement["consumerBindings"] = [
                {"authority": "homebrew", "component": "gettext", "version": "1.0"}
            ]
            inventory_path.write_text(
                json.dumps(inventory, indent=2) + "\n",
                encoding="utf-8",
            )
            failed = run_verifier(inventory_path, root / "source")
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("material bound to another identity", failed.stderr)

    def test_current_release_inputs_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            failed = run_verifier(INVENTORY, Path(temporary))
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("required material is unresolved", failed.stderr)

    def test_public_release_propagates_copyleft_gate_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            scripts = root / "Scripts"
            scripts.mkdir()
            release_gate = scripts / "verify-public-release-license-policy.sh"
            shutil.copy2(
                ROOT / "Scripts" / "verify-public-release-license-policy.sh",
                release_gate,
            )
            for stub_name in (
                "verify-open-source-export.sh",
                "verify-bundled-runtime-capability.sh",
            ):
                stub = scripts / stub_name
                stub.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                stub.chmod(0o755)
            shutil.copy2(VERIFIER, scripts / VERIFIER.name)
            for trusted_script in (
                "verify-public-runtime-build-receipt.py",
                "public-runtime-release-attestation.py",
            ):
                (scripts / trusted_script).write_text("#!/usr/bin/env python3\n", encoding="utf-8")

            app = root / "ForgePlayFixture.app"
            resources = app / "Contents" / "Resources"
            runtime = resources / "Runners" / "ForgePlayRuntime"
            (runtime / "Frameworks" / "renderer" / "d3dmetal").mkdir(parents=True)
            scope = resources / "LICENSES" / "ForgePlayGameMode" / "GAME_MODE_LICENSE_SCOPE.md"
            scope.parent.mkdir(parents=True)
            scope.write_text(
                "direct-DMG release contract intentionally includes D3DMetal\n"
                "not relicensed under `GPL-3.0-only`\n",
                encoding="utf-8",
            )
            (resources / "LICENSE.md").write_text(
                "identified third-party runtime component under its own Apple terms\n",
                encoding="utf-8",
            )
            (runtime / "PublicRuntimeBuildClaim.json").write_text("{}\n", encoding="utf-8")
            (resources / "PublicDistributionBuildClaim.json").write_text("{}\n", encoding="utf-8")

            corresponding_source = root / "OpenSource"
            source_scripts = corresponding_source / "Scripts"
            source_config = corresponding_source / "Config"
            source_scripts.mkdir(parents=True)
            source_config.mkdir()
            shutil.copy2(VERIFIER, source_scripts / VERIFIER.name)
            for required_script in (
                "verify-public-runtime-build-receipt.py",
                "public-runtime-release-attestation.py",
            ):
                (source_scripts / required_script).write_text("# fixture\n", encoding="utf-8")
            (corresponding_source / "SOURCE-INVENTORY.json").write_text("{}\n", encoding="utf-8")
            (source_config / "ForgePlayPublicDistributionSourceGraph.json").write_text(
                "{}\n", encoding="utf-8"
            )

            target_path = "wine/lib/libfixture.dylib"
            license_expression = "LGPL-2.1-only"
            self.write_json(
                source_config / "ForgePlayRuntimeDependencies.lock.json",
                {
                    "artifacts": [{
                        "formula": "fixture",
                        "formulaVersion": "1",
                        "targetPath": target_path,
                        "licenseExpression": license_expression,
                    }]
                },
            )
            self.write_json(
                source_config / "ForgePlayGStreamerPayload.lock.json",
                {"artifacts": []},
            )
            self.write_json(
                runtime / "RuntimeSBOM.json",
                {
                    "hostSupportPayload": [{
                        "path": target_path,
                        "component": "fixture",
                        "version": "1",
                        "licenseExpression": license_expression,
                        "sourceKind": "homebrew-core-prebuilt-package",
                        "contentSHA256": "0" * 64,
                    }]
                },
            )
            binding = {"authority": "homebrew", "component": "fixture", "version": "1"}
            requirement_ids = ["fixture-source", "fixture-build", "fixture-relink"]
            requirements = []
            for identifier, material_class in zip(
                requirement_ids,
                ("corresponding-source", "build-recipe", "relinking-materials"),
            ):
                requirements.append({
                    "id": identifier,
                    "materialClass": material_class,
                    "sourceKind": "fixture",
                    "version": "1",
                    "deliveryPath": f"fixtures/{identifier}",
                    "sourceURL": "UNRESOLVED: fixture",
                    "sha256": "UNRESOLVED",
                    "status": "unresolved",
                    "consumerBindings": [binding],
                })
            self.write_json(
                source_config / "ForgePlayCopyleftSourcePackages.json",
                {
                    "schemaVersion": 1,
                    "deliveryContract": {
                        "defaultSiblingSourceRoot": "ThirdPartyCorrespondingSource",
                        "distributionMode": "simultaneous-source-package",
                        "linkageEvidence": "declared-dynamic-library-paths-from-locks-and-runtime-sbom",
                        "releaseStatus": "fail-closed-until-all-required-materials-are-pinned-and-present",
                    },
                    "consumers": [{
                        "key": "homebrew:fixture@1",
                        "requiredRequirementIds": requirement_ids,
                    }],
                    "requirements": requirements,
                },
            )

            source_packages = root / "ThirdPartyCorrespondingSource"
            source_packages.mkdir()
            source_archive = root / "fixture-source.tar"
            source_archive.write_bytes(b"fixture archive\n")
            source_receipt = root / "fixture-source.receipt.json"
            source_receipt.write_text("{}\n", encoding="utf-8")
            trusted_repository = root / "trusted-repository"
            trusted_repository.mkdir()
            attestation = root / "attestation.json"
            attestation.write_text("{}\n", encoding="utf-8")
            failed = subprocess.run(
                [
                    "bash",
                    str(release_gate),
                    "--trusted-git-repository",
                    str(trusted_repository),
                    "--release-attestation",
                    str(attestation),
                    "--corresponding-source",
                    str(corresponding_source),
                    "--copyleft-source-archive",
                    str(source_archive),
                    "--copyleft-source-receipt",
                    str(source_receipt),
                    str(app),
                ],
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn(
                "bundled dynamic GPL/LGPL source-package delivery is incomplete",
                failed.stderr,
            )

    def test_public_release_rejects_corresponding_source_environment_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            app = root / "Fixture.app"
            app.mkdir()
            trusted = root / "trusted"
            trusted.mkdir()
            attestation = root / "attestation.json"
            attestation.write_text("{}\n", encoding="utf-8")
            archive = root / "source.tar"
            archive.write_bytes(b"archive\n")
            receipt = root / "source.receipt.json"
            receipt.write_text("{}\n", encoding="utf-8")
            environment = os.environ.copy()
            environment["FORGEPLAY_CORRESPONDING_SOURCE_ROOT"] = str(root / "environment-source")
            failed = subprocess.run(
                [
                    "bash",
                    str(ROOT / "Scripts" / "verify-public-release-license-policy.sh"),
                    "--trusted-git-repository", str(trusted),
                    "--release-attestation", str(attestation),
                    "--copyleft-source-archive", str(archive),
                    "--copyleft-source-receipt", str(receipt),
                    str(app),
                ],
                check=False,
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("--corresponding-source <export>", failed.stderr)

    def test_exporter_and_copyleft_tools_are_executable(self) -> None:
        for path in (
            ROOT / "Scripts" / "export-open-source.sh",
            VERIFIER,
            Path(__file__),
        ):
            self.assertTrue(path.stat().st_mode & stat.S_IXUSR, path)


if __name__ == "__main__":
    unittest.main()
