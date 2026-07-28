#!/usr/bin/env python3

import importlib.util
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit


class RendererLockError(RuntimeError):
    pass


SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
RENDERER_SOURCE_KINDS = {
    "d3dmetal": "apple-official-redistributable",
    "d9vk": "open-source-project-binary",
    "dxmt": "open-source-project-binary",
    "dxvk": "open-source-project-binary",
}
PRESERVED_SIGNATURE_PATHS = {
    "d3dmetal": {
        "external/D3DMetal.framework/Versions/A/_CodeSignature/CodeResources"
    },
    "d9vk": set(),
    "dxmt": set(),
    "dxvk": set(),
}


def fail(message: str) -> None:
    raise RendererLockError(message)


def load_sbom_helpers():
    helper_path = Path(__file__).with_name("runtime-sbom.py")
    sys.dont_write_bytecode = True
    specification = importlib.util.spec_from_file_location("forgeplay_runtime_sbom", helper_path)
    if specification is None or specification.loader is None:
        fail(f"runtime SBOM helper could not be loaded: {helper_path}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def require_directory(path: Path, label: str) -> Path:
    try:
        metadata = path.stat(follow_symlinks=False)
    except OSError as error:
        fail(f"{label} could not be inspected: {path}: {error}")
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} must be a non-symlink directory: {path}")
    return path


def require_regular_file(path: Path, label: str) -> Path:
    try:
        metadata = path.stat(follow_symlinks=False)
    except OSError as error:
        fail(f"{label} could not be inspected: {path}: {error}")
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} must be a non-symlink regular file: {path}")
    if metadata.st_nlink != 1:
        fail(f"{label} must not be hardlinked: {path}")
    return path


def require_safe_relative_path(value: object, label: str) -> None:
    if not isinstance(value, str) or not value or "\\" in value:
        fail(f"{label} must be a non-empty POSIX relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"{label} is unsafe: {value}")


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_lock(path: Path) -> dict[str, dict[str, object]]:
    require_regular_file(path, "renderer payload lock")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"renderer payload lock is unreadable: {error}")
    if not isinstance(payload, dict) or set(payload) != {
        "components",
        "hashAlgorithm",
        "provenancePolicy",
        "schemaVersion",
    }:
        fail("renderer payload lock schema is invalid")
    if (
        payload["schemaVersion"] != 2
        or payload["hashAlgorithm"] != "forgeplay-renderer-payload-tree-v3"
        or payload["provenancePolicy"] != "official-or-upstream-artifact-only-v1"
    ):
        fail("renderer payload lock version or hash algorithm is unsupported")
    components = payload["components"]
    if not isinstance(components, list) or not components:
        fail("renderer payload lock contains no components")
    mapped: dict[str, dict[str, object]] = {}
    required = {
        "fileCount",
        "licenseExpression",
        "licensePaths",
        "name",
        "preservedSignatureFiles",
        "sourceKind",
        "sourceReference",
        "treeSHA256",
        "version",
    }
    for component in components:
        if not isinstance(component, dict) or set(component) != required:
            fail("renderer payload component schema is invalid")
        name = component["name"]
        if name not in RENDERER_SOURCE_KINDS or name in mapped:
            fail(f"renderer payload component name is invalid or duplicated: {name}")
        if not isinstance(component["fileCount"], int) or component["fileCount"] <= 0:
            fail(f"renderer payload component fileCount is invalid: {name}")
        if not isinstance(component["treeSHA256"], str) or not SHA256_PATTERN.fullmatch(
            component["treeSHA256"]
        ):
            fail(f"renderer payload component treeSHA256 is invalid: {name}")
        for key in ("licenseExpression", "sourceKind", "sourceReference", "version"):
            if not isinstance(component[key], str) or not component[key]:
                fail(f"renderer payload component {key} is invalid: {name}")
        if not isinstance(component["licensePaths"], list) or not component["licensePaths"]:
            fail(f"renderer payload component licensePaths is invalid: {name}")
        for license_path in component["licensePaths"]:
            require_safe_relative_path(license_path, f"renderer payload license path for {name}")
        signatures = component["preservedSignatureFiles"]
        if not isinstance(signatures, list):
            fail(f"renderer payload preservedSignatureFiles is invalid: {name}")
        signature_paths: set[str] = set()
        for signature in signatures:
            if not isinstance(signature, dict) or set(signature) != {"path", "sha256"}:
                fail(f"renderer payload preserved signature schema is invalid: {name}")
            signature_path = signature.get("path")
            signature_sha256 = signature.get("sha256")
            require_safe_relative_path(
                signature_path,
                f"renderer payload preserved signature path for {name}",
            )
            if (
                not isinstance(signature_sha256, str)
                or not SHA256_PATTERN.fullmatch(signature_sha256)
            ):
                fail(f"renderer payload preserved signature SHA-256 is invalid: {name}")
            if signature_path in signature_paths:
                fail(f"renderer payload preserved signature path is duplicated: {name}")
            signature_paths.add(signature_path)
        if signature_paths != PRESERVED_SIGNATURE_PATHS[name]:
            fail(
                f"renderer payload preserved signature set is invalid for {name}: "
                f"{sorted(signature_paths)}"
            )
        if component["sourceKind"] != RENDERER_SOURCE_KINDS[name]:
            fail(f"renderer payload sourceKind violates the upstream-only policy: {name}")
        source_reference = urlsplit(component["sourceReference"])
        if (
            source_reference.scheme != "https"
            or not source_reference.hostname
            or source_reference.username
            or source_reference.password
            or source_reference.hostname in {"localhost", "127.0.0.1", "::1"}
        ):
            fail(f"renderer payload sourceReference must be a public HTTPS URL: {name}")
        mapped[name] = component
    if set(mapped) != set(RENDERER_SOURCE_KINDS):
        fail("renderer payload lock must declare the complete renderer component set")
    return mapped


