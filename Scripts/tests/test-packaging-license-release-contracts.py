#!/usr/bin/env python3
"""Static contracts for the public ForgePlay source publication graph."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def text(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class PublicSourcePackagingContractTests(unittest.TestCase):
    def test_export_injects_the_visible_source_policy_and_canonical_marker(self) -> None:
        exporter = text("Scripts/export-open-source.sh")
        verifier = text("Scripts/verify-open-source-export.sh")
        readme = text("Scripts/Templates/OpenSource/README.md")

        self.assertIn(
            "for template_file in README.md README_KO.md README_EN.md SOURCE-LICENSES.md",
            exporter,
        )
        self.assertIn(
            '".forgeplay-source-export": "Scripts/Templates/OpenSource/export-marker"',
            verifier,
        )
        self.assertIn(
            '"Resources/Runners/ForgePlayRuntime/Patches/'
            'wine-11.12-game-mode-process-host-routing.patch.license"',
            verifier,
        )
        self.assertIn(
            '"Resources/Runners/ForgePlayRuntime/Patches/'
            'wine-11.12-game-mode-direct-target-scope.patch.license"',
            verifier,
        )
        self.assertIn("allowlisted, source-only publication tree", readme)
        self.assertIn("source, tests, license records, and reconstruction tools", readme)

    def test_runtime_build_and_source_delivery_tools_remain_in_the_export(self) -> None:
        exporter = text("Scripts/export-open-source.sh")
        verifier = text("Scripts/verify-open-source-export.sh")
        for relative in (
            "build-forgeplay-wine-runtime.sh",
            "build-public-forgeplay-runtime.sh",
            "freeze-public-source-export.py",
            "materialize-forgeplay-wine-11.12-source.sh",
            "package-forgeplay-runtime.sh",
            "validate-d3dmetal-ngx-bridge.sh",
            "verify-copyleft-source-packages.py",
            "verify-public-runtime-build-receipt.py",
        ):
            with self.subTest(relative=relative):
                self.assertIn(relative, exporter)
                self.assertIn(relative, verifier)

    def test_generated_build_metadata_is_not_a_source_materializer_input(self) -> None:
        exporter = text("Scripts/export-open-source.sh")
        verifier = text("Scripts/verify-open-source-export.sh")
        materializer = text("Scripts/materialize-forgeplay-wine-11.12-source.sh")

        self.assertIn("generated package metadata are deliberately not exported", exporter)
        self.assertNotIn(
            'materialize_file "Resources/Runners/ForgePlayRuntime/BUILD-METADATA.md"',
            exporter,
        )
        self.assertIn('"Resources/Runners/ForgePlayRuntime/BUILD-METADATA.md"', verifier)
        for stale_input in (
            'BUILD_METADATA="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/BUILD-METADATA.md"',
            "build_metadata_path",
            "build_metadata_snapshot",
            "current_build_patch_set",
            "current_build_source_tree",
        ):
            self.assertNotIn(stale_input, materializer)

    def test_freezer_keeps_the_exact_additional_wine_archive_contract(self) -> None:
        freezer = text("Scripts/freeze-public-source-export.py")
        expected = "CorrespondingSource/Wine/wine-11.12.tar.xz"
        self.assertIn(f'WINE_ARCHIVE_PATH = "{expected}"', freezer)
        self.assertIn('len(additional_entries) != 1', freezer)

    def test_public_release_graph_is_exported_without_private_local_state(self) -> None:
        exporter = text("Scripts/export-open-source.sh")
        verifier = text("Scripts/verify-open-source-export.sh")
        for required in (
            'materialize_tree "Sources/ForgePlay"',
            'materialize_tree "Tests/ForgePlayTests"',
            'materialize_tree "Resources/AppIcon.icon"',
            "ForgePlayPublicDistributionSourceGraph.json",
            "build-commercial-release.sh",
            "build-public-distribution-archive.sh",
            "ForgePlayApp.xcconfig",
        ):
            self.assertIn(required, exporter)
        self.assertNotIn('materialize_file "Config/ForgePlay.local.xcconfig"', exporter)
        self.assertIn("-name 'ForgePlay.local.xcconfig'", verifier)
        self.assertIn('"Artifacts"', verifier)
        self.assertIn('"docs"', verifier)

    def test_d3dmetal_payload_is_source_excluded_and_not_relicensed(self) -> None:
        readme_english = text("Scripts/Templates/OpenSource/README_EN.md")
        license_manifest = text("LICENSE.md")
        self.assertIn("Excluded from this source tree and not relicensed", readme_english)
        self.assertIn(
            "identified third-party runtime component under its own Apple terms",
            license_manifest,
        )
        self.assertIn("is not relicensed under", license_manifest)


if __name__ == "__main__":
    unittest.main(verbosity=2)
