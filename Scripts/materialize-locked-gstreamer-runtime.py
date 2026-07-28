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


class MaterializationError(RuntimeError):
    pass


SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
EXPECTED_PROVIDER = "gstreamer-official-macos-universal-sdk"


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


def command(arguments: list[str], label: str) -> str:
    result = subprocess.run(arguments, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        fail(f"{label} failed: {detail}")
    return result.stdout


def load_lock(path: Path) -> tuple[dict[str, object], list[dict[str, object]], list[dict[str, object]]]:
    require_regular_file(path, "GStreamer payload lock")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"GStreamer payload lock is unreadable: {error}")
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
        or payload["provider"] != EXPECTED_PROVIDER
        or payload["version"] != "1.28.5"
    ):
        fail("GStreamer payload lock version, provider, or architecture is unsupported")
    reference = urlsplit(str(payload["sourceReference"]))
    if (
        reference.scheme != "https"
        or reference.hostname != "gstreamer.freedesktop.org"
        or reference.username
        or reference.password
    ):
        fail("GStreamer payload source reference must use the official HTTPS host")
    packages = payload["releasePackages"]
    if not isinstance(packages, list) or len(packages) != 2:
        fail("GStreamer payload lock must identify the runtime and development packages")
    for package in packages:
        if (
            not isinstance(package, dict)
            or set(package) != {"name", "sha256"}
            or not isinstance(package["name"], str)
            or not package["name"].endswith("-1.28.5-universal.pkg")
            or not isinstance(package["sha256"], str)
            or not SHA256_PATTERN.fullmatch(package["sha256"])
        ):
            fail("GStreamer release package record is invalid")
    artifacts = payload["artifacts"]
    licenses = payload["licenses"]
    if not isinstance(artifacts, list) or not artifacts:
        fail("GStreamer payload lock must contain artifacts")
    if not isinstance(licenses, list) or not licenses:
        fail("GStreamer payload lock must contain licenses")
    return payload, artifacts, licenses


def validate_artifact(raw: object) -> dict[str, object]:
    expected = {
        "component",
        "componentVersion",
        "licenseExpression",
        "licensePaths",
        "sourcePath",
        "sourceSHA256",
        "targetPath",
    }
    if not isinstance(raw, dict) or set(raw) != expected:
        fail("GStreamer artifact schema is invalid")
    for key in ("component", "componentVersion", "licenseExpression"):
        if not isinstance(raw[key], str) or not raw[key].strip():
            fail(f"GStreamer artifact {key} is invalid")
    if not isinstance(raw["sourceSHA256"], str) or not SHA256_PATTERN.fullmatch(raw["sourceSHA256"]):
        fail("GStreamer artifact source SHA-256 is invalid")
    source = safe_relative_path(raw["sourcePath"], "GStreamer artifact source path")
    target = safe_relative_path(raw["targetPath"], "GStreamer artifact target path")
    if not source.as_posix().startswith("lib/") or not source.name.endswith(".dylib"):
        fail(f"GStreamer artifact source is outside the SDK library closure: {source}")
    if not target.as_posix().startswith("wine/gstreamer/lib/") or not target.name.endswith(".dylib"):
        fail(f"GStreamer artifact target is outside the isolated runtime closure: {target}")
    paths = raw["licensePaths"]
    if not isinstance(paths, list) or not paths:
        fail(f"GStreamer artifact must identify licenses: {target}")
    for path in paths:
        license_path = safe_relative_path(path, "GStreamer artifact license path")
        if not license_path.as_posix().startswith("Legal/GStreamer/"):
            fail(f"GStreamer artifact license is outside Legal/GStreamer: {license_path}")
    return raw


def validate_license(raw: object) -> dict[str, object]:
    expected = {
        "component",
        "componentVersion",
        "sourcePath",
        "sourceSHA256",
        "targetPath",
    }
    if not isinstance(raw, dict) or set(raw) != expected:
        fail("GStreamer license schema is invalid")
    for key in ("component", "componentVersion"):
        if not isinstance(raw[key], str) or not raw[key].strip():
            fail(f"GStreamer license {key} is invalid")
    if not isinstance(raw["sourceSHA256"], str) or not SHA256_PATTERN.fullmatch(raw["sourceSHA256"]):
        fail("GStreamer license source SHA-256 is invalid")
    source = safe_relative_path(raw["sourcePath"], "GStreamer license source path")
    target = safe_relative_path(raw["targetPath"], "GStreamer license target path")
    if not source.as_posix().startswith("share/licenses/"):
        fail(f"GStreamer license source is outside SDK licenses: {source}")
    if not target.as_posix().startswith("Legal/GStreamer/"):
        fail(f"GStreamer license target is outside Legal/GStreamer: {target}")
    return raw


