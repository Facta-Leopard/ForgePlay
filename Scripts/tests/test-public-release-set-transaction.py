#!/usr/bin/env python3

from __future__ import annotations

import errno
import importlib.util
import io
import json
import os
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
TOOL_PATH = ROOT / "Scripts" / "public-release-set-transaction.py"
SPEC = importlib.util.spec_from_file_location("public_release_set_transaction", TOOL_PATH)
assert SPEC is not None and SPEC.loader is not None
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)


class ReleaseSetTransactionTests(unittest.TestCase):
    dmg_name = "ForgePlay-1.2.3-45.dmg"

    def populate(self, directory: Path, *, commercial: bool) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        kind = "official-notarized-dmg" if commercial else "local-unnotarized-dmg"
        names = TOOL.expected_names(self.dmg_name, commercial)
        for name in names:
            path = directory / name
            if name.endswith(".release.json"):
                manifest = {
                    "schemaVersion": 3,
                    "releaseKind": kind,
                    "publicRuntimeReleaseAttestation": None,
                    "projectCorrespondingSource": None,
                    "copyleftSourcePackage": None,
                }
                if commercial:
                    manifest.update({
                        "publicRuntimeReleaseAttestation": {
                            "value": {"runtime": {"subjects": {
                                "hostSupportPayloadFingerprint": "a" * 64,
                            }}},
                        },
                        "projectCorrespondingSource": {
                            "value": {"additionalEntries": [{
                                "path": TOOL.WINE_SOURCE_PATH,
                                "sha256": "b" * 64,
                            }]},
                        },
                        "copyleftSourcePackage": {
                            "receipt": {"value": {
                                "hostSupportPayloadFingerprint": "a" * 64,
                            }},
                        },
                    })
                path.write_text(
                    json.dumps(manifest, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            elif name.endswith("-OpenSource.tar"):
                path.write_bytes(
                    b"OpenSource/Scripts/verify-open-source-export.sh\n"
                    b"#!/bin/sh\ntouch SHOULD-NOT-EXECUTE\n"
                )
            else:
                path.write_bytes((name + "\n").encode())

    def private_snapshot_dir(self, root: Path, name: str = "snapshot") -> Path:
        path = root / name
        path.mkdir(mode=0o700)
        return path

    def test_commercial_and_local_sets_snapshot_without_executing_asset_content(self) -> None:
        for commercial in (False, True):
            with self.subTest(commercial=commercial), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                release = root / "release"
                self.populate(release, commercial=commercial)
                snapshot_dir = self.private_snapshot_dir(root)
                marker = root / "SHOULD-NOT-EXECUTE"
                snapshotted_dmg = TOOL.snapshot(release, snapshot_dir)
                self.assertEqual(snapshotted_dmg.name, self.dmg_name)
                self.assertEqual(
                    {path.name for path in snapshot_dir.iterdir()},
                    TOOL.expected_names(self.dmg_name, commercial),
                )
                self.assertFalse(marker.exists(), "release asset content was executed")

    def test_snapshot_rejects_extra_symlink_hardlink_and_schema_mismatch(self) -> None:
        for unsafe in ("extra", "symlink", "hardlink", "schema"):
            with self.subTest(unsafe=unsafe), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                release = root / "release"
                self.populate(release, commercial=True)
                if unsafe == "extra":
                    (release / "unexpected").write_text("x", encoding="utf-8")
                elif unsafe == "symlink":
                    target = release / f"{self.dmg_name}.sha256"
                    target.unlink()
                    target.symlink_to(release / self.dmg_name)
                elif unsafe == "hardlink":
                    target = release / f"{self.dmg_name}.sha256"
                    original = release / self.dmg_name
                    target.unlink()
                    os.link(original, target)
                else:
                    manifest = release / f"{self.dmg_name}.release.json"
                    manifest.write_text(
                        json.dumps({"schemaVersion": 3, "releaseKind": "local-unnotarized-dmg"}) + "\n",
                        encoding="utf-8",
                    )
                with self.assertRaises((OSError, TOOL.TransactionError)):
                    TOOL.snapshot(release, self.private_snapshot_dir(root))

    def test_snapshot_rejects_wine_and_host_support_binding_mismatch(self) -> None:
        for mismatch in ("wine-path", "wine-sha", "host-support"):
            with self.subTest(mismatch=mismatch), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                release = root / "release"
                self.populate(release, commercial=True)
                manifest_path = release / f"{self.dmg_name}.release.json"
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                if mismatch == "wine-path":
                    manifest["projectCorrespondingSource"]["value"]["additionalEntries"][0]["path"] = "Wine/source.tar.xz"
                elif mismatch == "wine-sha":
                    manifest["projectCorrespondingSource"]["value"]["additionalEntries"][0]["sha256"] = "not-a-digest"
                else:
                    manifest["copyleftSourcePackage"]["receipt"]["value"]["hostSupportPayloadFingerprint"] = "c" * 64
                manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
                with self.assertRaises(TOOL.TransactionError):
                    TOOL.snapshot(release, self.private_snapshot_dir(root))

    def test_arbitrary_ancestor_symlink_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            real = root / "real"
            real.mkdir()
            alias = root / "alias"
            alias.symlink_to(real, target_is_directory=True)
            with self.assertRaises(OSError):
                TOOL.create_stage(alias / self.dmg_name)

    def test_exact_macos_var_alias_reaches_the_same_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            physical = Path(temporary).resolve()
            physical_text = str(physical)
            if not physical_text.startswith("/private/var/"):
                self.skipTest("macOS /var alias is unavailable for this temporary directory")
            alias = Path("/var") / physical.relative_to("/private/var")
            physical_descriptor = TOOL.open_directory(physical)
            alias_descriptor = TOOL.open_directory(alias)
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

    def test_snapshot_detects_rename_swap_and_removes_partial_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            release = root / "release"
            self.populate(release, commercial=True)
            snapshot_dir = self.private_snapshot_dir(root)
            original_read = TOOL.os.read
            swapped = False

            def swapping_read(descriptor: int, size: int) -> bytes:
                nonlocal swapped
                if not swapped:
                    swapped = True
                    dmg = release / self.dmg_name
                    retained = release / (self.dmg_name + ".retained")
                    dmg.rename(retained)
                    dmg.write_bytes(b"replacement\n")
                return original_read(descriptor, size)

            with mock.patch.object(TOOL.os, "read", side_effect=swapping_read):
                with self.assertRaises(TOOL.TransactionError):
                    TOOL.snapshot(release, snapshot_dir)
            self.assertEqual(list(snapshot_dir.iterdir()), [])

    def test_publish_links_manifest_last_and_rolls_back_partial_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            destination = root / "dist"
            destination.mkdir()
            final_dmg = destination / self.dmg_name
            stage = TOOL.create_stage(final_dmg)
            self.populate(stage, commercial=True)
            real_link = TOOL.os.link
            linked_names: list[str] = []

            def failing_link(source: str, destination_name: str, **kwargs: object) -> None:
                linked_names.append(source)
                if len(linked_names) == 3:
                    raise OSError(errno.EIO, "fixture link failure")
                real_link(source, destination_name, **kwargs)

            with mock.patch.object(TOOL.os, "link", side_effect=failing_link):
                with self.assertRaises(OSError):
                    TOOL.publish(stage, final_dmg)
            self.assertFalse(any((destination / name).exists() for name in TOOL.expected_names(self.dmg_name, True)))
            self.assertNotIn(f"{self.dmg_name}.release.json", linked_names)

    def test_publish_rolls_back_after_real_manifest_link_precommit_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            destination = root / "dist"
            destination.mkdir()
            final_dmg = destination / self.dmg_name
            stage = TOOL.create_stage(final_dmg)
            self.populate(stage, commercial=True)

            def fail_after_manifest_link(
                event: str, _descriptor: int, _manifest_name: str
            ) -> None:
                if event == "manifest-linked":
                    raise OSError(errno.EIO, "fixture post-link failure")

            with mock.patch.object(
                TOOL, "_publication_precommit_seam", side_effect=fail_after_manifest_link
            ):
                with self.assertRaises(OSError):
                    TOOL.publish(stage, final_dmg)
            self.assertFalse(
                any(
                    (destination / name).exists()
                    for name in TOOL.expected_names(self.dmg_name, True)
                )
            )

    def test_publish_rejects_manifest_replacement_and_parent_swap_before_commit(self) -> None:
        for attack in ("manifest-replacement", "parent-swap"):
            with self.subTest(attack=attack), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                destination = root / "dist"
                destination.mkdir()
                displaced = root / "displaced"
                final_dmg = destination / self.dmg_name
                stage = TOOL.create_stage(final_dmg)
                self.populate(stage, commercial=True)
                manifest_name = f"{self.dmg_name}.release.json"

                def attack_before_commit(
                    event: str, _descriptor: int, _manifest_name: str
                ) -> None:
                    if attack == "manifest-replacement" and event == "manifest-linked":
                        manifest = destination / manifest_name
                        manifest.unlink()
                        manifest.write_text("replacement\n", encoding="utf-8")
                    elif attack == "parent-swap" and event == "before-destination-fsync":
                        destination.rename(displaced)
                        destination.mkdir()

                with mock.patch.object(
                    TOOL, "_publication_precommit_seam", side_effect=attack_before_commit
                ):
                    with self.assertRaises(TOOL.TransactionError):
                        TOOL.publish(stage, final_dmg)
                if attack == "manifest-replacement":
                    self.assertEqual(
                        (destination / manifest_name).read_text(encoding="utf-8"),
                        "replacement\n",
                    )
                    remaining_root = destination
                else:
                    self.assertEqual(list(destination.iterdir()), [])
                    remaining_root = displaced
                for name in TOOL.expected_names(self.dmg_name, True) - {manifest_name}:
                    self.assertFalse((remaining_root / name).exists(), name)

    def test_publish_commit_survives_postcommit_cleanup_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            destination = root / "dist"
            destination.mkdir()
            final_dmg = destination / self.dmg_name
            stage = TOOL.create_stage(final_dmg)
            self.populate(stage, commercial=True)
            real_link = TOOL.os.link
            linked_names: list[str] = []

            def recording_link(source: str, destination_name: str, **kwargs: object) -> None:
                linked_names.append(source)
                real_link(source, destination_name, **kwargs)

            with mock.patch.object(TOOL.os, "link", side_effect=recording_link), mock.patch.object(
                TOOL.os, "rmdir", side_effect=OSError(errno.EIO, "fixture cleanup failure")
            ):
                result = TOOL.publish(stage, final_dmg)
            self.assertTrue(result.startswith("COMMITTED: retained stage cleanup required:"), result)
            self.assertEqual(linked_names[-1], f"{self.dmg_name}.release.json")
            self.assertEqual(
                {path.name for path in destination.iterdir() if path.is_file()},
                TOOL.expected_names(self.dmg_name, True),
            )

    def test_publish_cli_treats_committed_cleanup_warning_as_success(self) -> None:
        standard_output = io.StringIO()
        standard_error = io.StringIO()
        with mock.patch.object(
            TOOL.sys,
            "argv",
            [
                str(TOOL_PATH),
                "publish",
                "--stage-dir",
                "/unused/stage",
                "--destination-dmg",
                f"/unused/{self.dmg_name}",
            ],
        ), mock.patch.object(
            TOOL,
            "publish",
            return_value="COMMITTED: retained stage cleanup required: fixture",
        ), redirect_stdout(standard_output), redirect_stderr(standard_error):
            result = TOOL.main()
        self.assertEqual(result, 0)
        self.assertEqual(standard_output.getvalue(), "COMMITTED\n")
        self.assertIn("warning: public release set committed", standard_error.getvalue())


if __name__ == "__main__":
    unittest.main()
