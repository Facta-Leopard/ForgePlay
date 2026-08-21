#!/usr/bin/env bash
set -euo pipefail

DMG_PATH="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_SOURCE_EXPORT_FREEZER="$SCRIPT_DIR/freeze-public-source-export.py"
RELEASE_SET_TRANSACTION="$SCRIPT_DIR/public-release-set-transaction.py"
PROJECT_SOURCE_BINDING_TEMP=""
RELEASE_SNAPSHOT_ROOT=""
PRIVATE_TEMP_ROOT=""

cleanup() {
  if [[ -n "$PROJECT_SOURCE_BINDING_TEMP" ]]; then
    /bin/rm -f "$PROJECT_SOURCE_BINDING_TEMP"
  fi
  if [[ -n "$RELEASE_SNAPSHOT_ROOT" ]]; then
    /bin/rm -rf "$RELEASE_SNAPSHOT_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  printf 'error: invalid release evidence: %s\n' "$*" >&2
  exit 1
}

reject_symlink_parent_components() {
  local path="$1"
  local label="$2"
  local absolute_path current parent

  if [[ "$path" = /* ]]; then
    absolute_path="$path"
  else
    absolute_path="$PWD/$path"
  fi

  current="$(dirname "$absolute_path")"
  [[ -d "$current" ]] || fail "$label parent directory does not exist: $current"

  while [[ "$current" != "/" ]]; do
    if [[ -L "$current" ]]; then
      fail "$label parent path must contain only non-symlink directories: $current"
    fi
    parent="$(dirname "$current")"
    [[ "$parent" != "$current" ]] || break
    current="$parent"
  done
}

require_regular_file() {
  local path="$1"
  local label="$2"
  local link_count
  reject_symlink_parent_components "$path" "$label"
  [[ -f "$path" && ! -L "$path" ]] || fail "$label must be a non-symlink regular file: $path"
  link_count="$(stat -f '%l' "$path" 2>/dev/null)" || fail "$label link count could not be inspected: $path"
  [[ "$link_count" == "1" ]] || fail "$label must not be hardlinked: $path"
}

require_file_size_at_most() {
  local path="$1"
  local label="$2"
  local max_bytes="$3"
  local byte_count
  byte_count="$(stat -f '%z' "$path" 2>/dev/null)" || fail "$label byte count could not be inspected: $path"
  [[ "$byte_count" =~ ^[0-9]+$ ]] || fail "$label byte count is not numeric: $path"
  (( byte_count <= max_bytes )) || fail "$label must be $max_bytes bytes or smaller: $path"
}

[[ -n "$DMG_PATH" ]] || fail "usage: verify-release-evidence.sh <dmg path>"
require_regular_file "$RELEASE_SET_TRANSACTION" "public release-set transaction helper"
PRIVATE_TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)" ||
  fail "private release evidence temp root could not be resolved"
RELEASE_SNAPSHOT_ROOT="$(mktemp -d "$PRIVATE_TEMP_ROOT/forgeplay-release-evidence-snapshot.XXXXXX")" ||
  fail "private release evidence snapshot directory could not be created"
chmod 0700 "$RELEASE_SNAPSHOT_ROOT" || fail "private release evidence snapshot permissions could not be fixed"
DMG_PATH="$(python3 "$RELEASE_SET_TRANSACTION" snapshot \
  --input "$DMG_PATH" \
  --snapshot-dir "$RELEASE_SNAPSHOT_ROOT")" ||
  fail "release evidence inputs could not be fixed into a stable private snapshot"
require_regular_file "$DMG_PATH" "DMG"

CHECKSUM_PATH="$DMG_PATH.sha256"
MANIFEST_PATH="$DMG_PATH.release.json"
require_regular_file "$CHECKSUM_PATH" "checksum sidecar"
require_regular_file "$MANIFEST_PATH" "release manifest sidecar"
require_file_size_at_most "$CHECKSUM_PATH" "checksum sidecar" 1024
require_file_size_at_most "$MANIFEST_PATH" "release manifest sidecar" 1048576

RELEASE_BASE="${DMG_PATH%.dmg}"
PROJECT_SOURCE_ARCHIVE="$RELEASE_BASE-OpenSource.tar"
COPYLEFT_SOURCE_ARCHIVE="$RELEASE_BASE-ThirdPartyCorrespondingSource.tar"
COPYLEFT_SOURCE_RECEIPT="$RELEASE_BASE-ThirdPartyCorrespondingSource.receipt.json"
RELEASE_KIND="$(python3 - "$MANIFEST_PATH" <<'PY'
import json
import sys
from pathlib import Path
value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
kind = value.get("releaseKind")
if kind not in {"official-notarized-dmg", "local-unnotarized-dmg"}:
    raise SystemExit("unsupported releaseKind")
print(kind)
PY
)" || fail "release manifest releaseKind could not be read"
if [[ "$RELEASE_KIND" == "official-notarized-dmg" ]]; then
  require_regular_file "$PROJECT_SOURCE_ARCHIVE" "project Corresponding Source archive"
  require_regular_file "$COPYLEFT_SOURCE_ARCHIVE" "copyleft source-package archive"
  require_regular_file "$COPYLEFT_SOURCE_RECEIPT" "copyleft source-package receipt"
fi

python3 - "$DMG_PATH" "$CHECKSUM_PATH" "$MANIFEST_PATH" \
  "$PROJECT_SOURCE_ARCHIVE" "$COPYLEFT_SOURCE_ARCHIVE" "$COPYLEFT_SOURCE_RECEIPT" <<'PY'
import hashlib
import json
import re
import sys
from datetime import datetime
from pathlib import Path

dmg_path = Path(sys.argv[1])
checksum_path = Path(sys.argv[2])
manifest_path = Path(sys.argv[3])
project_source_archive_path = Path(sys.argv[4])
copyleft_source_archive_path = Path(sys.argv[5])
copyleft_source_receipt_path = Path(sys.argv[6])
try:
    payload = json.loads(manifest_path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"release manifest is not valid JSON: {exc}")

def require(condition, message):
    if not condition:
        raise SystemExit(message)

def require_safe_filename_component(label, value):
    require(isinstance(value, str) and value, f"{label} must be a non-empty string")
    require(len(value) <= 64, f"{label} must be 64 characters or shorter")
    require(re.fullmatch(r"[A-Za-z0-9._-]+", value) is not None, f"{label} must be a safe filename component")
    require(value not in {".", ".."}, f"{label} must not be dot or dot-dot")

def require_numeric_version(label, value):
    require_safe_filename_component(label, value)
    require(
        re.fullmatch(r"\d+(\.\d+){0,2}", value) is not None,
        f"{label} must contain one to three dot-separated integer components",
    )

def require_reverse_dns_bundle_identifier(value):
    require(isinstance(value, str) and value, "bundleIdentifier must be a non-empty string")
    require("$(" not in value, f"bundleIdentifier must not contain unresolved build settings: {value}")
    require("." in value, f"bundleIdentifier must use a reverse-DNS style value: {value}")
    require(
        re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]", value) is not None,
        f"bundleIdentifier contains unsafe characters: {value}",
    )
    for component in value.split("."):
        require(component, f"bundleIdentifier contains an empty component: {value}")
        require(
            re.fullmatch(r"[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?", component) is not None,
            f"bundleIdentifier component is not DNS-label safe: {component}",
        )

def require_iso_utc_timestamp(label, value):
    require(
        isinstance(value, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value),
        f"{label} must be an ISO-8601 UTC timestamp",
    )
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as exc:
        raise SystemExit(f"{label} must be a valid ISO-8601 UTC timestamp: {exc}") from exc

LOCAL_PATH_PREFIXES = ("/Users", "/Volumes", "/private", "/tmp", "/var")
LOCAL_ABSOLUTE_PATH_PATTERN = re.compile(
    r"(^|[^A-Za-z0-9._-])("
    + "|".join(re.escape(prefix) for prefix in LOCAL_PATH_PREFIXES)
    + r")(/|$)"
)

def require_no_local_paths(value, path="$"):
    if isinstance(value, str):
        require(
            LOCAL_ABSOLUTE_PATH_PATTERN.search(value) is None,
            f"{path} must not contain a local absolute path",
        )
    elif isinstance(value, dict):
        for key, nested_value in value.items():
            require_no_local_paths(nested_value, f"{path}.{key}")
    elif isinstance(value, list):
        for index, nested_value in enumerate(value):
            require_no_local_paths(nested_value, f"{path}[{index}]")

expected_top_level_keys = {
    "appSignature",
    "artifact",
    "build",
    "bundleIdentifier",
    "configuration",
    "createdAtUTC",
    "gatekeeperAssessed",
    "notarization",
    "notarized",
    "product",
    "projectCorrespondingSource",
    "copyleftSourcePackage",
    "publicRuntimeReleaseAttestation",
    "releaseKind",
    "schemaVersion",
    "signingStyle",
    "stapled",
    "version",
}
require(set(payload.keys()) == expected_top_level_keys, "release manifest must contain only the supported schema keys")
require_no_local_paths(payload)

checksum_lines = checksum_path.read_text(encoding="utf-8").splitlines()
require(len(checksum_lines) == 1, "checksum sidecar must contain exactly one checksum line")
checksum_match = re.fullmatch(r"([0-9a-f]{64})  ([^\n/]+)", checksum_lines[0])
require(checksum_match is not None, "checksum sidecar must use '<sha256>  <fileName>' format")
checksum_digest, checksum_file_name = checksum_match.groups()
require(checksum_file_name == dmg_path.name, "checksum sidecar fileName must match the DMG")

actual_digest = hashlib.sha256()
with dmg_path.open("rb") as dmg_file:
    for chunk in iter(lambda: dmg_file.read(1024 * 1024), b""):
        actual_digest.update(chunk)
actual_sha256 = actual_digest.hexdigest()
require(checksum_digest == actual_sha256, "checksum sidecar digest must match the DMG")

require(payload.get("schemaVersion") == 3, "schemaVersion must be 3")
require(payload.get("product") == "ForgePlay", "product must be ForgePlay")
require_iso_utc_timestamp("createdAtUTC", payload.get("createdAtUTC"))
require(payload.get("configuration") == "Distribution", "configuration must be Distribution")
require(payload.get("signingStyle") in {"automatic", "manual"}, "signingStyle must be automatic or manual")
require(payload.get("releaseKind") in {"official-notarized-dmg", "local-unnotarized-dmg"}, "releaseKind is unsupported")
require(isinstance(payload.get("notarized"), bool), "notarized must be boolean")
require(isinstance(payload.get("stapled"), bool), "stapled must be boolean")
require(isinstance(payload.get("gatekeeperAssessed"), bool), "gatekeeperAssessed must be boolean")

notarization = payload.get("notarization")
require(isinstance(notarization, dict), "notarization must be an object")
require(set(notarization.keys()) == {"notarytoolStatus", "submissionId", "staplerValidated", "gatekeeperAssessed"}, "notarization must contain only notarytoolStatus, submissionId, staplerValidated, and gatekeeperAssessed")
require(isinstance(notarization.get("notarytoolStatus"), str), "notarytoolStatus must be a string")
require(isinstance(notarization.get("submissionId"), str), "submissionId must be a string")
require(isinstance(notarization.get("staplerValidated"), bool), "staplerValidated must be boolean")
require(isinstance(notarization.get("gatekeeperAssessed"), bool), "notarization gatekeeperAssessed must be boolean")
require(notarization["gatekeeperAssessed"] == payload["gatekeeperAssessed"], "notarization gatekeeperAssessed must match the top-level gatekeeperAssessed flag")

if payload["releaseKind"] == "official-notarized-dmg":
    require(payload["notarized"] and payload["stapled"] and payload["gatekeeperAssessed"], "official release manifest must prove notarization, stapling, and Gatekeeper assessment")
    require(notarization["notarytoolStatus"] == "Accepted", "official release manifest must record notarytoolStatus Accepted")
    require(re.fullmatch(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", notarization["submissionId"]), "official release manifest must record a notary submission id")
    require(notarization["staplerValidated"] is True, "official release manifest must prove stapler validation")
else:
    require(not payload["notarized"] and not payload["stapled"] and not payload["gatekeeperAssessed"], "local release manifest must not claim official notarization gates")
    require(notarization["notarytoolStatus"] == "not-run", "local release manifest must record notarytoolStatus not-run")
    require(notarization["submissionId"] == "", "local release manifest must not record a notary submission id")
    require(notarization["staplerValidated"] is False, "local release manifest must not claim stapler validation")

artifact = payload.get("artifact")
require(isinstance(artifact, dict), "artifact must be an object")
require(set(artifact.keys()) == {"byteCount", "fileName", "sha256"}, "artifact must contain only byteCount, fileName, and sha256")
require(artifact.get("fileName") == dmg_path.name, "artifact fileName must match the DMG")
require(isinstance(artifact.get("byteCount"), int) and artifact["byteCount"] == dmg_path.stat().st_size, "artifact byteCount must match the DMG")
require(isinstance(artifact.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", artifact["sha256"]), "artifact sha256 must be 64 lowercase hex characters")
require(artifact["sha256"] == actual_sha256, "artifact sha256 must match the DMG")

require_reverse_dns_bundle_identifier(payload.get("bundleIdentifier"))
require_numeric_version("version", payload.get("version"))
require_numeric_version("build", payload.get("build"))
expected_artifact_file_name = f"ForgePlay-{payload['version']}-{payload['build']}.dmg"
require(dmg_path.name == expected_artifact_file_name, "release artifact fileName must match ForgePlay-<version>-<build>.dmg")

app_signature = payload.get("appSignature")
require(isinstance(app_signature, dict), "appSignature must be an object")
require(set(app_signature.keys()) == {"authorities", "teamIdentifier", "hardenedRuntime"}, "appSignature must contain only authorities, teamIdentifier, and hardenedRuntime")
authorities = app_signature.get("authorities")
require(isinstance(authorities, list) and all(isinstance(item, str) and item for item in authorities), "appSignature authorities must be non-empty strings")
attestation_binding = payload.get("publicRuntimeReleaseAttestation")
project_source_binding = payload.get("projectCorrespondingSource")
copyleft_source_binding = payload.get("copyleftSourcePackage")
if payload["releaseKind"] == "official-notarized-dmg":
    require(isinstance(attestation_binding, dict), "official release manifest must bind a public Runtime release attestation")
    require(set(attestation_binding) == {"sha256", "value"}, "public Runtime release attestation binding schema is invalid")
    attestation = attestation_binding.get("value")
    require(isinstance(attestation, dict), "public Runtime release attestation value must be an object")
    attestation_raw = (json.dumps(attestation, indent=2, sort_keys=True) + "\n").encode("utf-8")
    require(
        isinstance(attestation_binding.get("sha256"), str)
        and re.fullmatch(r"[0-9a-f]{64}", attestation_binding["sha256"]) is not None
        and hashlib.sha256(attestation_raw).hexdigest() == attestation_binding["sha256"],
        "public Runtime release attestation digest is invalid",
    )
    require(set(attestation) == {"app", "attestationKind", "runtime", "schemaVersion"}, "public Runtime release attestation schema is invalid")
    require(attestation.get("schemaVersion") == 1, "public Runtime release attestation schemaVersion must be 1")
    require(attestation.get("attestationKind") == "forgeplay-public-runtime-developer-id-release-v1", "public Runtime release attestation kind is invalid")
    attested_app = attestation.get("app")
    require(isinstance(attested_app, dict), "public Runtime release attestation app subject must be an object")
    require(set(attested_app) == {"authorities", "bundleIdentifier", "cdHash", "designatedRequirement", "designatedRequirementSHA256", "teamIdentifier"}, "public Runtime release attestation app schema is invalid")
    require(attested_app.get("authorities") == authorities, "attested app authorities differ from release manifest")
    require(attested_app.get("teamIdentifier") == app_signature.get("teamIdentifier"), "attested app TeamIdentifier differs from release manifest")
    require(attested_app.get("bundleIdentifier") == payload.get("bundleIdentifier"), "attested app identifier differs from release manifest")
    require(isinstance(attested_app.get("cdHash"), str) and re.fullmatch(r"[0-9a-f]{40,64}", attested_app["cdHash"]), "attested app CDHash is invalid")
    requirement = attested_app.get("designatedRequirement")
    require(isinstance(requirement, str) and requirement, "attested app designated requirement is missing")
    require(hashlib.sha256(requirement.encode("utf-8")).hexdigest() == attested_app.get("designatedRequirementSHA256"), "attested app designated requirement digest is invalid")
    attested_runtime = attestation.get("runtime")
    require(isinstance(attested_runtime, dict), "public Runtime release attestation Runtime subject must be an object")
    require(set(attested_runtime) == {"buildReceiptSHA256", "fingerprintRoot", "runtimeManifestSHA256", "subjects", "unsignedBuildClaimSHA256"}, "public Runtime release attestation Runtime schema is invalid")
    for key in ("buildReceiptSHA256", "fingerprintRoot", "runtimeManifestSHA256", "unsignedBuildClaimSHA256"):
        require(isinstance(attested_runtime.get(key), str) and re.fullmatch(r"[0-9a-f]{64}", attested_runtime[key]), f"public Runtime release attestation {key} is invalid")
    subjects = attested_runtime.get("subjects")
    require(isinstance(subjects, dict) and set(subjects) == {"corePayloadFingerprint", "hostSupportPayloadFingerprint", "patchSetSHA256", "runnerBuildFingerprint", "runtimeManifestSHA256", "sourceTreeSHA256"}, "public Runtime release attestation subjects are invalid")
    require(all(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) for value in subjects.values()), "public Runtime release attestation subject digest is invalid")
    require(isinstance(project_source_binding, dict) and set(project_source_binding) == {"sha256", "value"}, "project Corresponding Source binding schema is invalid")
    project_source_value = project_source_binding.get("value")
    require(isinstance(project_source_value, dict), "project Corresponding Source binding value must be an object")
    project_source_raw = (json.dumps(project_source_value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    require(
        isinstance(project_source_binding.get("sha256"), str)
        and re.fullmatch(r"[0-9a-f]{64}", project_source_binding["sha256"]) is not None
        and hashlib.sha256(project_source_raw).hexdigest() == project_source_binding["sha256"],
        "project Corresponding Source binding digest is invalid",
    )
    require(set(project_source_value) == {"additionalEntries", "archive", "bindingKind", "schemaVersion", "sourceInventory", "sourceTreeSHA256"}, "project Corresponding Source binding value schema is invalid")
    require(project_source_value.get("bindingKind") == "forgeplay-project-corresponding-source-v1" and project_source_value.get("schemaVersion") == 1, "project Corresponding Source binding policy is invalid")
    project_archive = project_source_value.get("archive")
    require(isinstance(project_archive, dict) and set(project_archive) == {"byteCount", "fileName", "format", "sha256"}, "project Corresponding Source archive binding schema is invalid")
    require(project_archive.get("fileName") == project_source_archive_path.name and project_archive.get("format") == "ustar", "project Corresponding Source archive filename or format is invalid")
    project_digest = hashlib.sha256()
    project_size = 0
    with project_source_archive_path.open("rb") as source_file:
        for chunk in iter(lambda: source_file.read(1024 * 1024), b""):
            project_digest.update(chunk)
            project_size += len(chunk)
    require(project_archive.get("byteCount") == project_size and project_archive.get("sha256") == project_digest.hexdigest(), "project Corresponding Source archive bytes differ from binding")
    source_inventory = project_source_value.get("sourceInventory")
    require(isinstance(source_inventory, dict) and set(source_inventory) == {"byteCount", "entryCount", "gitObjectFormat", "inventorySHA256", "releaseCommit", "sha256"}, "project Corresponding Source inventory binding schema is invalid")
    require(all(isinstance(source_inventory.get(key), str) and re.fullmatch(r"[0-9a-f]{64}", source_inventory[key]) for key in ("inventorySHA256", "sha256")), "project Corresponding Source inventory digests are invalid")
    require(isinstance(project_source_value.get("sourceTreeSHA256"), str) and re.fullmatch(r"[0-9a-f]{64}", project_source_value["sourceTreeSHA256"]), "project Corresponding Source tree digest is invalid")
    additional_entries = project_source_value.get("additionalEntries")
    require(isinstance(additional_entries, list) and len(additional_entries) == 1 and isinstance(additional_entries[0], dict) and set(additional_entries[0]) == {"byteCount", "path", "sha256"}, "project Corresponding Source additionalEntries schema is invalid")
    require(additional_entries[0].get("path") == "CorrespondingSource/Wine/wine-11.12.tar.xz", "project Corresponding Source Wine path is invalid")
    require(isinstance(additional_entries[0].get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", additional_entries[0]["sha256"]), "project Corresponding Source Wine digest is invalid")
    require(isinstance(copyleft_source_binding, dict) and set(copyleft_source_binding) == {"archive", "inventorySHA256", "receipt", "sourceTreeSHA256"}, "copyleft source-package manifest binding schema is invalid")
    receipt_binding = copyleft_source_binding.get("receipt")
    require(isinstance(receipt_binding, dict) and set(receipt_binding) == {"sha256", "value"}, "copyleft source-package receipt binding schema is invalid")
    receipt = receipt_binding.get("value")
    require(isinstance(receipt, dict), "copyleft source-package receipt value must be an object")
    receipt_raw = (json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode("utf-8")
    require(hashlib.sha256(receipt_raw).hexdigest() == receipt_binding.get("sha256"), "copyleft source-package embedded receipt digest is invalid")
    require(copyleft_source_receipt_path.read_bytes() == receipt_raw, "published copyleft source-package receipt differs from release manifest")
    require(receipt.get("receiptKind") == "forgeplay-copyleft-source-package-v1", "copyleft source-package receipt kind is invalid")
    receipt_archive = receipt.get("archive")
    receipt_tree = receipt.get("sourceTree")
    require(isinstance(receipt_archive, dict) and receipt_archive == copyleft_source_binding.get("archive"), "copyleft source archive binding differs from receipt")
    require(isinstance(receipt_tree, dict) and receipt_tree.get("treeSHA256") == copyleft_source_binding.get("sourceTreeSHA256"), "copyleft source tree binding differs from receipt")
    require(receipt.get("inventorySHA256") == copyleft_source_binding.get("inventorySHA256"), "copyleft source inventory binding differs from receipt")
    require(receipt.get("hostSupportPayloadFingerprint") == subjects.get("hostSupportPayloadFingerprint"), "copyleft source receipt host support fingerprint differs from signed Runtime attestation")
    require(receipt_archive.get("fileName") == copyleft_source_archive_path.name, "copyleft source archive filename differs from receipt")
    copyleft_digest = hashlib.sha256()
    copyleft_size = 0
    with copyleft_source_archive_path.open("rb") as source_file:
        for chunk in iter(lambda: source_file.read(1024 * 1024), b""):
            copyleft_digest.update(chunk)
            copyleft_size += len(chunk)
    require(receipt_archive.get("byteCount") == copyleft_size and receipt_archive.get("sha256") == copyleft_digest.hexdigest(), "copyleft source archive bytes differ from receipt")
else:
    require(attestation_binding is None, "local release manifest must not claim a Developer ID Runtime release attestation")
    require(project_source_binding is None, "local release manifest must not claim project Corresponding Source binding")
    require(copyleft_source_binding is None, "local release manifest must not claim copyleft source-package binding")
    require(not project_source_archive_path.exists(), "local three-file release set must not contain project source archive")
    require(not copyleft_source_archive_path.exists(), "local three-file release set must not contain copyleft source archive")
    require(not copyleft_source_receipt_path.exists(), "local three-file release set must not contain copyleft source receipt")
require(any(item.startswith("Developer ID Application:") for item in authorities), "appSignature authorities must include Developer ID Application")
require(authorities[0].startswith("Developer ID Application:"), "appSignature first authority must be Developer ID Application")
require("Developer ID Certification Authority" in authorities, "appSignature authorities must include Developer ID Certification Authority")
require(authorities[-1] == "Apple Root CA", "appSignature authorities must end with Apple Root CA")
require(app_signature.get("hardenedRuntime") is True, "appSignature hardenedRuntime must be true")
team_identifier = app_signature.get("teamIdentifier")
require(isinstance(team_identifier, str) and re.fullmatch(r"[A-Z0-9]{10}", team_identifier), "teamIdentifier must be a 10-character team id")

print("Release evidence verification passed.")
PY

if [[ "$RELEASE_KIND" == "official-notarized-dmg" ]]; then
  require_regular_file "$PROJECT_SOURCE_EXPORT_FREEZER" "project Corresponding Source verifier"
  PROJECT_SOURCE_BINDING_TEMP="$(mktemp "${TMPDIR:-/tmp}/forgeplay-project-source-binding.XXXXXX")" ||
    fail "project Corresponding Source binding temporary file could not be created"
  python3 - "$MANIFEST_PATH" "$PROJECT_SOURCE_BINDING_TEMP" <<'PY' ||
import json
import sys
from pathlib import Path

manifest_path, output_path = map(Path, sys.argv[1:])
binding = json.loads(manifest_path.read_text(encoding="utf-8"))["projectCorrespondingSource"]["value"]
output_path.write_bytes((json.dumps(binding, indent=2, sort_keys=True) + "\n").encode("utf-8"))
PY
    fail "project Corresponding Source binding could not be materialized"
  python3 "$PROJECT_SOURCE_EXPORT_FREEZER" verify \
    --archive "$PROJECT_SOURCE_ARCHIVE" \
    --binding "$PROJECT_SOURCE_BINDING_TEMP" >/dev/null ||
    fail "project Corresponding Source archive closure verification failed"
fi
