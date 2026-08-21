#!/usr/bin/env python3
"""Regression tests for external Developer ID Runtime release attestation."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


REPOSITORY = Path(__file__).resolve().parents[2]
TOOL_PATH = REPOSITORY / "Scripts/public-runtime-release-attestation.py"
SPEC = importlib.util.spec_from_file_location("release_attestation", TOOL_PATH)
assert SPEC is not None and SPEC.loader is not None
TOOL = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = TOOL
SPEC.loader.exec_module(TOOL)


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(TOOL.canonical_json(value))


class PublicRuntimeReleaseAttestationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.app = root / "ForgePlay.app"
        self.runtime = self.app / "Contents/Resources/Runners/ForgePlayRuntime"
        self.runtime.mkdir(parents=True)
        self.manifest = {
            "corePayloadFingerprint": "1" * 64,
            "hostSupportPayloadFingerprint": "2" * 64,
            "patchSetSHA256": "3" * 64,
            "runnerBuildFingerprint": "4" * 64,
            "sourceTreeSHA256": "5" * 64,
        }
        manifest_raw = TOOL.canonical_json(self.manifest)
        receipt = {
            "claimStatus": "unsigned build claim awaiting release attestation",
            "runtimeOutputs": {
                **self.manifest,
                "runtimeManifestSHA256": TOOL.sha256(manifest_raw),
            },
            "schemaVersion": 2,
        }
        self.claim = {
            "claimStatus": "unsigned build claim awaiting release attestation",
            "corePayloadFingerprint": self.manifest["corePayloadFingerprint"],
            "currentFinalPatchedSourceTreeSHA256": self.manifest["sourceTreeSHA256"],
            "hostSupportPayloadFingerprint": self.manifest["hostSupportPayloadFingerprint"],
            "patchSetSHA256": self.manifest["patchSetSHA256"],
            "runnerBuildFingerprint": self.manifest["runnerBuildFingerprint"],
            "runtimeBuildReceipt": receipt,
            "runtimeManifestSHA256": TOOL.sha256(manifest_raw),
            "schemaVersion": 2,
        }
        write_json(self.runtime / "RuntimeManifest.json", self.manifest)
        write_json(self.runtime / "PublicRuntimeBuildClaim.json", self.claim)
        self.attestation = root / "ForgePlay.release-attestation.json"
        self.metadata = {
            "authorities": [
                "Developer ID Application: ForgePlay, Inc. (ABCDE12345)",
                "Developer ID Certification Authority",
                "Apple Root CA",
            ],
            "bundle": "com.forgeplay.app",
            "cdhash": "a" * 40,
            "requirement": 'anchor apple generic and identifier "com.forgeplay.app"',
            "team": "ABCDE12345",
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def mocked_command(self, argv: tuple[str, ...]) -> object:
        if argv[0] == TOOL.CODESIGN and argv[1:5] == ("--verify", "--strict", "--deep", "--verbose=4"):
            return TOOL.CommandOutput(0, "", "")
        if argv[0] == TOOL.CODESIGN and argv[1:3] == ("-d", "--verbose=4"):
            lines = [
                f"Identifier={self.metadata['bundle']}",
                *(f"Authority={value}" for value in self.metadata["authorities"]),
                f"TeamIdentifier={self.metadata['team']}",
                f"CDHash={self.metadata['cdhash']}",
                "Runtime Version=15.0.0",
            ]
            return TOOL.CommandOutput(0, "", "\n".join(lines) + "\n")
        if argv[0] == TOOL.CODESIGN and argv[1:3] == ("-d", "-r-"):
            return TOOL.CommandOutput(0, "", f"designated => {self.metadata['requirement']}\n")
        self.fail(f"unexpected command: {argv}")

    def create(self) -> None:
        with patch.object(TOOL, "run_command", side_effect=self.mocked_command):
            TOOL.create_attestation(self.app, self.attestation)

    def verify(self, succeeds: bool = True) -> None:
        with patch.object(TOOL, "run_command", side_effect=self.mocked_command):
            if succeeds:
                TOOL.verify_attestation(self.app, self.attestation)
            else:
                with self.assertRaises(TOOL.AttestationError):
                    TOOL.verify_attestation(self.app, self.attestation)

    def test_create_and_verify_bind_signed_app_and_runtime_subjects(self) -> None:
        self.create()
        self.verify()
        attestation = json.loads(self.attestation.read_text(encoding="utf-8"))
        self.assertEqual(attestation["schemaVersion"], 1)
        self.assertEqual(attestation["runtime"]["subjects"]["sourceTreeSHA256"], "5" * 64)

    def test_claim_receipt_and_runtime_tampering_is_rejected(self) -> None:
        self.create()
        self.claim["corePayloadFingerprint"] = "6" * 64
        write_json(self.runtime / "PublicRuntimeBuildClaim.json", self.claim)
        self.verify(False)
        self.claim["corePayloadFingerprint"] = "1" * 64
        self.claim["runtimeBuildReceipt"]["runtimeOutputs"]["corePayloadFingerprint"] = "6" * 64
        write_json(self.runtime / "PublicRuntimeBuildClaim.json", self.claim)
        self.verify(False)
        self.claim["runtimeBuildReceipt"]["runtimeOutputs"]["corePayloadFingerprint"] = "1" * 64
        write_json(self.runtime / "PublicRuntimeBuildClaim.json", self.claim)
        self.manifest["corePayloadFingerprint"] = "6" * 64
        write_json(self.runtime / "RuntimeManifest.json", self.manifest)
        self.verify(False)

    def test_team_cdhash_and_designated_requirement_tampering_is_rejected(self) -> None:
        self.create()
        for key, value in (("team", "ZZZZZ99999"), ("cdhash", "b" * 40), ("requirement", "anchor apple generic and identifier \"other\"")):
            self.metadata[key] = value
            self.verify(False)
            self.metadata[key] = {
                "team": "ABCDE12345",
                "cdhash": "a" * 40,
                "requirement": 'anchor apple generic and identifier "com.forgeplay.app"',
            }[key]

    def test_authority_tampering_and_non_developer_id_are_rejected(self) -> None:
        self.create()
        self.metadata["authorities"][1] = "Untrusted Intermediate"
        self.verify(False)
        self.metadata["authorities"][1] = "Developer ID Certification Authority"
        self.metadata["authorities"][0] = "Apple Development: ForgePlay, Inc. (ABCDE12345)"
        self.verify(False)


if __name__ == "__main__":
    unittest.main()
