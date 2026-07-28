#!/usr/bin/env python3

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
from pathlib import Path, PurePosixPath


class MaterializationError(RuntimeError):
    pass


SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9@+_.-]+")


def fail(message: str) -> None:
    raise MaterializationError(message)


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def safe_relative_path(value: object, label: str) -> PurePosixPath:
    if not isinstance(value, str) or not value or "\\" in value:
        fail(f"{label} must be a non-empty POSIX relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in path.parts):
        fail(f"{label} is unsafe: {value}")
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


def require_directory(path: Path, label: str) -> Path:
    try:
        metadata = path.stat(follow_symlinks=False)
    except OSError as error:
        fail(f"{label} could not be inspected: {path}: {error}")
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} must be a non-symlink directory: {path}")
    return path


def require_x86_64_macho(path: Path) -> None:
    description = subprocess.run(
        ["file", "-b", str(path)], capture_output=True, text=True, check=False
    )
    if description.returncode != 0:
        fail(f"file inspection failed for dependency input: {path}")
    if not description.stdout.startswith("Mach-O"):
        return
    architectures = subprocess.run(
        ["lipo", "-archs", str(path)], capture_output=True, text=True, check=False
    )
    if architectures.returncode != 0 or architectures.stdout.strip() != "x86_64":
        found = architectures.stdout.strip() or architectures.stderr.strip() or "unknown"
        fail(f"locked Mach-O dependency must contain exactly x86_64 (found {found}): {path}")


def load_lock(path: Path) -> tuple[list[object], list[object]]:
    require_regular_file(path, "runtime dependency lock")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"runtime dependency lock is unreadable: {error}")
    if not isinstance(payload, dict) or set(payload) != {
        "architecture",
        "artifacts",
        "licenses",
        "provider",
        "schemaVersion",
    }:
        fail("runtime dependency lock schema is invalid")
    if payload["schemaVersion"] != 1 or payload["architecture"] != "x86_64":
        fail("runtime dependency lock version or architecture is unsupported")
    if payload["provider"] != "homebrew-core-prebuilt-package":
        fail("runtime dependency lock provider must be homebrew-core-prebuilt-package")
    artifacts = payload["artifacts"]
    if not isinstance(artifacts, list) or not artifacts:
        fail("runtime dependency lock must contain artifacts")
    licenses = payload["licenses"]
    if not isinstance(licenses, list) or not licenses:
        fail("runtime dependency lock must contain license files")
    return artifacts, licenses


def validate_artifact(raw: object) -> dict[str, object]:
    if not isinstance(raw, dict) or set(raw) != {
        "formula",
        "formulaVersion",
        "licenseExpression",
        "licensePaths",
        "sourcePath",
        "sourceReference",
        "sourceSHA256",
        "targetPath",
    }:
        fail("runtime dependency artifact schema is invalid")
    for key in ("formula", "formulaVersion"):
        if not isinstance(raw[key], str) or not TOKEN_PATTERN.fullmatch(raw[key]):
            fail(f"runtime dependency artifact {key} is invalid")
    if not isinstance(raw["sourceSHA256"], str) or not SHA256_PATTERN.fullmatch(raw["sourceSHA256"]):
        fail("runtime dependency artifact sourceSHA256 is invalid")
    if not isinstance(raw["sourceReference"], str) or not raw["sourceReference"].startswith(
        "https://formulae.brew.sh/formula/"
    ):
        fail("runtime dependency artifact sourceReference must use formulae.brew.sh")
    if not isinstance(raw["licenseExpression"], str) or not raw["licenseExpression"].strip():
        fail("runtime dependency artifact licenseExpression is invalid")
    if not isinstance(raw["licensePaths"], list) or not raw["licensePaths"]:
        fail("runtime dependency artifact must identify bundled license paths")
    for license_path in raw["licensePaths"]:
        safe_relative_path(license_path, "runtime dependency licensePath")
    source = safe_relative_path(raw["sourcePath"], "runtime dependency sourcePath")
    target = safe_relative_path(raw["targetPath"], "runtime dependency targetPath")
    if not (
        target.as_posix().startswith("wine/lib/") and target.name.endswith(".dylib")
    ) and target.as_posix() != "wine/etc/vulkan/icd.d/MoltenVK_icd.json":
        fail(f"runtime dependency target is outside the self-contained Wine closure: {target}")
    return raw


def validate_license(raw: object) -> dict[str, object]:
    if not isinstance(raw, dict) or set(raw) != {
        "formula",
        "formulaVersion",
        "sourcePath",
        "sourceSHA256",
        "targetPath",
    }:
        fail("runtime dependency license schema is invalid")
    for key in ("formula", "formulaVersion"):
        if not isinstance(raw[key], str) or not TOKEN_PATTERN.fullmatch(raw[key]):
            fail(f"runtime dependency license {key} is invalid")
    if not isinstance(raw["sourceSHA256"], str) or not SHA256_PATTERN.fullmatch(raw["sourceSHA256"]):
        fail("runtime dependency license sourceSHA256 is invalid")
    safe_relative_path(raw["sourcePath"], "runtime dependency license sourcePath")
    target = safe_relative_path(raw["targetPath"], "runtime dependency license targetPath")
    if not target.as_posix().startswith("Legal/") or len(target.parts) < 3:
        fail(f"runtime dependency license target is outside Legal: {target}")
    return raw


