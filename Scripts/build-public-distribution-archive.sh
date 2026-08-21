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
ARCHIVE_PATH=""
DERIVED_DATA_PATH=""
LOG_PATH=""
SCHEME="ForgePlayDMG"
CONFIGURATION="Distribution"
SIGNING_STYLE="Automatic"
CODE_SIGN_IDENTITY=""
DEVELOPMENT_TEAM=""
CANONICAL_BUNDLE_IDENTIFIER="com.forgeplay.client"
CANONICAL_MARKETING_VERSION="1.1"
CANONICAL_BUILD_NUMBER="2"
RUNTIME_DESTINATION_RELATIVE="Resources/Runners/ForgePlayRuntime"

fail() {
  printf 'error: public Distribution archive failed: %s\n' "$*" >&2
  exit 1
}

stable_file_sha256() {
  local file_path="$1"
  local label="$2"
  local maximum_bytes="$3"
  /usr/bin/python3 - "$file_path" "$label" "$maximum_bytes" <<'PY'
import hashlib
import os
import stat
import sys

file_path, label, maximum_bytes_raw = sys.argv[1:]
try:
    maximum_bytes = int(maximum_bytes_raw)
except ValueError:
    raise SystemExit(f"{label} size bound is invalid")
if (
    not os.path.isabs(file_path)
    or os.path.normpath(file_path) != file_path
    or maximum_bytes <= 0
):
    raise SystemExit(f"{label} path or size bound is invalid")
descriptor = os.open(
    file_path,
    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
)
try:
    before = os.fstat(descriptor)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_uid != os.geteuid()
        or before.st_mode & (stat.S_IWGRP | stat.S_IWOTH | stat.S_ISUID | stat.S_ISGID)
        or before.st_size < 0
        or before.st_size > maximum_bytes
    ):
        raise SystemExit(f"{label} is not a safe single-link regular file")
    digest = hashlib.sha256()
    offset = 0
    while offset < before.st_size:
        chunk = os.pread(descriptor, min(1024 * 1024, before.st_size - offset), offset)
        if not chunk:
            raise SystemExit(f"{label} became incomplete while being read")
        digest.update(chunk)
        offset += len(chunk)
    after = os.fstat(descriptor)
finally:
    os.close(descriptor)
identity = lambda value: (
    value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
    value.st_size, value.st_mtime_ns, value.st_ctime_ns, value.st_uid,
)
if identity(before) != identity(after):
    raise SystemExit(f"{label} changed while being read")
print(digest.hexdigest())
PY
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
    --archive-path) ARCHIVE_PATH="${2:-}"; shift 2 ;;
    --derived-data-path) DERIVED_DATA_PATH="${2:-}"; shift 2 ;;
    --log) LOG_PATH="${2:-}"; shift 2 ;;
    --scheme) SCHEME="${2:-}"; shift 2 ;;
    --configuration) CONFIGURATION="${2:-}"; shift 2 ;;
    --signing-style) SIGNING_STYLE="${2:-}"; shift 2 ;;
    --code-sign-identity) CODE_SIGN_IDENTITY="${2:-}"; shift 2 ;;
    --development-team) DEVELOPMENT_TEAM="${2:-}"; shift 2 ;;
    *) fail "unknown or incomplete option: $1" ;;
  esac
done

[[ -n "$SOURCE_EXPORT" && -n "$TRUSTED_GIT_REPOSITORY" &&
   -n "$WORKSPACE" && -n "$RUNTIME_OUTPUT" &&
   -n "$ARCHIVE_PATH" && -n "$DERIVED_DATA_PATH" && -n "$LOG_PATH" &&
   -n "$DEVELOPMENT_TEAM" ]] ||
  fail "source export, workspace, Runtime payload, archive, DerivedData, log, and development team are required"
[[ "$SCHEME" == "ForgePlayDMG" && "$CONFIGURATION" == "Distribution" ]] ||
  fail "public binary must use the ForgePlayDMG/Distribution command graph"
[[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] ||
  fail "development team must be a 10-character Apple team identifier"
case "$(printf '%s' "$SIGNING_STYLE" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
  automatic) SIGNING_STYLE="Automatic" ;;
  manual) SIGNING_STYLE="Manual" ;;
  *) fail "signing style must be Automatic or Manual" ;;
