#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/ForgePlay.xcodeproj"
SCHEME="${FORGEPLAY_SCHEME:-ForgePlayDMG}"
TEST_SCHEME="${FORGEPLAY_TEST_SCHEME:-ForgePlay}"
CONFIGURATION="${FORGEPLAY_CONFIGURATION:-Distribution}"
DEFAULT_TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
BUILD_ROOT="${FORGEPLAY_RELEASE_BUILD_ROOT:-$DEFAULT_TEMP_ROOT/ForgePlayCommercialRelease}"
ARCHIVE_PATH="$BUILD_ROOT/ForgePlay.xcarchive"
EXPORT_PATH="$BUILD_ROOT/Export"
DIST_DIR="${FORGEPLAY_DIST_DIR:-$ROOT_DIR/dist}"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"
BUILD_PRODUCTS="$BUILD_ROOT/BuildProducts"
BUILD_INTERMEDIATES="$BUILD_ROOT/BuildIntermediates"
EXPORT_OPTIONS="$BUILD_ROOT/ExportOptions.plist"
DMG_ROOT="$BUILD_ROOT/DmgRoot"
CODE_SIGN_IDENTITY="${FORGEPLAY_CODE_SIGN_IDENTITY:-}"
MARKETING_VERSION_VALUE="${FORGEPLAY_RELEASE_MARKETING_VERSION:-1.2}"
BUILD_NUMBER_VALUE="${FORGEPLAY_RELEASE_BUILD_NUMBER:-3}"
CODE_SIGN_STYLE="${FORGEPLAY_RELEASE_CODE_SIGN_STYLE:-Automatic}"
EXPORT_SIGNING_STYLE=""
DMG_SIGNING_IDENTITY=""
APP_TEAM_IDENTIFIER=""
DMG_SIGNING_DETAILS=""
DMG_TEAM_IDENTIFIER=""
ARCHIVE_SIGNING_ARGS=()
NOTARY_PROFILE="${FORGEPLAY_NOTARY_PROFILE:-}"
NOTARY_KEY_PATH="${FORGEPLAY_NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${FORGEPLAY_NOTARY_KEY_ID:-}"
NOTARY_ISSUER="${FORGEPLAY_NOTARY_ISSUER:-}"
NOTARY_AUTH_ARGS=()
ALLOW_UNNOTARIZED_DMG="${FORGEPLAY_ALLOW_UNNOTARIZED_DMG:-0}"
SKIP_TESTS="${FORGEPLAY_SKIP_TESTS:-0}"
ENTITLEMENTS_PLIST="$BUILD_ROOT/ForgePlayRelease.entitlements.plist"
WARNING_CHECKER="$ROOT_DIR/Scripts/check-project-build-warnings.sh"
BUILD_ROOT_PREPARER="$ROOT_DIR/Scripts/prepare-clean-build-root.sh"
DMG_OUTPUT_PREPARER="$ROOT_DIR/Scripts/prepare-dmg-output-path.sh"
DMG_CONTENT_VERIFIER="$ROOT_DIR/Scripts/verify-dmg-contents.sh"
APP_INFO_VERIFIER="$ROOT_DIR/Scripts/verify-release-app-info.sh"
APP_LOCALIZATION_VERIFIER="$ROOT_DIR/Scripts/verify-release-app-localizations.sh"
PRIVACY_MANIFEST_VERIFIER="$ROOT_DIR/Scripts/verify-privacy-manifest.sh"
LEGAL_DOCUMENT_VERIFIER="$ROOT_DIR/Scripts/verify-legal-documents.sh"
PROJECT_DOCUMENT_VERIFIER="$ROOT_DIR/Scripts/verify-project-documents.sh"
LICENSE_DOCUMENT_VERIFIER="$ROOT_DIR/Scripts/verify-license-documents.sh"
PUBLIC_LICENSE_POLICY_VERIFIER="$ROOT_DIR/Scripts/verify-public-release-license-policy.sh"
OPEN_SOURCE_EXPORTER="$ROOT_DIR/Scripts/export-open-source.sh"
PUBLIC_SOURCE_EXPORT="$ROOT_DIR/OpenSource"
PUBLIC_ARCHIVE_BUILDER="$PUBLIC_SOURCE_EXPORT/Scripts/build-public-distribution-archive.sh"
PUBLIC_RUNTIME_BUILDER="$PUBLIC_SOURCE_EXPORT/Scripts/build-public-forgeplay-runtime.sh"
PUBLIC_RUNTIME_RELEASE_ATTESTATION_TOOL="$PUBLIC_SOURCE_EXPORT/Scripts/public-runtime-release-attestation.py"
COPYLEFT_SOURCE_PACKAGE_VERIFIER="$PUBLIC_SOURCE_EXPORT/Scripts/verify-copyleft-source-packages.py"
PROJECT_SOURCE_EXPORT_FREEZER="$PUBLIC_SOURCE_EXPORT/Scripts/freeze-public-source-export.py"
COPYLEFT_SOURCE_PACKAGE_ROOT="${FORGEPLAY_COPYLEFT_SOURCE_PACKAGE_ROOT:-$ROOT_DIR/ThirdPartyCorrespondingSource}"
COPYLEFT_SOURCE_ARCHIVE=""
COPYLEFT_SOURCE_RECEIPT=""
PROJECT_SOURCE_ARCHIVE=""
PROJECT_SOURCE_BINDING="$BUILD_ROOT/ProjectCorrespondingSource.binding.json"
PUBLIC_BUILD_WORKSPACE="$BUILD_ROOT/PublicSourceBuild"
PUBLIC_RUNTIME_TRANSACTION="$BUILD_ROOT/PublicRuntimeTransaction"
PUBLIC_RUNTIME_OUTPUT="$PUBLIC_RUNTIME_TRANSACTION/output/ForgePlayRuntime"
PUBLIC_RUNTIME_RELEASE_ATTESTATION="$BUILD_ROOT/PublicRuntimeReleaseAttestation.json"
PUBLIC_WINE_SOURCE_ARCHIVE="${FORGEPLAY_PUBLIC_WINE_SOURCE_ARCHIVE:-}"
PUBLIC_GSTREAMER_SDK_ROOT="${FORGEPLAY_GSTREAMER_SDK_ROOT:-}"
PUBLIC_RENDERER_SOURCE="${FORGEPLAY_RENDERER_SOURCE:-}"
PUBLIC_RUNTIME_POLICY_SOURCE="${FORGEPLAY_RUNTIME_POLICY_SOURCE:-}"
APP_SECURITY_VERIFIER="$ROOT_DIR/Scripts/verify-release-app-security.sh"
BUNDLE_PRIVACY_VERIFIER="$ROOT_DIR/Scripts/verify-release-bundle-privacy.sh"
RELEASE_EVIDENCE_VERIFIER="$ROOT_DIR/Scripts/verify-release-evidence.sh"
PUBLIC_RELEASE_ASSET_VERIFIER="$ROOT_DIR/Scripts/verify-public-release-assets.sh"
RELEASE_SET_TRANSACTION="$ROOT_DIR/Scripts/public-release-set-transaction.py"
NOTARY_SUBMIT_JSON_VERIFIER="$ROOT_DIR/Scripts/verify-notary-submit-json.sh"
APPLE_D3DMETAL_SIGNATURE_RESTORER="$ROOT_DIR/Scripts/restore-preserved-apple-d3dmetal-signatures.sh"
PUBLIC_KEY_VALIDATOR="$ROOT_DIR/Scripts/validate-compatibility-db-public-key.swift"
COMPAT_KEY_GENERATOR="$ROOT_DIR/Scripts/generate-compatibility-db-signing-key.swift"
COMPAT_FEED_SIGNER="$ROOT_DIR/Scripts/sign-compatibility-db-feed.swift"
TEST_LOG="$(mktemp "$DEFAULT_TEMP_ROOT/forgeplay-release-xctest.XXXXXX")"
ARCHIVE_LOG="$(mktemp "$DEFAULT_TEMP_ROOT/forgeplay-release-archive.XXXXXX")"
EXPORT_LOG="$(mktemp "$DEFAULT_TEMP_ROOT/forgeplay-release-export.XXXXXX")"
NOTARY_JSON_LOG="$(mktemp "$DEFAULT_TEMP_ROOT/forgeplay-release-notary-json.XXXXXX")"
NOTARY_ERROR_LOG="$(mktemp "$DEFAULT_TEMP_ROOT/forgeplay-release-notary-stderr.XXXXXX")"
DMG_MOUNT_POINT=""
FINAL_DMG_PATH=""
RELEASE_STAGE_DIR=""