def verify_preserved_signatures(path: Path, contract: dict[str, object]) -> None:
    expected = {
        signature["path"]: signature["sha256"]
        for signature in contract["preservedSignatureFiles"]
    }
    expected_directories = {
        str(PurePosixPath(relative).parent) for relative in expected
    }
    observed: dict[str, Path] = {}
    observed_directories: set[str] = set()
    for signature_directory in path.rglob("_CodeSignature"):
        require_directory(signature_directory, "renderer preserved signature directory")
        relative_directory = signature_directory.relative_to(path).as_posix()
        observed_directories.add(relative_directory)
        for entry in signature_directory.iterdir():
            signature_file = require_regular_file(
                entry,
                "renderer preserved signature file",
            )
            relative = signature_file.relative_to(path).as_posix()
            if relative in observed:
                fail(f"renderer preserved signature path is duplicated: {relative}")
            observed[relative] = signature_file
    if observed_directories != expected_directories:
        fail(
            f"renderer preserved signature directories do not match the lock for "
            f"{contract['name']}: expected={sorted(expected_directories)} "
            f"found={sorted(observed_directories)}"
        )
    if set(observed) != set(expected):
        fail(
            f"renderer preserved signature files do not match the lock for "
            f"{contract['name']}: missing={sorted(set(expected) - set(observed))} "
            f"undeclared={sorted(set(observed) - set(expected))}"
        )
    for relative, expected_sha256 in expected.items():
        actual_sha256 = digest_file(observed[relative])
        if actual_sha256 != expected_sha256:
            fail(
                f"renderer preserved signature digest mismatch for {contract['name']}: "
                f"{relative}"
            )


def verify_component(path: Path, contract: dict[str, object], sbom_helpers) -> None:
    require_directory(path, f"renderer component {contract['name']}")
    try:
        entries = sbom_helpers.renderer_tree_entries(path)
    except sbom_helpers.SBOMError as error:
        fail(str(error))
    if len(entries) != contract["fileCount"]:
        fail(
            f"renderer component file count mismatch for {contract['name']}: "
            f"expected {contract['fileCount']}, found {len(entries)}"
        )
    actual = sbom_helpers.renderer_tree_digest(entries)
    if actual != contract["treeSHA256"]:
        fail(
            f"renderer component tree digest mismatch for {contract['name']}: "
            f"expected {contract['treeSHA256']}, found {actual}"
        )
    verify_preserved_signatures(path, contract)


def materialize_preserved_signatures(
    source: Path,
    target: Path,
    contract: dict[str, object],
) -> None:
    for signature in contract["preservedSignatureFiles"]:
        relative = Path(signature["path"])
        source_file = require_regular_file(
            source / relative,
            "renderer preserved signature source",
        )
        target_file = target / relative
        target_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source_file, target_file)


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: materialize-locked-renderer.py "
            "<renderer payload lock> <renderer source root> <staged renderer root>",
            file=sys.stderr,
        )
        return 2
    try:
        lock = load_lock(Path(sys.argv[1]))
        source = require_directory(Path(sys.argv[2]), "renderer source root").resolve(strict=True)
        requested_target = Path(sys.argv[3])
        target_parent = require_directory(
            requested_target.parent, "staged renderer parent"
        ).resolve(strict=True)
        if requested_target.name in {"", ".", ".."}:
            fail(f"staged renderer target name is unsafe: {requested_target}")
        target = target_parent / requested_target.name
        if target == source or target.is_relative_to(source) or source.is_relative_to(target):
            fail("renderer source and staged target must not contain one another")

        source_entries = list(source.iterdir())
        source_names = {
            path.name for path in source_entries if path.is_dir() and not path.is_symlink()
        }
        if source_names != set(lock):
            fail(
                "renderer source component set does not match the lock: "
                f"missing={sorted(set(lock) - source_names)} "
                f"undeclared={sorted(source_names - set(lock))}"
            )
        unexpected_source_entries = sorted(
            path.name for path in source_entries if path.name not in source_names
        )
        if unexpected_source_entries:
            fail(
                "renderer source root contains undeclared files or symlinks: "
                f"{unexpected_source_entries}"
            )
        sbom_helpers = load_sbom_helpers()
        for name, contract in lock.items():
            verify_component(source / name, contract, sbom_helpers)

        if target.exists() or target.is_symlink():
            require_directory(target, "existing staged renderer target")

        temporary = Path(tempfile.mkdtemp(prefix=".renderer-materialize-", dir=target_parent))
        try:
            for name, contract in lock.items():
                shutil.copytree(
                    source / name,
                    temporary / name,
                    symlinks=True,
                    ignore=shutil.ignore_patterns("_CodeSignature"),
                )
                materialize_preserved_signatures(
                    source / name,
                    temporary / name,
                    contract,
                )
                verify_component(temporary / name, contract, sbom_helpers)
            if target.exists():
                shutil.rmtree(target)
            os.replace(temporary, target)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)
        print(f"Materialized {len(lock)} locked renderer components")
        return 0
    except RendererLockError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