esac
if [[ "$SIGNING_STYLE" == "Manual" ]]; then
  [[ -n "$CODE_SIGN_IDENTITY" ]] || fail "manual signing requires a code-sign identity"
  [[ "$CODE_SIGN_IDENTITY" == "Developer ID Application: "*" ($DEVELOPMENT_TEAM)" ]] ||
    fail "manual signing identity must be an exact Developer ID Application identity for $DEVELOPMENT_TEAM"
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

EXPORT_VERIFIER="$SOURCE_EXPORT/Scripts/verify-open-source-export.sh"
GENERATOR="$SOURCE_EXPORT/Scripts/generate-xcode-project.sh"
RUNTIME_RECEIPT_VERIFIER="$SOURCE_EXPORT/Scripts/verify-public-runtime-build-receipt.py"
RUNTIME_CAPABILITY_VERIFIER="$SOURCE_EXPORT/Scripts/verify-bundled-runtime-capability.sh"
OWNED_DIRECTORY_QUARANTINE_TOOL="$SOURCE_EXPORT/Scripts/quarantine-owned-directory.py"
[[ -f "$EXPORT_VERIFIER" && ! -L "$EXPORT_VERIFIER" ]] ||
  fail "exported source verifier is unavailable"
[[ -f "$GENERATOR" && ! -L "$GENERATOR" ]] ||
  fail "exported Xcode project generator is unavailable"
[[ -f "$RUNTIME_RECEIPT_VERIFIER" && ! -L "$RUNTIME_RECEIPT_VERIFIER" ]] ||
  fail "exported public Runtime receipt verifier is unavailable"
[[ -f "$RUNTIME_CAPABILITY_VERIFIER" && ! -L "$RUNTIME_CAPABILITY_VERIFIER" ]] ||
  fail "exported public Runtime inventory verifier is unavailable"
[[ -f "$OWNED_DIRECTORY_QUARANTINE_TOOL" && ! -L "$OWNED_DIRECTORY_QUARANTINE_TOOL" ]] ||
  fail "exported owned-directory quarantine tool is unavailable"

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
SOURCE_INVENTORY_PREVERIFY_SHA256="$(stable_file_sha256 \
  "$SOURCE_EXPORT/SOURCE-INVENTORY.json" \
  "public source inventory" \
  134217728)" ||
  fail "public source inventory could not be pinned before verification"
/bin/bash "$EXPORT_VERIFIER" \
  --project-root "$SOURCE_EXPORT" \
  --release-authority \
  --trusted-git-repository "$TRUSTED_GIT_REPOSITORY" \
  "$SOURCE_EXPORT"
VERIFIED_SOURCE_INVENTORY_SHA256="$(stable_file_sha256 \
  "$SOURCE_EXPORT/SOURCE-INVENTORY.json" \
  "verified public source inventory" \
  134217728)" ||
  fail "verified public source inventory identity is unavailable"
