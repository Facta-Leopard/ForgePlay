#!/usr/bin/env python3
"""Executable regressions for descriptor-bound private quarantine cleanup."""

from __future__ import annotations

import importlib.util
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = ROOT / "Scripts/quarantine-owned-directory.py"
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("quarantine_owned_directory", HELPER_PATH)
assert SPEC is not None and SPEC.loader is not None
quarantine = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(quarantine)


class QuarantineCleanupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="forgeplay-quarantine-test.")
        self.parent = Path(self.temporary.name)
        self.parent_id = quarantine.identity(self.parent.stat())

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def quarantine_residue(self) -> list[Path]:
        return list(self.parent.glob(".forgeplay-delete-quarantine.*"))

    def test_bound_tree_is_moved_then_deleted_without_following_symlinks(self) -> None:
        sentinel = self.parent / "sentinel"
        sentinel.write_text("must remain\n", encoding="utf-8")
        tree = self.parent / "owned"
        nested = tree / "readonly/nested"
        nested.mkdir(parents=True)
        (nested / "object").write_text("payload\n", encoding="utf-8")
        (tree / "external-link").symlink_to(sentinel)
        (nested / "object").chmod(0o400)
        nested.chmod(0o500)
        nested.parent.chmod(0o500)
        tree.chmod(0o500)
        tree_id = quarantine.identity(tree.stat())

        quarantine.quarantine_and_delete(
            os.fspath(tree), tree_id, os.fspath(self.parent), self.parent_id, "fixture"
        )

        self.assertFalse(tree.exists())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "must remain\n")
        self.assertEqual(self.quarantine_residue(), [])

    def test_precommit_substitution_preserves_replacement_and_displaced_inode(self) -> None:
        tree = self.parent / "owned"
        tree.mkdir()
        (tree / "original").write_text("original\n", encoding="utf-8")
        tree_id = quarantine.identity(tree.stat())
        displaced = self.parent / "owned.displaced"

        def substitute() -> None:
            tree.rename(displaced)
            tree.mkdir()
            (tree / "replacement").write_text("replacement\n", encoding="utf-8")

        with self.assertRaisesRegex(quarantine.QuarantineError, "path rebound"):
            quarantine.quarantine_and_delete(
                os.fspath(tree),
                tree_id,
                os.fspath(self.parent),
                self.parent_id,
                "substitution fixture",
                before_commit=substitute,
            )

        self.assertEqual((displaced / "original").read_text(), "original\n")
        self.assertEqual((tree / "replacement").read_text(), "replacement\n")
        self.assertEqual(self.quarantine_residue(), [])

    def test_postcommit_failure_leaves_only_bound_inode_in_private_quarantine(self) -> None:
        tree = self.parent / "owned"
        tree.mkdir()
        (tree / "object").write_text("recoverable\n", encoding="utf-8")
        tree_id = quarantine.identity(tree.stat())
        original_delete = quarantine.delete_directory_contents

        def fail_delete(_descriptor: int, _device: int) -> None:
            raise quarantine.QuarantineError("injected post-commit cleanup failure")

        quarantine.delete_directory_contents = fail_delete
        try:
            with self.assertRaisesRegex(
                quarantine.QuarantineError, "post-commit cleanup failure"
            ):
                quarantine.quarantine_and_delete(
                    os.fspath(tree),
                    tree_id,
                    os.fspath(self.parent),
                    self.parent_id,
                    "recovery fixture",
                )
        finally:
            quarantine.delete_directory_contents = original_delete

        self.assertFalse(tree.exists())
        residues = self.quarantine_residue()
        self.assertEqual(len(residues), 1)
        owned = residues[0] / "owned"
        self.assertEqual(quarantine.identity(owned.stat()), tree_id)
        self.assertEqual((owned / "object").read_text(), "recoverable\n")
        shutil.rmtree(residues[0])

    def test_parent_path_substitution_is_rejected_without_deleting_either_tree(self) -> None:
        tree = self.parent / "owned"
        tree.mkdir()
        (tree / "original").write_text("original\n")
        tree_id = quarantine.identity(tree.stat())
        displaced_parent = self.parent.with_name(self.parent.name + ".displaced")

        def substitute_parent() -> None:
            self.parent.rename(displaced_parent)
            self.parent.mkdir(mode=0o700)
            replacement = self.parent / "owned"
            replacement.mkdir()
            (replacement / "replacement").write_text("replacement\n")

        try:
            with self.assertRaisesRegex(quarantine.QuarantineError, "parent rebound"):
                quarantine.quarantine_and_delete(
                    os.fspath(tree),
                    tree_id,
                    os.fspath(self.parent),
                    self.parent_id,
                    "parent substitution fixture",
                    before_commit=substitute_parent,
                )
            self.assertEqual(
                (self.parent / "owned/replacement").read_text(), "replacement\n"
            )
            self.assertEqual(
                (displaced_parent / "owned/original").read_text(), "original\n"
            )
        finally:
            if self.parent.exists():
                shutil.rmtree(self.parent)
            if displaced_parent.exists():
                displaced_parent.rename(self.parent)


if __name__ == "__main__":
    unittest.main(verbosity=2)
