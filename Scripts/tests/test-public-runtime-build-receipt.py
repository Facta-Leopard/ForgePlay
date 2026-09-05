#!/usr/bin/env python3
"""Executable regression for the public Runtime source-to-output receipt."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
TOOL = REPOSITORY / "Scripts/verify-public-runtime-build-receipt.py"
ORCHESTRATOR = REPOSITORY / "Scripts/build-public-forgeplay-runtime.sh"
COMMAND_PATHS = (
    "Scripts/build-public-forgeplay-runtime.sh",
    "Scripts/materialize-forgeplay-wine-11.12-source.sh",
    "Scripts/build-forgeplay-wine-runtime.sh",
    "Scripts/package-forgeplay-runtime.sh",
    "Scripts/verify-open-source-export.sh",
    "Scripts/verify-public-runtime-build-receipt.py",
)


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class PublicRuntimeBuildReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.export = root / "export"
        self.install = root / "install"
        self.runtime = root / "runtime"
        self.export.mkdir()
        self.install.mkdir()
        self.runtime.mkdir()
        (self.install / "bin").mkdir()
        (self.install / "bin/wine").write_bytes(b"fresh-install-output")
        os.chmod(self.install / "bin/wine", 0o755)
        self.compiler = root / "compiler.json"
        self.build_tool = root / "build-tool.json"
        write_json(self.compiler, {"compiler": "fixture"})
        write_json(self.build_tool, {"buildTool": "fixture"})
        entries = []
        for index, relative in enumerate(COMMAND_PATHS, start=1):
            digest = hashlib.sha256(relative.encode()).hexdigest()
            entries.append(
                {
                    "byteLength": len(relative),
                    "mode": "100755" if relative.endswith(".sh") else "100644",
                    "origin": {
                        "classification": "release-commit-blob",
                        "destinationPath": relative,
                        "gitMode": "100755" if relative.endswith(".sh") else "100644",
                        "gitObjectID": f"{index:040x}",
                        "sha256": digest,
                        "sourcePath": relative,
                    },
                    "path": relative,
                    "sha256": digest,
                }
            )
        self.inventory = {
            "entries": entries,
            "inventorySHA256": "1" * 64,
            "releaseCommit": "2" * 40,
            "schemaVersion": 2,
        }
        write_json(self.export / "SOURCE-INVENTORY.json", self.inventory)
        write_json(
            self.export / "Config/ForgePlayPublicDistributionSourceGraph.json",
            {"requiredReleaseCommitPaths": list(COMMAND_PATHS), "schemaVersion": 1},
        )
        self.receipt = root / "receipt.json"
        self.source_sha = "3" * 64
        self.run_tool(
            "create-prepackage",
            "--export-root", str(self.export),
            "--source-tree-sha256", self.source_sha,
            "--install-root", str(self.install),
            "--compiler-capsule-manifest", str(self.compiler),
            "--build-tool-capsule-manifest", str(self.build_tool),
            "--receipt", str(self.receipt),
        )
        manifest = {
            "corePayloadFingerprint": "4" * 64,
            "hostSupportPayloadFingerprint": "5" * 64,
            "patchSetSHA256": "6" * 64,
            "runnerBuildFingerprint": "7" * 64,
            "sourceTreeSHA256": self.source_sha,
        }
        write_json(self.runtime / "RuntimeManifest.json", manifest)
        self.run_tool(
            "write-claim",
            "--receipt", str(self.receipt),
            "--manifest", str(self.runtime / "RuntimeManifest.json"),
            "--output", str(self.runtime / "PublicRuntimeBuildClaim.json"),
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_tool(self, *arguments: str, expect_success: bool = True) -> subprocess.CompletedProcess:
        result = subprocess.run(
            ["/usr/bin/python3", os.fspath(TOOL), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if expect_success and result.returncode != 0:
            self.fail(result.stderr)
        if not expect_success and result.returncode == 0:
            self.fail("receipt verifier unexpectedly accepted a malformed fixture")
        return result

    def verify_prepackage(self, expect_success: bool = True) -> None:
        self.run_tool(
            "verify-prepackage",
            "--export-root", str(self.export),
            "--source-tree-sha256", self.source_sha,
            "--install-root", str(self.install),
            "--compiler-capsule-manifest", str(self.compiler),
            "--build-tool-capsule-manifest", str(self.build_tool),
            "--receipt", str(self.receipt),
            expect_success=expect_success,
        )

    def test_receipt_binds_fresh_install_toolchain_graph_and_outputs(self) -> None:
        self.verify_prepackage()
        self.run_tool(
            "verify-runtime",
            "--runtime-root", str(self.runtime),
            "--source-inventory", str(self.export / "SOURCE-INVENTORY.json"),
        )
        claim = json.loads(
            (self.runtime / "PublicRuntimeBuildClaim.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            claim["claimStatus"], "unsigned build claim awaiting release attestation"
        )
        self.assertFalse((self.runtime / "PublicRuntimeReleaseAttestation.json").exists())
        (self.install / "bin/wine").write_bytes(b"substituted-install")
        self.verify_prepackage(expect_success=False)
        (self.compiler).write_text("{}\n", encoding="utf-8")
        self.verify_prepackage(expect_success=False)
        claim = json.loads(
            (self.runtime / "PublicRuntimeBuildClaim.json").read_text(encoding="utf-8")
        )
        claim["runtimeBuildReceipt"]["runtimeOutputs"]["runnerBuildFingerprint"] = "8" * 64
        write_json(self.runtime / "PublicRuntimeBuildClaim.json", claim)
        self.run_tool(
            "verify-runtime",
            "--runtime-root", str(self.runtime),
            "--source-inventory", str(self.export / "SOURCE-INVENTORY.json"),
            expect_success=False,
        )

    def test_orchestrator_builds_and_packages_in_one_fresh_transaction(self) -> None:
        text = ORCHESTRATOR.read_text(encoding="utf-8")
        ordered = [
            '/bin/bash "$MATERIALIZER" "$WINE_SOURCE_ARCHIVE" "$SOURCE_ROOT"',
            '/bin/bash "$BUILDER" "$SOURCE_ROOT" "$BUILD_ROOT" "$INSTALL_ROOT"',
            "create-prepackage",
            '"$PACKAGER" --public-source-package',
            "verify-runtime",
        ]
        positions = [text.index(marker) for marker in ordered]
        self.assertEqual(positions, sorted(positions))
        self.assertIn('TRANSACTION_ROOT=""', text)
        self.assertNotIn('$SOURCE_EXPORT/Resources/Runners', text)


if __name__ == "__main__":
    unittest.main()