[[ "$VERIFIED_SOURCE_INVENTORY_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  fail "verified public source inventory identity is invalid"
[[ "$VERIFIED_SOURCE_INVENTORY_SHA256" == "$SOURCE_INVENTORY_PREVERIFY_SHA256" ]] ||
  fail "public source inventory changed during release-authority verification"
RUNTIME_BUILD_CLAIM_PREVERIFY_SHA256="$(stable_file_sha256 \
  "$RUNTIME_OUTPUT/PublicRuntimeBuildClaim.json" \
  "public Runtime build claim" \
  16777216)" ||
  fail "public Runtime build claim could not be pinned before verification"
/usr/bin/python3 "$RUNTIME_RECEIPT_VERIFIER" verify-runtime \
  --runtime-root "$RUNTIME_OUTPUT" \
  --source-inventory "$SOURCE_EXPORT/SOURCE-INVENTORY.json" ||
  fail "Runtime output is not bound to this exact public source build transaction"
/bin/bash "$RUNTIME_CAPABILITY_VERIFIER" \
  --verify-runtime-file-inventory \
  "$RUNTIME_OUTPUT" \
  "$RUNTIME_OUTPUT/RuntimeFileInventory.json" ||
  fail "Runtime output differs from its raw complete file inventory"
/bin/bash "$RUNTIME_CAPABILITY_VERIFIER" \
  --release-runtime-inventory-only \
  "$RUNTIME_OUTPUT" ||
  fail "Runtime output differs from its complete file inventory or payload locks"
VERIFIED_RUNTIME_BUILD_CLAIM_SHA256="$(stable_file_sha256 \
  "$RUNTIME_OUTPUT/PublicRuntimeBuildClaim.json" \
  "verified public Runtime build claim" \
  16777216)" ||
  fail "verified public Runtime build claim identity is unavailable"
[[ "$VERIFIED_RUNTIME_BUILD_CLAIM_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  fail "verified public Runtime build claim identity is invalid"
[[ "$VERIFIED_RUNTIME_BUILD_CLAIM_SHA256" == "$RUNTIME_BUILD_CLAIM_PREVERIFY_SHA256" ]] ||
  fail "public Runtime build claim changed during Runtime verification"

/bin/mkdir -m 700 "$WORKSPACE"
/usr/bin/ditto "$SOURCE_EXPORT" "$WORKSPACE"

verify_inventory_bound_files() {
  local ownership_mode="$1"
  /usr/bin/python3 - \
    "$WORKSPACE" \
    "$ownership_mode" \
    "$RUNTIME_DESTINATION_RELATIVE" \
    "$VERIFIED_SOURCE_INVENTORY_SHA256" <<'PY'
import hashlib
import json
import os
import stat
import sys
from pathlib import Path, PurePosixPath

root = Path(sys.argv[1])
ownership_mode = sys.argv[2]
runtime_relative = sys.argv[3]
expected_inventory_sha256 = sys.argv[4]
if ownership_mode not in {"pristine-source", "runtime-overlay"}:
    raise SystemExit("public build ownership mode is invalid")
runtime_path = PurePosixPath(runtime_relative)
if (
    runtime_path.is_absolute()
    or runtime_relative != runtime_path.as_posix()
    or any(part in {"", ".", ".."} for part in runtime_path.parts)
    or runtime_relative != "Resources/Runners/ForgePlayRuntime"
):
    raise SystemExit("public Runtime destination is invalid")
if (
    len(expected_inventory_sha256) != 64
    or any(character not in "0123456789abcdef" for character in expected_inventory_sha256)
):
    raise SystemExit("verified public source inventory identity is invalid")


def metadata_identity(value):
    return (
        value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
        value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    )


inventory_path = root / "SOURCE-INVENTORY.json"
inventory_descriptor = os.open(
    inventory_path,
    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
)
try:
    inventory_before = os.fstat(inventory_descriptor)
    if (
        not stat.S_ISREG(inventory_before.st_mode)
        or inventory_before.st_nlink != 1
        or inventory_before.st_size < 0
        or inventory_before.st_size > 128 * 1024 * 1024
    ):
        raise SystemExit("public source inventory is not a safe single-link file")
    inventory_raw = bytearray()
    while len(inventory_raw) < inventory_before.st_size:
        chunk = os.read(
            inventory_descriptor,
            min(1024 * 1024, inventory_before.st_size - len(inventory_raw)),
        )
        if not chunk:
            raise SystemExit("public source inventory became incomplete while being read")
        inventory_raw.extend(chunk)
    inventory_after = os.fstat(inventory_descriptor)
finally:
    os.close(inventory_descriptor)
if metadata_identity(inventory_before) != metadata_identity(inventory_after):
    raise SystemExit("public source inventory changed while being read")
if hashlib.sha256(inventory_raw).hexdigest() != expected_inventory_sha256:
    raise SystemExit("public build source inventory differs from the verified export")
inventory = json.loads(inventory_raw.decode("utf-8"))
if not isinstance(inventory, dict) or inventory.get("schemaVersion") != 2:
    raise SystemExit("public build requires source inventory schema 2")
entries = inventory.get("entries")
if not isinstance(entries, list):
    raise SystemExit("public source inventory entries are invalid")
seen = set()


def is_runtime_owned(relative):
    return relative == runtime_relative or relative.startswith(f"{runtime_relative}/")


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
    if ownership_mode == "runtime-overlay" and is_runtime_owned(relative):
        continue
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
    if metadata_identity(before) != metadata_identity(after):
        raise SystemExit(f"public build input changed while hashing: {relative}")
    if (
        total != row["byteLength"]
        or digest.hexdigest() != row["sha256"]
        or f"100{stat.S_IMODE(before.st_mode):03o}" != row["mode"]
    ):
        raise SystemExit(f"public build input differs from exported source: {relative}")
allowed_additions = {
    "SOURCE-INVENTORY.json",
    "Resources/PublicDistributionBuildClaim.json",
}
for path in root.rglob("*"):
    relative = path.relative_to(root).as_posix()
    metadata = path.lstat()
    if ownership_mode == "runtime-overlay" and is_runtime_owned(relative):
        continue
    if stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(f"public build graph contains a symlink: {relative}")
    if stat.S_ISDIR(metadata.st_mode):
        continue
    if not stat.S_ISREG(metadata.st_mode):
        raise SystemExit(f"public build graph contains an unsupported entry: {relative}")
    if metadata.st_nlink != 1:
        raise SystemExit(f"public build graph contains a hardlinked file: {relative}")
    if (
        relative not in seen
        and relative not in allowed_additions
        and not (ownership_mode == "runtime-overlay" and is_runtime_owned(relative))
    ):
        raise SystemExit(f"public build graph contains an unbound addition: {relative}")
PY
}

verify_runtime_owned_files() {
  local runtime_root="$1"
  local runtime_build_claim_sha256
  /bin/bash "$WORKSPACE_RUNTIME_CAPABILITY_VERIFIER" \
    --verify-runtime-file-inventory \
    "$runtime_root" \
    "$runtime_root/RuntimeFileInventory.json" ||
    fail "public build Runtime differs from its raw complete file inventory"
  /bin/bash "$WORKSPACE_RUNTIME_CAPABILITY_VERIFIER" \
    --release-runtime-inventory-only \
    "$runtime_root" ||
    fail "public build Runtime differs from its complete file inventory or payload locks"
  /usr/bin/python3 "$WORKSPACE_RUNTIME_RECEIPT_VERIFIER" verify-runtime \
    --runtime-root "$runtime_root" \
    --source-inventory "$WORKSPACE_SOURCE_INVENTORY" ||
    fail "public build Runtime is not bound to this exact public source build transaction"
  runtime_build_claim_sha256="$(stable_file_sha256 \
    "$runtime_root/PublicRuntimeBuildClaim.json" \
    "public build Runtime claim" \
    16777216)" ||
    fail "public build Runtime claim identity is unavailable"
  [[ "$runtime_build_claim_sha256" == "$VERIFIED_RUNTIME_BUILD_CLAIM_SHA256" ]] ||
    fail "public build Runtime claim differs from the verified Runtime output"
}

verify_overlaid_public_build_inputs() {
  verify_inventory_bound_files "runtime-overlay"
  verify_runtime_owned_files "$WORKSPACE/$RUNTIME_DESTINATION_RELATIVE"
}

verify_inventory_bound_files "pristine-source"
WORKSPACE_SOURCE_INVENTORY="$WORKSPACE/SOURCE-INVENTORY.json"
WORKSPACE_RUNTIME_RECEIPT_VERIFIER="$WORKSPACE/Scripts/verify-public-runtime-build-receipt.py"
WORKSPACE_RUNTIME_CAPABILITY_VERIFIER="$WORKSPACE/Scripts/verify-bundled-runtime-capability.sh"
WORKSPACE_OWNED_DIRECTORY_QUARANTINE_TOOL="$WORKSPACE/Scripts/quarantine-owned-directory.py"
for workspace_tool in \
  "$WORKSPACE_RUNTIME_RECEIPT_VERIFIER" \
  "$WORKSPACE_RUNTIME_CAPABILITY_VERIFIER" \
  "$WORKSPACE_OWNED_DIRECTORY_QUARANTINE_TOOL"; do
  [[ -f "$workspace_tool" && ! -L "$workspace_tool" ]] ||
    fail "verified public build tool is unavailable: $workspace_tool"
done
RUNTIME_DESTINATION="$WORKSPACE/$RUNTIME_DESTINATION_RELATIVE"
require_absolute_directory \
  "$RUNTIME_DESTINATION" \
  "public source Runtime reference subtree"
# The public source export carries checked-in Runtime reference material and
# source-only license sidecars. The authenticated fresh Runtime is a separate
# exact-tree authority, so replace this leaf instead of merging both owners.
RUNTIME_DESTINATION_PARENT="$(/usr/bin/dirname "$RUNTIME_DESTINATION")"
RUNTIME_DESTINATION_IDENTITY="$(/usr/bin/stat -f '%d:%i' "$RUNTIME_DESTINATION")" ||
  fail "public source Runtime reference subtree identity is unavailable"
RUNTIME_DESTINATION_PARENT_IDENTITY="$(/usr/bin/stat -f '%d:%i' \
  "$RUNTIME_DESTINATION_PARENT")" ||
  fail "public source Runtime reference parent identity is unavailable"
/usr/bin/python3 "$WORKSPACE_OWNED_DIRECTORY_QUARANTINE_TOOL" \
  --tree "$RUNTIME_DESTINATION" \
  --tree-identity "$RUNTIME_DESTINATION_IDENTITY" \
  --parent "$RUNTIME_DESTINATION_PARENT" \
  --parent-identity "$RUNTIME_DESTINATION_PARENT_IDENTITY" \
  --label "public source Runtime reference subtree" ||
  fail "public source Runtime reference subtree could not be quarantine-removed"
[[ ! -e "$RUNTIME_DESTINATION" && ! -L "$RUNTIME_DESTINATION" ]] ||
  fail "public source Runtime reference subtree could not be removed"
/usr/bin/ditto "$RUNTIME_OUTPUT" "$RUNTIME_DESTINATION"
require_absolute_directory "$RUNTIME_DESTINATION" "public build Runtime"
verify_overlaid_public_build_inputs

(
  cd "$WORKSPACE"
  /bin/bash Scripts/generate-xcode-project.sh
)
# The archive consumes the exported generated project only when regeneration
# from the exact public graph is byte-for-byte identical to the inventory.
verify_overlaid_public_build_inputs

CLAIM_PATH="$WORKSPACE/Resources/PublicDistributionBuildClaim.json"
[[ ! -e "$CLAIM_PATH" && ! -L "$CLAIM_PATH" ]] ||
  fail "public Distribution build claim path is already occupied"
RUNTIME_BUILD_CLAIM_SHA256="$(stable_file_sha256 \
  "$RUNTIME_DESTINATION/PublicRuntimeBuildClaim.json" \
  "public build Runtime claim" \
  16777216)" ||
  fail "public build Runtime claim identity is unavailable"
[[ "$RUNTIME_BUILD_CLAIM_SHA256" == "$VERIFIED_RUNTIME_BUILD_CLAIM_SHA256" ]] ||
  fail "public build Runtime claim differs from the verified Runtime output"
GENERATED_DISTRIBUTION_BUILD_CLAIM_SHA256="$(/usr/bin/python3 - \
  "$WORKSPACE" "$SCHEME" "$CONFIGURATION" \
  "$RUNTIME_BUILD_CLAIM_SHA256" <<'PY'
import hashlib
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
    or graph["runtimePayloadInjectionRoot"] != "Resources/Runners/ForgePlayRuntime"
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
print(hashlib.sha256(payload_bytes).hexdigest())
PY
)" || fail "public Distribution build claim could not be created"
[[ "$GENERATED_DISTRIBUTION_BUILD_CLAIM_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  fail "generated public Distribution build claim identity is invalid"
VERIFIED_DISTRIBUTION_BUILD_CLAIM_SHA256="$(stable_file_sha256 \
  "$CLAIM_PATH" \
  "public Distribution build claim" \
  16777216)" ||
  fail "public Distribution build claim identity is unavailable"
[[ "$VERIFIED_DISTRIBUTION_BUILD_CLAIM_SHA256" == \
   "$GENERATED_DISTRIBUTION_BUILD_CLAIM_SHA256" ]] ||
  fail "public Distribution build claim differs from the generated authority"
verify_overlaid_public_build_inputs
POST_VERIFY_DISTRIBUTION_BUILD_CLAIM_SHA256="$(stable_file_sha256 \
  "$CLAIM_PATH" \
  "verified public Distribution build claim" \
  16777216)" ||
  fail "verified public Distribution build claim identity is unavailable"
[[ "$POST_VERIFY_DISTRIBUTION_BUILD_CLAIM_SHA256" == \
   "$VERIFIED_DISTRIBUTION_BUILD_CLAIM_SHA256" ]] ||
  fail "public Distribution build claim changed after creation"

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
  "FORGEPLAY_ALLOW_UNNOTARIZED_DMG=0"
  "FORGEPLAY_APP_BUNDLE_ID=$CANONICAL_BUNDLE_IDENTIFIER"
  "FORGEPLAY_DISTRIBUTION_BUNDLE_ID=$CANONICAL_BUNDLE_IDENTIFIER"
  "FORGEPLAY_MARKETING_VERSION=$CANONICAL_MARKETING_VERSION"
  "FORGEPLAY_CURRENT_PROJECT_VERSION=$CANONICAL_BUILD_NUMBER"
  "MARKETING_VERSION=$CANONICAL_MARKETING_VERSION"
  "CURRENT_PROJECT_VERSION=$CANONICAL_BUILD_NUMBER"
  "FORGEPLAY_DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
  "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
  "FORGEPLAY_CODE_SIGN_STYLE=$SIGNING_STYLE"
  "CODE_SIGN_STYLE=$SIGNING_STYLE"
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
# Xcodebuild must not mutate the pinned source workspace or its raw Runtime
# authority while producing the separately verified signed archive.
verify_overlaid_public_build_inputs
POST_XCODEBUILD_DISTRIBUTION_BUILD_CLAIM_SHA256="$(stable_file_sha256 \
  "$CLAIM_PATH" \
  "post-xcodebuild public Distribution build claim" \
  16777216)" ||
  fail "post-xcodebuild public Distribution build claim identity is unavailable"
[[ "$POST_XCODEBUILD_DISTRIBUTION_BUILD_CLAIM_SHA256" == \
   "$VERIFIED_DISTRIBUTION_BUILD_CLAIM_SHA256" ]] ||
  fail "public Distribution build claim changed after creation"
ARCHIVED_CLAIM="$ARCHIVE_PATH/Products/Applications/ForgePlay.app/Contents/Resources/PublicDistributionBuildClaim.json"
ARCHIVED_RUNTIME="$ARCHIVE_PATH/Products/Applications/ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime"
[[ -f "$ARCHIVED_CLAIM" && ! -L "$ARCHIVED_CLAIM" ]] ||
  fail "archive omitted the public Distribution build claim resource"
ARCHIVED_DISTRIBUTION_BUILD_CLAIM_SHA256="$(stable_file_sha256 \
  "$ARCHIVED_CLAIM" \
  "archived public Distribution build claim" \
  16777216)" ||
  fail "archived public Distribution build claim identity is unavailable"
[[ "$ARCHIVED_DISTRIBUTION_BUILD_CLAIM_SHA256" == \
   "$VERIFIED_DISTRIBUTION_BUILD_CLAIM_SHA256" ]] ||
  fail "archive changed the public Distribution build claim resource"
/usr/bin/cmp -s "$CLAIM_PATH" "$ARCHIVED_CLAIM" ||
  fail "archive changed the public Distribution build claim resource"
/bin/bash "$WORKSPACE_RUNTIME_CAPABILITY_VERIFIER" \
  --release-runtime-inventory-only \
  "$ARCHIVED_RUNTIME" ||
  fail "archive changed the signed-release Runtime inventory or payload locks"
/usr/bin/python3 "$WORKSPACE_RUNTIME_RECEIPT_VERIFIER" verify-runtime \
  --runtime-root "$ARCHIVED_RUNTIME" \
  --source-inventory "$WORKSPACE_SOURCE_INVENTORY" ||
  fail "archived Runtime is not bound to this exact public source build transaction"
ARCHIVED_RUNTIME_BUILD_CLAIM_SHA256="$(stable_file_sha256 \
  "$ARCHIVED_RUNTIME/PublicRuntimeBuildClaim.json" \
  "archived Runtime claim" \
  16777216)" ||
  fail "archived Runtime claim identity is unavailable"
[[ "$ARCHIVED_RUNTIME_BUILD_CLAIM_SHA256" == "$VERIFIED_RUNTIME_BUILD_CLAIM_SHA256" ]] ||
  fail "archived Runtime claim differs from the verified Runtime output"

printf 'Public-source Distribution archive built: %s\n' "$ARCHIVE_PATH"
