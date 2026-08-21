#!/usr/bin/env python3
"""Executable regressions for exact Git export and atomic publication."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = ROOT / "Scripts/open-source-export-transaction.py"
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("open_source_export_transaction", HELPER_PATH)
assert SPEC is not None and SPEC.loader is not None
transaction = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(transaction)


def run_git(repository: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", os.fspath(repository), *arguments],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return result.stdout.strip()


def write_marker(directory: Path, payload: bytes) -> str:
    directory.mkdir(mode=0o700)
    marker = directory / ".forgeplay-source-export"
    marker.write_bytes(payload)
    marker.chmod(0o644)
    return hashlib.sha256(payload).hexdigest()


class ExactGitMaterializationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="forgeplay-git-export-test.")
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repository"
        self.repository.mkdir()
        run_git(self.repository, "init", "-q")
        run_git(self.repository, "config", "user.email", "fixture@forgeplay.invalid")
        run_git(self.repository, "config", "user.name", "ForgePlay Fixture")
        (self.repository / ".gitignore").write_text("ignored.txt\n", encoding="utf-8")
        (self.repository / "tracked.txt").write_text("committed bytes\n", encoding="utf-8")
        tool = self.repository / "tree/tool.sh"
        tool.parent.mkdir()
        tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        tool.chmod(0o755)
        template = self.repository / "templates/readme"
        template.parent.mkdir()
        template.write_text("public template\n", encoding="utf-8")
        run_git(self.repository, "add", ".")
        run_git(self.repository, "commit", "-qm", "fixture")
        self.commit = run_git(self.repository, "rev-parse", "HEAD")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_materialization_uses_commit_blobs_modes_and_classifications(self) -> None:
        (self.repository / "tracked.txt").write_text("dirty worktree bytes\n", encoding="utf-8")
        (self.repository / "tree/tool.sh").chmod(0o644)
        (self.repository / "ignored.txt").write_text("ignored secret\n", encoding="utf-8")
        (self.repository / "untracked.txt").write_text("untracked secret\n", encoding="utf-8")

        export_root = self.root / "export"
        export_root.mkdir(mode=0o700)
        origins = export_root / ".origins.jsonl"
        transaction.materialize_entry(
            self.repository,
            self.commit,
            export_root,
            "tracked.txt",
            "tracked.txt",
            "release-commit-blob",
            origins,
            recursive=False,
        )
        transaction.materialize_entry(
            self.repository,
            self.commit,
            export_root,
            "tree",
            "tree",
            "release-commit-blob",
            origins,
            recursive=True,
        )
        transaction.materialize_entry(
            self.repository,
            self.commit,
            export_root,
            "templates/readme",
            "README.md",
            "injected-template-blob",
            origins,
            recursive=False,
        )

        self.assertEqual((export_root / "tracked.txt").read_bytes(), b"committed bytes\n")
        self.assertEqual(stat.S_IMODE((export_root / "tree/tool.sh").stat().st_mode), 0o755)
        self.assertFalse((export_root / "ignored.txt").exists())
        self.assertFalse((export_root / "untracked.txt").exists())
        records = [json.loads(line) for line in origins.read_text().splitlines()]
        by_destination = {record["destinationPath"]: record for record in records}
        self.assertEqual(
            by_destination["tracked.txt"]["gitObjectID"],
            run_git(self.repository, "rev-parse", f"{self.commit}:tracked.txt"),
        )
        self.assertEqual(by_destination["tree/tool.sh"]["gitMode"], "100755")
        self.assertEqual(
            by_destination["README.md"],
            {
                "classification": "injected-template-blob",
                "destinationPath": "README.md",
                "gitMode": "100644",
                "gitObjectID": run_git(
                    self.repository, "rev-parse", f"{self.commit}:templates/readme"
                ),
                "sha256": hashlib.sha256(b"public template\n").hexdigest(),
                "sourcePath": "templates/readme",
            },
        )


class AtomicPublicationTests(unittest.TestCase):
    marker = b"ForgePlay managed public export\n"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="forgeplay-publish-test.")
        self.parent = Path(self.temporary.name)
        self.marker_sha = hashlib.sha256(self.marker).hexdigest()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_create_and_swap_commit_exact_bound_inodes(self) -> None:
        stage = self.parent / ".stage-one"
        write_marker(stage, self.marker)
        stage_id = transaction.file_identity(stage.stat())
        destination = self.parent / "OpenSource"
        state, old = transaction.atomic_publish(
            os.fspath(stage),
            os.fspath(destination),
            stage_id,
            transaction.file_identity(self.parent.stat()),
            self.marker_sha,
        )
        self.assertEqual((state, old), ("created", None))
        self.assertEqual(transaction.file_identity(destination.stat()), stage_id)

        replacement = self.parent / ".stage-two"
        write_marker(replacement, self.marker)
        (replacement / "new").write_text("new\n", encoding="utf-8")
        replacement_id = transaction.file_identity(replacement.stat())
        previous_id = transaction.file_identity(destination.stat())
        state, old = transaction.atomic_publish(
            os.fspath(replacement),
            os.fspath(destination),
            replacement_id,
            transaction.file_identity(self.parent.stat()),
            self.marker_sha,
        )
        self.assertEqual((state, old), ("replaced", previous_id))
        self.assertEqual(transaction.file_identity(destination.stat()), replacement_id)
        self.assertEqual(transaction.file_identity(replacement.stat()), previous_id)
        self.assertEqual(stat.S_IMODE(replacement.stat().st_mode), 0o700)

    def test_stage_and_destination_rebinding_are_rejected_without_commit(self) -> None:
        destination = self.parent / "OpenSource"
        write_marker(destination, self.marker)
        original_destination_id = transaction.file_identity(destination.stat())
        stage = self.parent / ".stage"
        write_marker(stage, self.marker)
        original_stage_id = transaction.file_identity(stage.stat())
        displaced_stage = self.parent / ".stage.displaced"

        def replace_stage() -> None:
            stage.rename(displaced_stage)
            write_marker(stage, self.marker)

        with self.assertRaisesRegex(transaction.ExportTransactionError, "staging rebound"):
            transaction.atomic_publish(
                os.fspath(stage),
                os.fspath(destination),
                original_stage_id,
                transaction.file_identity(self.parent.stat()),
                self.marker_sha,
                before_commit=replace_stage,
            )
        self.assertEqual(transaction.file_identity(destination.stat()), original_destination_id)
        self.assertEqual(transaction.file_identity(displaced_stage.stat()), original_stage_id)
        self.assertNotEqual(transaction.file_identity(stage.stat()), original_stage_id)

        shutil.rmtree(stage)
        displaced_stage.rename(stage)
        displaced_destination = self.parent / "OpenSource.displaced"

        def replace_destination() -> None:
            destination.rename(displaced_destination)
            write_marker(destination, self.marker)

        with self.assertRaisesRegex(transaction.ExportTransactionError, "output rebound"):
            transaction.atomic_publish(
                os.fspath(stage),
                os.fspath(destination),
                original_stage_id,
                transaction.file_identity(self.parent.stat()),
                self.marker_sha,
                before_commit=replace_destination,
            )
        self.assertEqual(transaction.file_identity(displaced_destination.stat()), original_destination_id)
        self.assertEqual(transaction.file_identity(stage.stat()), original_stage_id)

    def test_nonadjacent_and_cross_filesystem_stage_is_rejected(self) -> None:
        stage_parent = Path(tempfile.mkdtemp(prefix="forgeplay-stage-volume.", dir=ROOT.parent))
        try:
            stage = stage_parent / ".stage"
            write_marker(stage, self.marker)
            destination = self.parent / "OpenSource"
            with self.assertRaisesRegex(
                transaction.ExportTransactionError, "adjacent sibling paths"
            ):
                transaction.atomic_publish(
                    os.fspath(stage),
                    os.fspath(destination),
                    transaction.file_identity(stage.stat()),
                    transaction.file_identity(self.parent.stat()),
                    self.marker_sha,
                )
            # On standard ForgePlay developer machines these parents are on
            # the external workspace volume and the system temporary volume,
            # respectively. The behavioral rejection is mandatory either way.
            if stage_parent.stat().st_dev != self.parent.stat().st_dev:
                self.assertNotEqual(stage_parent.stat().st_dev, self.parent.stat().st_dev)
        finally:
            shutil.rmtree(stage_parent)

    def test_destination_parent_path_rebinding_is_rejected(self) -> None:
        stage = self.parent / ".stage"
        write_marker(stage, self.marker)
        destination = self.parent / "OpenSource"
        write_marker(destination, self.marker)
        parent_id = transaction.file_identity(self.parent.stat())
        stage_id = transaction.file_identity(stage.stat())
        displaced_parent = self.parent.with_name(self.parent.name + ".displaced")

        def replace_parent() -> None:
            self.parent.rename(displaced_parent)
            self.parent.mkdir(mode=0o700)
            (self.parent / "replacement-token").write_text("replacement\n")

        try:
            with self.assertRaisesRegex(
                transaction.ExportTransactionError, "parent or staging rebound"
            ):
                transaction.atomic_publish(
                    os.fspath(stage),
                    os.fspath(destination),
                    stage_id,
                    parent_id,
                    self.marker_sha,
                    before_commit=replace_parent,
                )
            self.assertEqual(
                (self.parent / "replacement-token").read_text(), "replacement\n"
            )
            self.assertEqual(
                transaction.file_identity((displaced_parent / ".stage").stat()), stage_id
            )
        finally:
            if self.parent.exists():
                shutil.rmtree(self.parent)
            if displaced_parent.exists():
                displaced_parent.rename(self.parent)


if __name__ == "__main__":
    unittest.main(verbosity=2)
