#!/bin/bash
set -euo pipefail

readonly FORGEPLAY_SYSTEM_TOOL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PATH="$FORGEPLAY_SYSTEM_TOOL_PATH"
export PATH
unset CDPATH

ROOT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"
DESTINATION="$ROOT_DIR/OpenSource"
DESTINATION_PARENT="$(cd "$(/usr/bin/dirname "$DESTINATION")" && /bin/pwd -P)"
DESTINATION_PARENT_ID="$(/usr/bin/stat -f '%d:%i' "$DESTINATION_PARENT")"
WORK_ROOT="$(/usr/bin/mktemp -d "$DESTINATION_PARENT/.forgeplay-open-source-work.XXXXXXXX")"
STAGED_EXPORT="$(/usr/bin/mktemp -d "$DESTINATION_PARENT/.OpenSource.stage.XXXXXXXX")"
/bin/chmod 700 "$WORK_ROOT" "$STAGED_EXPORT"
WORK_ROOT_ID="$(/usr/bin/stat -f '%d:%i' "$WORK_ROOT")"
STAGED_EXPORT_ID="$(/usr/bin/stat -f '%d:%i' "$STAGED_EXPORT")"
ORIGIN_RECORDS="$STAGED_EXPORT/.forgeplay-export-origins.jsonl"
TRANSACTION_SNAPSHOT="$WORK_ROOT/open-source-export-transaction.py"
QUARANTINE_SNAPSHOT="$WORK_ROOT/quarantine-owned-directory.py"
PUBLISHED=0

fail() {
  printf 'error: open-source export failed: %s\n' "$*" >&2
  exit 1
}

quarantine_cleanup() {
  local owned_path="$1"
  local owned_identity="$2"
  local label="$3"
  [[ -n "$owned_path" && -d "$owned_path" && ! -L "$owned_path" ]] || return 0
  [[ -x "$QUARANTINE_SNAPSHOT" && ! -L "$QUARANTINE_SNAPSHOT" ]] || return 1
  /usr/bin/python3 "$QUARANTINE_SNAPSHOT" \
    --tree "$owned_path" \
    --tree-identity "$owned_identity" \
    --parent "$DESTINATION_PARENT" \
    --parent-identity "$DESTINATION_PARENT_ID" \
    --label "$label"
}

cleanup() {
  local cleanup_failed=0
  if [[ -n "${STAGED_EXPORT:-}" && -d "$STAGED_EXPORT" && ! -L "$STAGED_EXPORT" ]]; then
    quarantine_cleanup \
      "$STAGED_EXPORT" \
      "${STAGED_EXPORT_ID:-}" \
      "OpenSource staging" || cleanup_failed=1
  fi
  if [[ -n "${WORK_ROOT:-}" && -d "$WORK_ROOT" && ! -L "$WORK_ROOT" ]]; then
    quarantine_cleanup \
      "$WORK_ROOT" \
      "${WORK_ROOT_ID:-}" \
      "OpenSource transaction workspace" || cleanup_failed=1
  fi
  if [[ "$cleanup_failed" -ne 0 ]]; then
    printf 'warning: OpenSource publication state is preserved, but private cleanup residue remains recoverable\n' >&2
  fi
  return 0
}
trap cleanup EXIT INT TERM

command -v git >/dev/null 2>&1 || fail "git is required"
command -v xcodegen >/dev/null 2>&1 || fail "xcodegen is required"

RELEASE_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify 'HEAD^{commit}')" ||
  fail "release commit identity is unavailable"
[[ "$RELEASE_COMMIT" =~ ^[0-9a-f]{40,64}$ ]] || fail "release commit identity is invalid"
GIT_OBJECT_FORMAT="$(git -C "$ROOT_DIR" rev-parse --show-object-format)" ||
  fail "Git object format is unavailable"
[[ "$GIT_OBJECT_FORMAT" == "sha1" || "$GIT_OBJECT_FORMAT" == "sha256" ]] ||
  fail "unsupported Git object format: $GIT_OBJECT_FORMAT"
if [[ "$GIT_OBJECT_FORMAT" == "sha1" ]]; then
  [[ "${#RELEASE_COMMIT}" -eq 40 ]] || fail "SHA-1 release commit identity length is invalid"
else
  [[ "${#RELEASE_COMMIT}" -eq 64 ]] || fail "SHA-256 release commit identity length is invalid"
fi

git -C "$ROOT_DIR" diff --quiet --ignore-submodules -- ||
  fail "public Corresponding Source must be exported from a clean release commit"
git -C "$ROOT_DIR" diff --cached --quiet --ignore-submodules -- ||
  fail "public Corresponding Source must not contain staged changes outside the release commit"