def resolve_source(source_root: Path, relative: PurePosixPath, expected_sha256: str, label: str) -> Path:
    unresolved = source_root.joinpath(*relative.parts)
    try:
        source = unresolved.resolve(strict=True)
        source.relative_to(source_root)
    except (OSError, ValueError) as error:
        fail(f"{label} escapes the GStreamer SDK root: {unresolved}: {error}")
    require_regular_file(source, label)
    actual = digest(source)
    if actual != expected_sha256:
        fail(f"{label} digest mismatch: expected {expected_sha256}, found {actual}: {relative}")
    return source


def safe_target(staging_root: Path, relative: PurePosixPath, label: str) -> Path:
    target = staging_root.joinpath(*relative.parts)
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        target.parent.resolve(strict=True).relative_to(staging_root)
    except (OSError, ValueError) as error:
        fail(f"{label} target parent is unsafe: {target}: {error}")
    if target.exists() or target.is_symlink():
        fail(f"{label} target already exists: {target}")
    return target


def materialize_x86_64_macho(source: Path, target: Path) -> None:
    architectures = command(["lipo", "-archs", str(source)], f"architecture inspection for {source}")
    if "x86_64" not in architectures.split():
        fail(f"GStreamer artifact does not contain x86_64: {source}")
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        command(
            ["lipo", str(source), "-thin", "x86_64", "-output", str(temporary)],
            f"x86_64 thinning for {source}",
        )
        os.chmod(temporary, source.stat().st_mode | stat.S_IWUSR)
        os.replace(temporary, target)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    require_regular_file(target, "materialized GStreamer artifact")
    target_architectures = command(["lipo", "-archs", str(target)], f"target inspection for {target}")
    if target_architectures.strip() != "x86_64":
        fail(f"materialized GStreamer artifact must contain exactly x86_64: {target}")


def main() -> int:
    if len(sys.argv) != 4:
        print(
            "usage: materialize-locked-gstreamer-runtime.py "
            "<payload lock> <GStreamer SDK root> <staged runtime root>",
            file=sys.stderr,
        )
        return 2
    try:
        lock_path = Path(sys.argv[1])
        source_root = require_directory(Path(sys.argv[2]), "GStreamer SDK root").resolve(strict=True)
        staging_root = require_directory(Path(sys.argv[3]), "staged runtime root").resolve(strict=True)
        _, raw_artifacts, raw_licenses = load_lock(lock_path)
        artifacts = [validate_artifact(raw) for raw in raw_artifacts]
        licenses = [validate_license(raw) for raw in raw_licenses]

        artifact_targets = [str(record["targetPath"]) for record in artifacts]
        license_targets = [str(record["targetPath"]) for record in licenses]
        if len(artifact_targets) != len(set(artifact_targets)):
            fail("GStreamer payload lock contains duplicate artifact targets")
        if len(license_targets) != len(set(license_targets)):
            fail("GStreamer payload lock contains duplicate license targets")
        referenced_licenses = {
            str(path)
            for artifact in artifacts
            for path in artifact["licensePaths"]
        }
        if referenced_licenses != set(license_targets):
            fail("GStreamer artifact license references do not match declared licenses")

        license_components = {
            str(record["targetPath"]): (
                str(record["component"]),
                str(record["componentVersion"]),
            )
            for record in licenses
        }
        for artifact in artifacts:
            identity = (str(artifact["component"]), str(artifact["componentVersion"]))
            if any(license_components[str(path)] != identity for path in artifact["licensePaths"]):
                fail(f"GStreamer artifact license attribution is inconsistent: {artifact['targetPath']}")
            source_relative = safe_relative_path(
                artifact["sourcePath"], "GStreamer artifact source path"
            )
            target_relative = safe_relative_path(
                artifact["targetPath"], "GStreamer artifact target path"
            )
            source = resolve_source(
                source_root,
                source_relative,
                str(artifact["sourceSHA256"]),
                "locked GStreamer artifact",
            )
            target = safe_target(staging_root, target_relative, "GStreamer artifact")
            materialize_x86_64_macho(source, target)

        for record in licenses:
            source_relative = safe_relative_path(
                record["sourcePath"], "GStreamer license source path"
            )
            target_relative = safe_relative_path(
                record["targetPath"], "GStreamer license target path"
            )
            source = resolve_source(
                source_root,
                source_relative,
                str(record["sourceSHA256"]),
                "locked GStreamer license",
            )
            target = safe_target(staging_root, target_relative, "GStreamer license")
            shutil.copyfile(source, target)
            os.chmod(target, source.stat().st_mode | stat.S_IWUSR)
            require_regular_file(target, "materialized GStreamer license")

        print(
            "Materialized locked GStreamer runtime: "
            f"{len(artifacts)} x86_64 Mach-O files, {len(licenses)} license files"
        )
        return 0
    except MaterializationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
