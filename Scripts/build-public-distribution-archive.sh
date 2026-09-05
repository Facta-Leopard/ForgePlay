#!/bin/bash
set -euo pipefail

readonly FORGEPLAY_SYSTEM_TOOL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PATH="$FORGEPLAY_SYSTEM_TOOL_PATH"
export PATH
unset CDPATH

SOURCE_EXPORT=""
TRUSTED_GIT_REPOSITORY=""
WORKSPACE=""
RUNTIME_OUTPUT=""
LOCAL_XCCONFIG=""
ARCHIVE_PATH=""
DERIVED_DATA_PATH=""
LOG_PATH=""
SCHEME="ForgePlayDMG"
CONFIGURATION="Distribution"
SIGNING_STYLE="Automatic"
CODE_SIGN_IDENTITY=""
MARKETING_VERSION=""
BUILD_NUMBER=""

fail() {
  printf 'error: public Distribution archive failed: %s\n' "$*" >&2
  exit 1
}

require_absolute_directory() {
  local candidate="$1"
  local label="$2"
  [[ "$candidate" = /* && -d "$candidate" && ! -L "$candidate" &&
     "$(cd "$candidate" && /bin/pwd -P)" == "$candidate" ]] ||
    fail "$label must be an exact absolute non-symlink directory: $candidate"
}

require_absolute_output() {
  local candidate="$1"
  local label="$2"
  local parent
  [[ "$candidate" = /* && "$candidate" != */../* && "$candidate" != */./* ]] ||
    fail "$label must be an absolute normalized path"
  parent="$(/usr/bin/dirname "$candidate")"
  require_absolute_directory "$parent" "$label parent"
  [[ ! -e "$candidate" && ! -L "$candidate" ]] ||
    fail "$label must not exist before the public build: $candidate"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --source-export) SOURCE_EXPORT="${2:-}"; shift 2 ;;
    --trusted-git-repository) TRUSTED_GIT_REPOSITORY="${2:-}"; shift 2 ;;
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --runtime-output) RUNTIME_OUTPUT="${2:-}"; shift 2 ;;
    --local-xcconfig) LOCAL_XCCONFIG="${2:-}"; shift 2 ;;
    --archive-path) ARCHIVE_PATH="${2:-}"; shift 2 ;;
    --derived-data-path) DERIVED_DATA_PATH="${2:-}"; shift 2 ;;
    --log) LOG_PATH="${2:-}"; shift 2 ;;
    --scheme) SCHEME="${2:-}"; shift 2 ;;
    --configuration) CONFIGURATION="${2:-}"; shift 2 ;;
    --signing-style) SIGNING_STYLE="${2:-}"; shift 2 ;;
    --code-sign-identity) CODE_SIGN_IDENTITY="${2:-}"; shift 2 ;;
    --marketing-version) MARKETING_VERSION="${2:-}"; shift 2 ;;
    --build-number) BUILD_NUMBER="${2:-}"; shift 2 ;;
    *) fail "unknown or incomplete option: $1" ;;
  esac
done

[[ -n "$SOURCE_EXPORT" && -n "$TRUSTED_GIT_REPOSITORY" &&
   -n "$WORKSPACE" && -n "$RUNTIME_OUTPUT" &&
   -n "$ARCHIVE_PATH" && -n "$DERIVED_DATA_PATH" && -n "$LOG_PATH" &&
   -n "$MARKETING_VERSION" && -n "$BUILD_NUMBER" ]] ||
  fail "source export, workspace, Runtime payload, archive, DerivedData, log, marketing version, and build number are required"
[[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] ||
  fail "marketing version must contain two or three numeric components"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] ||
  fail "build number must be a positive integer"
[[ "$SCHEME" == "ForgePlayDMG" && "$CONFIGURATION" == "Distribution" ]] ||
  fail "public binary must use the ForgePlayDMG/Distribution command graph"
case "$(printf '%s' "$SIGNING_STYLE" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
  automatic) SIGNING_STYLE="Automatic" ;;
  manual) SIGNING_STYLE="Manual" ;;
  *) fail "signing style must be Automatic or Manual" ;;
esac
if [[ "$SIGNING_STYLE" == "Manual" ]]; then
  [[ -n "$CODE_SIGN_IDENTITY" ]] || fail "manual signing requires a code-sign identity"
else
  [[ -z "$CODE_SIGN_IDENTITY" ]] || fail "automatic signing cannot accept a manual identity"
fi

require_absolute_directory "$SOURCE_EXPORT" "public source export"
require_absolute_directory "$TRUSTED_GIT_REPOSITORY" "trusted Git repository"
require_absolute_directory "$RUNTIME_OUTPUT" "public Runtime output"
require_absolute_output "$WORKSPACE" "public build workspace"
require_absolute_output "$ARCHIVE_PATH" "archive output"
[[ "$DERIVED_DATA_PATH" = /* && ! -L "$DERIVED_DATA_PATH" ]] ||
  fail "DerivedData path must be absolute and non-symlink"
[[ "$LOG_PATH" = /* && -f "$LOG_PATH" && ! -L "$LOG_PATH" ]] ||
  fail "archive log must be an existing absolute non-symlink file"
if [[ -n "$LOCAL_XCCONFIG" ]]; then
  [[ "$LOCAL_XCCONFIG" = /* && -f "$LOCAL_XCCONFIG" && ! -L "$LOCAL_XCCONFIG" ]] ||
    fail "local Xcode configuration must be an absolute non-symlink regular file"
fi

EXPORT_VERIFIER="$SOURCE_EXPORT/Scripts/verify-open-source-export.sh"
GENERATOR="$SOURCE_EXPORT/Scripts/generate-xcode-project.sh"
RUNTIME_RECEIPT_VERIFIER="$SOURCE_EXPORT/Scripts/verify-public-runtime-build-receipt.py"
[[ -f "$EXPORT_VERIFIER" && ! -L "$EXPORT_VERIFIER" ]] ||
  fail "exported source verifier is unavailable"
[[ -f "$GENERATOR" && ! -L "$GENERATOR" ]] ||
  fail "exported Xcode project generator is unavailable"
[[ -f "$RUNTIME_RECEIPT_VERIFIER" && ! -L "$RUNTIME_RECEIPT_VERIFIER" ]] ||
  fail "exported public Runtime receipt verifier is unavailable"

/usr/bin/python3 - "$SOURCE_EXPORT" "$TRUSTED_GIT_REPOSITORY" "$RUNTIME_OUTPUT" <<'PY'
import os
import sys

source, trusted, runtime = map(os.path.normpath, sys.argv[1:])
if os.path.commonpath([source, runtime]) in {source, runtime}:
    raise SystemExit("public Runtime output must be disjoint from the source export")
if os.path.commonpath([trusted, runtime]) in {trusted, runtime}:
    raise SystemExit("public Runtime output must be disjoint from the trusted Git repository")
PY

# This is the production gate: the pristine input is verified before any
# release-only Runtime or local signing information is overlaid.
/bin/bash "$EXPORT_VERIFIER" \
  --project-root "$SOURCE_EXPORT" \
  --release-authority \
  --trusted-git-repository "$TRUSTED_GIT_REPOSITORY" \
  "$SOURCE_EXPORT"
/usr/bin/python3 "$RUNTIME_RECEIPT_VERIFIER" verify-runtime \
  --runtime-root "$RUNTIME_OUTPUT" \
  --source-inventory "$SOURCE_EXPORT/SOURCE-INVENTORY.json" ||
  fail "Runtime output is not bound to this exact public source build transaction"

/bin/mkdir -m 700 "$WORKSPACE"
/usr/bin/ditto "$SOURCE_EXPORT" "$WORKSPACE"

verify_inventory_bound_files() {
  /usr/bin/python3 - "$WORKSPACE" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1])
inventory = json.loads((root / "SOURCE-INVENTORY.json").read_text(encoding="utf-8"))
if not isinstance(inventory, dict) or inventory.get("schemaVersion") != 2:
    raise SystemExit("public build requires source inventory schema 2")
entries = inventory.get("entries")
if not isinstance(entries, list):
    raise SystemExit("public source inventory entries are invalid")
seen = set()
for row in entries:
    if not isinstance(row, dict) or set(row) != {"byteLength", "mode", "origin", "path", "sha256"}:
        raise SystemExit("public source inventory row is invalid")
    relative = row["path"]
    parsed = PurePosixPath(relative) if isinstance(relative, str) else None
    if parsed is None or parsed.is_absolute() or relative != parsed.as_posix() or any(
        part in {"", ".", ".."} for part in parsed.parts
    ) or relative in seen:
        raise SystemExit("public source inventory path is unsafe or duplicate")
    seen.add(relative)
    path = root / relative
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise SystemExit(f"public build input is not a single-link file: {relative}")
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            digest.update(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    identity = lambda value: (
        value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
        value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    )
    if identity(before) != identity(after):
        raise SystemExit(f"public build input changed while hashing: {relative}")
    if (
        total != row["byteLength"]
        or digest.hexdigest() != row["sha256"]
        or f"100{stat.S_IMODE(before.st_mode):03o}" != row["mode"]
    ):
        raise SystemExit(f"public build input differs from exported source: {relative}")
allowed_additions = {
    "SOURCE-INVENTORY.json",
    "Config/ForgePlay.local.xcconfig",
    "Resources/PublicDistributionBuildClaim.json",
}
for path in root.rglob("*"):
    relative = path.relative_to(root).as_posix()
    if path.is_symlink():
        if relative.startswith("Resources/Runners/"):
            continue
        raise SystemExit(f"public build graph contains a symlink: {relative}")
    if not path.is_file():
        continue
    if (
        relative not in seen
        and relative not in allowed_additions
        and not relative.startswith("Resources/Runners/")
    ):
        raise SystemExit(f"public build graph contains an unbound addition: {relative}")
PY
}

verify_inventory_bound_files
/usr/bin/ditto "$RUNTIME_OUTPUT" "$WORKSPACE/Resources/Runners/ForgePlayRuntime"
if [[ -n "$LOCAL_XCCONFIG" ]]; then
  /usr/bin/ditto "$LOCAL_XCCONFIG" "$WORKSPACE/Config/ForgePlay.local.xcconfig"
fi
# The Runtime overlay may add distributable payload bytes, including D3DMetal,
# but it may not replace any source/inventory-bound file.
verify_inventory_bound_files

(
  cd "$WORKSPACE"
  /bin/bash Scripts/generate-xcode-project.sh
)
# The archive consumes the exported generated project only when regeneration
# from the exact public graph is byte-for-byte identical to the inventory.
verify_inventory_bound_files

CLAIM_PATH="$WORKSPACE/Resources/PublicDistributionBuildClaim.json"
[[ ! -e "$CLAIM_PATH" && ! -L "$CLAIM_PATH" ]] ||
  fail "public Distribution build claim path is already occupied"
RUNTIME_BUILD_CLAIM_SHA256="$(/usr/bin/shasum -a 256 \
  "$RUNTIME_OUTPUT/PublicRuntimeBuildClaim.json" | /usr/bin/awk '{print $1}')" ||
  fail "public Runtime build claim identity is unavailable"
/usr/bin/python3 - "$WORKSPACE" "$SCHEME" "$CONFIGURATION" \
  "$RUNTIME_BUILD_CLAIM_SHA256" <<'PY'
import json
import os
import re
import sys
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1])
scheme = sys.argv[2]
configuration = sys.argv[3]
runtime_build_claim_sha256 = sys.argv[4]
if re.fullmatch(r"[0-9a-f]{64}", runtime_build_claim_sha256) is None:
    raise SystemExit("public Runtime build claim digest is invalid")
inventory = json.loads((root / "SOURCE-INVENTORY.json").read_text(encoding="utf-8"))
graph = json.loads(
    (root / "Config/ForgePlayPublicDistributionSourceGraph.json").read_text(encoding="utf-8")
)
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
    or graph["buildClaimResourcePath"] != "Resources/PublicDistributionBuildClaim.json"
    or graph["runtimePayloadInjectionRoot"] != "Resources/Runners"
    or graph["excludedThirdPartyPayloadRoots"]
    != ["Resources/Runners/ForgePlayRuntime/Frameworks/renderer/d3dmetal"]
):
    raise SystemExit("public Distribution source graph boundaries are invalid")
rows = {row.get("path"): row for row in inventory.get("entries", []) if isinstance(row, dict)}
required = graph["requiredReleaseCommitPaths"]
if not isinstance(required, list) or not required or len(required) != len(set(required)):
    raise SystemExit("public Distribution required graph is invalid")
bound = []
for relative in required:
    parsed = PurePosixPath(relative) if isinstance(relative, str) else None
    if parsed is None or parsed.is_absolute() or relative != parsed.as_posix() or any(
        part in {"", ".", ".."} for part in parsed.parts
    ):
        raise SystemExit("public Distribution graph path is unsafe")
    row = rows.get(relative)
    origin = row.get("origin") if isinstance(row, dict) else None
    if (
        not isinstance(origin, dict)
        or origin.get("classification") != "release-commit-blob"
        or origin.get("sourcePath") != relative
        or origin.get("destinationPath") != relative
        or origin.get("sha256") != row.get("sha256")
        or origin.get("gitMode") != row.get("mode")
    ):
        raise SystemExit(f"public Distribution graph is not an exact release blob: {relative}")
    bound.append(
        {
            "gitMode": origin["gitMode"],
            "gitObjectID": origin["gitObjectID"],
            "path": relative,
            "sha256": row["sha256"],
        }
    )
payload = {
    "archiveCommandPath": graph["archiveCommandPath"],
    "claimStatus": "unsigned build claim awaiting release attestation",
    "configuration": configuration,
    "excludedThirdPartyPayloadRoots": graph["excludedThirdPartyPayloadRoots"],
    "releaseCommit": inventory["releaseCommit"],
    "requiredSourceGraph": bound,
    "runtimePayloadInjectionRoot": graph["runtimePayloadInjectionRoot"],
    "runtimeBuildClaimSHA256": runtime_build_claim_sha256,
    "schemaVersion": 2,
    "scheme": scheme,
    "sourceInventorySHA256": inventory["inventorySHA256"],
}
destination = root / graph["buildClaimResourcePath"]
descriptor = os.open(
    destination,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
    0o644,
)
try:
    payload_bytes = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    view = memoryview(payload_bytes)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise SystemExit("public Distribution build claim write made no progress")
        view = view[written:]
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
verify_inventory_bound_files

XCODEBUILD_TOOL="/usr/bin/xcodebuild"
if [[ "${FORGEPLAY_PUBLIC_ARCHIVE_TEST_MODE:-0}" == "1" ]]; then
  XCODEBUILD_TOOL="${FORGEPLAY_PUBLIC_ARCHIVE_XCODEBUILD:-}"
  [[ "$XCODEBUILD_TOOL" = /* && -x "$XCODEBUILD_TOOL" && ! -L "$XCODEBUILD_TOOL" ]] ||
    fail "test-mode xcodebuild fixture must be an absolute non-symlink executable"
else
  [[ -x "$XCODEBUILD_TOOL" && ! -L "$XCODEBUILD_TOOL" ]] ||
    fail "system xcodebuild is unavailable"
fi

XCODEBUILD_ARGUMENTS=(
  archive
  -project "$WORKSPACE/ForgePlay.xcodeproj"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  "CODE_SIGN_STYLE=$SIGNING_STYLE"
  "FORGEPLAY_MARKETING_VERSION=$MARKETING_VERSION"
  "FORGEPLAY_CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
  "MARKETING_VERSION=$MARKETING_VERSION"
  "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
  "OTHER_CODE_SIGN_FLAGS=--timestamp"
  -derivedDataPath "$DERIVED_DATA_PATH"
)
if [[ -n "$CODE_SIGN_IDENTITY" ]]; then
  XCODEBUILD_ARGUMENTS+=("CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY")
fi

if ! "$XCODEBUILD_TOOL" "${XCODEBUILD_ARGUMENTS[@]}" >"$LOG_PATH" 2>&1; then
  exit 1
fi
[[ -d "$ARCHIVE_PATH" && ! -L "$ARCHIVE_PATH" ]] ||
  fail "xcodebuild did not create the requested archive"
ARCHIVED_CLAIM="$ARCHIVE_PATH/Products/Applications/ForgePlay.app/Contents/Resources/PublicDistributionBuildClaim.json"
[[ -f "$ARCHIVED_CLAIM" && ! -L "$ARCHIVED_CLAIM" ]] ||
  fail "archive omitted the public Distribution build claim resource"
/usr/bin/cmp -s "$CLAIM_PATH" "$ARCHIVED_CLAIM" ||
  fail "archive changed the public Distribution build claim resource"
ARCHIVED_INFO="$ARCHIVE_PATH/Products/Applications/ForgePlay.app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ARCHIVED_INFO")" == "$MARKETING_VERSION" ]] ||
  fail "archive marketing version does not match the requested release"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ARCHIVED_INFO")" == "$BUILD_NUMBER" ]] ||
  fail "archive build number does not match the requested release"

printf 'Public-source Distribution archive built: %s\n' "$ARCHIVE_PATH"
