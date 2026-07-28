#!/usr/bin/env python3

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit


class SBOMError(RuntimeError):
    pass


HASH_ALGORITHM = "sha256-after-canonical-adhoc-sign-and-remove-signature-v1"
EXCLUDED_DIRECTORY_NAMES = {"_CodeSignature"}
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


RENDERER_COMPONENTS = {"d3dmetal", "d9vk", "dxmt", "dxvk"}
RENDERER_SOURCE_KINDS = {
    "d3dmetal": "apple-official-redistributable",
    "d9vk": "open-source-project-binary",
    "dxmt": "open-source-project-binary",
    "dxvk": "open-source-project-binary",
}
PRESERVED_RENDERER_SIGNATURE_PATHS = {
    "d3dmetal": {
        "external/D3DMetal.framework/Versions/A/_CodeSignature/CodeResources"
    },
    "d9vk": set(),
    "dxmt": set(),
    "dxvk": set(),
}
D3DMETAL_COMPONENT_FRAMEWORK = PurePosixPath(
    "external/D3DMetal.framework"
)
D3DMETAL_COMPONENT_ALIAS_EXECUTABLE = (
    D3DMETAL_COMPONENT_FRAMEWORK / "D3DMetal"
)
D3DMETAL_COMPONENT_ALIAS_DIRECTORIES = {
    D3DMETAL_COMPONENT_FRAMEWORK / "Resources",
    D3DMETAL_COMPONENT_FRAMEWORK / "Versions/Current",
}
D3DMETAL_RUNTIME_COMPONENT = PurePosixPath(
    "Frameworks/renderer/d3dmetal"
)
D3DMETAL_RUNTIME_ALIAS_EXECUTABLE = (
    D3DMETAL_RUNTIME_COMPONENT / D3DMETAL_COMPONENT_ALIAS_EXECUTABLE
)
D3DMETAL_RUNTIME_ALIAS_DIRECTORIES = {
    D3DMETAL_RUNTIME_COMPONENT / relative
    for relative in D3DMETAL_COMPONENT_ALIAS_DIRECTORIES
}


def fail(message: str) -> None:
    raise SBOMError(message)


def digest_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def digest_file(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def require_regular_file(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"{label} could not be inspected: {path}: {error}")
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} must be a non-symlink regular file: {path}")
    if metadata.st_nlink != 1:
        fail(f"{label} must not be hardlinked: {path}")
    return path


def require_directory(path: Path, label: str) -> Path:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"{label} could not be inspected: {path}: {error}")
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} must be a non-symlink directory: {path}")
    return path