[[ -z "$(git -C "$ROOT_DIR" ls-files --others --exclude-standard)" ]] ||
  fail "public Corresponding Source must not contain untracked files outside the release commit"

bootstrap_commit_tool() {
  local relative_path="$1"
  local destination="$2"
  local record mode object_type object_id recorded_path extra
  record="$(git -C "$ROOT_DIR" ls-tree "$RELEASE_COMMIT" -- "$relative_path")" ||
    fail "release helper identity is unavailable: $relative_path"
  IFS=$' \t' read -r mode object_type object_id recorded_path extra <<< "$record"
  [[ "$mode" == "100755" && "$object_type" == "blob" &&
     "$recorded_path" == "$relative_path" && -z "${extra:-}" &&
     "$object_id" =~ ^[0-9a-f]{40,64}$ ]] ||
    fail "release helper is not one exact executable blob: $relative_path"
  /usr/bin/python3 - "$ROOT_DIR" "$object_id" "$destination" <<'PY'
import os
import subprocess
import sys

repository, object_id, destination = sys.argv[1:]
descriptor = os.open(
    destination,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
    0o500,
)
try:
    result = subprocess.run(
        ["git", "-C", repository, "cat-file", "blob", object_id],
        stdin=subprocess.DEVNULL,
        stdout=descriptor,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(result.stderr.decode("utf-8", "replace"))
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY
}

bootstrap_commit_tool \
  "Scripts/open-source-export-transaction.py" \
  "$TRANSACTION_SNAPSHOT"
bootstrap_commit_tool \
  "Scripts/quarantine-owned-directory.py" \
  "$QUARANTINE_SNAPSHOT"

materialize_file() {
  local source="$1"
  local destination="${2:-$source}"
  local classification="${3:-release-commit-blob}"
  /usr/bin/python3 "$TRANSACTION_SNAPSHOT" materialize \
    --repository "$ROOT_DIR" \
    --commit "$RELEASE_COMMIT" \
    --export-root "$STAGED_EXPORT" \
    --source "$source" \
    --destination "$destination" \
    --classification "$classification" \
    --origin-records "$ORIGIN_RECORDS"
}

materialize_tree() {
  local source="$1"
  local destination="${2:-$source}"
  local classification="${3:-release-commit-blob}"
  /usr/bin/python3 "$TRANSACTION_SNAPSHOT" materialize \
    --repository "$ROOT_DIR" \
    --commit "$RELEASE_COMMIT" \
    --export-root "$STAGED_EXPORT" \
    --source "$source" \
    --destination "$destination" \
    --classification "$classification" \
    --origin-records "$ORIGIN_RECORDS" \
    --recursive
}

materialize_tree "Sources/ForgePlay"
materialize_tree "Tests/ForgePlayTests"
materialize_tree "Tests/ForgePlayD3DMetalFrameGenerationProxyTests"
materialize_tree "Native/D3DMetalFrameGenerationProxy"
materialize_tree "Native/ExternalStorageAccessBridge"
materialize_tree "Native/GameModeProcessHost"
materialize_tree "Native/NetworkControlHelper"

for config_file in \
  ForgePlayApp.xcconfig \
  ForgePlayAppStore.xcconfig \
  ForgePlayCopyleftSourcePackages.json \
  ForgePlayDefaults.xcconfig \
  ForgePlayDirectRelease.xcconfig \
  ForgePlayDistribution.xcconfig \
  ForgePlayD3DMetalFrameGenerationProxy.xcconfig \
  ForgePlayExternalStorageAccessBridge.xcconfig \
  ForgePlayGameModeProcessHost.xcconfig \
  ForgePlayGameModeProcessHostAppStore.xcconfig \
  ForgePlayGameModeProcessHostDistribution.xcconfig \
  ForgePlayGameModeProcessHostRelease.xcconfig \
  ForgePlayGStreamerPayload.lock.json \
  ForgePlayNetworkControlHelper.xcconfig \
  ForgePlayNetworkControlHelperAppStore.xcconfig \
  ForgePlayNetworkControlHelperDistribution.xcconfig \
  ForgePlayPublicDistributionSourceGraph.json \
  ForgePlayRendererPayload.lock.json \
  ForgePlayRuntimeDependencies.lock.json \
  ForgePlayRuntimePatchProvenance.lock.json \
  ForgePlayRuntimeSourceIdentity.lock.json \
  ForgePlayTests.xcconfig; do
  materialize_file "Config/$config_file"
done

materialize_tree "Resources/Assets.xcassets"
materialize_tree "Resources/AppIcon.icon"
materialize_tree "Resources/CompatibilityDB"
materialize_tree "Resources/Documents"
materialize_tree "Resources/Fonts"
materialize_tree "Resources/Legal"
materialize_file "Resources/CompatibilityDBPublicKey.base64"
materialize_file "Resources/PrivacyInfo.xcprivacy"
for localization in en ko es de ja zh-Hans zh-Hant fr; do
  materialize_file "Resources/$localization.lproj/InfoPlist.strings"
  materialize_file "Resources/$localization.lproj/Localizable.strings"
  materialize_file "Resources/$localization.lproj/ForgePlayLicenseNotice.md"
done

# Source and notice material only. Runtime binaries, Frameworks, D3DMetal,
# SteamCompat, and generated package metadata are deliberately not exported.
materialize_tree "Resources/Runners/ForgePlayRuntime/Patches"
materialize_tree "Resources/Runners/ForgePlayRuntime/Sources"
materialize_tree "Resources/Runners/ForgePlayRuntime/Legal/Wine"
materialize_file "Resources/Runners/ForgePlayRuntime/Info.plist"
materialize_file "Resources/Runners/ForgePlayRuntime/RuntimeManifest.json"
materialize_file "Resources/Runners/ForgePlayRuntime/SOURCE-AVAILABILITY.md"

materialize_file "site-data/compatibility-games.json"
materialize_tree "site-data/why-story"
materialize_file "LICENSE.md"
materialize_tree "LICENSES"
materialize_file "project.yml"

for script_file in \
  build-commercial-release.sh \
  build-forgeplay-wine-runtime.sh \
  build-public-forgeplay-runtime.sh \
  build-public-distribution-archive.sh \
  check-project-build-warnings.sh \
  export-open-source.sh \
  freeze-public-source-export.py \
  generate-compatibility-db-signing-key.swift \
  generate-xcode-project.sh \
  materialize-forgeplay-wine-11.12-source.sh \
  materialize-locked-gstreamer-runtime.py \
  materialize-locked-renderer.py \
  materialize-locked-runtime-dependencies.py \
  open-source-export-transaction.py \
  package-forgeplay-runtime.sh \
  prepare-app-store-runtime-payload.sh \
  prepare-clean-build-root.sh \
  prepare-dmg-output-path.sh \
  prepare-game-mode-host-build-identity.sh \
  public-runtime-release-attestation.py \
  public-release-set-transaction.py \
  quarantine-owned-directory.py \
  restore-preserved-apple-d3dmetal-signatures.sh \
  runtime-core-payload-identity.py \
  runtime-sbom.py \
  sign-app-store-runtime-code.sh \
  sign-compatibility-db-feed.swift \
  test-wine-session-compatibility.sh \
  test-wine-game-renderer-d3dmetal.sh \
  validate-compatibility-db-public-key.swift \
  validate-product-identity.sh \
  verify-clean-wine-runtime-markers.py \
  verify-copyleft-source-packages.py \
  verify-app-store-app-security.sh \
  verify-app-store-controller-permissions.py \
  verify-bundled-runtime-capability.sh \
  verify-dmg-contents.sh \
  verify-forgeplay-runtime-patch-provenance.py \
  verify-game-mode-source-licenses.py \
  verify-legal-documents.sh \
  verify-license-documents.sh \
  verify-macho-runtime-closure.py \
  verify-notary-submit-json.sh \
  verify-open-source-export.sh \
  verify-privacy-manifest.sh \
  verify-project-documents.sh \
  verify-public-release-assets.sh \
  verify-public-release-license-policy.sh \
  verify-public-runtime-build-receipt.py \
  verify-release-app-info.sh \
  verify-release-app-localizations.sh \
  verify-release-app-security.sh \
  verify-release-bundle-privacy.sh \
  verify-release-evidence.sh \
  verify-wine-runtime-build-paths.py; do
  materialize_file "Scripts/$script_file"
done

materialize_tree "Scripts/Fixtures/WineSessionCompatibility"
for renderer_fixture in base_desktop_initializer.c d3dmetal_probe.c launcher.c; do
  materialize_file "Scripts/Fixtures/WineGameRendererPolicy/$renderer_fixture"
done
for test_file in \
  test-copyleft-source-packages.py \
  test-d3dmetal-frame-generation-production-contract.sh \
  test-freeze-public-source-export.py \
  test-open-source-export-transaction.py \
  test-packaging-license-release-contracts.py \
  test-public-distribution-archive-graph.py \
  test-public-runtime-build-receipt.py \
  test-public-runtime-release-attestation.py \
  test-public-release-set-transaction.py \
  test-quarantine-owned-directory.py \
  test-wine-game-mode-process-host-routing.sh; do
  materialize_file "Scripts/tests/$test_file"
done

for template_file in README.md README_KO.md README_EN.md SOURCE-LICENSES.md; do
  materialize_file \
    "Scripts/Templates/OpenSource/$template_file" \
    "$template_file" \
    "injected-template-blob"
done
materialize_file \
  "Scripts/Templates/OpenSource/gitignore" \
  ".gitignore" \
  "injected-template-blob"
materialize_file \
  "Scripts/Templates/OpenSource/export-marker" \
  ".forgeplay-source-export" \
  "injected-template-blob"
for game_mode_patch in \
  wine-11.12-game-mode-process-host-routing.patch \
  wine-11.12-game-mode-direct-target-scope.patch; do
  materialize_file \
    "Scripts/Templates/OpenSource/PatchLicenses/$game_mode_patch.license" \
    "Resources/Runners/ForgePlayRuntime/Patches/$game_mode_patch.license" \
    "injected-template-blob"
done

(
  cd "$STAGED_EXPORT"
  /bin/bash Scripts/generate-xcode-project.sh
)
XCODEGEN_VERSION="$(xcodegen --version | /usr/bin/tr -d '\r\n')"
[[ -n "$XCODEGEN_VERSION" ]] || fail "xcodegen version identity is unavailable"

# Normalize directory permissions for recipients without changing source bytes.
/usr/bin/find "$STAGED_EXPORT" -mindepth 1 -type d -exec /bin/chmod 755 {} +

/usr/bin/python3 - \
  "$STAGED_EXPORT" \
  "$ORIGIN_RECORDS" \
  "$RELEASE_COMMIT" \
  "$GIT_OBJECT_FORMAT" \
  "$XCODEGEN_VERSION" <<'PY' || fail "release-commit source inventory could not be generated"
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
origin_path = Path(sys.argv[2])
release_commit = sys.argv[3]
git_object_format = sys.argv[4]
xcodegen_version = sys.argv[5]
inventory_path = root / "SOURCE-INVENTORY.json"

origins = {}
with origin_path.open("r", encoding="utf-8") as handle:
    for line in handle:
        value = json.loads(line)
        destination = value.get("destinationPath")
        if not isinstance(destination, str) or destination in origins:
            raise SystemExit("source-origin map contains a duplicate or invalid destination")
        origins[destination] = value
origin_path.unlink()

generator_entry = origins.get("Scripts/generate-xcode-project.sh")
project_entry = origins.get("project.yml")
exporter_entry = origins.get("Scripts/export-open-source.sh")
if any(entry is None for entry in (generator_entry, project_entry, exporter_entry)):
    raise SystemExit("inventory generator inputs are absent from the exact commit map")

def projection(entry):
    return {
        "gitMode": entry["gitMode"],
        "gitObjectID": entry["gitObjectID"],
        "path": entry["destinationPath"],
        "sha256": entry["sha256"],
        "sourcePath": entry["sourcePath"],
    }

generated_origin = {
    "classification": "generated-xcode-project",
    "generator": projection(generator_entry),
    "inputs": [projection(project_entry)],
    "tool": {"name": "xcodegen", "version": xcodegen_version},
}

rows = []
for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
    relative = path.relative_to(root).as_posix()
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(f"source inventory cannot bind a symlink: {relative}")
    if not stat.S_ISREG(metadata.st_mode):
        continue
    if path == inventory_path or metadata.st_nlink != 1:
        if path == inventory_path:
            raise SystemExit("source inventory already exists")
        raise SystemExit(f"source inventory cannot bind a hardlink: {relative}")
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
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
    stable = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    if stable(before) != stable(after) or total != before.st_size:
        raise SystemExit(f"source inventory input changed while hashing: {relative}")
    sha256 = digest.hexdigest()
    if relative.startswith("ForgePlay.xcodeproj/"):
        origin = generated_origin
    else:
        origin = origins.pop(relative, None)
        if origin is None:
            raise SystemExit(f"export file lacks an exact commit/generated origin: {relative}")
        if origin.get("sha256") != sha256:
            raise SystemExit(f"materialized export differs from its Git blob: {relative}")
        expected_mode = {"100644": 0o644, "100755": 0o755}.get(origin.get("gitMode"))
        if expected_mode is None or stat.S_IMODE(metadata.st_mode) != expected_mode:
            raise SystemExit(f"materialized export mode differs from its Git blob: {relative}")
    rows.append(
        {
            "byteLength": total,
            "mode": f"100{stat.S_IMODE(metadata.st_mode):03o}",
            "origin": origin,
            "path": relative,
            "sha256": sha256,
        }
    )

if origins:
    raise SystemExit(f"materialized origin entries are absent from export: {sorted(origins)}")
canonical_lines = [
    "forgeplay-public-source-inventory-v2",
    f"releaseCommit={release_commit}",
    f"gitObjectFormat={git_object_format}",
    *(
        f"{row['path']}\0{row['mode']}\0{row['byteLength']}\0{row['sha256']}\0"
        + json.dumps(row["origin"], sort_keys=True, separators=(",", ":"))
        for row in rows
    ),
]
payload = {
    "entries": rows,
    "gitObjectFormat": git_object_format,
    "hashAlgorithm": "sha256",
    "inventoryGenerator": projection(exporter_entry),
    "inventorySHA256": hashlib.sha256(
        ("\n".join(canonical_lines) + "\n").encode("utf-8")
    ).hexdigest(),
    "releaseCommit": release_commit,
    "schemaVersion": 2,
}
descriptor = os.open(
    inventory_path,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
    0o644,
)
try:
    serialized = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    view = memoryview(serialized)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise SystemExit("source inventory write made no progress")
        view = view[written:]
    os.fsync(descriptor)
finally:
    os.close(descriptor)
PY

PRIVATE_MARKER=""
if [[ -f "$ROOT_DIR/Config/ForgePlay.local.xcconfig" &&
      ! -L "$ROOT_DIR/Config/ForgePlay.local.xcconfig" ]]; then
  PRIVATE_MARKER="$(
    /usr/bin/awk -F= '
      /^[[:space:]]*FORGEPLAY_DEVELOPMENT_TEAM[[:space:]]*=/ {
        value = $2
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        if (value !~ /^$/ && value !~ /^</) { print value; exit }
      }
    ' "$ROOT_DIR/Config/ForgePlay.local.xcconfig"
  )"
