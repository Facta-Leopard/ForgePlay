#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_PATH=""
TRUSTED_GIT_REPOSITORY=""
RELEASE_ATTESTATION=""
CORRESPONDING_SOURCE_ROOT=""
COPYLEFT_SOURCE_ARCHIVE=""
COPYLEFT_SOURCE_RECEIPT=""
RUNTIME_CAPABILITY_VERIFIER="$SCRIPT_DIR/verify-bundled-runtime-capability.sh"
SOURCE_LICENSE_VERIFIER="$SCRIPT_DIR/verify-game-mode-source-licenses.py"
OPEN_SOURCE_EXPORT_VERIFIER="$SCRIPT_DIR/verify-open-source-export.sh"

fail() {
  printf 'error: invalid public release license contract: %s\n' "$*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --corresponding-source)
      [[ "$#" -ge 2 ]] || fail "--corresponding-source requires a path"
      CORRESPONDING_SOURCE_ROOT="$2"
      shift 2
      ;;
    --copyleft-source-archive)
      [[ "$#" -ge 2 ]] || fail "--copyleft-source-archive requires a path"
      COPYLEFT_SOURCE_ARCHIVE="$2"
      shift 2
      ;;
    --copyleft-source-receipt)
      [[ "$#" -ge 2 ]] || fail "--copyleft-source-receipt requires a path"
      COPYLEFT_SOURCE_RECEIPT="$2"
      shift 2
      ;;
    --trusted-git-repository)
      [[ "$#" -ge 2 ]] || fail "--trusted-git-repository requires a path"
      TRUSTED_GIT_REPOSITORY="$2"
      shift 2
      ;;
    --release-attestation)
      [[ "$#" -ge 2 ]] || fail "--release-attestation requires a path"
      RELEASE_ATTESTATION="$2"
      shift 2
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$INPUT_PATH" ]] ||
        fail "usage: verify-public-release-license-policy.sh --copyleft-source-archive <tar> --copyleft-source-receipt <json> [--corresponding-source <export>] <signed app bundle>"
      INPUT_PATH="$1"
      shift
      ;;
  esac
done

[[ -n "$INPUT_PATH" && -n "$TRUSTED_GIT_REPOSITORY" && -n "$RELEASE_ATTESTATION" &&
   -n "$CORRESPONDING_SOURCE_ROOT" && -n "$COPYLEFT_SOURCE_ARCHIVE" &&
   -n "$COPYLEFT_SOURCE_RECEIPT" ]] ||
  fail "usage: verify-public-release-license-policy.sh --trusted-git-repository <repo> --release-attestation <json> --copyleft-source-archive <tar> --copyleft-source-receipt <json> [--corresponding-source <export>] <signed app bundle>"
[[ -d "$INPUT_PATH" && ! -L "$INPUT_PATH" ]] ||
  fail "input must be a non-symlink directory: $INPUT_PATH"
[[ "$INPUT_PATH" == *.app ]] ||
  fail "an unsigned project or archive candidate is not public release authority"