def safe_relative_path(value: object, label: str) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\\" in value:
        fail(f"{label} must be a non-empty POSIX relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"{label} is unsafe: {value}")
    return path


def is_macho(path: Path) -> bool:
    result = subprocess.run(["file", "-b", str(path)], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        fail(f"file inspection failed for host support payload: {path}")
    return result.stdout.startswith("Mach-O")


def content_digest(path: Path) -> tuple[str, str]:
    if not is_macho(path):
        return digest_file(path), "sha256"
    with tempfile.TemporaryDirectory(prefix="forgeplay-runtime-sbom-") as temporary_directory:
        unsigned = Path(temporary_directory) / "payload"
        shutil.copyfile(path, unsigned)
        os.chmod(unsigned, 0o700)
        sign_result = subprocess.run(
            [
                "codesign",
                "--force",
                "--sign",
                "-",
                "--timestamp=none",
                str(unsigned),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if sign_result.returncode != 0:
            detail = (sign_result.stderr or sign_result.stdout).strip()
            fail(f"Mach-O canonical ad-hoc signing failed for {path}: {detail}")
        result = subprocess.run(
            ["codesign", "--remove-signature", str(unsigned)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).strip()
            if "not signed at all" not in detail:
                fail(f"Mach-O signature normalization failed for {path}: {detail}")
        return digest_file(unsigned), HASH_ALGORITHM


def load_json(path: Path, label: str) -> object:
    require_regular_file(path, label)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"{label} is unreadable: {error}")


def dependency_provenance(lock_path: Path) -> dict[str, dict[str, object]]:
    payload = load_json(lock_path, "runtime dependency lock")
    if not isinstance(payload, dict) or set(payload) != {
        "architecture",
        "artifacts",
        "licenses",
        "provider",
        "schemaVersion",
    }:
        fail("runtime dependency lock schema is invalid")
    if payload.get("schemaVersion") != 1:
        fail("runtime dependency lock schema is unsupported")
    if (
        payload.get("architecture") != "x86_64"
        or payload.get("provider") != "homebrew-core-prebuilt-package"
    ):
        fail("runtime dependency lock provider or architecture is invalid")
    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        fail("runtime dependency lock has no artifacts")
    mapped: dict[str, dict[str, object]] = {}
    formula_provenance: dict[tuple[str, str], dict[str, object]] = {}
    referenced_licenses: dict[str, tuple[str, str]] = {}
    required_fields = {
        "formula",
        "formulaVersion",
        "licenseExpression",
        "licensePaths",
        "sourcePath",
        "sourceReference",
        "sourceSHA256",
        "targetPath",
    }
    for artifact in artifacts:
        if not isinstance(artifact, dict) or set(artifact) != required_fields:
            fail("runtime dependency artifact schema is invalid")
        target_path = artifact.get("targetPath")
        required_strings = (
            "formula",
            "formulaVersion",
            "licenseExpression",
            "sourceReference",
            "sourceSHA256",
            "targetPath",
        )
        if any(not isinstance(artifact.get(key), str) or not artifact[key] for key in required_strings):
            fail("runtime dependency artifact contains an invalid field")
        if not SHA256_PATTERN.fullmatch(artifact["sourceSHA256"]):
            fail(f"runtime dependency artifact has an invalid source SHA-256: {target_path}")
        if not artifact["sourceReference"].startswith("https://formulae.brew.sh/formula/"):
            fail(f"runtime dependency artifact has an invalid source reference: {target_path}")
        safe_relative_path(artifact["sourcePath"], "runtime dependency source path")
        target = safe_relative_path(target_path, "runtime dependency target path")
        if not (
            target.as_posix().startswith("wine/lib/") and target.name.endswith(".dylib")
        ) and target.as_posix() != "wine/etc/vulkan/icd.d/MoltenVK_icd.json":
            fail(f"runtime dependency target is outside the Wine host closure: {target_path}")
        license_paths = artifact.get("licensePaths")
        if not isinstance(license_paths, list) or not license_paths or not all(
            isinstance(path, str) and path for path in license_paths
        ):
            fail(f"runtime dependency artifact has invalid license paths: {target_path}")
        for license_path in license_paths:
            safe_relative_path(license_path, "runtime dependency license path")
            license_key = str(license_path)
            formula_key = (artifact["formula"], artifact["formulaVersion"])
            existing_formula = referenced_licenses.get(license_key)
            if existing_formula is not None and existing_formula != formula_key:
                fail(f"runtime dependency license is attributed to multiple formulas: {license_key}")
            referenced_licenses[license_key] = formula_key
        if target_path in mapped:
            fail(f"runtime dependency lock contains duplicate target: {target_path}")
        base_provenance = {
            "component": artifact["formula"],
            "version": artifact["formulaVersion"],
            "sourceKind": "homebrew-core-prebuilt-package",
            "sourceReference": artifact["sourceReference"],
            "licenseExpression": artifact["licenseExpression"],
            "licensePaths": license_paths,
        }
        formula_key = (artifact["formula"], artifact["formulaVersion"])
        existing_provenance = formula_provenance.get(formula_key)
        if existing_provenance is not None and existing_provenance != base_provenance:
            fail(f"runtime dependency formula provenance is inconsistent: {formula_key[0]}")
        formula_provenance[formula_key] = base_provenance
        mapped[target_path] = {
            **base_provenance,
            "sourceSHA256": artifact["sourceSHA256"],
        }

    licenses = payload.get("licenses")
    if not isinstance(licenses, list) or not licenses:
        fail("runtime dependency lock has no license files")
    required_license_fields = {
        "formula",
        "formulaVersion",
        "sourcePath",
        "sourceSHA256",
        "targetPath",
    }
    declared_licenses: set[str] = set()
    for license_record in licenses:
        if not isinstance(license_record, dict) or set(license_record) != required_license_fields:
            fail("runtime dependency license schema is invalid")
        for key in ("formula", "formulaVersion", "sourcePath", "sourceSHA256", "targetPath"):
            if not isinstance(license_record[key], str) or not license_record[key]:
                fail(f"runtime dependency license {key} is invalid")
        if not SHA256_PATTERN.fullmatch(license_record["sourceSHA256"]):
            fail("runtime dependency license source SHA-256 is invalid")
        safe_relative_path(license_record["sourcePath"], "runtime dependency license source path")
        target = safe_relative_path(
            license_record["targetPath"], "runtime dependency license target path"
        )
        target_key = target.as_posix()
        if not target_key.startswith("Legal/") or len(target.parts) < 3:
            fail(f"runtime dependency license target is outside Legal: {target_key}")
        if target_key in declared_licenses or target_key in mapped:
            fail(f"runtime dependency lock contains duplicate license target: {target_key}")
        declared_licenses.add(target_key)
        formula_key = (license_record["formula"], license_record["formulaVersion"])
        if referenced_licenses.get(target_key) != formula_key:
            fail(f"runtime dependency license target does not match artifact provenance: {target_key}")
        provenance = formula_provenance.get(formula_key)
        if provenance is None:
            fail(f"runtime dependency license has no locked artifact formula: {target_key}")
        mapped[target_key] = {
            **provenance,
            "sourceSHA256": license_record["sourceSHA256"],
            "licensePaths": [target_key],
        }
    if declared_licenses != set(referenced_licenses):
        fail(
            "runtime dependency license target set does not match artifact references: "
            f"missing={sorted(set(referenced_licenses) - declared_licenses)} "
            f"undeclared={sorted(declared_licenses - set(referenced_licenses))}"
        )
    return mapped


def gstreamer_provenance(lock_path: Path) -> dict[str, dict[str, object]]:
    payload = load_json(lock_path, "GStreamer payload lock")
    expected_keys = {
        "architecture",
        "artifacts",
        "licenses",
        "provider",
        "releasePackages",
        "schemaVersion",
        "sourceReference",
        "version",
    }
    if not isinstance(payload, dict) or set(payload) != expected_keys:
        fail("GStreamer payload lock schema is invalid")
    if (
        payload["schemaVersion"] != 1
        or payload["architecture"] != "x86_64"
        or payload["provider"] != "gstreamer-official-macos-universal-sdk"
        or payload["version"] != "1.28.5"
    ):
        fail("GStreamer payload lock provider, version, or architecture is invalid")
    source_reference = urlsplit(str(payload["sourceReference"]))
    if (
        source_reference.scheme != "https"
        or source_reference.hostname != "gstreamer.freedesktop.org"
        or source_reference.username
        or source_reference.password
    ):
        fail("GStreamer payload source reference must use the official HTTPS host")
    packages = payload["releasePackages"]
    if not isinstance(packages, list) or len(packages) != 2:
        fail("GStreamer payload lock release package set is invalid")
    for package in packages:
        if (
            not isinstance(package, dict)
            or set(package) != {"name", "sha256"}
            or not isinstance(package["name"], str)
            or not package["name"].endswith("-1.28.5-universal.pkg")
            or not isinstance(package["sha256"], str)
            or not SHA256_PATTERN.fullmatch(package["sha256"])
        ):
            fail("GStreamer payload release package record is invalid")

    artifacts = payload["artifacts"]
    if not isinstance(artifacts, list) or not artifacts:
        fail("GStreamer payload lock has no artifacts")
    artifact_fields = {
        "component",
        "componentVersion",
        "licenseExpression",
        "licensePaths",
        "sourcePath",
        "sourceSHA256",
        "targetPath",
    }
    mapped: dict[str, dict[str, object]] = {}
    component_provenance: dict[tuple[str, str], dict[str, object]] = {}
    referenced_licenses: dict[str, tuple[str, str]] = {}
    for artifact in artifacts:
        if not isinstance(artifact, dict) or set(artifact) != artifact_fields:
            fail("GStreamer payload artifact schema is invalid")
        for key in (
            "component",
            "componentVersion",
            "licenseExpression",
            "sourcePath",
            "sourceSHA256",
            "targetPath",
        ):
            if not isinstance(artifact[key], str) or not artifact[key]:
                fail(f"GStreamer payload artifact {key} is invalid")
        if not SHA256_PATTERN.fullmatch(artifact["sourceSHA256"]):
            fail("GStreamer payload artifact source SHA-256 is invalid")
        safe_relative_path(artifact["sourcePath"], "GStreamer artifact source path")
        target = safe_relative_path(artifact["targetPath"], "GStreamer artifact target path")
        if (
            not target.as_posix().startswith("wine/gstreamer/lib/")
            or not target.name.endswith(".dylib")
        ):
            fail(f"GStreamer artifact target is outside the isolated runtime closure: {target}")
        license_paths = artifact["licensePaths"]
        if not isinstance(license_paths, list) or not license_paths:
            fail(f"GStreamer artifact has no license paths: {target}")
        component_key = (artifact["component"], artifact["componentVersion"])
        for license_path in license_paths:
            path = safe_relative_path(license_path, "GStreamer artifact license path")
            if not path.as_posix().startswith("Legal/GStreamer/"):
                fail(f"GStreamer artifact license is outside Legal/GStreamer: {path}")
            existing_component = referenced_licenses.get(path.as_posix())
            if existing_component is not None and existing_component != component_key:
                fail(f"GStreamer license is attributed to multiple components: {path}")
            referenced_licenses[path.as_posix()] = component_key
        provenance = {
            "component": artifact["component"],
            "version": artifact["componentVersion"],
            "sourceKind": "gstreamer-official-macos-universal-sdk",
            "sourceReference": payload["sourceReference"],
            "licenseExpression": artifact["licenseExpression"],
            "licensePaths": license_paths,
        }
        existing_provenance = component_provenance.get(component_key)
        if existing_provenance is not None and existing_provenance != provenance:
            fail(f"GStreamer component provenance is inconsistent: {component_key[0]}")
        component_provenance[component_key] = provenance
        target_key = target.as_posix()
        if target_key in mapped:
            fail(f"GStreamer payload lock contains duplicate target: {target_key}")
        mapped[target_key] = {
            **provenance,
            "sourceSHA256": artifact["sourceSHA256"],
        }

    licenses = payload["licenses"]
    if not isinstance(licenses, list) or not licenses:
        fail("GStreamer payload lock has no licenses")
    license_fields = {
        "component",
        "componentVersion",
        "sourcePath",
        "sourceSHA256",
        "targetPath",
    }
    declared_licenses: set[str] = set()
    for record in licenses:
        if not isinstance(record, dict) or set(record) != license_fields:
            fail("GStreamer payload license schema is invalid")
        for key in license_fields:
            if not isinstance(record[key], str) or not record[key]:
                fail(f"GStreamer payload license {key} is invalid")
        if not SHA256_PATTERN.fullmatch(record["sourceSHA256"]):
            fail("GStreamer payload license source SHA-256 is invalid")
        safe_relative_path(record["sourcePath"], "GStreamer license source path")
        target = safe_relative_path(record["targetPath"], "GStreamer license target path")
        target_key = target.as_posix()
        if not target_key.startswith("Legal/GStreamer/"):
            fail(f"GStreamer license target is outside Legal/GStreamer: {target}")
        component_key = (record["component"], record["componentVersion"])
        if referenced_licenses.get(target_key) != component_key:
            fail(f"GStreamer license attribution does not match its artifacts: {target}")
        provenance = component_provenance.get(component_key)
        if provenance is None:
            fail(f"GStreamer license has no artifact component: {target}")
        if target_key in declared_licenses or target_key in mapped:
            fail(f"GStreamer payload lock contains duplicate license target: {target}")
        declared_licenses.add(target_key)
        mapped[target_key] = {
            **provenance,
            "sourceSHA256": record["sourceSHA256"],
            "licensePaths": [target_key],
        }
    if declared_licenses != set(referenced_licenses):
        fail("GStreamer artifact license references do not match declared licenses")
    return mapped


def renderer_contracts(lock_path: Path) -> dict[str, dict[str, object]]:
    payload = load_json(lock_path, "renderer payload lock")
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
        fail("renderer payload lock version or provenance policy is unsupported")
    components = payload["components"]
    if not isinstance(components, list) or not components:
        fail("renderer payload lock contains no components")
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
    mapped: dict[str, dict[str, object]] = {}
    for component in components:
        if not isinstance(component, dict) or set(component) != required:
            fail("renderer payload component schema is invalid")
        name = component["name"]
        if name not in RENDERER_COMPONENTS or name in mapped:
            fail(f"renderer payload component name is invalid or duplicated: {name}")
        if component["sourceKind"] != RENDERER_SOURCE_KINDS[name]:
            fail(f"renderer payload sourceKind violates the upstream-only policy: {name}")
        if not isinstance(component["fileCount"], int) or component["fileCount"] <= 0:
            fail(f"renderer payload component fileCount is invalid: {name}")
        if not isinstance(component["treeSHA256"], str) or not SHA256_PATTERN.fullmatch(
            component["treeSHA256"]
        ):
            fail(f"renderer payload component treeSHA256 is invalid: {name}")
        for key in ("licenseExpression", "sourceReference", "version"):
            if not isinstance(component[key], str) or not component[key]:
                fail(f"renderer payload component {key} is invalid: {name}")
        source_reference = urlsplit(component["sourceReference"])
        if (
            source_reference.scheme != "https"
            or not source_reference.hostname
            or source_reference.username
            or source_reference.password
            or source_reference.hostname in {"localhost", "127.0.0.1", "::1"}
        ):
            fail(f"renderer payload sourceReference must be a public HTTPS URL: {name}")
        license_paths = component["licensePaths"]
        if not isinstance(license_paths, list) or not license_paths:
            fail(f"renderer payload component licensePaths is invalid: {name}")
        for license_path in license_paths:
            safe_relative_path(license_path, f"renderer payload license path for {name}")
        signatures = component["preservedSignatureFiles"]
        if not isinstance(signatures, list):
            fail(f"renderer payload preservedSignatureFiles is invalid: {name}")
        signature_paths: set[str] = set()
        for signature in signatures:
            if not isinstance(signature, dict) or set(signature) != {"path", "sha256"}:
                fail(f"renderer payload preserved signature schema is invalid: {name}")
            signature_path = signature.get("path")
            signature_sha256 = signature.get("sha256")
            safe_relative_path(
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
        if signature_paths != PRESERVED_RENDERER_SIGNATURE_PATHS[name]:
            fail(
                f"renderer payload preserved signature set is invalid for {name}: "
                f"{sorted(signature_paths)}"
            )
        mapped[name] = component
    if set(mapped) != RENDERER_COMPONENTS:
        fail("renderer payload lock must declare the complete renderer component set")
    return mapped


def require_exact_relative_symlink(
    path: Path,
    expected_target: str,
    expected_resolved: Path,
    label: str,
) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"{label} could not be inspected: {path}: {error}")
    if not stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} must be a symlink: {path}")
    target = os.readlink(path)
    if target != expected_target:
        fail(
            f"{label} target is invalid: {path} -> {target}; "
            f"expected {expected_target}"
        )
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        fail(f"{label} target is unavailable: {path} -> {target}: {error}")
    if resolved != expected_resolved.resolve(strict=True):
        fail(
            f"{label} does not resolve to the canonical framework payload: "
            f"{path} -> {target}"
        )


def renderer_directory_content(
    root: Path,
    label: str,
) -> list[tuple[str, str, str]]:
    root = require_directory(root, label)
    entries: list[tuple[str, str, str]] = []
    for current_root, directory_names, file_names in os.walk(
        root, followlinks=False
    ):
        current = Path(current_root)
        for name in directory_names:
            directory = current / name
            if directory.is_symlink():
                fail(f"{label} must not contain directory symlinks: {directory}")
        directory_names[:] = sorted(directory_names)
        for name in sorted(file_names):
            path = current / name
            if path.is_symlink():
                fail(f"{label} must not contain file symlinks: {path}")
            require_regular_file(path, label)
            content_sha256, algorithm = content_digest(path)
            entries.append(
                (
                    path.relative_to(root).as_posix(),
                    algorithm,
                    content_sha256,
                )
            )
    return sorted(entries)


def verify_d3dmetal_framework_aliases(component_root: Path) -> None:
    if component_root.name != "d3dmetal":
        return

    framework = require_directory(
        component_root / D3DMETAL_COMPONENT_FRAMEWORK,
        "D3DMetal framework",
    )
    canonical_executable = require_regular_file(
        framework / "Versions/A/D3DMetal",
        "D3DMetal canonical executable",
    )
    canonical_resources = require_directory(
        framework / "Versions/A/Resources",
        "D3DMetal canonical Resources",
    )
    alias_executable = framework / "D3DMetal"
    alias_resources = framework / "Resources"
    current_version = framework / "Versions/Current"

    canonical_layout = any(
        path.is_symlink()
        for path in (alias_executable, alias_resources, current_version)
    )
    if canonical_layout:
        require_exact_relative_symlink(
            current_version,
            "A",
            framework / "Versions/A",
            "D3DMetal current-version alias",
        )
        require_exact_relative_symlink(
            alias_executable,
            "Versions/Current/D3DMetal",
            canonical_executable,
            "D3DMetal executable alias",
        )
        require_exact_relative_symlink(
            alias_resources,
            "Versions/Current/Resources",
            canonical_resources,
            "D3DMetal Resources alias",
        )
        return

    if os.path.lexists(current_version):
        fail(
            "materialized D3DMetal framework must not contain a "
            f"Versions/Current entry: {current_version}"
        )
    materialized_executable = require_regular_file(
        alias_executable,
        "D3DMetal materialized executable alias",
    )
    materialized_resources = require_directory(
        alias_resources,
        "D3DMetal materialized Resources alias",
    )
    canonical_sha256, canonical_algorithm = content_digest(canonical_executable)
    materialized_sha256, materialized_algorithm = content_digest(
        materialized_executable
    )
    if (
        canonical_algorithm,
        canonical_sha256,
    ) != (
        materialized_algorithm,
        materialized_sha256,
    ):
        fail(
            "materialized D3DMetal executable alias does not match "
            "Versions/A/D3DMetal"
        )
    if renderer_directory_content(
        materialized_resources,
        "D3DMetal materialized Resources alias",
    ) != renderer_directory_content(
        canonical_resources,
        "D3DMetal canonical Resources",
    ):
        fail(
            "materialized D3DMetal Resources alias does not match "
            "Versions/A/Resources"
        )


def renderer_tree_entries(root: Path) -> list[tuple[str, str, str, str, str]]:
    root = require_directory(root, "renderer component").resolve(strict=True)
    verify_d3dmetal_framework_aliases(root)
    entries: list[tuple[str, str, str, str, str]] = []
    for current_root, directory_names, file_names in os.walk(root, followlinks=False):
        current = Path(current_root)
        for name in directory_names:
            path = current / name
            relative = PurePosixPath(path.relative_to(root).as_posix())
            if (
                path.is_symlink()
                and relative not in D3DMETAL_COMPONENT_ALIAS_DIRECTORIES
            ):
                fail(f"renderer payload must not contain directory symlinks: {path}")
        directory_names[:] = sorted(
            name
            for name in directory_names
            if name not in EXCLUDED_DIRECTORY_NAMES
            and PurePosixPath(
                (current / name).relative_to(root).as_posix()
            )
            not in D3DMETAL_COMPONENT_ALIAS_DIRECTORIES
        )
        for name in sorted(file_names):
            path = current / name
            relative = path.relative_to(root).as_posix()
            if (
                PurePosixPath(relative)
                == D3DMETAL_COMPONENT_ALIAS_EXECUTABLE
            ):
                continue
            if path.is_symlink():
                target = os.readlink(path)
                if Path(target).is_absolute():
                    fail(f"renderer payload symlink target must be relative: {path} -> {target}")
                try:
                    resolved_target = path.resolve(strict=True)
                    resolved_target.relative_to(root)
                except (OSError, ValueError) as error:
                    fail(f"renderer payload symlink escapes its component: {path} -> {target}: {error}")
                require_regular_file(resolved_target, "renderer payload symlink target")
                entries.append(
                    (
                        relative,
                        "symlink",
                        "sha256-symlink-target-v1",
                        digest_bytes(target.encode("utf-8")),
                        target,
                    )
                )
                continue
            require_regular_file(path, "renderer payload file")
            content_sha256, algorithm = content_digest(path)
            entries.append((relative, "file", algorithm, content_sha256, ""))
    return sorted(entries)


def renderer_tree_digest(entries: list[tuple[str, str, str, str, str]]) -> str:
    lines = ["forgeplay-renderer-payload-v1"]
    lines.extend("\0".join(entry) for entry in entries)
    return digest_bytes(("\n".join(lines) + "\n").encode("utf-8"))


def verify_renderer_preserved_signatures(
    component_root: Path,
    contract: dict[str, object],
) -> None:
    expected = {
        signature["path"]: signature["sha256"]
        for signature in contract["preservedSignatureFiles"]
    }
    expected_directories = {
        str(PurePosixPath(relative).parent) for relative in expected
    }
    observed: dict[str, Path] = {}
    observed_directories: set[str] = set()
    for signature_directory in component_root.rglob("_CodeSignature"):
        require_directory(signature_directory, "renderer preserved signature directory")
        relative_directory = signature_directory.relative_to(component_root).as_posix()
        observed_directories.add(relative_directory)
        for entry in signature_directory.iterdir():
            signature_file = require_regular_file(
                entry,
                "renderer preserved signature file",
            )
            relative = signature_file.relative_to(component_root).as_posix()
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
        if digest_file(observed[relative]) != expected_sha256:
            fail(
                f"renderer preserved signature digest mismatch for {contract['name']}: "
                f"{relative}"
            )


def verify_renderer_payload(
    runtime_root: Path, contracts: dict[str, dict[str, object]]
) -> None:
    frameworks = require_directory(runtime_root / "Frameworks", "runtime Frameworks root")
    framework_entries = list(frameworks.iterdir())
    if {path.name for path in framework_entries} != {"renderer"}:
        fail("runtime Frameworks root must contain only the locked renderer payload")
    renderer_root = require_directory(frameworks / "renderer", "runtime renderer root")
    renderer_entries = list(renderer_root.iterdir())
    if any(not path.is_dir() or path.is_symlink() for path in renderer_entries):
        fail("runtime renderer root must contain only non-symlink component directories")
    observed_names = {path.name for path in renderer_entries}
    if observed_names != set(contracts):
        fail(
            "runtime renderer component set does not match the lock: "
            f"missing={sorted(set(contracts) - observed_names)} "
            f"undeclared={sorted(observed_names - set(contracts))}"
        )
    for name, contract in contracts.items():
        component_root = renderer_root / name
        entries = renderer_tree_entries(component_root)
        if len(entries) != contract["fileCount"]:
            fail(
                f"renderer component file count mismatch for {name}: "
                f"expected {contract['fileCount']}, found {len(entries)}"
            )
        actual = renderer_tree_digest(entries)
        if actual != contract["treeSHA256"]:
            fail(
                f"renderer component tree digest mismatch for {name}: "
                f"expected {contract['treeSHA256']}, found {actual}"
            )
        verify_renderer_preserved_signatures(component_root, contract)


def discover_host_support_paths(
    runtime_root: Path, host_support_map: dict[str, dict[str, object]]
) -> list[Path]:
    paths: list[Path] = []
    info_plist = runtime_root / "Info.plist"
    require_regular_file(info_plist, "runtime policy Info.plist")
    paths.append(info_plist)

    wine_lib = require_directory(runtime_root / "wine/lib", "runtime Wine library root")
    for path in sorted(wine_lib.iterdir(), key=lambda item: item.name):
        if path.is_symlink() or not path.is_file():
            continue
        if path.suffix == ".dylib":
            paths.append(require_regular_file(path, "runtime Wine dependency"))

    icd_root = require_directory(
        runtime_root / "wine/etc/vulkan/icd.d", "runtime Vulkan ICD directory"
    )
    for path in sorted(icd_root.iterdir(), key=lambda item: item.name):
        if path.is_symlink():
            fail(f"runtime Vulkan ICD must not be a symlink: {path}")
        if path.is_file():
            paths.append(require_regular_file(path, "runtime Vulkan ICD"))

    gstreamer_root = require_directory(
        runtime_root / "wine/gstreamer", "runtime GStreamer root"
    )
    for current_root, directory_names, file_names in os.walk(
        gstreamer_root, followlinks=False
    ):
        current = Path(current_root)
        directory_names[:] = [
            name for name in directory_names if not (current / name).is_symlink()
        ]
        for name in file_names:
            path = current / name
            if path.is_symlink():
                fail(f"runtime GStreamer payload must not contain symlinks: {path}")
            paths.append(require_regular_file(path, "runtime GStreamer payload"))

    for relative in sorted(host_support_map):
        if relative.startswith("Legal/"):
            paths.append(
                require_regular_file(
                    runtime_root / relative,
                    f"locked runtime dependency license {relative}",
                )
            )

    frameworks = require_directory(runtime_root / "Frameworks", "runtime Frameworks root")
    for current_root, directory_names, file_names in os.walk(frameworks, followlinks=False):
        current = Path(current_root)
        directory_names[:] = [
            name
            for name in directory_names
            if name not in EXCLUDED_DIRECTORY_NAMES
            and PurePosixPath(
                (current / name).relative_to(runtime_root).as_posix()
            )
            not in D3DMETAL_RUNTIME_ALIAS_DIRECTORIES
            and not (current / name).is_symlink()
        ]
        for name in file_names:
            path = current / name
            if (
                PurePosixPath(path.relative_to(runtime_root).as_posix())
                == D3DMETAL_RUNTIME_ALIAS_EXECUTABLE
            ):
                continue
            if path.is_symlink():
                paths.append(path)
            else:
                paths.append(require_regular_file(path, "runtime Frameworks payload"))
    return sorted(paths, key=lambda path: path.relative_to(runtime_root).as_posix())


def provenance_for_path(
    relative: str,
    host_support_map: dict[str, dict[str, object]],
    renderer_map: dict[str, dict[str, object]],
) -> dict[str, object]:
    if relative in host_support_map:
        return host_support_map[relative]
    if relative == "Info.plist":
        return {
            "component": "ForgePlay runtime policy",
            "version": "1",
            "sourceKind": "forgeplay-authored",
            "sourceReference": "Resources/Runners/ForgePlayRuntime/Info.plist",
            "licenseExpression": "LicenseRef-ForgePlay-Project",
            "licensePaths": [],
        }
    prefix = "Frameworks/renderer/"
    if relative.startswith(prefix):
        renderer_name = relative.removeprefix(prefix).split("/", 1)[0]
        contract = renderer_map.get(renderer_name)
        provenance = None if contract is None else {
            "component": contract["name"],
            "version": contract["version"],
            "sourceKind": contract["sourceKind"],
            "sourceReference": contract["sourceReference"],
            "sourceTreeSHA256": contract["treeSHA256"],
            "licenseExpression": contract["licenseExpression"],
            "licensePaths": contract["licensePaths"],
        }
        if provenance is None:
            fail(f"renderer payload has no explicit provenance mapping: {relative}")
        return provenance
    fail(f"host support payload is not declared by the dependency lock or renderer policy: {relative}")


def verify_license_paths(runtime_root: Path, entry: dict[str, object]) -> None:
    for relative in entry["licensePaths"]:
        license_path = runtime_root / str(relative)
        require_regular_file(license_path, f"license for {entry['path']}")


def create_sbom(
    runtime_root: Path,
    dependency_lock_path: Path,
    renderer_lock_path: Path,
    gstreamer_lock_path: Path,
) -> dict[str, object]:
    runtime_root = require_directory(runtime_root, "runtime root").resolve(strict=True)
    dependency_map = dependency_provenance(dependency_lock_path)
    gstreamer_map = gstreamer_provenance(gstreamer_lock_path)
    duplicate_targets = set(dependency_map).intersection(gstreamer_map)
    if duplicate_targets:
        fail(
            "GStreamer and base dependency locks contain duplicate targets: "
            + ", ".join(sorted(duplicate_targets))
        )
    host_support_map = {**dependency_map, **gstreamer_map}
    renderer_map = renderer_contracts(renderer_lock_path)
    verify_renderer_payload(runtime_root, renderer_map)
    manifest = load_json(runtime_root / "RuntimeManifest.json", "runtime manifest")
    if not isinstance(manifest, dict) or not isinstance(manifest.get("runtimeIdentifier"), str):
        fail("runtime manifest does not identify the runtime")

    entries: list[dict[str, object]] = []
    observed_dependencies: set[str] = set()
    for path in discover_host_support_paths(runtime_root, host_support_map):
        relative = path.relative_to(runtime_root).as_posix()
        provenance = provenance_for_path(relative, host_support_map, renderer_map)
        if relative in host_support_map:
            observed_dependencies.add(relative)
        if path.is_symlink():
            target = os.readlink(path)
            entry = {
                **provenance,
                "contentHashAlgorithm": "sha256-symlink-target-v1",
                "contentSHA256": digest_bytes(target.encode("utf-8")),
                "path": relative,
                "type": "symlink",
                "linkTarget": target,
            }
        else:
            content_sha256, algorithm = content_digest(path)
            entry = {
                **provenance,
                "contentHashAlgorithm": algorithm,
                "contentSHA256": content_sha256,
                "path": relative,
                "type": "file",
            }
        verify_license_paths(runtime_root, entry)
        entries.append(entry)

    missing_dependencies = sorted(set(host_support_map) - observed_dependencies)
    if missing_dependencies:
        fail(f"locked runtime dependencies are missing from payload: {', '.join(missing_dependencies)}")
    canonical_lines = [
        "forgeplay-host-support-payload-v1",
        *[
            "\0".join(
                [
                    str(entry["path"]),
                    str(entry["type"]),
                    str(entry["contentHashAlgorithm"]),
                    str(entry["contentSHA256"]),
                    str(entry["component"]),
                    str(entry["version"]),
                    str(entry["sourceKind"]),
                    str(entry["sourceReference"]),
                    str(entry.get("sourceSHA256", entry.get("sourceTreeSHA256", ""))),
                    str(entry["licenseExpression"]),
                    ",".join(str(path) for path in entry["licensePaths"]),
                ]
            )
            for entry in entries
        ],
    ]
    payload_fingerprint = digest_bytes(("\n".join(canonical_lines) + "\n").encode("utf-8"))
    return {
        "hostSupportPayload": entries,
        "inputs": {
            "dependencyLockPath": "Config/ForgePlayRuntimeDependencies.lock.json",
            "dependencyLockSHA256": digest_file(
                require_regular_file(dependency_lock_path, "runtime dependency lock")
            ),
            "rendererPayloadLockPath": "Config/ForgePlayRendererPayload.lock.json",
            "rendererPayloadLockSHA256": digest_file(
                require_regular_file(renderer_lock_path, "renderer payload lock")
            ),
            "gstreamerPayloadLockPath": "Config/ForgePlayGStreamerPayload.lock.json",
            "gstreamerPayloadLockSHA256": digest_file(
                require_regular_file(gstreamer_lock_path, "GStreamer payload lock")
            ),
        },
        "payloadFingerprint": payload_fingerprint,
        "policy": {
            "applicationBundleExtractionAllowed": False,
            "checkedInRuntimeOutputAsPackagingInputAllowed": False,
            "rendererProvenance": "official-or-upstream-artifact-only-v1",
            "undeclaredHostLibrariesAllowed": False,
        },
        "runtimeIdentifier": manifest["runtimeIdentifier"],
        "schemaVersion": 1,
    }


def serialized(payload: object) -> bytes:
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")


def atomic_write(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_path, 0o644)
        os.replace(temporary_path, path)
    finally:
        try:
            temporary_path.unlink()
        except FileNotFoundError:
            pass


def main() -> int:
    if len(sys.argv) != 7 or sys.argv[1] not in {"generate", "verify"}:
        print(
            "usage: runtime-sbom.py <generate|verify> "
            "<runtime root> <dependency lock> <renderer lock> "
            "<GStreamer lock> <RuntimeSBOM.json>",
            file=sys.stderr,
        )
        return 2
    try:
        mode = sys.argv[1]
        runtime_root = Path(sys.argv[2])
        dependency_lock_path = Path(sys.argv[3])
        renderer_lock_path = Path(sys.argv[4])
        gstreamer_lock_path = Path(sys.argv[5])
        sbom_path = Path(sys.argv[6])
        expected = serialized(
            create_sbom(
                runtime_root,
                dependency_lock_path,
                renderer_lock_path,
                gstreamer_lock_path,
            )
        )
        if mode == "generate":
            atomic_write(sbom_path, expected)
            print(f"Generated runtime host-support SBOM: {sbom_path}")
            return 0
        actual = require_regular_file(sbom_path, "runtime host-support SBOM").read_bytes()
        if actual != expected:
            fail("runtime host-support SBOM does not match the bundled payload and dependency lock")
        print(f"Runtime host-support SBOM verification passed: {sbom_path}")
        return 0
    except SBOMError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
