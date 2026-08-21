#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=""
EXPORT_ROOT=""
TRUSTED_GIT_REPOSITORY=""
VERIFICATION_MODE="recipient-self-check"

fail() {
  printf 'error: invalid open-source export: %s\n' "$*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --project-root)
      [[ "$#" -ge 2 ]] || fail "--project-root requires a path"
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --release-authority)
      VERIFICATION_MODE="release-authority"
      shift
      ;;
    --recipient-self-check)
      VERIFICATION_MODE="recipient-self-check"
      shift
      ;;
    --trusted-git-repository)
      [[ "$#" -ge 2 ]] || fail "--trusted-git-repository requires a path"
      TRUSTED_GIT_REPOSITORY="$2"
      shift 2
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$EXPORT_ROOT" ]] ||
        fail "usage: verify-open-source-export.sh --project-root <path> [--release-authority --trusted-git-repository <path> | --recipient-self-check] <export root>"
      EXPORT_ROOT="$1"
      shift
      ;;
  esac
done

[[ -n "$PROJECT_ROOT" && -n "$EXPORT_ROOT" ]] ||
  fail "usage: verify-open-source-export.sh --project-root <path> [--release-authority --trusted-git-repository <path> | --recipient-self-check] <export root>"
[[ "$PROJECT_ROOT" = /* && -d "$PROJECT_ROOT" && ! -L "$PROJECT_ROOT" ]] ||
  fail "project root must be an absolute non-symlink directory"
[[ "$EXPORT_ROOT" = /* && -d "$EXPORT_ROOT" && ! -L "$EXPORT_ROOT" ]] ||
  fail "export root must be an absolute non-symlink directory"

PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"
EXPORT_ROOT="$(cd "$EXPORT_ROOT" && pwd -P)"

case "$VERIFICATION_MODE" in
  release-authority)
    [[ -n "$TRUSTED_GIT_REPOSITORY" ]] ||
      fail "release-authority verification requires --trusted-git-repository"
    [[ "$TRUSTED_GIT_REPOSITORY" = /* && -d "$TRUSTED_GIT_REPOSITORY" && ! -L "$TRUSTED_GIT_REPOSITORY" ]] ||
      fail "trusted Git repository must be an absolute non-symlink directory"
    TRUSTED_GIT_REPOSITORY="$(cd "$TRUSTED_GIT_REPOSITORY" && pwd -P)"
    [[ "$TRUSTED_GIT_REPOSITORY" != "$EXPORT_ROOT" ]] ||
      fail "trusted Git repository must be separate from the export root"
    ;;
  recipient-self-check)
    [[ -z "$TRUSTED_GIT_REPOSITORY" ]] ||
      fail "--trusted-git-repository is valid only with --release-authority"
    ;;
  *)
    fail "verification mode is invalid"
    ;;
esac

if find "$EXPORT_ROOT" -type l -print -quit | grep -q .; then
  fail "source export must not contain symlinks"
fi

PROHIBITED_NAMES="$(
  find "$EXPORT_ROOT" \( \
    -name '.DS_Store' -o \
    -name '.git' -o \
    -name '.env' -o \
    -name 'xcuserdata' -o \
    -name '*.xcuserstate' -o \
    -name 'ForgePlay.local.xcconfig' -o \
    -iname 'AuthKey_*.p8' -o \
    -iname '*.p8' -o \
    -iname '*.p12' -o \
    -iname '*.mobileprovision' -o \
    -iname '*.provisionprofile' -o \
    -iname '*.app' -o \
    -iname '*.dmg' -o \
    -iname '*.xcarchive' -o \
    -iname '*.framework' -o \
    -iname '*.dylib' -o \
    -iname '*.so' -o \
    -iname '*.dll' -o \
    -iname '*.exe' -o \
    -iname '*.msi' -o \
    -iname '*.pkg' -o \
    -iname '*.zip' -o \
    -iname '*.7z' -o \
    -iname '*.rar' \
  \) -print
)"
if [[ -n "$PROHIBITED_NAMES" ]]; then
  while IFS= read -r prohibited_path; do
    printf '%s\n' "${prohibited_path#"$EXPORT_ROOT/"}" >&2
  done <<< "$PROHIBITED_NAMES"
  fail "source export contains a credential, bundle, archive, or binary payload"
fi

python3 - "$EXPORT_ROOT" "$PROJECT_ROOT" "$VERIFICATION_MODE" "$TRUSTED_GIT_REPOSITORY" "${HOME:-}" "${USER:-}" <<'PY'
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
project_root = sys.argv[2]
verification_mode = sys.argv[3]
trusted_git_repository = sys.argv[4]
home = sys.argv[5]
user = sys.argv[6]
private_marker = os.environ.get("FORGEPLAY_OPEN_SOURCE_PRIVATE_MARKER", "")

allowed_top_level = {
    ".forgeplay-source-export",
    ".gitignore",
    "Config",
    "ForgePlay.xcodeproj",
    "LICENSE.md",
    "LICENSES",
    "Native",
    "README.md",
    "README_EN.md",
    "README_KO.md",
    "Resources",
    "SOURCE-INVENTORY.json",
    "SOURCE-LICENSES.md",
    "Scripts",
    "Sources",
    "Tests",
    "project.yml",
    "site-data",
}
actual_top_level = {path.name for path in root.iterdir()}
unexpected_top_level = sorted(actual_top_level - allowed_top_level)
missing_top_level = sorted(allowed_top_level - actual_top_level)
if unexpected_top_level or missing_top_level:
    raise SystemExit(
        f"top-level allowlist mismatch; unexpected={unexpected_top_level}, missing={missing_top_level}"
    )

for forbidden_relative_path in [
    "AppStoreConnect",
    "Artifacts",
    "LiveEvidence",
    "CleanRoom",
    "dist",
    "docs",
    "Resources/Runners/ForgePlayRuntime/BUILD-METADATA.md",
    "Resources/Runners/ForgePlayRuntime/Frameworks",
    "Resources/Runners/ForgePlayRuntime/RuntimeSBOM.json",
    "Resources/Runners/ForgePlayRuntime/Sources/renderer/d3dmetal",
    "Resources/Runners/ForgePlayRuntime/SteamCompat",
    "Resources/Runners/ForgePlayRuntime/wine",
]:
    if (root / forbidden_relative_path).exists():
        raise SystemExit(f"forbidden development or binary path is present: {forbidden_relative_path}")

allowed_configs = {
    "ForgePlayApp.xcconfig",
    "ForgePlayAppStore.xcconfig",
    "ForgePlayCopyleftSourcePackages.json",
    "ForgePlayDefaults.xcconfig",
    "ForgePlayDirectRelease.xcconfig",
    "ForgePlayDistribution.xcconfig",
    "ForgePlayExternalStorageAccessBridge.xcconfig",
    "ForgePlayGameModeProcessHost.xcconfig",
    "ForgePlayGameModeProcessHostAppStore.xcconfig",
    "ForgePlayGameModeProcessHostDistribution.xcconfig",
    "ForgePlayGameModeProcessHostRelease.xcconfig",
    "ForgePlayGStreamerPayload.lock.json",
    "ForgePlayNetworkControlHelper.xcconfig",
    "ForgePlayNetworkControlHelperAppStore.xcconfig",
    "ForgePlayNetworkControlHelperDistribution.xcconfig",
    "ForgePlayPublicDistributionSourceGraph.json",
    "ForgePlayRendererPayload.lock.json",
    "ForgePlayRuntimeDependencies.lock.json",
    "ForgePlayRuntimePatchProvenance.lock.json",
    "ForgePlayRuntimeSourceIdentity.lock.json",
    "ForgePlayTests.xcconfig",
}
actual_configs = {path.name for path in (root / "Config").iterdir()}
if actual_configs != allowed_configs:
    raise SystemExit(
        f"Config allowlist mismatch; unexpected={sorted(actual_configs - allowed_configs)}, "
        f"missing={sorted(allowed_configs - actual_configs)}"
    )

allowed_scripts = {
    "Fixtures",
    "build-commercial-release.sh",
    "build-forgeplay-wine-runtime.sh",
    "build-public-forgeplay-runtime.sh",
    "build-public-distribution-archive.sh",
    "check-project-build-warnings.sh",
    "export-open-source.sh",
    "freeze-public-source-export.py",
    "generate-compatibility-db-signing-key.swift",
    "generate-xcode-project.sh",
    "materialize-locked-gstreamer-runtime.py",
    "materialize-locked-renderer.py",
    "materialize-locked-runtime-dependencies.py",
    "materialize-forgeplay-wine-11.12-source.sh",
    "open-source-export-transaction.py",
    "package-forgeplay-runtime.sh",
    "prepare-app-store-runtime-payload.sh",
    "prepare-clean-build-root.sh",
    "prepare-dmg-output-path.sh",
    "prepare-game-mode-host-build-identity.sh",
    "public-runtime-release-attestation.py",
    "public-release-set-transaction.py",
    "quarantine-owned-directory.py",
    "restore-preserved-apple-d3dmetal-signatures.sh",
    "runtime-core-payload-identity.py",
    "runtime-sbom.py",
    "sign-app-store-runtime-code.sh",
    "sign-compatibility-db-feed.swift",
    "test-wine-session-compatibility.sh",
    "tests",
    "validate-d3dmetal-ngx-bridge.sh",
    "validate-compatibility-db-public-key.swift",
    "validate-product-identity.sh",
    "verify-app-store-app-security.sh",
    "verify-app-store-controller-permissions.py",
    "verify-bundled-runtime-capability.sh",
    "verify-clean-wine-runtime-markers.py",
    "verify-copyleft-source-packages.py",
    "verify-dmg-contents.sh",
    "verify-forgeplay-runtime-patch-provenance.py",
    "verify-game-mode-source-licenses.py",
    "verify-legal-documents.sh",
    "verify-license-documents.sh",
    "verify-macho-runtime-closure.py",
    "verify-notary-submit-json.sh",
    "verify-open-source-export.sh",
    "verify-privacy-manifest.sh",
    "verify-project-documents.sh",
    "verify-public-release-assets.sh",
    "verify-public-release-license-policy.sh",
    "verify-public-runtime-build-receipt.py",
    "verify-release-app-info.sh",
    "verify-release-app-localizations.sh",
    "verify-release-app-security.sh",
    "verify-release-bundle-privacy.sh",
    "verify-release-evidence.sh",
    "verify-wine-runtime-build-paths.py",
}
actual_scripts = {path.name for path in (root / "Scripts").iterdir()}
if actual_scripts != allowed_scripts:
    raise SystemExit(
        f"Scripts allowlist mismatch; unexpected={sorted(actual_scripts - allowed_scripts)}, "
        f"missing={sorted(allowed_scripts - actual_scripts)}"
    )

fixture_root = root / "Scripts" / "Fixtures"
if not fixture_root.is_dir() or fixture_root.is_symlink():
    raise SystemExit("source fixture directory is unavailable")
expected_fixture_groups = {"WineSessionCompatibility"}
actual_fixture_groups = {path.name for path in fixture_root.iterdir()}
if actual_fixture_groups != expected_fixture_groups:
    raise SystemExit(
        "source fixture-group allowlist mismatch; "
        f"unexpected={sorted(actual_fixture_groups - expected_fixture_groups)}, "
        f"missing={sorted(expected_fixture_groups - actual_fixture_groups)}"
    )

expected_compatibility_fixtures = {"session_compatibility_probe.c"}
compatibility_fixture_root = fixture_root / "WineSessionCompatibility"
if (
    not compatibility_fixture_root.is_dir()
    or compatibility_fixture_root.is_symlink()
):
    raise SystemExit("Steam session compatibility fixture directory is unavailable")
actual_compatibility_fixtures = {
    path.name for path in compatibility_fixture_root.iterdir()
}
if actual_compatibility_fixtures != expected_compatibility_fixtures:
    raise SystemExit(
        "Steam session compatibility fixture allowlist mismatch; "
        f"unexpected={sorted(actual_compatibility_fixtures - expected_compatibility_fixtures)}, "
        f"missing={sorted(expected_compatibility_fixtures - actual_compatibility_fixtures)}"
    )

required_test_sources = {
    "GameModeHostCapabilityTests.swift",
    "GameModeLaunchRequestStoreTests.swift",
}
test_source_root = root / "Tests" / "ForgePlayTests"
if not test_source_root.is_dir() or test_source_root.is_symlink():
    raise SystemExit("Game Mode test source directory is unavailable")
actual_test_sources = {path.name for path in test_source_root.iterdir()}
if not required_test_sources.issubset(actual_test_sources):
    raise SystemExit(
        "required Game Mode test sources are missing; "
        f"missing={sorted(required_test_sources - actual_test_sources)}"
    )
for path in test_source_root.iterdir():
    if not path.is_file() or path.is_symlink() or path.suffix != ".swift":
        raise SystemExit(f"unexpected non-Swift test source: {path.name}")

expected_script_tests = {
    "test-copyleft-source-packages.py",
    "test-freeze-public-source-export.py",
    "test-generate-xcode-project.sh",
    "test-open-source-export-transaction.py",
    "test-packaging-license-release-contracts.py",
    "test-public-distribution-archive-graph.py",
    "test-public-runtime-build-receipt.py",
    "test-public-runtime-release-attestation.py",
    "test-public-release-set-transaction.py",
    "test-quarantine-owned-directory.py",
    "test-wine-game-mode-process-host-routing.sh",
}
script_test_root = root / "Scripts" / "tests"
if not script_test_root.is_dir() or script_test_root.is_symlink():
    raise SystemExit("Game Mode script-test directory is unavailable")
actual_script_tests = {path.name for path in script_test_root.iterdir()}
if actual_script_tests != expected_script_tests:
    raise SystemExit(
        "Game Mode script-test allowlist mismatch; "
        f"unexpected={sorted(actual_script_tests - expected_script_tests)}, "
        f"missing={sorted(expected_script_tests - actual_script_tests)}"
    )

markers: list[tuple[str, bytes]] = [
    ("private-key PEM header", b"-----BEGIN " + b"PRIVATE KEY-----"),
    ("RSA private-key PEM header", b"-----BEGIN " + b"RSA PRIVATE KEY-----"),
    ("EC private-key PEM header", b"-----BEGIN " + b"EC PRIVATE KEY-----"),
    ("OpenSSH private-key header", b"-----BEGIN " + b"OPENSSH PRIVATE KEY-----"),
]

def add_marker(label: str, value: str) -> None:
    if value:
        markers.append((label, os.fsencode(value)))

add_marker("development workspace path", project_root)
add_marker("user home path", home.rstrip("/") if home.startswith("/") else "")
if user and user not in {"root", "runner"}:
    add_marker("local account name", user)
add_marker("local signing-team override", private_marker)

macho_magics = {
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
}
max_marker_length = max(len(marker) for _, marker in markers)
violations: list[tuple[str, str]] = []

for path in sorted(root.rglob("*")):
    if not path.is_file() or path.is_symlink():
        continue
    relative = str(path.relative_to(root))
    size_limit = 10 * 1024 * 1024
    if relative.startswith("Resources/Fonts/") or relative.startswith(
        "Resources/Runners/ForgePlayRuntime/Sources/"
    ):
        size_limit = 512 * 1024 * 1024
    if path.stat().st_size > size_limit:
        violations.append((relative, f"file exceeds {size_limit} byte source-export limit"))
        continue
    with path.open("rb") as handle:
        prefix = handle.read(4)
        if prefix in macho_magics:
            violations.append((relative, "Mach-O binary"))
            continue
        if prefix[:2] == b"MZ":
            violations.append((relative, "PE binary"))
            continue
        if prefix == b"PK\x03\x04":
            violations.append((relative, "ZIP archive"))
            continue
        handle.seek(0)
        tail = b""
        found: set[str] = set()
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            data = tail + chunk
            for label, marker in markers:
                if label not in found and marker in data:
                    found.add(label)
            tail = data[-(max_marker_length - 1):] if max_marker_length > 1 else b""
        for label in sorted(found):
            violations.append((relative, label))

if violations:
    for relative, reason in violations:
        print(f"{relative}: {reason}", file=sys.stderr)
    raise SystemExit("source export contains a binary, credential, or local identity marker")

inventory_path = root / "SOURCE-INVENTORY.json"
try:
    inventory_raw = inventory_path.read_bytes()
    inventory = json.loads(inventory_raw)
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"source inventory is unreadable: {error}") from error
if not isinstance(inventory, dict) or set(inventory) != {
    "entries",
    "gitObjectFormat",
    "hashAlgorithm",
    "inventoryGenerator",
    "inventorySHA256",
    "releaseCommit",
    "schemaVersion",
}:
    raise SystemExit("source inventory schema is invalid")
if inventory["schemaVersion"] != 2 or inventory["hashAlgorithm"] != "sha256":
    raise SystemExit("source inventory policy is unsupported")
git_object_format = inventory["gitObjectFormat"]
if git_object_format not in {"sha1", "sha256"}:
    raise SystemExit("source inventory Git object format is invalid")
release_commit = inventory["releaseCommit"]
if not isinstance(release_commit, str) or re.fullmatch(r"[0-9a-f]{40,64}", release_commit) is None:
    raise SystemExit("source inventory release commit is invalid")
if len(release_commit) != (40 if git_object_format == "sha1" else 64):
    raise SystemExit("source inventory release commit does not match its Git object format")

def safe_relative(value: object) -> bool:
    if not isinstance(value, str) or not value:
        return False
    from pathlib import PurePosixPath

    parsed = PurePosixPath(value)
    return (
        not parsed.is_absolute()
        and value == parsed.as_posix()
        and all(part not in {"", ".", ".."} for part in parsed.parts)
        and all(ord(character) >= 0x20 and character != "\x7f" for character in value)
    )

entries = inventory["entries"]
if not isinstance(entries, list):
    raise SystemExit("source inventory entries are invalid")
inventory_rows = {}
for row in entries:
    if not isinstance(row, dict) or set(row) != {
        "byteLength", "mode", "origin", "path", "sha256"
    }:
        raise SystemExit("source inventory row schema is invalid")
    relative = row["path"]
    if not safe_relative(relative) or relative in inventory_rows:
        raise SystemExit("source inventory contains an unsafe or duplicate path")
    if (
        not isinstance(row["byteLength"], int)
        or row["byteLength"] < 0
        or row["mode"] not in {"100644", "100755"}
        or not isinstance(row["sha256"], str)
        or re.fullmatch(r"[0-9a-f]{64}", row["sha256"]) is None
        or not isinstance(row["origin"], dict)
    ):
        raise SystemExit(f"source inventory metadata is invalid: {relative}")
    inventory_rows[relative] = row
if list(inventory_rows) != sorted(inventory_rows):
    raise SystemExit("source inventory entries are not path-sorted")
for executable_path in (
    "Scripts/export-open-source.sh",
    "Scripts/freeze-public-source-export.py",
    "Scripts/tests/test-generate-xcode-project.sh",
    "Scripts/public-release-set-transaction.py",
    "Scripts/verify-copyleft-source-packages.py",
    "Scripts/tests/test-copyleft-source-packages.py",
    "Scripts/tests/test-freeze-public-source-export.py",
    "Scripts/tests/test-public-release-set-transaction.py",
):
    row = inventory_rows.get(executable_path)
    if not isinstance(row, dict) or row.get("mode") != "100755":
        raise SystemExit(f"required exported tool is not executable: {executable_path}")

actual_rows = []
for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
    if path == inventory_path or not path.is_file() or path.is_symlink():
        continue
    relative = path.relative_to(root).as_posix()
    expected = inventory_rows.get(relative)
    if expected is None:
        raise SystemExit(f"exported file is absent from source inventory: {relative}")
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise SystemExit(f"source inventory input is not a single-link file: {relative}")
        digest = hashlib.sha256()
        git_digest = hashlib.new(git_object_format)
        git_digest.update(f"blob {before.st_size}\0".encode("ascii"))
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            digest.update(chunk)
            git_digest.update(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    if identity(before) != identity(after) or total != before.st_size:
        raise SystemExit(f"source inventory input changed while hashing: {relative}")
    actual_mode = f"100{stat.S_IMODE(before.st_mode):03o}"
    actual_sha256 = digest.hexdigest()
    if (
        expected["byteLength"] != total
        or expected["mode"] != actual_mode
        or expected["sha256"] != actual_sha256
    ):
        raise SystemExit(f"source inventory metadata differs from exported bytes: {relative}")
    origin = expected["origin"]
    classification = origin.get("classification")
    if classification in {"release-commit-blob", "injected-template-blob"}:
        if set(origin) != {
            "classification",
            "destinationPath",
            "gitMode",
            "gitObjectID",
            "sha256",
            "sourcePath",
        }:
            raise SystemExit(f"Git-blob origin schema is invalid: {relative}")
        if (
            origin["destinationPath"] != relative
            or origin["gitMode"] != actual_mode
            or origin["sha256"] != actual_sha256
            or not safe_relative(origin["sourcePath"])
            or origin["gitObjectID"] != git_digest.hexdigest()
        ):
            raise SystemExit(f"Git-blob origin does not bind exported bytes: {relative}")
        if classification == "release-commit-blob" and origin["sourcePath"] != relative:
            raise SystemExit(f"release-commit blob was remapped unexpectedly: {relative}")
    elif classification == "generated-xcode-project":
        if not relative.startswith("ForgePlay.xcodeproj/"):
            raise SystemExit(f"generated classification escaped Xcode project: {relative}")
    else:
        raise SystemExit(f"unsupported source origin classification: {relative}")
    actual_rows.append(
        {
            "byteLength": total,
            "mode": actual_mode,
            "origin": origin,
            "path": relative,
            "sha256": actual_sha256,
        }
    )
if inventory["entries"] != actual_rows:
    raise SystemExit("source inventory does not exactly match the exported release files")

def git_projection(row: dict) -> dict:
    origin = row["origin"]
    if origin.get("classification") not in {"release-commit-blob", "injected-template-blob"}:
        raise SystemExit(f"source projection is not backed by one Git blob: {row['path']}")
    return {
        "gitMode": origin["gitMode"],
        "gitObjectID": origin["gitObjectID"],
        "path": origin["destinationPath"],
        "sha256": origin["sha256"],
        "sourcePath": origin["sourcePath"],
    }

generator_projection = git_projection(inventory_rows["Scripts/generate-xcode-project.sh"])
project_projection = git_projection(inventory_rows["project.yml"])
for relative, row in inventory_rows.items():
    if not relative.startswith("ForgePlay.xcodeproj/"):
        continue
    origin = row["origin"]
    if set(origin) != {"classification", "generator", "inputs", "tool"} or origin != {
        "classification": "generated-xcode-project",
        "generator": generator_projection,
        "inputs": [project_projection],
        "tool": origin.get("tool"),
    }:
        raise SystemExit(f"generated Xcode project origin is invalid: {relative}")
    tool = origin["tool"]
    if (
        not isinstance(tool, dict)
        or set(tool) != {"name", "version"}
        or tool.get("name") != "xcodegen"
        or not isinstance(tool.get("version"), str)
        or not tool["version"]
    ):
        raise SystemExit(f"generated Xcode project tool identity is invalid: {relative}")

injected_sources = {
    ".forgeplay-source-export": "Scripts/Templates/OpenSource/export-marker",
    ".gitignore": "Scripts/Templates/OpenSource/gitignore",
    "README.md": "Scripts/Templates/OpenSource/README.md",
    "README_EN.md": "Scripts/Templates/OpenSource/README_EN.md",
    "README_KO.md": "Scripts/Templates/OpenSource/README_KO.md",
    "SOURCE-LICENSES.md": "Scripts/Templates/OpenSource/SOURCE-LICENSES.md",
    "Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-process-host-routing.patch.license":
        "Scripts/Templates/OpenSource/PatchLicenses/wine-11.12-game-mode-process-host-routing.patch.license",
    "Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-direct-target-scope.patch.license":
        "Scripts/Templates/OpenSource/PatchLicenses/wine-11.12-game-mode-direct-target-scope.patch.license",
}
actual_injected = {}
for relative, row in inventory_rows.items():
    origin = row["origin"]
    if origin.get("classification") == "injected-template-blob":
        actual_injected[relative] = origin.get("sourcePath")
if actual_injected != injected_sources:
    raise SystemExit("injected export templates do not match the exact public allowlist")

if inventory["inventoryGenerator"] != git_projection(
    inventory_rows["Scripts/export-open-source.sh"]
):
    raise SystemExit("source inventory generator is not the exact release exporter blob")

if verification_mode == "release-authority":
    repository = Path(trusted_git_repository)

    def git_output(*arguments: str) -> bytes:
        result = subprocess.run(
            ["git", "--no-replace-objects", "-C", os.fspath(repository), *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            raise SystemExit(
                "trusted release Git verification failed: "
                + result.stderr.decode("utf-8", "replace").strip()
            )
        return result.stdout

    checked_format = git_output("rev-parse", "--show-object-format").decode().strip()
    if checked_format != git_object_format:
        raise SystemExit("trusted Git object format does not match source inventory")
    checked_commit = git_output(
        "rev-parse", "--verify", f"{release_commit}^{{commit}}"
    ).decode().strip()
    if checked_commit != release_commit:
        raise SystemExit("trusted Git repository does not contain the exact release commit")
    # Resolve the tree separately so a supplied object database must contain a
    # real commit/tree relationship, not merely a blob with a forged origin.
    git_output("rev-parse", "--verify", f"{release_commit}^{{tree}}")
    tree_entries = {}
    for record in git_output("ls-tree", "-rz", "--full-tree", release_commit).split(b"\0"):
        if not record:
            continue
        try:
            header, raw_path = record.split(b"\t", 1)
            mode, object_type, object_id = header.decode("ascii").split(" ")
            source_path = raw_path.decode("utf-8")
        except (UnicodeDecodeError, ValueError) as error:
            raise SystemExit("trusted release Git tree record is invalid") from error
        if not safe_relative(source_path) or source_path in tree_entries:
            raise SystemExit("trusted release Git tree contains an unsafe or duplicate path")
        tree_entries[source_path] = (mode, object_type, object_id)
    for relative, row in inventory_rows.items():
        origin = row["origin"]
        if origin.get("classification") not in {
            "release-commit-blob", "injected-template-blob"
        }:
            continue
        expected_entry = (origin["gitMode"], "blob", origin["gitObjectID"])
        if tree_entries.get(origin["sourcePath"]) != expected_entry:
            raise SystemExit(
                "export origin is absent from the exact trusted release tree: "
                f"{relative}"
            )
canonical_lines = [
    "forgeplay-public-source-inventory-v2",
    f"releaseCommit={release_commit}",
    f"gitObjectFormat={git_object_format}",
    *(
        f"{row['path']}\0{row['mode']}\0{row['byteLength']}\0{row['sha256']}\0"
        + json.dumps(row["origin"], sort_keys=True, separators=(",", ":"))
        for row in actual_rows
    ),
]
expected_inventory_sha256 = hashlib.sha256(
    ("\n".join(canonical_lines) + "\n").encode("utf-8")
).hexdigest()
if inventory["inventorySHA256"] != expected_inventory_sha256:
    raise SystemExit("source inventory digest is invalid")
canonical_inventory = (json.dumps(inventory, indent=2, sort_keys=True) + "\n").encode("utf-8")
if inventory_raw != canonical_inventory:
    raise SystemExit("source inventory is not canonical JSON")

graph_path = root / "Config/ForgePlayPublicDistributionSourceGraph.json"
try:
    graph = json.loads(graph_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as error:
    raise SystemExit(f"public Distribution source graph is unreadable: {error}") from error
if not isinstance(graph, dict) or set(graph) != {
    "archiveCommandPath",
    "buildClaimResourcePath",
    "excludedThirdPartyPayloadRoots",
    "requiredReleaseCommitPaths",
    "runtimePayloadInjectionRoot",
    "schemaVersion",
} or graph["schemaVersion"] != 1:
    raise SystemExit("public Distribution source graph schema is invalid")
if (
    graph["archiveCommandPath"] != "Scripts/build-public-distribution-archive.sh"
    or graph["buildClaimResourcePath"]
    != "Resources/PublicDistributionBuildClaim.json"
    or graph["runtimePayloadInjectionRoot"] != "Resources/Runners/ForgePlayRuntime"
    or graph["excludedThirdPartyPayloadRoots"]
    != ["Resources/Runners/ForgePlayRuntime/Frameworks/renderer/d3dmetal"]
):
    raise SystemExit("public Distribution source graph boundaries are invalid")
expected_graph_paths = {
    "project.yml",
    "Config/ForgePlayApp.xcconfig",
    "Config/ForgePlayCopyleftSourcePackages.json",
    "Config/ForgePlayDefaults.xcconfig",
    "Config/ForgePlayDirectRelease.xcconfig",
    "Config/ForgePlayDistribution.xcconfig",
    "Config/ForgePlayExternalStorageAccessBridge.xcconfig",
    "Config/ForgePlayGameModeProcessHost.xcconfig",
    "Config/ForgePlayGameModeProcessHostDistribution.xcconfig",
    "Config/ForgePlayGameModeProcessHostRelease.xcconfig",
    "Config/ForgePlayNetworkControlHelper.xcconfig",
    "Config/ForgePlayNetworkControlHelperDistribution.xcconfig",
    "Config/ForgePlayPublicDistributionSourceGraph.json",
    "Sources/ForgePlay/ForgePlay-Distribution.entitlements",
    "Sources/ForgePlay/ForgePlay-DirectRelease.entitlements",
    "Sources/ForgePlay/ForgePlay-Runtime-Direct.entitlements",
    "Sources/ForgePlay/ForgePlay-Runtime-Inherit.entitlements",
    "Native/GameModeProcessHost/GameModeProcessHost-Distribution.entitlements",
    "Native/GameModeProcessHost/GameModeProcessHost-Release.entitlements",
    "Native/NetworkControlHelper/ForgePlayNetworkControl.plist",
    "Native/NetworkControlHelper/Info.plist",
    "Native/NetworkControlHelper/main.swift",
    "Resources/AppIcon.icon/Assets/ForgePlay_ICON_Dark.png",
    "Resources/AppIcon.icon/Assets/ForgePlay_ICON_Default.png",
    "Resources/AppIcon.icon/icon.json",
} | {
    f"Scripts/{name}" for name in allowed_scripts if name not in {"Fixtures", "tests"}
}
required_graph_paths = graph["requiredReleaseCommitPaths"]
if (
    not isinstance(required_graph_paths, list)
    or len(required_graph_paths) != len(set(required_graph_paths))
    or set(required_graph_paths) != expected_graph_paths
):
    raise SystemExit("public Distribution source graph is incomplete or overbroad")
for relative in required_graph_paths:
    row = inventory_rows.get(relative)
    origin = row.get("origin") if isinstance(row, dict) else None
    if (
        not isinstance(origin, dict)
        or origin.get("classification") != "release-commit-blob"
        or origin.get("sourcePath") != relative
        or origin.get("destinationPath") != relative
        or origin.get("sha256") != row.get("sha256")
        or origin.get("gitMode") != row.get("mode")
    ):
        raise SystemExit(f"Distribution graph is not one exact release blob: {relative}")

project_definition = (root / "project.yml").read_text(encoding="utf-8")
for required_fragment in (
    "Distribution: Config/ForgePlayDistribution.xcconfig",
    "Distribution: Config/ForgePlayNetworkControlHelperDistribution.xcconfig",
    '"$SRCROOT/Scripts/sign-app-store-runtime-code.sh"',
    '"$SRCROOT/Scripts/prepare-game-mode-host-build-identity.sh"',
    "Sources/ForgePlay/ForgePlay-Runtime-Inherit.entitlements",
    "Sources/ForgePlay/ForgePlay-Runtime-Direct.entitlements",
    "Resources/PublicDistributionBuildClaim.json",
    "Native/NetworkControlHelper/ForgePlayNetworkControl.plist",
    "Native/NetworkControlHelper/main.swift",
    '/usr/bin/install -m 0444 "$claim_source" "$claim_destination"',
):
    if required_fragment not in project_definition:
        raise SystemExit(f"Distribution project graph is missing: {required_fragment}")

source_identity = json.loads(
    (root / "Config/ForgePlayRuntimeSourceIdentity.lock.json").read_text(encoding="utf-8")
)
provenance = json.loads(
    (root / "Config/ForgePlayRuntimePatchProvenance.lock.json").read_text(encoding="utf-8")
)
runtime_manifest = json.loads(
    (root / "Resources/Runners/ForgePlayRuntime/RuntimeManifest.json").read_text(encoding="utf-8")
)
current = source_identity.get("currentFinalPatchedSourceTree", {})
if source_identity.get("schemaVersion") != 2:
    raise SystemExit("current source identity schema is unsupported")
if current.get("sha256") != provenance.get("upstreamSource", {}).get("patchedSourceTreeSHA256"):
    raise SystemExit("current source identity is not bound to patch provenance")
if current.get("sha256") != runtime_manifest.get("sourceTreeSHA256"):
    raise SystemExit("current final source identity is not shared by the Runtime manifest")
PY

for localization in en ko es de ja zh-Hans zh-Hant fr; do
  for localized_file in InfoPlist.strings Localizable.strings ForgePlayLicenseNotice.md; do
    path="$EXPORT_ROOT/Resources/$localization.lproj/$localized_file"
    [[ -f "$path" && ! -L "$path" ]] ||
      fail "missing localized source resource: $localization.lproj/$localized_file"
  done
done

[[ -f "$EXPORT_ROOT/Resources/CompatibilityDBPublicKey.base64" ]] ||
  fail "public compatibility verification key is missing"
[[ ! -e "$EXPORT_ROOT/Config/ForgePlay.local.xcconfig" ]] ||
  fail "local Xcode configuration was exported"

README_KO="$EXPORT_ROOT/README_KO.md"
README_EN="$EXPORT_ROOT/README_EN.md"
for localized_readme in "$README_KO" "$README_EN"; do
  [[ -f "$localized_readme" && ! -L "$localized_readme" ]] ||
    fail "localized implementation README is missing: $(basename "$localized_readme")"
  grep -Fq 'RTL_USER_PROCESS_PARAMETERS.ImagePathName' "$localized_readme" ||
    fail "localized README does not document the trusted Steam target identity"
  grep -Fq 'GameModeProcessHost' "$localized_readme" ||
    fail "localized README does not document the independent Game Mode host target"
  grep -Fq 'Wine 11.12' "$localized_readme" ||
    fail "localized README does not disclose the Wine-derived loader boundary"
  grep -Fq 'steam_api64.dll' "$localized_readme" ||
    fail "localized README does not distinguish Steam metadata integration from Steamworks"
done

SOURCE_LICENSE_GUIDE="$EXPORT_ROOT/SOURCE-LICENSES.md"
[[ -f "$SOURCE_LICENSE_GUIDE" && ! -L "$SOURCE_LICENSE_GUIDE" ]] ||
  fail "source-license boundary guide is missing"
grep -Fq 'wholeFileSPDX' "$SOURCE_LICENSE_GUIDE" ||
  fail "source-license guide does not explain whole-file GPL assignments"
grep -Fq 'GAME_MODE_SYMBOL_MANIFEST.md' "$SOURCE_LICENSE_GUIDE" ||
  fail "source-license guide does not explain mixed-file GPL boundaries"
grep -Fq 'adjacent `.license` sidecars' "$SOURCE_LICENSE_GUIDE" ||
  fail "source-license guide does not explain hash-preserving patch sidecars"
grep -Fq 'does not by itself apply the Game Mode' \
  "$SOURCE_LICENSE_GUIDE" ||
  fail "source-license guide does not prevent blanket GPL inference"
grep -Fq 'exact release commit' "$SOURCE_LICENSE_GUIDE" ||
  fail "source-license guide does not bind Corresponding Source to the release commit"
grep -Fq 'SOURCE-INVENTORY.json' "$SOURCE_LICENSE_GUIDE" ||
  fail "source-license guide does not document the exact release inventory"
grep -Fq 'PublicDistributionBuildClaim.json' "$SOURCE_LICENSE_GUIDE" ||
  fail "source-license guide does not document the unsigned public archive claim"
grep -Fq 'unsigned build claim awaiting release attestation' "$SOURCE_LICENSE_GUIDE" ||
  fail "source-license guide does not distinguish a reproducible candidate from an official release"

grep -Fq -- '--public-source-package' \
  "$EXPORT_ROOT/Scripts/package-forgeplay-runtime.sh" ||
  fail "public package command graph is unavailable"
grep -Fq 'public-source package mode requires FORGEPLAY_RUNTIME_POLICY_SOURCE' \
  "$EXPORT_ROOT/Scripts/package-forgeplay-runtime.sh" ||
  fail "public package command graph has an implicit private Runtime policy input"
grep -Fq 'ForgePlayRuntimeSourceIdentity.lock.json' \
  "$EXPORT_ROOT/Scripts/materialize-forgeplay-wine-11.12-source.sh" ||
  fail "Wine source materializer does not enforce the current final source identity"

python3 "$EXPORT_ROOT/Scripts/verify-game-mode-source-licenses.py" \
  "$EXPORT_ROOT" ||
  fail "Game Mode source-license scope verification failed"
python3 "$EXPORT_ROOT/Scripts/verify-forgeplay-runtime-patch-provenance.py" \
  --lock "$EXPORT_ROOT/Config/ForgePlayRuntimePatchProvenance.lock.json" \
  --source-identity-lock "$EXPORT_ROOT/Config/ForgePlayRuntimeSourceIdentity.lock.json" \
  --patch-root "$EXPORT_ROOT/Resources/Runners/ForgePlayRuntime/Patches" \
  --export-license-inventory ||
  fail "Wine patch/license provenance verification failed"

if [[ "$VERIFICATION_MODE" == "release-authority" ]]; then
  printf 'Open-source export release-authority verification passed: %s\n' "$EXPORT_ROOT"
else
  printf 'Open-source export recipient self-check passed (non-authoritative): %s\n' "$EXPORT_ROOT"
fi