fi

FORGEPLAY_OPEN_SOURCE_PRIVATE_MARKER="$PRIVATE_MARKER" \
  /bin/bash "$STAGED_EXPORT/Scripts/verify-open-source-export.sh" \
    --project-root "$ROOT_DIR" \
    --release-authority \
    --trusted-git-repository "$ROOT_DIR" \
    "$STAGED_EXPORT"

MARKER_SHA256="$(
  /usr/bin/shasum -a 256 "$STAGED_EXPORT/.forgeplay-source-export" |
    /usr/bin/awk '{print $1}'
)" || fail "managed export marker identity is unavailable"
PUBLICATION_JSON="$(
  /usr/bin/python3 "$TRANSACTION_SNAPSHOT" publish \
    --staged "$STAGED_EXPORT" \
    --destination "$DESTINATION" \
    --stage-identity "$STAGED_EXPORT_ID" \
    --parent-identity "$DESTINATION_PARENT_ID" \
    --managed-marker-sha256 "$MARKER_SHA256"
)" || fail "atomic OpenSource publication failed"

PUBLICATION_STATE="$(/usr/bin/python3 - "$PUBLICATION_JSON" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
if set(value) != {"oldIdentity", "state"} or value["state"] not in {"created", "replaced"}:
    raise SystemExit("publication receipt is invalid")