cleanup_mounted_dmg() {
  if [[ -n "$DMG_MOUNT_POINT" ]]; then
    hdiutil detach "$DMG_MOUNT_POINT" -quiet >/dev/null 2>&1 ||
      hdiutil detach "$DMG_MOUNT_POINT" -force -quiet >/dev/null 2>&1 ||
      true
    rmdir "$DMG_MOUNT_POINT" >/dev/null 2>&1 || true
    DMG_MOUNT_POINT=""
  fi
}

cleanup_release_resources() {
  cleanup_mounted_dmg
  if [[ -n "$RELEASE_STAGE_DIR" ]]; then
    python3 "$RELEASE_SET_TRANSACTION" discard-stage \
      --stage-dir "$RELEASE_STAGE_DIR" >/dev/null 2>&1 ||
      printf 'warning: private release stage requires manual cleanup: %s\n' "$RELEASE_STAGE_DIR" >&2
    RELEASE_STAGE_DIR=""
  fi
}
trap cleanup_release_resources EXIT

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

print_release_prerequisites_help() {
  cat >&2 <<'EOF'

Commercial release prerequisites:
  1. Xcode signing must be configured for the ForgePlay target. This script
     does not inspect local signing identities; Xcode archive/export is the
     app signing authority. The matching Developer ID private key must remain
     available in the local Keychain so the exported app identity can also
     sign the outer DMG. Leave signing environment variables unset for the
     default Automatic signing path.
  2. If Xcode needs a non-default Developer ID signing identity, use manual signing:
       export FORGEPLAY_RELEASE_CODE_SIGN_STYLE=Manual
       export FORGEPLAY_CODE_SIGN_IDENTITY="Developer ID Application: Example Developer (TEAMID)"
  3. Provide notarization credentials. App Store Connect API key files avoid
     any release-script credential lookup:
       export FORGEPLAY_NOTARY_KEY_PATH="/secure/path/AuthKey_EXAMPLE.p8"
       export FORGEPLAY_NOTARY_KEY_ID="<KEY_ID>"
       export FORGEPLAY_NOTARY_ISSUER="<ISSUER_UUID>"
     Or pass an existing notarytool saved profile that you manage outside
     this script:
       export FORGEPLAY_NOTARY_PROFILE=ForgePlayNotary
  4. Re-run:
       Scripts/build-commercial-release.sh

Unsigned local DMG structure checks belong in Scripts/audit-commercial-readiness.sh and are not commercial release artifacts.
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_regular_file() {
  local path="$1"
  local link_count
  if [[ -L "$path" || ! -f "$path" ]]; then
    fail "required file must be a non-symlink regular file: $path"
  fi
  if ! link_count="$(stat -f '%l' "$path" 2>/dev/null)"; then
    fail "could not inspect link count for required file: $path"
  fi
  [[ "$link_count" == "1" ]] || fail "required file must not be hardlinked: $path"
}

reject_symlink_parent_components() {
  local path="$1"
  local label="$2"
  local current parent

  [[ "$path" = /* ]] || fail "$label path must be absolute: $path"
  current="$(dirname "$path")"
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

require_private_key_file() {
  local path="$1"
  local label="$2"
  local mode
  reject_symlink_parent_components "$path" "$label"
  require_regular_file "$path"
  mode="$(stat -f '%Lp' "$path" 2>/dev/null)" ||
    fail "$label file permissions could not be inspected: $path"
  if (( (8#$mode & 077) != 0 )); then
    fail "$label file permissions must not allow group or other access: $path"
  fi
}

validate_notary_api_key_id() {
  local key_id="$1"
  [[ "$key_id" =~ ^[A-Za-z0-9]{10}$ ]] ||
    fail "FORGEPLAY_NOTARY_KEY_ID must be a 10-character App Store Connect key id."
}

validate_notary_issuer() {
  local issuer="$1"
  [[ -z "$issuer" || "$issuer" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] ||
    fail "FORGEPLAY_NOTARY_ISSUER must be a UUID when set."
}

validate_release_scheme() {
  [[ "$SCHEME" == "ForgePlayDMG" ]] ||
    fail "DMG release must use the ForgePlayDMG scheme."
  [[ "$TEST_SCHEME" == "ForgePlay" ]] ||
    fail "DMG release tests must use the ForgePlay test scheme."
}

validate_release_mode() {
  if [[ "$ALLOW_UNNOTARIZED_DMG" == "1" && "${#NOTARY_AUTH_ARGS[@]}" -gt 0 ]]; then
    fail "FORGEPLAY_ALLOW_UNNOTARIZED_DMG=1 cannot be combined with notarization credentials."
  fi
}

require_xcrun_tool() {
  xcrun -f "$1" >/dev/null 2>&1 || fail "required Xcode tool not found: $1"
}

require_true_entitlement() {
  local plist="$1"
  local key="$2"
  if [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" != "true" ]]; then
    fail "exported app is missing required entitlement: $key"
  fi
}

require_no_project_warnings() {
  local log_file="$1"
  local label="$2"
  if ! bash "$WARNING_CHECKER" "$ROOT_DIR" "$log_file"; then
    fail "$label produced project compiler warnings."
  fi
}

normalize_export_signing_style() {
  local style="$1"
  case "$(printf '%s' "$style" | tr '[:upper:]' '[:lower:]')" in
    automatic)
      printf 'automatic'
      ;;
    manual)
      printf 'manual'
      ;;
    *)
      fail "FORGEPLAY_RELEASE_CODE_SIGN_STYLE must be Automatic or Manual."
      ;;
  esac
}

configure_archive_signing_args() {
  ARCHIVE_SIGNING_ARGS=("CODE_SIGN_STYLE=$CODE_SIGN_STYLE")
  if [[ "$EXPORT_SIGNING_STYLE" == "manual" ]]; then
    [[ -n "$CODE_SIGN_IDENTITY" ]] ||
      fail "FORGEPLAY_CODE_SIGN_IDENTITY is required when FORGEPLAY_RELEASE_CODE_SIGN_STYLE=Manual."
    ARCHIVE_SIGNING_ARGS+=("CODE_SIGN_IDENTITY=$CODE_SIGN_IDENTITY")
  elif [[ -n "$CODE_SIGN_IDENTITY" ]]; then
    fail "FORGEPLAY_CODE_SIGN_IDENTITY requires FORGEPLAY_RELEASE_CODE_SIGN_STYLE=Manual. Leave it unset for Xcode Automatic signing."
  fi
}

configure_notary_auth_args() {
  local has_profile="0"
  local has_api_key_input="0"

  [[ -n "$NOTARY_PROFILE" ]] && has_profile="1"
  if [[ -n "$NOTARY_KEY_PATH" || -n "$NOTARY_KEY_ID" || -n "$NOTARY_ISSUER" ]]; then
    has_api_key_input="1"
  fi

  if [[ "$has_profile" == "1" && "$has_api_key_input" == "1" ]]; then
    fail "choose either FORGEPLAY_NOTARY_PROFILE or App Store Connect API key variables, not both."
  fi

  if [[ "$has_profile" == "1" ]]; then
    NOTARY_AUTH_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    return
  fi

  if [[ "$has_api_key_input" == "1" ]]; then
    [[ -n "$NOTARY_KEY_PATH" ]] ||
      fail "FORGEPLAY_NOTARY_KEY_PATH is required when using App Store Connect API key notarization."
    [[ -n "$NOTARY_KEY_ID" ]] ||
      fail "FORGEPLAY_NOTARY_KEY_ID is required when using App Store Connect API key notarization."
    require_private_key_file "$NOTARY_KEY_PATH" "notary API key"
    validate_notary_api_key_id "$NOTARY_KEY_ID"
    validate_notary_issuer "$NOTARY_ISSUER"
    NOTARY_AUTH_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID")
    if [[ -n "$NOTARY_ISSUER" ]]; then
      NOTARY_AUTH_ARGS+=(--issuer "$NOTARY_ISSUER")
    fi
  fi
}

require_release_app_excludes_debug_launch_hooks() {
  local app_path="$1"
  local executable="$app_path/Contents/MacOS/ForgePlay"
  local debug_markers

  [[ -f "$executable" ]] || fail "exported app executable not found for debug hook scan."
  debug_markers="$(LC_ALL=C strings -a "$executable" | grep -E 'FORGEPLAY_QA_|debugLayoutFixture|Debug startup failure fixture' || true)"
  if [[ -n "$debug_markers" ]]; then
    printf '%s\n' "$debug_markers" >&2
    fail "exported app contains DEBUG QA launch hooks."
  fi
}

verify_dmg_artifact() {
  local dmg_path="$1"
  local label="$2"
  local mounted_app

  sync
  for _ in {1..30}; do
    if ! lsof "$dmg_path" 2>/dev/null |
      awk 'NR > 1 && $4 ~ /^[0-9]+u/ { found = 1 } END { exit(found ? 0 : 1) }'; then
      break
    fi
    sleep 1
  done
  if lsof "$dmg_path" 2>/dev/null |
    awk 'NR > 1 && $4 ~ /^[0-9]+u/ { found = 1 } END { exit(found ? 0 : 1) }'; then
    fail "$label is still held open for writing by a disk image helper."
  fi

  hdiutil verify "$dmg_path" >/dev/null || fail "$label failed hdiutil verify."
  DMG_MOUNT_POINT="$(mktemp -d "$DEFAULT_TEMP_ROOT/forgeplay-release-dmg-mount.XXXXXX")" ||
    fail "$label mount point could not be created."
  hdiutil attach -readonly -nobrowse -mountpoint "$DMG_MOUNT_POINT" "$dmg_path" >/dev/null ||
    fail "$label did not attach as a read-only DMG."
  if [[ -z "$DMG_MOUNT_POINT" || ! -d "$DMG_MOUNT_POINT" ]]; then
    fail "$label did not mount to a readable volume."
  fi
  mounted_app="$DMG_MOUNT_POINT/ForgePlay.app"
  bash "$DMG_CONTENT_VERIFIER" "$DMG_MOUNT_POINT"
  bash "$APP_INFO_VERIFIER" "$mounted_app"
  bash "$APP_LOCALIZATION_VERIFIER" "$mounted_app"
  bash "$PRIVACY_MANIFEST_VERIFIER" "$mounted_app"
  bash "$LEGAL_DOCUMENT_VERIFIER" "$mounted_app"
  bash "$PROJECT_DOCUMENT_VERIFIER" "$mounted_app"
  bash "$LICENSE_DOCUMENT_VERIFIER" "$mounted_app"
  if [[ "$ALLOW_UNNOTARIZED_DMG" != "1" ]]; then
    bash "$PUBLIC_LICENSE_POLICY_VERIFIER" \
      --corresponding-source "$PUBLIC_SOURCE_EXPORT" \
      --trusted-git-repository "$ROOT_DIR" \
      --release-attestation "$PUBLIC_RUNTIME_RELEASE_ATTESTATION" \
      --copyleft-source-archive "$COPYLEFT_SOURCE_ARCHIVE" \
      --copyleft-source-receipt "$COPYLEFT_SOURCE_RECEIPT" \
      "$mounted_app"
  fi
  bash "$APP_SECURITY_VERIFIER" --require-developer-id "$mounted_app" >/dev/null
  bash "$BUNDLE_PRIVACY_VERIFIER" --project-root "$ROOT_DIR" "$mounted_app" >/dev/null
  cleanup_mounted_dmg
}

check_compatibility_db_public_key() {
  local source="$1"
  local value="$2"
  local validation_output
  if ! validation_output="$(printf '%s' "$value" | xcrun swift "$PUBLIC_KEY_VALIDATOR" 2>&1)"; then
    printf '%s\n' "$validation_output" >&2
    fail "remote compatibility DB public key $source is not a valid P-256 signing key."
  fi
}

check_remote_compatibility_db_key() {
  local public_key_value
  if [[ -L "$ROOT_DIR/Resources/CompatibilityDBPublicKey.base64" ||
        -e "$ROOT_DIR/Resources/CompatibilityDBPublicKey.base64" ]]; then
    require_regular_file "$ROOT_DIR/Resources/CompatibilityDBPublicKey.base64"
    check_compatibility_db_public_key "resource" "$(cat "$ROOT_DIR/Resources/CompatibilityDBPublicKey.base64")"
  elif public_key_value="$(/usr/libexec/PlistBuddy -c 'Print :ForgePlayCompatibilityDBPublicKeyBase64' "$ROOT_DIR/Sources/ForgePlay/Info.plist" 2>/dev/null)"; then
    check_compatibility_db_public_key "Info.plist value" "$public_key_value"
  elif [[ "$ALLOW_UNNOTARIZED_DMG" == "1" ]]; then
    printf 'warning: remote compatibility DB updates will stay disabled until a trusted public key is shipped.\n' >&2
  else
    fail "commercial release requires a trusted remote compatibility DB public key. Add Resources/CompatibilityDBPublicKey.base64 or ForgePlayCompatibilityDBPublicKeyBase64 in Info.plist. Use FORGEPLAY_ALLOW_UNNOTARIZED_DMG=1 only for local packaging checks without the key."
  fi
}

require_app_compatibility_db_public_key() {
  local app_path="$1"
  local key_path="$app_path/Contents/Resources/CompatibilityDBPublicKey.base64"
  require_regular_file "$key_path"
  check_compatibility_db_public_key "app bundle resource" "$(cat "$key_path")"
}

require_compatibility_db_public_key_validator() {
  local valid_test_key="FOoOcZDFiGjHdnHyBgek68b8cL+cmTwU5sXwBGC+Sz10n69VNpnKWTZtRS8rrYSyh5Q67Qx6YMRn6FHwmZxKow=="
  local validation_output
  xcrun swiftc -parse "$PUBLIC_KEY_VALIDATOR" >/dev/null 2>&1 || fail "compatibility DB public key validator syntax failed."
  if ! validation_output="$(printf '%s' "$valid_test_key" | xcrun swift "$PUBLIC_KEY_VALIDATOR" 2>&1)"; then
    printf '%s\n' "$validation_output" >&2
    fail "compatibility DB public key validator rejected a valid P-256 signing key."
  fi
  if printf 'not-base64' | xcrun swift "$PUBLIC_KEY_VALIDATOR" >/dev/null 2>&1; then
    fail "compatibility DB public key validator accepted invalid base64."
  fi
}

prepare_sidecar_output_path() {
  local path="$1"
  reject_symlink_parent_components "$path" "release sidecar output"
  if [[ -L "$path" ]]; then
    fail "release sidecar output must not be a symlink: $path"
  fi
  if [[ -e "$path" ]]; then
    require_regular_file "$path"
  fi
}

prepare_sidecar_temp_output_path() {
  local template="$1"
  local temp_path
  reject_symlink_parent_components "$template" "release sidecar temp output"
  temp_path="$(mktemp "$template")" ||
    fail "release sidecar temp file could not be created: $template"
  require_regular_file "$temp_path"
  printf '%s\n' "$temp_path"
}

write_release_evidence() {
  local release_kind="$1"
  local notarized="$2"
  local stapled="$3"
  local gatekeeper_assessed="$4"
  local bundle_identifier="$5"
  local notary_status="$6"
  local notary_submission_id="$7"
  local stapler_validated="$8"
  local dmg_sha dmg_size checksum_path manifest_path checksum_tmp manifest_tmp signing_details_path

  reject_symlink_parent_components "$DMG_PATH" "release DMG"
  require_regular_file "$DMG_PATH"
  checksum_path="$DMG_PATH.sha256"
  manifest_path="$DMG_PATH.release.json"
  prepare_sidecar_output_path "$checksum_path"
  prepare_sidecar_output_path "$manifest_path"

  dmg_sha="$(shasum -a 256 "$DMG_PATH" | awk '{ print $1 }')"
  [[ "$dmg_sha" =~ ^[0-9a-f]{64}$ ]] || fail "could not compute SHA-256 for release artifact."
  dmg_size="$(stat -f '%z' "$DMG_PATH" 2>/dev/null)" ||
    fail "could not inspect release artifact byte count."

  checksum_tmp="$(prepare_sidecar_temp_output_path "$checksum_path.tmp.XXXXXX")"
  manifest_tmp="$(prepare_sidecar_temp_output_path "$manifest_path.tmp.XXXXXX")"
  signing_details_path="$BUILD_ROOT/ForgePlayRelease.codesign.txt"
  printf '%s\n' "$SIGNING_DETAILS" > "$signing_details_path"

  printf '%s  %s\n' "$dmg_sha" "$(basename "$DMG_PATH")" > "$checksum_tmp"
  mv -f "$checksum_tmp" "$checksum_path"
  require_regular_file "$checksum_path"
  (cd "$(dirname "$DMG_PATH")" && shasum -a 256 -c "$(basename "$checksum_path")" >/dev/null) ||
    fail "release artifact checksum sidecar does not verify."

  FORGEPLAY_RELEASE_MANIFEST_KIND="$release_kind" \
  FORGEPLAY_RELEASE_MANIFEST_CONFIGURATION="$CONFIGURATION" \
  FORGEPLAY_RELEASE_MANIFEST_SIGNING_STYLE="$EXPORT_SIGNING_STYLE" \
  FORGEPLAY_RELEASE_MANIFEST_NOTARIZED="$notarized" \
  FORGEPLAY_RELEASE_MANIFEST_STAPLED="$stapled" \
  FORGEPLAY_RELEASE_MANIFEST_GATEKEEPER_ASSESSED="$gatekeeper_assessed" \
  FORGEPLAY_RELEASE_MANIFEST_BUNDLE_IDENTIFIER="$bundle_identifier" \
  FORGEPLAY_RELEASE_MANIFEST_VERSION="$VERSION" \
  FORGEPLAY_RELEASE_MANIFEST_BUILD="$BUILD" \
  FORGEPLAY_RELEASE_MANIFEST_NOTARY_STATUS="$notary_status" \
  FORGEPLAY_RELEASE_MANIFEST_NOTARY_SUBMISSION_ID="$notary_submission_id" \
  FORGEPLAY_RELEASE_MANIFEST_STAPLER_VALIDATED="$stapler_validated" \
  FORGEPLAY_RELEASE_MANIFEST_DMG_FILE_NAME="$(basename "$DMG_PATH")" \
  FORGEPLAY_RELEASE_MANIFEST_DMG_SIZE="$dmg_size" \
  FORGEPLAY_RELEASE_MANIFEST_DMG_SHA256="$dmg_sha" \
  python3 - "$manifest_tmp" "$signing_details_path" \
    "$PUBLIC_RUNTIME_RELEASE_ATTESTATION" "$PROJECT_SOURCE_BINDING" \
    "$COPYLEFT_SOURCE_ARCHIVE" "$COPYLEFT_SOURCE_RECEIPT" <<'PY'
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

manifest_path = Path(sys.argv[1])
signing_details_path = Path(sys.argv[2])
attestation_path = Path(sys.argv[3])
project_source_binding_path = Path(sys.argv[4]) if sys.argv[4] else None
copyleft_source_archive_path = Path(sys.argv[5]) if sys.argv[5] else None
copyleft_source_receipt_path = Path(sys.argv[6]) if sys.argv[6] else None
signing_details = signing_details_path.read_text(encoding="utf-8", errors="replace").splitlines()
authorities = [
    line.split("=", 1)[1]
    for line in signing_details
    if line.startswith("Authority=")
]
team_identifier = next(
    (line.split("=", 1)[1] for line in signing_details if line.startswith("TeamIdentifier=")),
    "",
)
hardened_runtime = any(re.search(r"flags=.*\bruntime\b", line) for line in signing_details)

release_kind = os.environ["FORGEPLAY_RELEASE_MANIFEST_KIND"]
attestation_binding = None
project_source_binding = None
copyleft_source_binding = None
if release_kind == "commercial-notarized-dmg":
    attestation_raw = attestation_path.read_bytes()
    attestation = json.loads(attestation_raw)
    canonical_attestation = (
        json.dumps(attestation, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    if attestation_raw != canonical_attestation:
        raise SystemExit("public Runtime release attestation is not canonical JSON")
    attestation_binding = {
        "sha256": hashlib.sha256(attestation_raw).hexdigest(),
        "value": attestation,
    }
    project_binding_raw = project_source_binding_path.read_bytes()
    project_binding = json.loads(project_binding_raw)
    canonical_project_binding = (
        json.dumps(project_binding, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    if project_binding_raw != canonical_project_binding:
        raise SystemExit("project Corresponding Source binding is not canonical JSON")
    project_source_binding = {
        "sha256": hashlib.sha256(project_binding_raw).hexdigest(),
        "value": project_binding,
    }
    copyleft_receipt_raw = copyleft_source_receipt_path.read_bytes()
    copyleft_receipt = json.loads(copyleft_receipt_raw)
    canonical_copyleft_receipt = (
        json.dumps(copyleft_receipt, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    if copyleft_receipt_raw != canonical_copyleft_receipt:
        raise SystemExit("copyleft source-package receipt is not canonical JSON")
    archive = copyleft_receipt.get("archive")
    source_tree = copyleft_receipt.get("sourceTree")
    if (
        copyleft_receipt.get("receiptKind") != "forgeplay-copyleft-source-package-v1"
        or not isinstance(archive, dict)
        or archive.get("fileName") != copyleft_source_archive_path.name
        or archive.get("format") != "ustar"
        or not isinstance(source_tree, dict)
    ):
        raise SystemExit("copyleft source-package receipt contract is invalid")
    archive_digest = hashlib.sha256()
    archive_size = 0
    with copyleft_source_archive_path.open("rb") as source_archive:
        for chunk in iter(lambda: source_archive.read(1024 * 1024), b""):
            archive_digest.update(chunk)
            archive_size += len(chunk)
    if (
        archive.get("byteCount") != archive_size
        or archive.get("sha256") != archive_digest.hexdigest()
    ):
        raise SystemExit("copyleft source archive differs from its receipt")
    attested_host_support = (
        attestation.get("runtime", {}).get("subjects", {}).get("hostSupportPayloadFingerprint")
    )
    if copyleft_receipt.get("hostSupportPayloadFingerprint") != attested_host_support:
        raise SystemExit("copyleft source receipt is not bound to the signed Runtime host support payload")
    copyleft_source_binding = {
        "archive": archive,
        "inventorySHA256": copyleft_receipt.get("inventorySHA256"),
        "sourceTreeSHA256": source_tree.get("treeSHA256"),
        "receipt": {
            "sha256": hashlib.sha256(copyleft_receipt_raw).hexdigest(),
            "value": copyleft_receipt,
        },
    }

payload = {
    "schemaVersion": 3,
    "product": "ForgePlay",
    "releaseKind": release_kind,
    "createdAtUTC": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "configuration": os.environ["FORGEPLAY_RELEASE_MANIFEST_CONFIGURATION"],
    "signingStyle": os.environ["FORGEPLAY_RELEASE_MANIFEST_SIGNING_STYLE"],
    "notarized": os.environ["FORGEPLAY_RELEASE_MANIFEST_NOTARIZED"] == "true",
    "stapled": os.environ["FORGEPLAY_RELEASE_MANIFEST_STAPLED"] == "true",
    "gatekeeperAssessed": os.environ["FORGEPLAY_RELEASE_MANIFEST_GATEKEEPER_ASSESSED"] == "true",
    "bundleIdentifier": os.environ["FORGEPLAY_RELEASE_MANIFEST_BUNDLE_IDENTIFIER"],
    "version": os.environ["FORGEPLAY_RELEASE_MANIFEST_VERSION"],
    "build": os.environ["FORGEPLAY_RELEASE_MANIFEST_BUILD"],
    "notarization": {
        "notarytoolStatus": os.environ["FORGEPLAY_RELEASE_MANIFEST_NOTARY_STATUS"],
        "submissionId": os.environ["FORGEPLAY_RELEASE_MANIFEST_NOTARY_SUBMISSION_ID"],
        "staplerValidated": os.environ["FORGEPLAY_RELEASE_MANIFEST_STAPLER_VALIDATED"] == "true",
        "gatekeeperAssessed": os.environ["FORGEPLAY_RELEASE_MANIFEST_GATEKEEPER_ASSESSED"] == "true",
    },
    "artifact": {
        "fileName": os.environ["FORGEPLAY_RELEASE_MANIFEST_DMG_FILE_NAME"],
        "byteCount": int(os.environ["FORGEPLAY_RELEASE_MANIFEST_DMG_SIZE"]),
        "sha256": os.environ["FORGEPLAY_RELEASE_MANIFEST_DMG_SHA256"],
    },
    "appSignature": {
        "authorities": authorities,
        "teamIdentifier": team_identifier,
        "hardenedRuntime": hardened_runtime,
    },
    "publicRuntimeReleaseAttestation": attestation_binding,
    "projectCorrespondingSource": project_source_binding,
    "copyleftSourcePackage": copyleft_source_binding,
}
manifest_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  mv -f "$manifest_tmp" "$manifest_path"
  require_regular_file "$manifest_path"
  python3 -m json.tool "$manifest_path" >/dev/null ||
    fail "release manifest sidecar is not valid JSON."
  bash "$RELEASE_EVIDENCE_VERIFIER" "$DMG_PATH" >/dev/null
  printf 'Release artifact checksum: %s\n' "$checksum_path"
  printf 'Release artifact manifest: %s\n' "$manifest_path"
}

require_command xcodebuild
require_command codesign
require_command hdiutil
require_command lsof
require_command python3
require_command shasum
require_command spctl
require_command strings
require_command xcrun

require_regular_file "$WARNING_CHECKER"
bash -n "$WARNING_CHECKER" || fail "project build warning checker syntax failed."
require_regular_file "$BUILD_ROOT_PREPARER"
bash -n "$BUILD_ROOT_PREPARER" || fail "build root preparer syntax failed."
require_regular_file "$DMG_OUTPUT_PREPARER"
bash -n "$DMG_OUTPUT_PREPARER" || fail "DMG output preparer syntax failed."
require_regular_file "$DMG_CONTENT_VERIFIER"
bash -n "$DMG_CONTENT_VERIFIER" || fail "DMG content verifier syntax failed."
require_regular_file "$APP_INFO_VERIFIER"
bash -n "$APP_INFO_VERIFIER" || fail "release app metadata verifier syntax failed."
require_regular_file "$APP_LOCALIZATION_VERIFIER"
bash -n "$APP_LOCALIZATION_VERIFIER" || fail "release app localization verifier syntax failed."
require_regular_file "$PRIVACY_MANIFEST_VERIFIER"
bash -n "$PRIVACY_MANIFEST_VERIFIER" || fail "privacy manifest verifier syntax failed."
bash "$PRIVACY_MANIFEST_VERIFIER" "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy"
require_regular_file "$LEGAL_DOCUMENT_VERIFIER"
bash -n "$LEGAL_DOCUMENT_VERIFIER" || fail "legal document verifier syntax failed."
bash "$LEGAL_DOCUMENT_VERIFIER" "$ROOT_DIR"
require_regular_file "$PROJECT_DOCUMENT_VERIFIER"
bash -n "$PROJECT_DOCUMENT_VERIFIER" || fail "project document verifier syntax failed."
bash "$PROJECT_DOCUMENT_VERIFIER" "$ROOT_DIR"
require_regular_file "$LICENSE_DOCUMENT_VERIFIER"
bash -n "$LICENSE_DOCUMENT_VERIFIER" || fail "license document verifier syntax failed."
bash "$LICENSE_DOCUMENT_VERIFIER" "$ROOT_DIR"
require_regular_file "$PUBLIC_LICENSE_POLICY_VERIFIER"
bash -n "$PUBLIC_LICENSE_POLICY_VERIFIER" || fail "public release license policy verifier syntax failed."
if [[ "$ALLOW_UNNOTARIZED_DMG" != "1" ]]; then
  require_regular_file "$OPEN_SOURCE_EXPORTER"
  bash -n "$OPEN_SOURCE_EXPORTER" || fail "open-source export script syntax failed."
  bash "$OPEN_SOURCE_EXPORTER"
  require_regular_file "$PUBLIC_ARCHIVE_BUILDER"
  bash -n "$PUBLIC_ARCHIVE_BUILDER" ||
    fail "exported public Distribution archive command syntax failed."
  require_regular_file "$PUBLIC_RUNTIME_BUILDER"
  bash -n "$PUBLIC_RUNTIME_BUILDER" ||
    fail "exported public Runtime build command syntax failed."
  require_regular_file "$PUBLIC_RUNTIME_RELEASE_ATTESTATION_TOOL"
  python3 - "$PUBLIC_RUNTIME_RELEASE_ATTESTATION_TOOL" <<'PY' ||
import sys
from pathlib import Path
compile(Path(sys.argv[1]).read_bytes(), sys.argv[1], "exec")
PY
    fail "exported public Runtime release attestation tool syntax failed."
  require_regular_file "$COPYLEFT_SOURCE_PACKAGE_VERIFIER"
  require_regular_file "$PROJECT_SOURCE_EXPORT_FREEZER"
  python3 - "$COPYLEFT_SOURCE_PACKAGE_VERIFIER" "$PROJECT_SOURCE_EXPORT_FREEZER" <<'PY' ||
import sys
from pathlib import Path
for path in map(Path, sys.argv[1:]):
    compile(path.read_bytes(), str(path), "exec")
PY
    fail "exported source-package freezer/verifier syntax failed."
  [[ -n "$PUBLIC_WINE_SOURCE_ARCHIVE" && -n "$PUBLIC_GSTREAMER_SDK_ROOT" &&
     -n "$PUBLIC_RENDERER_SOURCE" && -n "$PUBLIC_RUNTIME_POLICY_SOURCE" ]] ||
    fail "public release requires FORGEPLAY_PUBLIC_WINE_SOURCE_ARCHIVE, FORGEPLAY_GSTREAMER_SDK_ROOT, FORGEPLAY_RENDERER_SOURCE, and FORGEPLAY_RUNTIME_POLICY_SOURCE"
fi
require_regular_file "$APP_SECURITY_VERIFIER"
bash -n "$APP_SECURITY_VERIFIER" || fail "release app security verifier syntax failed."
require_regular_file "$BUNDLE_PRIVACY_VERIFIER"
bash -n "$BUNDLE_PRIVACY_VERIFIER" || fail "release bundle privacy verifier syntax failed."
require_regular_file "$RELEASE_EVIDENCE_VERIFIER"
bash -n "$RELEASE_EVIDENCE_VERIFIER" || fail "release evidence verifier syntax failed."
require_regular_file "$PUBLIC_RELEASE_ASSET_VERIFIER"
bash -n "$PUBLIC_RELEASE_ASSET_VERIFIER" || fail "public release asset verifier syntax failed."
require_regular_file "$RELEASE_SET_TRANSACTION"
require_regular_file "$NOTARY_SUBMIT_JSON_VERIFIER"
bash -n "$NOTARY_SUBMIT_JSON_VERIFIER" || fail "notary submit JSON verifier syntax failed."
require_regular_file "$APPLE_D3DMETAL_SIGNATURE_RESTORER"
bash -n "$APPLE_D3DMETAL_SIGNATURE_RESTORER" ||
  fail "Apple D3DMetal signature restorer syntax failed."
require_regular_file "$PUBLIC_KEY_VALIDATOR"
require_compatibility_db_public_key_validator
require_regular_file "$COMPAT_KEY_GENERATOR"
xcrun swiftc -parse "$COMPAT_KEY_GENERATOR" >/dev/null 2>&1 || fail "compatibility DB signing key generator syntax failed."
require_regular_file "$COMPAT_FEED_SIGNER"
xcrun swiftc -parse "$COMPAT_FEED_SIGNER" >/dev/null 2>&1 || fail "compatibility DB feed signer syntax failed."

EXPORT_SIGNING_STYLE="$(normalize_export_signing_style "$CODE_SIGN_STYLE")"
validate_release_scheme
configure_archive_signing_args
configure_notary_auth_args
validate_release_mode
check_remote_compatibility_db_key

[[ "$MARKETING_VERSION_VALUE" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] ||
  fail "FORGEPLAY_RELEASE_MARKETING_VERSION must contain two or three numeric components."
[[ "$BUILD_NUMBER_VALUE" =~ ^[1-9][0-9]*$ ]] ||
  fail "FORGEPLAY_RELEASE_BUILD_NUMBER must be a positive integer."

if [[ "$ALLOW_UNNOTARIZED_DMG" != "1" ]]; then
  [[ "$CONFIGURATION" == "Distribution" ]] || fail "DMG release must use Distribution configuration. Use FORGEPLAY_ALLOW_UNNOTARIZED_DMG=1 for local packaging experiments."
  [[ "$SKIP_TESTS" != "1" ]] || fail "commercial release cannot skip tests. FORGEPLAY_SKIP_TESTS=1 is only allowed with FORGEPLAY_ALLOW_UNNOTARIZED_DMG=1 for local packaging."
fi

if [[ "${#NOTARY_AUTH_ARGS[@]}" -eq 0 && "$ALLOW_UNNOTARIZED_DMG" != "1" ]]; then
  print_release_prerequisites_help
  fail "notarization credentials are required. Set FORGEPLAY_NOTARY_PROFILE or FORGEPLAY_NOTARY_KEY_PATH/FORGEPLAY_NOTARY_KEY_ID, or use FORGEPLAY_ALLOW_UNNOTARIZED_DMG=1 for local packaging only."
fi
if [[ "${#NOTARY_AUTH_ARGS[@]}" -gt 0 || "$ALLOW_UNNOTARIZED_DMG" != "1" ]]; then
  require_xcrun_tool notarytool
  require_xcrun_tool stapler
fi

BUILD_ROOT="$(bash "$BUILD_ROOT_PREPARER" "$ROOT_DIR" "$BUILD_ROOT" "release")"
ARCHIVE_PATH="$BUILD_ROOT/ForgePlay.xcarchive"
EXPORT_PATH="$BUILD_ROOT/Export"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"
BUILD_PRODUCTS="$BUILD_ROOT/BuildProducts"
BUILD_INTERMEDIATES="$BUILD_ROOT/BuildIntermediates"
EXPORT_OPTIONS="$BUILD_ROOT/ExportOptions.plist"
DMG_ROOT="$BUILD_ROOT/DmgRoot"
ENTITLEMENTS_PLIST="$BUILD_ROOT/ForgePlayRelease.entitlements.plist"
PUBLIC_BUILD_WORKSPACE="$BUILD_ROOT/PublicSourceBuild"
PUBLIC_RUNTIME_TRANSACTION="$BUILD_ROOT/PublicRuntimeTransaction"
PUBLIC_RUNTIME_OUTPUT="$PUBLIC_RUNTIME_TRANSACTION/output/ForgePlayRuntime"
PUBLIC_RUNTIME_RELEASE_ATTESTATION="$BUILD_ROOT/PublicRuntimeReleaseAttestation.json"
mkdir -p "$BUILD_ROOT"

if [[ "$SKIP_TESTS" != "1" ]]; then
  plutil -lint "$ROOT_DIR"/Resources/*.lproj/Localizable.strings
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$TEST_SCHEME" \
    -destination 'platform=macOS' \
    SYMROOT="$BUILD_PRODUCTS" \
    OBJROOT="$BUILD_INTERMEDIATES" \
    -derivedDataPath "$DERIVED_DATA_PATH" > "$TEST_LOG" 2>&1 || {
      cat "$TEST_LOG" >&2
      fail "XCTest suite failed."
    }
  require_no_project_warnings "$TEST_LOG" "XCTest build"
fi

if [[ "$ALLOW_UNNOTARIZED_DMG" != "1" ]]; then
  /bin/bash "$PUBLIC_RUNTIME_BUILDER" \
    --source-export "$PUBLIC_SOURCE_EXPORT" \
    --trusted-git-repository "$ROOT_DIR" \
    --wine-source-archive "$PUBLIC_WINE_SOURCE_ARCHIVE" \
    --gstreamer-sdk-root "$PUBLIC_GSTREAMER_SDK_ROOT" \
    --renderer-source "$PUBLIC_RENDERER_SOURCE" \
    --runtime-policy-source "$PUBLIC_RUNTIME_POLICY_SOURCE" \
    --transaction-root "$PUBLIC_RUNTIME_TRANSACTION" ||
    fail "public-source Runtime build transaction failed."
  PUBLIC_ARCHIVE_ARGS=(
    --source-export "$PUBLIC_SOURCE_EXPORT"
    --trusted-git-repository "$ROOT_DIR"
    --workspace "$PUBLIC_BUILD_WORKSPACE"
    --runtime-output "$PUBLIC_RUNTIME_OUTPUT"
    --archive-path "$ARCHIVE_PATH"
    --derived-data-path "$DERIVED_DATA_PATH"
    --log "$ARCHIVE_LOG"
    --scheme "$SCHEME"
    --configuration "$CONFIGURATION"
    --signing-style "$CODE_SIGN_STYLE"
    --marketing-version "$MARKETING_VERSION_VALUE"
    --build-number "$BUILD_NUMBER_VALUE"
  )
  if [[ -f "$ROOT_DIR/Config/ForgePlay.local.xcconfig" &&
        ! -L "$ROOT_DIR/Config/ForgePlay.local.xcconfig" ]]; then
    PUBLIC_ARCHIVE_ARGS+=(
      --local-xcconfig "$ROOT_DIR/Config/ForgePlay.local.xcconfig"
    )
  fi
  if [[ -n "$CODE_SIGN_IDENTITY" ]]; then
    PUBLIC_ARCHIVE_ARGS+=(--code-sign-identity "$CODE_SIGN_IDENTITY")
  fi
  /bin/bash "$PUBLIC_ARCHIVE_BUILDER" "${PUBLIC_ARCHIVE_ARGS[@]}" || {
    /bin/cat "$ARCHIVE_LOG" >&2
    fail "public-source Distribution archive failed."
  }
else
  xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    FORGEPLAY_ALLOW_UNNOTARIZED_DMG="$ALLOW_UNNOTARIZED_DMG" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    FORGEPLAY_MARKETING_VERSION="$MARKETING_VERSION_VALUE" \
    FORGEPLAY_CURRENT_PROJECT_VERSION="$BUILD_NUMBER_VALUE" \
    MARKETING_VERSION="$MARKETING_VERSION_VALUE" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER_VALUE" \
    "${ARCHIVE_SIGNING_ARGS[@]}" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    -derivedDataPath "$DERIVED_DATA_PATH" > "$ARCHIVE_LOG" 2>&1 || {
      cat "$ARCHIVE_LOG" >&2
      fail "Release archive failed."
    }
fi
require_no_project_warnings "$ARCHIVE_LOG" "Release archive"

/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :method string developer-id' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :destination string export' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Add :signingStyle string $EXPORT_SIGNING_STYLE" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :stripSwiftSymbols bool true' "$EXPORT_OPTIONS"
if [[ "$EXPORT_SIGNING_STYLE" == "manual" ]]; then
  /usr/libexec/PlistBuddy -c "Add :signingCertificate string $CODE_SIGN_IDENTITY" "$EXPORT_OPTIONS"
fi

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates > "$EXPORT_LOG" 2>&1 || {
    cat "$EXPORT_LOG" >&2
    fail "Developer ID export failed."
  }
require_no_project_warnings "$EXPORT_LOG" "Developer ID export"

APP_PATH="$EXPORT_PATH/ForgePlay.app"
[[ -d "$APP_PATH" ]] || fail "exported app not found: $APP_PATH"
if [[ "$ALLOW_UNNOTARIZED_DMG" == "1" ]]; then
  [[ ! -e "$APP_PATH/Contents/Resources/PublicDistributionBuildClaim.json" &&
     ! -L "$APP_PATH/Contents/Resources/PublicDistributionBuildClaim.json" ]] ||
    fail "local QA app must not contain a public Distribution build claim."
fi
bash "$APPLE_D3DMETAL_SIGNATURE_RESTORER" \
  "$ARCHIVE_PATH/Products/Applications/ForgePlay.app" \
  "$APP_PATH" \
  "$CODE_SIGN_IDENTITY"
bash "$APP_INFO_VERIFIER" "$APP_PATH"
bash "$APP_LOCALIZATION_VERIFIER" "$APP_PATH"
bash "$PRIVACY_MANIFEST_VERIFIER" "$APP_PATH"
bash "$LEGAL_DOCUMENT_VERIFIER" "$APP_PATH"
bash "$PROJECT_DOCUMENT_VERIFIER" "$APP_PATH"
bash "$LICENSE_DOCUMENT_VERIFIER" "$APP_PATH"
require_app_compatibility_db_public_key "$APP_PATH"

ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
[[ "$ICON_NAME" == "AppIcon" ]] || fail "exported app is missing CFBundleIconName=AppIcon."

ASSETS_CAR="$APP_PATH/Contents/Resources/Assets.car"
[[ -f "$ASSETS_CAR" ]] || fail "exported app is missing compiled asset catalog."
python3 - "$ASSETS_CAR" <<'PY' || fail "compiled asset catalog is missing the required AppIcon or LaunchSplash rendition."
import json
import subprocess
import sys

asset_catalog = sys.argv[1]
payload = subprocess.run(
    ["xcrun", "assetutil", "--info", asset_catalog],
    check=True,
    capture_output=True,
    text=True,
)
entries = json.loads(payload.stdout)
has_app_icon = any(
    isinstance(entry, dict)
    and entry.get("AssetType") == "MultiSized Image"
    and entry.get("Name") == "AppIcon"
    and "1024x1024 index:7 idiom:universal" in entry.get("Sizes", [])
    for entry in entries
)
has_launch_splash = any(
    isinstance(entry, dict)
    and entry.get("AssetType") == "Image"
    and entry.get("Name") == "LaunchSplash"
    and entry.get("PixelWidth") == 1600
    and entry.get("PixelHeight") == 1000
    for entry in entries
)
if not has_app_icon or not has_launch_splash:
    raise SystemExit(1)
PY

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
SIGNING_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)"
printf '%s\n' "$SIGNING_DETAILS" | grep -Eq 'flags=.*\bruntime\b' || {
  printf '%s\n' "$SIGNING_DETAILS" >&2
  fail "exported app is not signed with Hardened Runtime."
}
printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Authority=Developer ID Application' || {
  printf '%s\n' "$SIGNING_DETAILS" >&2
  fail "exported app is not signed with Developer ID Application."
}
DMG_SIGNING_IDENTITY="$(
  printf '%s\n' "$SIGNING_DETAILS" |
    awk -F= '/^Authority=Developer ID Application:/ { sub(/^Authority=/, ""); print; exit }'
)"
[[ -n "$DMG_SIGNING_IDENTITY" ]] ||
  fail "exported app Developer ID signing identity could not be resolved for DMG signing."
APP_TEAM_IDENTIFIER="$(
  printf '%s\n' "$SIGNING_DETAILS" |
    awk -F= '/^TeamIdentifier=/ { print $2; exit }'
)"
[[ -n "$APP_TEAM_IDENTIFIER" ]] ||
  fail "exported app TeamIdentifier could not be resolved for DMG signing."

codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_PLIST" 2>/dev/null || {
  fail "exported app entitlements could not be read."
}
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$ENTITLEMENTS_PLIST" 2>/dev/null || true)" == "true" ]]; then
  fail "exported app contains com.apple.security.get-task-allow; this is not allowed for commercial release."
fi
require_true_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.app-sandbox"
require_true_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.files.user-selected.read-write"
require_true_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.files.user-selected.executable"
require_true_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.files.bookmarks.app-scope"
require_true_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.cs.allow-unsigned-executable-memory"
require_true_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.network.client"
if [[ -n "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.allow-jit' "$ENTITLEMENTS_PLIST" 2>/dev/null || true)" ]]; then
  fail "exported DMG app must not enable com.apple.security.cs.allow-jit in the main process."
fi
if [[ -n "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$ENTITLEMENTS_PLIST" 2>/dev/null || true)" ]]; then
  fail "exported DMG app must not disable library validation in the main process."
fi

require_release_app_excludes_debug_launch_hooks "$APP_PATH"
bash "$APP_SECURITY_VERIFIER" --require-developer-id "$APP_PATH" >/dev/null
bash "$BUNDLE_PRIVACY_VERIFIER" --project-root "$ROOT_DIR" "$APP_PATH" >/dev/null

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
[[ "$VERSION" == "$MARKETING_VERSION_VALUE" ]] ||
  fail "exported app marketing version is $VERSION; expected $MARKETING_VERSION_VALUE."
[[ "$BUILD" == "$BUILD_NUMBER_VALUE" ]] ||
  fail "exported app build number is $BUILD; expected $BUILD_NUMBER_VALUE."
if [[ "$ALLOW_UNNOTARIZED_DMG" != "1" ]]; then
  python3 "$PUBLIC_RUNTIME_RELEASE_ATTESTATION_TOOL" create \
    --app "$APP_PATH" \
    --attestation "$PUBLIC_RUNTIME_RELEASE_ATTESTATION" ||
    fail "Developer ID signed Runtime release attestation could not be created."
fi
FINAL_DMG_PATH="$(bash "$DMG_OUTPUT_PREPARER" "$ROOT_DIR" "$DIST_DIR" "$VERSION" "$BUILD")"
RELEASE_STAGE_DIR="$(python3 "$RELEASE_SET_TRANSACTION" create-stage \
  --destination-dmg "$FINAL_DMG_PATH")" ||
  fail "private adjacent release-set stage could not be created."
DMG_PATH="$RELEASE_STAGE_DIR/$(basename "$FINAL_DMG_PATH")"
if [[ "$ALLOW_UNNOTARIZED_DMG" != "1" ]]; then
  RELEASE_BASE="${DMG_PATH%.dmg}"
  PROJECT_SOURCE_ARCHIVE="$RELEASE_BASE-OpenSource.tar"
  COPYLEFT_SOURCE_ARCHIVE="$RELEASE_BASE-ThirdPartyCorrespondingSource.tar"
  COPYLEFT_SOURCE_RECEIPT="$RELEASE_BASE-ThirdPartyCorrespondingSource.receipt.json"
  PROJECT_SOURCE_BINDING="$BUILD_ROOT/ProjectCorrespondingSource.binding.json"
  python3 - "$PUBLIC_WINE_SOURCE_ARCHIVE" \
    "$PUBLIC_SOURCE_EXPORT/Config/ForgePlayRuntimeSourceIdentity.lock.json" <<'PY' ||
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

archive_path = Path(sys.argv[1])
lock_path = Path(sys.argv[2])
descriptor = os.open(archive_path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise SystemExit("Wine source archive must be a single-link regular file")
    digest = hashlib.sha256()
    total = 0
    while chunk := os.read(descriptor, 1024 * 1024):
        digest.update(chunk)
        total += len(chunk)
    after = os.fstat(descriptor)
    identity = lambda value: (
        value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
        value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    )
    if identity(before) != identity(after) or total != before.st_size:
        raise SystemExit("Wine source archive changed while hashing")
finally:
    os.close(descriptor)
lock = json.loads(lock_path.read_text(encoding="utf-8"))
expected = lock.get("upstreamSource", {}).get("archiveSHA256")
if digest.hexdigest() != expected:
    raise SystemExit("Wine source archive SHA-256 differs from exported source identity lock")
PY
    fail "Wine source archive does not match the exported source identity lock."
  python3 "$PROJECT_SOURCE_EXPORT_FREEZER" create \
    --source-export "$PUBLIC_SOURCE_EXPORT" \
    --archive-out "$PROJECT_SOURCE_ARCHIVE" \
    --binding-out "$PROJECT_SOURCE_BINDING" \
    --additional-file "$PUBLIC_WINE_SOURCE_ARCHIVE" \
    --additional-path "CorrespondingSource/Wine/wine-11.12.tar.xz" ||
    fail "project Corresponding Source export could not be frozen."
  python3 "$PROJECT_SOURCE_EXPORT_FREEZER" verify \
    --archive "$PROJECT_SOURCE_ARCHIVE" \
    --binding "$PROJECT_SOURCE_BINDING" ||
    fail "frozen project Corresponding Source export did not verify."
  python3 "$COPYLEFT_SOURCE_PACKAGE_VERIFIER" \
    --inventory "$PUBLIC_SOURCE_EXPORT/Config/ForgePlayCopyleftSourcePackages.json" \
    --runtime-sbom "$APP_PATH/Contents/Resources/Runners/ForgePlayRuntime/RuntimeSBOM.json" \
    --dependency-lock "$PUBLIC_SOURCE_EXPORT/Config/ForgePlayRuntimeDependencies.lock.json" \
    --gstreamer-lock "$PUBLIC_SOURCE_EXPORT/Config/ForgePlayGStreamerPayload.lock.json" \
    --source-root "$COPYLEFT_SOURCE_PACKAGE_ROOT" \
    --archive-out "$COPYLEFT_SOURCE_ARCHIVE" \
    --receipt-out "$COPYLEFT_SOURCE_RECEIPT" ||
    fail "third-party copyleft Corresponding Source could not be frozen."
  bash "$PUBLIC_LICENSE_POLICY_VERIFIER" \
    --corresponding-source "$PUBLIC_SOURCE_EXPORT" \
    --trusted-git-repository "$ROOT_DIR" \
    --release-attestation "$PUBLIC_RUNTIME_RELEASE_ATTESTATION" \
    --copyleft-source-archive "$COPYLEFT_SOURCE_ARCHIVE" \
    --copyleft-source-receipt "$COPYLEFT_SOURCE_RECEIPT" \
    "$APP_PATH"
fi

rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT"
/usr/bin/ditto "$APP_PATH" "$DMG_ROOT/ForgePlay.app"
ln -s /Applications "$DMG_ROOT/Applications"
bash "$DMG_CONTENT_VERIFIER" "$DMG_ROOT"
bash "$APP_INFO_VERIFIER" "$DMG_ROOT/ForgePlay.app"
bash "$APP_LOCALIZATION_VERIFIER" "$DMG_ROOT/ForgePlay.app"
bash "$PRIVACY_MANIFEST_VERIFIER" "$DMG_ROOT/ForgePlay.app"
bash "$LEGAL_DOCUMENT_VERIFIER" "$DMG_ROOT/ForgePlay.app"
bash "$PROJECT_DOCUMENT_VERIFIER" "$DMG_ROOT/ForgePlay.app"
bash "$LICENSE_DOCUMENT_VERIFIER" "$DMG_ROOT/ForgePlay.app"
if [[ "$ALLOW_UNNOTARIZED_DMG" != "1" ]]; then
  bash "$PUBLIC_LICENSE_POLICY_VERIFIER" \
    --corresponding-source "$PUBLIC_SOURCE_EXPORT" \
    --trusted-git-repository "$ROOT_DIR" \
    --release-attestation "$PUBLIC_RUNTIME_RELEASE_ATTESTATION" \
    --copyleft-source-archive "$COPYLEFT_SOURCE_ARCHIVE" \
    --copyleft-source-receipt "$COPYLEFT_SOURCE_RECEIPT" \
    "$DMG_ROOT/ForgePlay.app"
fi
bash "$APP_SECURITY_VERIFIER" --require-developer-id "$DMG_ROOT/ForgePlay.app" >/dev/null
bash "$BUNDLE_PRIVACY_VERIFIER" --project-root "$ROOT_DIR" "$DMG_ROOT/ForgePlay.app" >/dev/null

hdiutil create \
  -volname "ForgePlay" \
  -srcfolder "$DMG_ROOT" \
  -format UDZO \
  "$DMG_PATH"
codesign --timestamp --sign "$DMG_SIGNING_IDENTITY" "$DMG_PATH" || {
  fail "DMG Developer ID signing failed. Ensure the exported app signing identity and private key are available in the local Keychain."
}
codesign --verify --verbose=4 "$DMG_PATH" ||
  fail "created DMG Developer ID signature verification failed."
DMG_SIGNING_DETAILS="$(codesign -dvvv "$DMG_PATH" 2>&1 || true)"
printf '%s\n' "$DMG_SIGNING_DETAILS" | grep -Fq "Authority=$DMG_SIGNING_IDENTITY" || {
  printf '%s\n' "$DMG_SIGNING_DETAILS" >&2
  fail "created DMG is not signed with the exported app Developer ID identity."
}
printf '%s\n' "$DMG_SIGNING_DETAILS" | grep -Fq 'Timestamp=' || {
  printf '%s\n' "$DMG_SIGNING_DETAILS" >&2
  fail "created DMG Developer ID signature is missing a secure timestamp."
}
DMG_TEAM_IDENTIFIER="$(
  printf '%s\n' "$DMG_SIGNING_DETAILS" |
    awk -F= '/^TeamIdentifier=/ { print $2; exit }'
)"
[[ "$DMG_TEAM_IDENTIFIER" == "$APP_TEAM_IDENTIFIER" ]] || {
  printf '%s\n' "$DMG_SIGNING_DETAILS" >&2
  fail "created DMG signing team does not match the exported app signing team."
}
verify_dmg_artifact "$DMG_PATH" "created DMG"

if [[ "${#NOTARY_AUTH_ARGS[@]}" -gt 0 ]]; then
  xcrun notarytool submit "$DMG_PATH" "${NOTARY_AUTH_ARGS[@]}" --wait --output-format json > "$NOTARY_JSON_LOG" 2> "$NOTARY_ERROR_LOG" || {
    cat "$NOTARY_ERROR_LOG" >&2
    cat "$NOTARY_JSON_LOG" >&2
    fail "notarytool submit failed."
  }
  if [[ -s "$NOTARY_ERROR_LOG" ]]; then
    cat "$NOTARY_ERROR_LOG" >&2
  fi
  cat "$NOTARY_JSON_LOG"
  NOTARY_SUBMISSION_ID="$(bash "$NOTARY_SUBMIT_JSON_VERIFIER" "$NOTARY_JSON_LOG")" || {
    cat "$NOTARY_ERROR_LOG" >&2
    cat "$NOTARY_JSON_LOG" >&2
    fail "notarytool submit did not produce accepted notarization evidence."
  }
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  verify_dmg_artifact "$DMG_PATH" "stapled DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
  write_release_evidence "commercial-notarized-dmg" "true" "true" "true" "$BUNDLE_IDENTIFIER" "Accepted" "$NOTARY_SUBMISSION_ID" "true"
  bash "$PUBLIC_RELEASE_ASSET_VERIFIER" "$DMG_PATH" >/dev/null
  python3 "$RELEASE_SET_TRANSACTION" publish \
    --stage-dir "$RELEASE_STAGE_DIR" \
    --destination-dmg "$FINAL_DMG_PATH" ||
    fail "verified commercial release set could not be transactionally published."
  RELEASE_STAGE_DIR=""
  DMG_PATH="$FINAL_DMG_PATH"
  printf 'Commercial release artifact: %s\n' "$DMG_PATH"
else
  printf 'warning: notarization was skipped because FORGEPLAY_ALLOW_UNNOTARIZED_DMG=1. This artifact is for local packaging checks only.\n' >&2
  write_release_evidence "local-unnotarized-dmg" "false" "false" "false" "$BUNDLE_IDENTIFIER" "not-run" "" "false"
  python3 "$RELEASE_SET_TRANSACTION" publish \
    --stage-dir "$RELEASE_STAGE_DIR" \
    --destination-dmg "$FINAL_DMG_PATH" ||
    fail "verified local release set could not be transactionally published."
  RELEASE_STAGE_DIR=""
  DMG_PATH="$FINAL_DMG_PATH"
  printf 'Unnotarized local DMG artifact: %s\n' "$DMG_PATH"
fi
