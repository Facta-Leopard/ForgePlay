#!/usr/bin/env python3
"""Static contracts for the public compatibility-source package."""

from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def text(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


class CompatibilitySourcePackagingContractTests(unittest.TestCase):
    def test_export_materializes_full_allowlisted_source_and_visible_policy(self) -> None:
        exporter = text("Scripts/export-open-source.sh")
        verifier = text("Scripts/verify-open-source-export.sh")
        readme = text("Scripts/Templates/OpenSource/README.md")

        for fragment in (
            'materialize_tree "Sources/ForgePlay"',
            'materialize_tree "Tests/ForgePlayTests"',
            'materialize_tree "Native/D3DMetalFrameGenerationProxy"',
            'materialize_file "project.yml"',
            "for template_file in README.md README_KO.md README_EN.md SOURCE-LICENSES.md",
        ):
            self.assertIn(fragment, exporter)
        self.assertIn('"README.md": "Scripts/Templates/OpenSource/README.md"', verifier)
        self.assertIn('"SOURCE-INVENTORY.json"', verifier)
        self.assertIn("allowlisted, source-only publication tree", readme)

    def test_runtime_build_and_source_delivery_tools_remain_in_the_export(self) -> None:
        exporter = text("Scripts/export-open-source.sh")
        verifier = text("Scripts/verify-open-source-export.sh")
        for relative in (
            "build-forgeplay-wine-runtime.sh",
            "build-public-forgeplay-runtime.sh",
            "freeze-public-source-export.py",
            "materialize-forgeplay-wine-11.12-source.sh",
            "materialize-locked-gstreamer-runtime.py",
            "materialize-locked-renderer.py",
            "materialize-locked-runtime-dependencies.py",
            "package-forgeplay-runtime.sh",
            "verify-copyleft-source-packages.py",
            "verify-public-runtime-build-receipt.py",
        ):
            self.assertIn(relative, exporter)
            self.assertIn(relative, verifier)

    def test_freezer_keeps_the_exact_additional_wine_archive_contract(self) -> None:
        freezer = text("Scripts/freeze-public-source-export.py")
        readme = text("Scripts/Templates/OpenSource/README.md")
        expected = "CorrespondingSource/Wine/wine-11.12.tar.xz"
        self.assertIn(f'WINE_ARCHIVE_PATH = "{expected}"', freezer)
        self.assertIn('len(additional_entries) != 1', freezer)
        self.assertIn("runtime source and reconstruction record", readme)

    def test_public_app_source_graph_excludes_third_party_binary_payloads(self) -> None:
        exporter = text("Scripts/export-open-source.sh")
        graph = text("Config/ForgePlayPublicDistributionSourceGraph.json")
        for required in (
            "ForgePlayPublicDistributionSourceGraph.json",
            "build-commercial-release.sh",
            "build-public-distribution-archive.sh",
            'materialize_tree "Sources/ForgePlay"',
            'materialize_tree "Tests/ForgePlayTests"',
            "ForgePlayApp.xcconfig",
        ):
            self.assertIn(required, exporter)
        self.assertIn(
            "Resources/Runners/ForgePlayRuntime/Frameworks/renderer/d3dmetal",
            graph,
        )
        self.assertIn("Runtime binaries, Frameworks, D3DMetal", exporter)

    def test_d3dmetal_binary_is_excluded_while_proxy_source_is_published(self) -> None:
        readme = text("Scripts/Templates/OpenSource/README_EN.md")
        source_licenses = text("Scripts/Templates/OpenSource/SOURCE-LICENSES.md")
        license_manifest = text("LICENSE.md")
        self.assertIn("built Wine, D3DMetal, renderer, GStreamer, SDL", readme)
        self.assertIn("independent bridge source", source_licenses)
        self.assertIn("relicensed under GPL or LGPL", source_licenses)
        self.assertIn("includes D3DMetal as a separately", license_manifest)
        self.assertIn("identified third-party runtime component", license_manifest)


if __name__ == "__main__":
    unittest.main(verbosity=2)