print(value["state"])
PY
)" || fail "OpenSource publication receipt is invalid"

if [[ "$PUBLICATION_STATE" == "replaced" ]]; then
  OLD_IDENTITY="$(/usr/bin/python3 - "$PUBLICATION_JSON" <<'PY'
import json
import re
import sys
value = json.loads(sys.argv[1]).get("oldIdentity")
if not isinstance(value, str) or re.fullmatch(r"[0-9]+:[0-9]+", value) is None:
    raise SystemExit("old publication identity is invalid")
print(value)
PY
)" || fail "old OpenSource publication identity is unavailable"
  STAGED_EXPORT_ID="$OLD_IDENTITY"
  if ! quarantine_cleanup "$STAGED_EXPORT" "$STAGED_EXPORT_ID" "previous committed OpenSource export"; then
    printf 'warning: OpenSource publication committed; previous export remains in private recoverable quarantine\n' >&2
  fi
fi
STAGED_EXPORT=""
STAGED_EXPORT_ID=""
PUBLISHED=1

if ! quarantine_cleanup "$WORK_ROOT" "$WORK_ROOT_ID" "OpenSource transaction workspace"; then
  printf 'warning: OpenSource publication committed; transaction workspace remains recoverable\n' >&2
fi
WORK_ROOT=""
WORK_ROOT_ID=""
trap - EXIT INT TERM

printf 'Open-source source tree exported from commit %s: %s\n' \
  "$RELEASE_COMMIT" "$DESTINATION"
