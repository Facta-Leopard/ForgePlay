#!/usr/bin/env python3
"""Create and verify the public Runtime build transaction receipt."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path


HASH = re.compile(r"^[0-9a-f]{64}$")
COMMAND_GRAPH_PATHS = (
    "Scripts/build-public-forgeplay-runtime.sh",
    "Scripts/materialize-forgeplay-wine-11.12-source.sh",
    "Scripts/build-forgeplay-wine-runtime.sh",
    "Scripts/package-forgeplay-runtime.sh",
    "Scripts/verify-open-source-export.sh",
    "Scripts/verify-public-runtime-build-receipt.py",
)


class ReceiptError(RuntimeError):
    pass


def read_json(path: Path, label: str) -> tuple[dict, bytes]:
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise ReceiptError(f"{label} must be a single-link regular file")
        payload = b""
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            payload += chunk
    finally:
        os.close(descriptor)
    try:
        value = json.loads(payload)
    except json.JSONDecodeError as error:
        raise ReceiptError(f"{label} is invalid JSON") from error
    if not isinstance(value, dict):
        raise ReceiptError(f"{label} must be a JSON object")
    return value, payload


def sha256_file(path: Path, label: str) -> str:
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise ReceiptError(f"{label} must be a single-link regular file")
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            digest.update(chunk)
        if total != metadata.st_size:
            raise ReceiptError(f"{label} changed while hashing")
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def tree_sha256(root: Path) -> str:
    if not root.is_absolute() or not root.is_dir() or root.is_symlink():
        raise ReceiptError("fresh install root must be an absolute non-symlink directory")
    records: list[bytes] = []
    for current, directories, files in os.walk(root, topdown=True, followlinks=False):
        current_path = Path(current)
        directories.sort()
        files.sort()
        retained_directories = []
        for name in directories:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                records.append(
                    f"L\0{relative}\0{stat.S_IMODE(metadata.st_mode):04o}\0{os.readlink(path)}\n".encode()
                )
            elif stat.S_ISDIR(metadata.st_mode):
                records.append(
                    f"D\0{relative}\0{stat.S_IMODE(metadata.st_mode):04o}\n".encode()
                )
                retained_directories.append(name)
            else:
                raise ReceiptError(f"fresh install contains a special entry: {relative}")
        directories[:] = retained_directories
        for name in files:
            path = current_path / name
            relative = path.relative_to(root).as_posix()
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                records.append(
                    f"L\0{relative}\0{stat.S_IMODE(metadata.st_mode):04o}\0{os.readlink(path)}\n".encode()
                )
            elif stat.S_ISREG(metadata.st_mode):
                records.append(
                    f"F\0{relative}\0{stat.S_IMODE(metadata.st_mode):04o}\0{metadata.st_size}\0"
                    f"{sha256_file(path, relative)}\n".encode()
                )
            else:
                raise ReceiptError(f"fresh install contains a special entry: {relative}")
    digest = hashlib.sha256(b"forgeplay-fresh-install-tree-v1\n")
    for record in sorted(records):
        digest.update(record)
    return digest.hexdigest()


def command_graph(inventory: dict, export_root: Path) -> list[dict]:
    rows = {
        row.get("path"): row
        for row in inventory.get("entries", [])
        if isinstance(row, dict)
    }
    distribution_graph, _ = read_json(
        export_root / "Config/ForgePlayPublicDistributionSourceGraph.json",
        "public Distribution command graph",
    )
    required = distribution_graph.get("requiredReleaseCommitPaths")
    if (
        distribution_graph.get("schemaVersion") != 1
        or not isinstance(required, list)
        or any(not isinstance(value, str) for value in required)
    ):
        raise ReceiptError("public Distribution command graph is invalid")
    command_paths = tuple(value for value in required if value.startswith("Scripts/"))
    if (
        len(command_paths) != len(set(command_paths))
        or any(value not in command_paths for value in COMMAND_GRAPH_PATHS)
    ):
        raise ReceiptError("public Runtime command graph is incomplete")
    graph = []
    for relative in command_paths:
        row = rows.get(relative)
        origin = row.get("origin") if isinstance(row, dict) else None
        if (
            not isinstance(origin, dict)
            or origin.get("classification") != "release-commit-blob"
            or origin.get("sourcePath") != relative
            or origin.get("destinationPath") != relative
            or origin.get("gitMode") != row.get("mode")
            or origin.get("sha256") != row.get("sha256")
            or not isinstance(origin.get("gitObjectID"), str)
        ):
            raise ReceiptError(f"Runtime command graph is not an exact release blob: {relative}")
        graph.append(
            {
                "gitMode": origin["gitMode"],
                "gitObjectID": origin["gitObjectID"],
                "path": relative,
                "sha256": row["sha256"],
            }
        )
    return graph


def graph_sha256(graph: list[dict]) -> str:
    payload = json.dumps(graph, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(b"forgeplay-public-runtime-command-graph-v1\n" + payload).hexdigest()


def expected_prepackage(
    export_root: Path,
    source_tree_sha256: str,
    install_root: Path,
    compiler_manifest: Path,
    tool_manifest: Path,
) -> dict:
    if HASH.fullmatch(source_tree_sha256) is None:
        raise ReceiptError("patched source-tree SHA-256 is invalid")
    inventory, _ = read_json(export_root / "SOURCE-INVENTORY.json", "source inventory")
    release_commit = inventory.get("releaseCommit")
    inventory_sha256 = inventory.get("inventorySHA256")
    if not isinstance(release_commit, str) or re.fullmatch(r"[0-9a-f]{40,64}", release_commit) is None:
        raise ReceiptError("source inventory release commit is invalid")
    if not isinstance(inventory_sha256, str) or HASH.fullmatch(inventory_sha256) is None:
        raise ReceiptError("source inventory digest is invalid")
    graph = command_graph(inventory, export_root)
    compiler_sha = sha256_file(compiler_manifest, "compiler capsule manifest")
    tool_sha = sha256_file(tool_manifest, "build-tool capsule manifest")
    toolchain = {
        "buildToolCapsuleManifestSHA256": tool_sha,
        "compilerCapsuleManifestSHA256": compiler_sha,
    }
    toolchain_sha = hashlib.sha256(
        (
            "forgeplay-public-runtime-toolchain-v1\n"
            + json.dumps(toolchain, sort_keys=True, separators=(",", ":"))
        ).encode()
    ).hexdigest()
    return {
        "claimStatus": "unsigned build claim awaiting release attestation",
        "commandGraph": graph,
        "commandGraphSHA256": graph_sha256(graph),
        "freshInstallTreeSHA256": tree_sha256(install_root),
        "releaseCommit": release_commit,
        "schemaVersion": 1,
        "sourceInventorySHA256": inventory_sha256,
        "sourceTreeSHA256": source_tree_sha256,
        "toolchain": toolchain,
        "toolchainSHA256": toolchain_sha,
        "transactionMode": "fresh-source-build-install-package-v1",
    }


def write_exclusive_json(path: Path, value: dict, mode: int = 0o600) -> None:
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        mode,
    )
    try:
        payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise ReceiptError("receipt write made no progress")
            view = view[written:]
        os.fchmod(descriptor, mode)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def runtime_outputs(manifest_raw: bytes, manifest: dict) -> dict:
    fields = {
        "corePayloadFingerprint": manifest.get("corePayloadFingerprint"),
        "hostSupportPayloadFingerprint": manifest.get("hostSupportPayloadFingerprint"),
        "patchSetSHA256": manifest.get("patchSetSHA256"),
        "runnerBuildFingerprint": manifest.get("runnerBuildFingerprint"),
        "runtimeManifestSHA256": hashlib.sha256(manifest_raw).hexdigest(),
        "sourceTreeSHA256": manifest.get("sourceTreeSHA256"),
    }
    if any(not isinstance(value, str) or HASH.fullmatch(value) is None for value in fields.values()):
        raise ReceiptError("Runtime output receipt contains an invalid SHA-256")
    return fields


def validate_prepackage(value: dict) -> None:
    if set(value) != {
        "claimStatus",
        "commandGraph",
        "commandGraphSHA256",
        "freshInstallTreeSHA256",
        "releaseCommit",
        "schemaVersion",
        "sourceInventorySHA256",
        "sourceTreeSHA256",
        "toolchain",
        "toolchainSHA256",
        "transactionMode",
    } or value.get("schemaVersion") != 1 or value.get("claimStatus") != (
        "unsigned build claim awaiting release attestation"
    ):
        raise ReceiptError("pre-package Runtime build receipt schema is invalid")


def write_claim(receipt_path: Path, manifest_path: Path, output: Path) -> None:
    receipt, _ = read_json(receipt_path, "pre-package Runtime build receipt")
    validate_prepackage(receipt)
    manifest, manifest_raw = read_json(manifest_path, "Runtime manifest")
    outputs = runtime_outputs(manifest_raw, manifest)
    if outputs["sourceTreeSHA256"] != receipt["sourceTreeSHA256"]:
        raise ReceiptError("Runtime output source identity differs from its build receipt")
    final_receipt = {**receipt, "runtimeOutputs": outputs, "schemaVersion": 2}
    claim = {
        "claimStatus": "unsigned build claim awaiting release attestation",
        "commandGraph": {
            "builder": "Scripts/build-public-forgeplay-runtime.sh",
            "externalInputs": [
                "FORGEPLAY_GSTREAMER_SDK_ROOT",
                "FORGEPLAY_RENDERER_SOURCE",
                "FORGEPLAY_RUNTIME_POLICY_SOURCE",
                "trusted-git-repository-argument",
                "wine-source-archive-argument",
            ],
            "packageMode": "--public-source-package",
            "sourceInventoryAuthority": "SOURCE-INVENTORY.json",
        },
        "corePayloadFingerprint": outputs["corePayloadFingerprint"],
        "currentFinalPatchedSourceTreeSHA256": outputs["sourceTreeSHA256"],
        "hostSupportPayloadFingerprint": outputs["hostSupportPayloadFingerprint"],
        "patchSetSHA256": outputs["patchSetSHA256"],
        "releaseCommit": receipt["releaseCommit"],
        "runnerBuildFingerprint": outputs["runnerBuildFingerprint"],
        "runtimeBuildReceipt": final_receipt,
        "runtimeManifestSHA256": outputs["runtimeManifestSHA256"],
        "schemaVersion": 2,
        "sourceInventorySHA256": receipt["sourceInventorySHA256"],
    }
    write_exclusive_json(output, claim, 0o644)


def verify_runtime(runtime_root: Path, inventory_path: Path) -> None:
    claim, claim_raw = read_json(
        runtime_root / "PublicRuntimeBuildClaim.json", "unsigned public Runtime build claim"
    )
    manifest, manifest_raw = read_json(runtime_root / "RuntimeManifest.json", "Runtime manifest")
    inventory, _ = read_json(inventory_path, "source inventory")
    if set(claim) != {
        "claimStatus",
        "commandGraph",
        "corePayloadFingerprint",
        "currentFinalPatchedSourceTreeSHA256",
        "hostSupportPayloadFingerprint",
        "patchSetSHA256",
        "releaseCommit",
        "runnerBuildFingerprint",
        "runtimeBuildReceipt",
        "runtimeManifestSHA256",
        "schemaVersion",
        "sourceInventorySHA256",
    } or claim.get("schemaVersion") != 2 or claim.get("claimStatus") != (
        "unsigned build claim awaiting release attestation"
    ):
        raise ReceiptError("unsigned public Runtime build claim schema is invalid")
    receipt = claim["runtimeBuildReceipt"]
    if not isinstance(receipt, dict) or receipt.get("schemaVersion") != 2:
        raise ReceiptError("final Runtime build receipt schema is invalid")
    prepackage = {key: value for key, value in receipt.items() if key != "runtimeOutputs"}
    prepackage["schemaVersion"] = 1
    validate_prepackage(prepackage)
    if receipt.get("commandGraph") != command_graph(inventory, inventory_path.parent):
        raise ReceiptError("Runtime receipt command graph differs from source inventory")
    if receipt.get("commandGraphSHA256") != graph_sha256(receipt["commandGraph"]):
        raise ReceiptError("Runtime receipt command graph digest is invalid")
    toolchain = receipt.get("toolchain")
    if not isinstance(toolchain, dict) or set(toolchain) != {
        "buildToolCapsuleManifestSHA256", "compilerCapsuleManifestSHA256"
    } or any(
        not isinstance(value, str) or HASH.fullmatch(value) is None
        for value in toolchain.values()
    ):
        raise ReceiptError("Runtime receipt toolchain identity is invalid")
    expected_toolchain_sha = hashlib.sha256(
        (
            "forgeplay-public-runtime-toolchain-v1\n"
            + json.dumps(toolchain, sort_keys=True, separators=(",", ":"))
        ).encode()
    ).hexdigest()
    if receipt.get("toolchainSHA256") != expected_toolchain_sha:
        raise ReceiptError("Runtime receipt toolchain digest is invalid")
    outputs = runtime_outputs(manifest_raw, manifest)
    if receipt.get("runtimeOutputs") != outputs:
        raise ReceiptError("Runtime receipt output hashes differ from Runtime manifest")
    if (
        claim["releaseCommit"] != inventory.get("releaseCommit")
        or claim["sourceInventorySHA256"] != inventory.get("inventorySHA256")
        or receipt.get("releaseCommit") != claim["releaseCommit"]
        or receipt.get("sourceInventorySHA256") != claim["sourceInventorySHA256"]
        or receipt.get("sourceTreeSHA256") != outputs["sourceTreeSHA256"]
    ):
        raise ReceiptError("Runtime receipt source authority is inconsistent")
    for authority_key, output_key in (
        ("corePayloadFingerprint", "corePayloadFingerprint"),
        ("hostSupportPayloadFingerprint", "hostSupportPayloadFingerprint"),
        ("patchSetSHA256", "patchSetSHA256"),
        ("runnerBuildFingerprint", "runnerBuildFingerprint"),
        ("runtimeManifestSHA256", "runtimeManifestSHA256"),
        ("currentFinalPatchedSourceTreeSHA256", "sourceTreeSHA256"),
    ):
        if claim[authority_key] != outputs[output_key]:
            raise ReceiptError(f"Runtime build claim {authority_key} is inconsistent")
    canonical = (json.dumps(claim, indent=2, sort_keys=True) + "\n").encode()
    if claim_raw != canonical:
        raise ReceiptError("public Runtime build claim is not canonical JSON")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("create-prepackage", "verify-prepackage"):
        command = subparsers.add_parser(name)
        command.add_argument("--export-root", required=True, type=Path)
        command.add_argument("--source-tree-sha256", required=True)
        command.add_argument("--install-root", required=True, type=Path)
        command.add_argument("--compiler-capsule-manifest", required=True, type=Path)
        command.add_argument("--build-tool-capsule-manifest", required=True, type=Path)
        command.add_argument("--receipt", required=True, type=Path)
    claim = subparsers.add_parser("write-claim")
    claim.add_argument("--receipt", required=True, type=Path)
    claim.add_argument("--manifest", required=True, type=Path)
    claim.add_argument("--output", required=True, type=Path)
    runtime = subparsers.add_parser("verify-runtime")
    runtime.add_argument("--runtime-root", required=True, type=Path)
    runtime.add_argument("--source-inventory", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.command in {"create-prepackage", "verify-prepackage"}:
            expected = expected_prepackage(
                arguments.export_root.resolve(strict=True),
                arguments.source_tree_sha256,
                arguments.install_root.resolve(strict=True),
                arguments.compiler_capsule_manifest.resolve(strict=True),
                arguments.build_tool_capsule_manifest.resolve(strict=True),
            )
            if arguments.command == "create-prepackage":
                write_exclusive_json(arguments.receipt, expected)
            else:
                actual, raw = read_json(arguments.receipt, "pre-package Runtime build receipt")
                if actual != expected:
                    raise ReceiptError("pre-package Runtime build receipt does not match fresh inputs")
                if raw != (json.dumps(actual, indent=2, sort_keys=True) + "\n").encode():
                    raise ReceiptError("pre-package Runtime build receipt is not canonical JSON")
        elif arguments.command == "write-claim":
            write_claim(arguments.receipt, arguments.manifest, arguments.output)
        else:
            verify_runtime(arguments.runtime_root.resolve(strict=True), arguments.source_inventory)
    except (OSError, ReceiptError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