def resolve_locked_source(
    package_prefix: Path,
    record: dict[str, object],
    label: str,
    require_macho_architecture: bool,
) -> Path:
    formula = str(record["formula"])
    version = str(record["formulaVersion"])
    formula_root = require_directory(
        package_prefix / "Cellar" / formula / version,
        f"locked upstream formula {formula} {version}",
    ).resolve(strict=True)
    source_relative = safe_relative_path(record["sourcePath"], f"{label} sourcePath")
    unresolved_source = formula_root.joinpath(*source_relative.parts)
    try:
        source = unresolved_source.resolve(strict=True)
        source.relative_to(formula_root)
    except (OSError, ValueError) as error:
        fail(f"{label} source escapes its locked formula: {unresolved_source}: {error}")
    require_regular_file(source, label)
    actual_digest = digest(source)
    if actual_digest != record["sourceSHA256"]:
        fail(
            f"{label} digest mismatch: {formula}/{source_relative}: "
            f"expected {record['sourceSHA256']}, found {actual_digest}"
        )
    if require_macho_architecture:
        require_x86_64_macho(source)
    return source


def materialize_target(
    staging_root: Path,
    source: Path,
    target_relative: PurePosixPath,
    label: str,
) -> None:
    target = staging_root.joinpath(*target_relative.parts)
    try:
        target.relative_to(staging_root)
    except ValueError as error:
        fail(f"{label} target parent is unsafe: {target}: {error}")
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        target.parent.resolve(strict=True).relative_to(staging_root)
    except (OSError, ValueError) as error:
        fail(f"{label} target parent is unsafe: {target}: {error}")
    if target.exists() or target.is_symlink():
        require_regular_file(target, f"existing {label} target")
    shutil.copyfile(source, target)
    os.chmod(target, source.stat().st_mode | stat.S_IWUSR)
    require_regular_file(target, f"materialized {label}")


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: materialize-locked-runtime-dependencies.py "
            "<dependency lock> <x86_64 prebuilt package prefix> <staged runtime root>",
            file=sys.stderr,
        )
        return 2
    try:
        lock_path = Path(sys.argv[1])
        package_prefix = require_directory(
            Path(sys.argv[2]), "x86_64 prebuilt package prefix"
        ).resolve(strict=True)
        staging_root = require_directory(Path(sys.argv[3]), "staged runtime root").resolve(strict=True)
        if package_prefix != Path("/usr/local"):
            fail("locked x86_64 prebuilt package prefix must resolve exactly to /usr/local")
        raw_artifacts, raw_licenses = load_lock(lock_path)
        artifacts = [validate_artifact(raw) for raw in raw_artifacts]
        licenses = [validate_license(raw) for raw in raw_licenses]
        targets: set[str] = set()
        formula_versions = {
            (str(artifact["formula"]), str(artifact["formulaVersion"]))
            for artifact in artifacts
        }
        referenced_license_targets = {
            str(license_path)
            for artifact in artifacts
            for license_path in artifact["licensePaths"]
        }
        declared_license_targets = {str(license["targetPath"]) for license in licenses}
        if referenced_license_targets != declared_license_targets:
            fail(
                "runtime dependency license target set does not match artifact references: "
                f"missing={sorted(referenced_license_targets - declared_license_targets)} "
                f"undeclared={sorted(declared_license_targets - referenced_license_targets)}"
            )
        for artifact in artifacts:
            target_relative = safe_relative_path(artifact["targetPath"], "runtime dependency targetPath")
            target_key = target_relative.as_posix()
            if target_key in targets:
                fail(f"runtime dependency lock contains duplicate target: {target_key}")
            targets.add(target_key)
            source = resolve_locked_source(
                package_prefix,
                artifact,
                "locked prebuilt package artifact",
                require_macho_architecture=True,
            )
            materialize_target(
                staging_root,
                source,
                target_relative,
                f"runtime dependency {target_key}",
            )

        license_targets: set[str] = set()
        for license_record in licenses:
            target_relative = safe_relative_path(
                license_record["targetPath"], "runtime dependency license targetPath"
            )
            target_key = target_relative.as_posix()
            if target_key in license_targets:
                fail(f"runtime dependency lock contains duplicate license target: {target_key}")
            license_targets.add(target_key)
            formula_version = (
                str(license_record["formula"]),
                str(license_record["formulaVersion"]),
            )
            if formula_version not in formula_versions:
                fail(
                    "runtime dependency license does not belong to a locked artifact formula: "
                    f"{formula_version[0]} {formula_version[1]}"
                )
            source = resolve_locked_source(
                package_prefix,
                license_record,
                f"locked dependency license {target_key}",
                require_macho_architecture=False,
            )
            materialize_target(
                staging_root,
                source,
                target_relative,
                f"runtime dependency license {target_key}",
            )
        print(
            f"Materialized {len(artifacts)} locked runtime dependency artifacts "
            f"and {len(licenses)} license files"
        )
        return 0
    except MaterializationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