[[ "$RELEASE_ATTESTATION" = /* && -f "$RELEASE_ATTESTATION" &&
   ! -L "$RELEASE_ATTESTATION" ]] ||
  fail "public release requires an absolute non-symlink PublicRuntimeReleaseAttestation.json"
[[ "$CORRESPONDING_SOURCE_ROOT" = /* && -d "$CORRESPONDING_SOURCE_ROOT" &&
   ! -L "$CORRESPONDING_SOURCE_ROOT" ]] ||
  fail "Corresponding Source must be an absolute non-symlink export root"
CORRESPONDING_SOURCE_ROOT="$(cd "$CORRESPONDING_SOURCE_ROOT" && pwd -P)"
[[ "$COPYLEFT_SOURCE_ARCHIVE" = /* && -f "$COPYLEFT_SOURCE_ARCHIVE" &&
   ! -L "$COPYLEFT_SOURCE_ARCHIVE" ]] ||
  fail "copyleft source archive must be an absolute non-symlink regular file"
[[ "$(stat -f '%l' "$COPYLEFT_SOURCE_ARCHIVE" 2>/dev/null)" == "1" ]] ||
  fail "copyleft source archive must not be hardlinked"
[[ "$COPYLEFT_SOURCE_RECEIPT" = /* && -f "$COPYLEFT_SOURCE_RECEIPT" &&
   ! -L "$COPYLEFT_SOURCE_RECEIPT" ]] ||
  fail "copyleft source receipt must be an absolute non-symlink regular file"
[[ "$(stat -f '%l' "$COPYLEFT_SOURCE_RECEIPT" 2>/dev/null)" == "1" ]] ||
  fail "copyleft source receipt must not be hardlinked"
[[ "$TRUSTED_GIT_REPOSITORY" = /* && -d "$TRUSTED_GIT_REPOSITORY" &&
   ! -L "$TRUSTED_GIT_REPOSITORY" &&
   "$(cd "$TRUSTED_GIT_REPOSITORY" && pwd -P)" == "$TRUSTED_GIT_REPOSITORY" ]] ||
  fail "trusted Git repository must be an exact absolute non-symlink directory"

RESOURCE_ROOT="$INPUT_PATH/Contents/Resources"
RUNTIME_VERIFIER_INPUT="$INPUT_PATH"

SCOPE_DOCUMENT="$RESOURCE_ROOT/LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md"
LICENSE_MANIFEST="$RESOURCE_ROOT/LICENSE.md"
RUNTIME_ROOT="$RESOURCE_ROOT/Runners/ForgePlayRuntime"
PUBLIC_RUNTIME_BUILD_CLAIM="$RUNTIME_ROOT/PublicRuntimeBuildClaim.json"
PUBLIC_RUNTIME_RECEIPT_VERIFIER="$SCRIPT_DIR/verify-public-runtime-build-receipt.py"
PUBLIC_RUNTIME_RELEASE_ATTESTATION_VERIFIER="$SCRIPT_DIR/public-runtime-release-attestation.py"
SOURCE_INVENTORY="$CORRESPONDING_SOURCE_ROOT/SOURCE-INVENTORY.json"
PUBLIC_DISTRIBUTION_GRAPH="$CORRESPONDING_SOURCE_ROOT/Config/ForgePlayPublicDistributionSourceGraph.json"
PUBLIC_DISTRIBUTION_BUILD_CLAIM="$RESOURCE_ROOT/PublicDistributionBuildClaim.json"
COPYLEFT_SOURCE_PACKAGE_INVENTORY="$CORRESPONDING_SOURCE_ROOT/Config/ForgePlayCopyleftSourcePackages.json"
COPYLEFT_SOURCE_PACKAGE_VERIFIER="$SCRIPT_DIR/verify-copyleft-source-packages.py"

[[ -f "$SCOPE_DOCUMENT" && ! -L "$SCOPE_DOCUMENT" ]] ||
  fail "final Game Mode scope document is unavailable"
[[ -f "$LICENSE_MANIFEST" && ! -L "$LICENSE_MANIFEST" ]] ||
  fail "final root license manifest is unavailable"
[[ -f "$RUNTIME_CAPABILITY_VERIFIER" && ! -L "$RUNTIME_CAPABILITY_VERIFIER" ]] ||
  fail "bundled runtime capability verifier is unavailable"
[[ -f "$OPEN_SOURCE_EXPORT_VERIFIER" && ! -L "$OPEN_SOURCE_EXPORT_VERIFIER" ]] ||
  fail "open-source export verifier is unavailable"
[[ -f "$PUBLIC_RUNTIME_BUILD_CLAIM" && ! -L "$PUBLIC_RUNTIME_BUILD_CLAIM" ]] ||
  fail "public release Runtime lacks its unsigned public-source build claim"
[[ -f "$PUBLIC_RUNTIME_RECEIPT_VERIFIER" && ! -L "$PUBLIC_RUNTIME_RECEIPT_VERIFIER" ]] ||
  fail "public Runtime build receipt verifier is unavailable from Corresponding Source"
[[ -f "$PUBLIC_RUNTIME_RELEASE_ATTESTATION_VERIFIER" &&
   ! -L "$PUBLIC_RUNTIME_RELEASE_ATTESTATION_VERIFIER" ]] ||
  fail "public Runtime signed-release attestation verifier is unavailable from Corresponding Source"
[[ -f "$SOURCE_INVENTORY" && ! -L "$SOURCE_INVENTORY" ]] ||
  fail "simultaneous Corresponding Source inventory is unavailable"
[[ -f "$PUBLIC_DISTRIBUTION_GRAPH" && ! -L "$PUBLIC_DISTRIBUTION_GRAPH" ]] ||
  fail "public Distribution Corresponding Source graph is unavailable"
[[ -f "$PUBLIC_DISTRIBUTION_BUILD_CLAIM" &&
   ! -L "$PUBLIC_DISTRIBUTION_BUILD_CLAIM" ]] ||
  fail "public binary lacks its unsigned Distribution build claim"
[[ -f "$COPYLEFT_SOURCE_PACKAGE_INVENTORY" &&
   ! -L "$COPYLEFT_SOURCE_PACKAGE_INVENTORY" ]] ||
  fail "copyleft source-package inventory is unavailable from Corresponding Source"
[[ -f "$COPYLEFT_SOURCE_PACKAGE_VERIFIER" &&
   ! -L "$COPYLEFT_SOURCE_PACKAGE_VERIFIER" ]] ||
  fail "copyleft source-package verifier is unavailable from Corresponding Source"
grep -Fq 'direct-DMG release contract intentionally includes D3DMetal' "$SCOPE_DOCUMENT" ||
  fail "final Game Mode scope does not record the D3DMetal direct-DMG contract"
grep -Fq 'not relicensed under `GPL-3.0-only`' "$SCOPE_DOCUMENT" ||
  fail "final Game Mode scope does not preserve D3DMetal's separate license scope"
grep -Fq 'identified third-party runtime component under its own Apple terms' "$LICENSE_MANIFEST" ||
  fail "root license manifest does not preserve D3DMetal's third-party scope"

D3DMETAL_ROOT="$RUNTIME_ROOT/Frameworks/renderer/d3dmetal"
[[ -d "$D3DMETAL_ROOT" && ! -L "$D3DMETAL_ROOT" ]] ||
  fail "direct DMG must include the configured D3DMetal runtime payload"

bash "$OPEN_SOURCE_EXPORT_VERIFIER" \
  --project-root "$SCRIPT_DIR/.." \
  --release-authority \
  --trusted-git-repository "$TRUSTED_GIT_REPOSITORY" \
  "$CORRESPONDING_SOURCE_ROOT" >/dev/null ||
  fail "version-matched Corresponding Source export verification failed"

python3 "$COPYLEFT_SOURCE_PACKAGE_VERIFIER" \
  --inventory "$COPYLEFT_SOURCE_PACKAGE_INVENTORY" \
  --runtime-sbom "$RUNTIME_ROOT/RuntimeSBOM.json" \
  --dependency-lock "$CORRESPONDING_SOURCE_ROOT/Config/ForgePlayRuntimeDependencies.lock.json" \
  --gstreamer-lock "$CORRESPONDING_SOURCE_ROOT/Config/ForgePlayGStreamerPayload.lock.json" \
  --archive "$COPYLEFT_SOURCE_ARCHIVE" \
  --receipt "$COPYLEFT_SOURCE_RECEIPT" >/dev/null ||
  fail "bundled dynamic GPL/LGPL source-package delivery is incomplete"

python3 "$PUBLIC_RUNTIME_RECEIPT_VERIFIER" verify-runtime \
  --runtime-root "$RUNTIME_ROOT" \
  --source-inventory "$SOURCE_INVENTORY" >/dev/null ||
  fail "Runtime output is not bound to the exact public source build receipt"

python3 "$PUBLIC_RUNTIME_RELEASE_ATTESTATION_VERIFIER" verify \
  --app "$INPUT_PATH" \
  --attestation "$RELEASE_ATTESTATION" >/dev/null ||
  fail "unsigned candidate claims were not promoted by the signed app release attestation"

python3 - \
  "$PUBLIC_RUNTIME_BUILD_CLAIM" \
  "$SOURCE_INVENTORY" \
  "$CORRESPONDING_SOURCE_ROOT/Config/ForgePlayRuntimeSourceIdentity.lock.json" \
  "$RUNTIME_ROOT/RuntimeManifest.json" \
  "$RUNTIME_ROOT/BUILD-METADATA.md" \
  "$PUBLIC_DISTRIBUTION_GRAPH" \
  "$PUBLIC_DISTRIBUTION_BUILD_CLAIM" <<'PY' ||
import hashlib
import json
import re
import sys
from pathlib import Path

authority_path, inventory_path, source_identity_path, manifest_path, metadata_path, graph_path = map(
    Path, sys.argv[1:7]
)
distribution_authority_path = Path(sys.argv[7]) if sys.argv[7] else None
authority = json.loads(authority_path.read_text(encoding="utf-8"))
inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
source_identity = json.loads(source_identity_path.read_text(encoding="utf-8"))
manifest_raw = manifest_path.read_bytes()
manifest = json.loads(manifest_raw)
metadata = metadata_path.read_text(encoding="utf-8")
graph = json.loads(graph_path.read_text(encoding="utf-8"))
if not isinstance(authority, dict) or set(authority) != {
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
}:
    raise SystemExit("unsigned public-source build claim schema is invalid")
if authority["schemaVersion"] != 2 or authority["claimStatus"] != (
    "unsigned build claim awaiting release attestation"
) or authority["commandGraph"] != {
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
}:
    raise SystemExit("public-source package command graph is not exact")
if authority["releaseCommit"] != inventory.get("releaseCommit"):
    raise SystemExit("Runtime release commit does not match Corresponding Source")
if authority["sourceInventorySHA256"] != inventory.get("inventorySHA256"):
    raise SystemExit("Runtime source inventory does not match Corresponding Source")
if authority["runtimeManifestSHA256"] != hashlib.sha256(manifest_raw).hexdigest():
    raise SystemExit("Runtime build claim does not bind the exact final Runtime manifest")
for authority_key, manifest_key in (
    ("corePayloadFingerprint", "corePayloadFingerprint"),
    ("hostSupportPayloadFingerprint", "hostSupportPayloadFingerprint"),
    ("runnerBuildFingerprint", "runnerBuildFingerprint"),
):
    if authority[authority_key] != manifest.get(manifest_key):
        raise SystemExit(
            f"Runtime build claim {authority_key} does not match the final Runtime output identity"
        )
current_source = source_identity.get("currentFinalPatchedSourceTree", {}).get("sha256")
if authority["currentFinalPatchedSourceTreeSHA256"] != current_source:
    raise SystemExit("Runtime build claim does not match the current final source identity")
if manifest.get("sourceTreeSHA256") != current_source:
    raise SystemExit("Runtime manifest does not match the current final source identity")
if authority["patchSetSHA256"] != manifest.get("patchSetSHA256"):
    raise SystemExit("Runtime build claim patch set does not match the Runtime manifest")
required_metadata = (
    "- Packaging source claim: public-source-release-export-v1",
    "- Release attestation status: unsigned build claim awaiting release attestation",
    f"- Public source release commit: {authority['releaseCommit']}",
    f"- Public source inventory SHA-256: {authority['sourceInventorySHA256']}",
)
if any(metadata.count(line) != 1 for line in required_metadata):
    raise SystemExit("Runtime build metadata does not bind the public source claim")
if re.fullmatch(r"[0-9a-f]{40,64}", authority["releaseCommit"]) is None:
    raise SystemExit("public-source release commit is invalid")
if inventory.get("schemaVersion") != 2:
    raise SystemExit("public release requires exact Git-object source inventory schema 2")

if distribution_authority_path is not None:
    distribution_authority = json.loads(
        distribution_authority_path.read_text(encoding="utf-8")
    )
    if not isinstance(distribution_authority, dict) or set(distribution_authority) != {
        "archiveCommandPath",
        "claimStatus",
        "configuration",
        "excludedThirdPartyPayloadRoots",
        "releaseCommit",
        "requiredSourceGraph",
        "runtimePayloadInjectionRoot",
        "runtimeBuildClaimSHA256",
        "schemaVersion",
        "scheme",
        "sourceInventorySHA256",
    }:
        raise SystemExit("unsigned public Distribution build claim schema is invalid")
    if (
        distribution_authority["schemaVersion"] != 2
        or distribution_authority["claimStatus"]
        != "unsigned build claim awaiting release attestation"
        or distribution_authority["archiveCommandPath"]
        != graph.get("archiveCommandPath")
        or distribution_authority["configuration"] != "Distribution"
        or distribution_authority["scheme"] != "ForgePlayDMG"
        or distribution_authority["runtimePayloadInjectionRoot"]
        != graph.get("runtimePayloadInjectionRoot")
        or distribution_authority["excludedThirdPartyPayloadRoots"]
        != graph.get("excludedThirdPartyPayloadRoots")
        or distribution_authority["releaseCommit"] != inventory.get("releaseCommit")
        or distribution_authority["sourceInventorySHA256"]
        != inventory.get("inventorySHA256")
        or distribution_authority["runtimeBuildClaimSHA256"]
        != hashlib.sha256(authority_path.read_bytes()).hexdigest()
    ):
        raise SystemExit("public binary archive graph does not match Corresponding Source")
    rows = {
        row.get("path"): row
        for row in inventory.get("entries", [])
        if isinstance(row, dict)
    }
    expected_graph = []
    for relative in graph.get("requiredReleaseCommitPaths", []):
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
            raise SystemExit(
                f"public Distribution build graph input is not exact: {relative}"
            )
        expected_graph.append(
            {
                "gitMode": origin["gitMode"],
                "gitObjectID": origin["gitObjectID"],
                "path": relative,
                "sha256": row["sha256"],
            }
        )
    if distribution_authority["requiredSourceGraph"] != expected_graph:
        raise SystemExit("archived public Distribution source graph is incomplete")
PY
  fail "public binary and simultaneous Corresponding Source identities differ"

FORGEPLAY_REQUIRE_DIRECT_DMG_RUNTIME=1 \
  bash "$RUNTIME_CAPABILITY_VERIFIER" "$RUNTIME_VERIFIER_INPUT" >/dev/null ||
  fail "bundled direct-DMG runtime contract verification failed"

printf 'ForgePlay public release D3DMetal contract verified: %s\n' "$RESOURCE_ROOT"
