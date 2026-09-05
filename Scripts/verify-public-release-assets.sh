#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:-}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
RELEASE_EVIDENCE_VERIFIER="$ROOT_DIR/Scripts/verify-release-evidence.sh"
DMG_CONTENT_VERIFIER="$ROOT_DIR/Scripts/verify-dmg-contents.sh"
APP_INFO_VERIFIER="$ROOT_DIR/Scripts/verify-release-app-info.sh"
APP_LOCALIZATION_VERIFIER="$ROOT_DIR/Scripts/verify-release-app-localizations.sh"
PRIVACY_MANIFEST_VERIFIER="$ROOT_DIR/Scripts/verify-privacy-manifest.sh"
LEGAL_DOCUMENT_VERIFIER="$ROOT_DIR/Scripts/verify-legal-documents.sh"
LICENSE_DOCUMENT_VERIFIER="$ROOT_DIR/Scripts/verify-license-documents.sh"
PUBLIC_LICENSE_POLICY_VERIFIER="$ROOT_DIR/Scripts/verify-public-release-license-policy.sh"
PUBLIC_RUNTIME_RELEASE_ATTESTATION_VERIFIER="$ROOT_DIR/Scripts/public-runtime-release-attestation.py"
PROJECT_SOURCE_EXPORT_FREEZER="$ROOT_DIR/Scripts/freeze-public-source-export.py"
COPYLEFT_SOURCE_PACKAGE_VERIFIER="$ROOT_DIR/Scripts/verify-copyleft-source-packages.py"
OPEN_SOURCE_EXPORT_VERIFIER="$ROOT_DIR/Scripts/verify-open-source-export.sh"
RELEASE_SET_TRANSACTION="$ROOT_DIR/Scripts/public-release-set-transaction.py"
APP_SECURITY_VERIFIER="$ROOT_DIR/Scripts/verify-release-app-security.sh"
BUNDLE_PRIVACY_VERIFIER="$ROOT_DIR/Scripts/verify-release-bundle-privacy.sh"
DMG_MOUNT_POINT=""
ATTESTATION_TEMP_PATH=""
PROJECT_SOURCE_BINDING_TEMP_PATH=""
PROJECT_SOURCE_EXTRACT_ROOT=""
ASSET_SNAPSHOT_ROOT=""

cleanup_mounted_dmg() {
  if [[ -n "$ATTESTATION_TEMP_PATH" ]]; then
    /bin/rm -f "$ATTESTATION_TEMP_PATH"
    ATTESTATION_TEMP_PATH=""
  fi
  if [[ -n "$PROJECT_SOURCE_BINDING_TEMP_PATH" ]]; then
    /bin/rm -f "$PROJECT_SOURCE_BINDING_TEMP_PATH"
    PROJECT_SOURCE_BINDING_TEMP_PATH=""
  fi
  if [[ -n "$PROJECT_SOURCE_EXTRACT_ROOT" ]]; then
    /bin/rm -rf "$PROJECT_SOURCE_EXTRACT_ROOT"
    PROJECT_SOURCE_EXTRACT_ROOT=""
  fi
  if [[ -n "$ASSET_SNAPSHOT_ROOT" ]]; then
    /bin/rm -rf "$ASSET_SNAPSHOT_ROOT"
    ASSET_SNAPSHOT_ROOT=""
  fi
  if [[ -n "$DMG_MOUNT_POINT" ]]; then
    hdiutil detach "$DMG_MOUNT_POINT" -quiet >/dev/null 2>&1 ||
      hdiutil detach "$DMG_MOUNT_POINT" -force -quiet >/dev/null 2>&1 ||
      true
    rmdir "$DMG_MOUNT_POINT" >/dev/null 2>&1 || true
    DMG_MOUNT_POINT=""
  fi
}
trap cleanup_mounted_dmg EXIT

fail() {
  printf 'error: invalid public release assets: %s\n' "$*" >&2
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

require_directory() {
  local path="$1"
  local label="$2"
  reject_symlink_parent_components "$path" "$label"
  [[ -d "$path" && ! -L "$path" ]] || fail "$label must be a non-symlink directory: $path"
}

verify_dmg_developer_id_signature() {
  local dmg_path="$1"
  local manifest_path="$2"
  local signing_details dmg_team_identifier manifest_team_identifier

  codesign --verify --verbose=4 "$dmg_path" ||
    fail "public release DMG Developer ID signature verification failed"
  signing_details="$(codesign -dvvv "$dmg_path" 2>&1 || true)"
  printf '%s\n' "$signing_details" | grep -Fq 'Authority=Developer ID Application:' ||
    fail "public release DMG is not signed with Developer ID Application"
  printf '%s\n' "$signing_details" | grep -Fq 'Authority=Developer ID Certification Authority' ||
    fail "public release DMG signature is missing the Developer ID certificate chain"
  printf '%s\n' "$signing_details" | grep -Fq 'Authority=Apple Root CA' ||
    fail "public release DMG signature is missing the Apple root certificate"
  printf '%s\n' "$signing_details" | grep -Fq 'Timestamp=' ||
    fail "public release DMG signature is missing a secure timestamp"

  dmg_team_identifier="$(
    printf '%s\n' "$signing_details" |
      awk -F= '/^TeamIdentifier=/ { print $2; exit }'
  )"
  [[ -n "$dmg_team_identifier" ]] ||
    fail "public release DMG signature is missing TeamIdentifier"
  manifest_team_identifier="$(
    python3 - "$manifest_path" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
signature = payload.get("appSignature")
if not isinstance(signature, dict):
    raise SystemExit("release manifest appSignature must be an object")
team_identifier = signature.get("teamIdentifier")
if not isinstance(team_identifier, str) or not team_identifier:
    raise SystemExit("release manifest appSignature teamIdentifier must be a non-empty string")
print(team_identifier)
PY
  )" || fail "public release manifest signing team could not be read"
  [[ "$dmg_team_identifier" == "$manifest_team_identifier" ]] ||
    fail "public release DMG signing team does not match the app signing team in the release manifest"
}

require_release_directory_contents() {
  local directory="$1"
  local dmg_path="$2"
  local dmg_name checksum_name manifest_name release_base_name project_source_name copyleft_source_name copyleft_receipt_name entry entry_name
  local -a unexpected_entries

  dmg_name="$(basename "$dmg_path")"
  checksum_name="$dmg_name.sha256"
  manifest_name="$dmg_name.release.json"
  release_base_name="${dmg_name%.dmg}"
  project_source_name="$release_base_name-OpenSource.tar"
  copyleft_source_name="$release_base_name-ThirdPartyCorrespondingSource.tar"
  copyleft_receipt_name="$release_base_name-ThirdPartyCorrespondingSource.receipt.json"
  unexpected_entries=()

  while IFS= read -r -d '' entry; do
    entry_name="$(basename "$entry")"
    if [[ "$entry_name" != "$dmg_name" &&
          "$entry_name" != "$checksum_name" &&
          "$entry_name" != "$manifest_name" &&
          "$entry_name" != "$project_source_name" &&
          "$entry_name" != "$copyleft_source_name" &&
          "$entry_name" != "$copyleft_receipt_name" ]]; then
      unexpected_entries+=("$entry_name")
    fi
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -print0)

  if [[ "${#unexpected_entries[@]}" -ne 0 ]]; then
    fail "commercial release asset directory must contain only the exact six-file DMG, checksum, manifest, project source archive, copyleft source archive, and copyleft receipt set; unexpected entries: ${unexpected_entries[*]}"
  fi
}

verify_manifest_matches_mounted_app() {
  local manifest_path="$1"
  local mounted_app="$2"
  local info_plist="$mounted_app/Contents/Info.plist"

  python3 - "$manifest_path" "$info_plist" "$mounted_app" <<'PY'
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
info_plist = Path(sys.argv[2])
app_path = Path(sys.argv[3])

payload = json.loads(manifest_path.read_text(encoding="utf-8"))
with info_plist.open("rb") as handle:
    info = plistlib.load(handle)

codesign_result = subprocess.run(
    ["codesign", "-dv", "--verbose=4", str(app_path)],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)

def require(condition, message):
    if not condition:
        raise SystemExit(message)

require(codesign_result.returncode == 0, "mounted app signing details could not be read")
signing_details = "\n".join(part for part in (codesign_result.stdout, codesign_result.stderr) if part)
authorities = [
    line.split("=", 1)[1]
    for line in signing_details.splitlines()
    if line.startswith("Authority=")
]
runtime_enabled = re.search(r"flags=.*\bruntime\b", signing_details) is not None
team_identifier = next(
    (line.split("=", 1)[1] for line in signing_details.splitlines() if line.startswith("TeamIdentifier=")),
    "",
)
signature = payload.get("appSignature")

require(payload.get("bundleIdentifier") == info.get("CFBundleIdentifier"), "public release manifest bundleIdentifier must match mounted app CFBundleIdentifier")
require(payload.get("version") == info.get("CFBundleShortVersionString"), "public release manifest version must match mounted app CFBundleShortVersionString")
require(payload.get("build") == info.get("CFBundleVersion"), "public release manifest build must match mounted app CFBundleVersion")
require(isinstance(signature, dict), "public release manifest appSignature must be an object")
require(signature.get("teamIdentifier") == team_identifier, "public release manifest appSignature teamIdentifier must match mounted app codesign team")
require(signature.get("authorities") == authorities, "public release manifest appSignature must match mounted app codesign authorities")
require(signature.get("hardenedRuntime") == runtime_enabled, "public release manifest appSignature hardenedRuntime must match mounted app codesign runtime flag")
print("Public release manifest matches mounted app metadata and signature.")
PY
}

verify_mounted_public_dmg() {
  local dmg_path="$1"
  local manifest_path="$2"
  local mounted_app

  DMG_MOUNT_POINT="$(mktemp -d "$DEFAULT_TEMP_ROOT/forgeplay-public-release-dmg-mount.XXXXXX")" ||
    fail "public release DMG mount point could not be created"
  hdiutil attach -readonly -nobrowse -mountpoint "$DMG_MOUNT_POINT" "$dmg_path" >/dev/null ||
    fail "public release DMG did not attach as a read-only volume"
  mounted_app="$DMG_MOUNT_POINT/ForgePlay.app"
  ATTESTATION_TEMP_PATH="$(mktemp "$DEFAULT_TEMP_ROOT/forgeplay-runtime-release-attestation.XXXXXX")" ||
    fail "public Runtime release attestation temporary file could not be created"
  python3 - "$manifest_path" "$ATTESTATION_TEMP_PATH" <<'PY' ||
import hashlib
import json
import sys
from pathlib import Path

manifest_path, output_path = map(Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
binding = manifest.get("publicRuntimeReleaseAttestation")
if not isinstance(binding, dict) or set(binding) != {"sha256", "value"}:
    raise SystemExit("release manifest lacks its public Runtime release attestation")
value = binding["value"]
payload = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
if hashlib.sha256(payload).hexdigest() != binding["sha256"]:
    raise SystemExit("release manifest public Runtime release attestation digest is invalid")
output_path.write_bytes(payload)
PY
    fail "public Runtime release attestation could not be materialized from the release manifest"
  PROJECT_SOURCE_BINDING_TEMP_PATH="$(mktemp "$DEFAULT_TEMP_ROOT/forgeplay-project-source-binding.XXXXXX")" ||
    fail "project Corresponding Source binding temporary file could not be created"
  python3 - "$manifest_path" "$PROJECT_SOURCE_BINDING_TEMP_PATH" <<'PY' ||
import hashlib
import json
import sys
from pathlib import Path

manifest_path, output_path = map(Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
binding = manifest.get("projectCorrespondingSource")
if not isinstance(binding, dict) or set(binding) != {"sha256", "value"}:
    raise SystemExit("release manifest lacks its project Corresponding Source binding")
payload = (json.dumps(binding["value"], indent=2, sort_keys=True) + "\n").encode("utf-8")
if hashlib.sha256(payload).hexdigest() != binding["sha256"]:
    raise SystemExit("release manifest project Corresponding Source binding digest is invalid")
output_path.write_bytes(payload)
PY
    fail "project Corresponding Source binding could not be materialized from the release manifest"
  python3 "$PROJECT_SOURCE_EXPORT_FREEZER" verify \
    --archive "$PROJECT_SOURCE_ARCHIVE" \
    --binding "$PROJECT_SOURCE_BINDING_TEMP_PATH" >/dev/null ||
    fail "published project Corresponding Source archive does not match its release binding"
  PROJECT_SOURCE_EXTRACT_ROOT="$(mktemp -d "$DEFAULT_TEMP_ROOT/forgeplay-project-source-export.XXXXXX")" ||
    fail "project Corresponding Source extraction root could not be created"
  /usr/bin/tar -xf "$PROJECT_SOURCE_ARCHIVE" -C "$PROJECT_SOURCE_EXTRACT_ROOT" ||
    fail "verified project Corresponding Source archive could not be extracted"
  require_directory "$PROJECT_SOURCE_EXTRACT_ROOT/OpenSource" "published project Corresponding Source export"
  require_regular_file "$PROJECT_SOURCE_EXTRACT_ROOT/CorrespondingSource/Wine/wine-11.12.tar.xz" "published Wine 11.12 Corresponding Source archive"
  python3 - \
    "$PROJECT_SOURCE_EXTRACT_ROOT/CorrespondingSource/Wine/wine-11.12.tar.xz" \
    "$PROJECT_SOURCE_EXTRACT_ROOT/OpenSource/Config/ForgePlayRuntimeSourceIdentity.lock.json" <<'PY' ||
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

archive_path, lock_path = map(Path, sys.argv[1:])
descriptor = os.open(archive_path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise SystemExit("published Wine source archive is not a single-link regular file")
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
        raise SystemExit("published Wine source archive changed while hashing")
finally:
    os.close(descriptor)
lock = json.loads(lock_path.read_text(encoding="utf-8"))
if digest.hexdigest() != lock.get("upstreamSource", {}).get("archiveSHA256"):
    raise SystemExit("published Wine source archive differs from exported source identity lock")
PY
    fail "published Wine Corresponding Source does not match the exported source identity lock"
  bash "$OPEN_SOURCE_EXPORT_VERIFIER" \
    --project-root "$ROOT_DIR" \
    --release-authority \
    --trusted-git-repository "$ROOT_DIR" \
    "$PROJECT_SOURCE_EXTRACT_ROOT/OpenSource" >/dev/null ||
    fail "published project Corresponding Source export lacks release authority"
  python3 "$COPYLEFT_SOURCE_PACKAGE_VERIFIER" \
    --inventory "$PROJECT_SOURCE_EXTRACT_ROOT/OpenSource/Config/ForgePlayCopyleftSourcePackages.json" \
    --runtime-sbom "$mounted_app/Contents/Resources/Runners/ForgePlayRuntime/RuntimeSBOM.json" \
    --dependency-lock "$PROJECT_SOURCE_EXTRACT_ROOT/OpenSource/Config/ForgePlayRuntimeDependencies.lock.json" \
    --gstreamer-lock "$PROJECT_SOURCE_EXTRACT_ROOT/OpenSource/Config/ForgePlayGStreamerPayload.lock.json" \
    --archive "$COPYLEFT_SOURCE_ARCHIVE" \
    --receipt "$COPYLEFT_SOURCE_RECEIPT" >/dev/null ||
    fail "published copyleft source package does not match the mounted Runtime and exported locks"
  python3 "$PUBLIC_RUNTIME_RELEASE_ATTESTATION_VERIFIER" verify \
    --app "$mounted_app" \
    --attestation "$ATTESTATION_TEMP_PATH" >/dev/null ||
    fail "public Runtime release attestation does not match the mounted signed app"
  bash "$DMG_CONTENT_VERIFIER" "$DMG_MOUNT_POINT" >/dev/null
  bash "$APP_INFO_VERIFIER" "$mounted_app" >/dev/null
  bash "$APP_LOCALIZATION_VERIFIER" "$mounted_app" >/dev/null
  bash "$PRIVACY_MANIFEST_VERIFIER" "$mounted_app" >/dev/null
  bash "$LEGAL_DOCUMENT_VERIFIER" "$mounted_app" >/dev/null
  bash "$LICENSE_DOCUMENT_VERIFIER" "$mounted_app" >/dev/null
  bash "$PUBLIC_LICENSE_POLICY_VERIFIER" \
    --corresponding-source "$PROJECT_SOURCE_EXTRACT_ROOT/OpenSource" \
    --trusted-git-repository "$ROOT_DIR" \
    --release-attestation "$ATTESTATION_TEMP_PATH" \
    --copyleft-source-archive "$COPYLEFT_SOURCE_ARCHIVE" \
    --copyleft-source-receipt "$COPYLEFT_SOURCE_RECEIPT" \
    "$mounted_app" >/dev/null
  bash "$APP_SECURITY_VERIFIER" --require-developer-id "$mounted_app" >/dev/null
  bash "$BUNDLE_PRIVACY_VERIFIER" --project-root "$ROOT_DIR" "$mounted_app" >/dev/null
  verify_manifest_matches_mounted_app "$manifest_path" "$mounted_app" >/dev/null
  cleanup_mounted_dmg
}

[[ -n "$INPUT_PATH" ]] || fail "usage: verify-public-release-assets.sh <release asset directory or dmg path>"
require_regular_file "$RELEASE_EVIDENCE_VERIFIER" "release evidence verifier"
require_regular_file "$DMG_CONTENT_VERIFIER" "DMG content verifier"
require_regular_file "$APP_INFO_VERIFIER" "release app metadata verifier"
require_regular_file "$APP_LOCALIZATION_VERIFIER" "release app localization verifier"
require_regular_file "$PRIVACY_MANIFEST_VERIFIER" "privacy manifest verifier"
require_regular_file "$LEGAL_DOCUMENT_VERIFIER" "legal document verifier"
require_regular_file "$LICENSE_DOCUMENT_VERIFIER" "license document verifier"
require_regular_file "$PUBLIC_LICENSE_POLICY_VERIFIER" "public release license policy verifier"
require_regular_file "$PUBLIC_RUNTIME_RELEASE_ATTESTATION_VERIFIER" "public Runtime release attestation verifier"
require_regular_file "$PROJECT_SOURCE_EXPORT_FREEZER" "project Corresponding Source freezer/verifier"
require_regular_file "$COPYLEFT_SOURCE_PACKAGE_VERIFIER" "copyleft source-package verifier"
require_regular_file "$OPEN_SOURCE_EXPORT_VERIFIER" "open-source export verifier"
require_regular_file "$RELEASE_SET_TRANSACTION" "public release-set transaction helper"
require_regular_file "$APP_SECURITY_VERIFIER" "release app security verifier"
require_regular_file "$BUNDLE_PRIVACY_VERIFIER" "release bundle privacy verifier"

ASSET_SNAPSHOT_ROOT="$(mktemp -d "$DEFAULT_TEMP_ROOT/forgeplay-public-release-snapshot.XXXXXX")" ||
  fail "private public release snapshot directory could not be created"
chmod 0700 "$ASSET_SNAPSHOT_ROOT" || fail "private public release snapshot permissions could not be fixed"
DMG_PATH="$(python3 "$RELEASE_SET_TRANSACTION" snapshot \
  --input "$INPUT_PATH" \
  --snapshot-dir "$ASSET_SNAPSHOT_ROOT")" ||
  fail "public release set could not be fixed into a stable private snapshot"
require_regular_file "$DMG_PATH" "public release DMG"
require_release_directory_contents "$(dirname "$DMG_PATH")" "$DMG_PATH"

CHECKSUM_PATH="$DMG_PATH.sha256"
MANIFEST_PATH="$DMG_PATH.release.json"
RELEASE_BASE="${DMG_PATH%.dmg}"
PROJECT_SOURCE_ARCHIVE="$RELEASE_BASE-OpenSource.tar"
COPYLEFT_SOURCE_ARCHIVE="$RELEASE_BASE-ThirdPartyCorrespondingSource.tar"
COPYLEFT_SOURCE_RECEIPT="$RELEASE_BASE-ThirdPartyCorrespondingSource.receipt.json"
require_regular_file "$CHECKSUM_PATH" "public release checksum sidecar"
require_regular_file "$MANIFEST_PATH" "public release manifest sidecar"
require_regular_file "$PROJECT_SOURCE_ARCHIVE" "public project Corresponding Source archive"
require_regular_file "$COPYLEFT_SOURCE_ARCHIVE" "public copyleft source-package archive"
require_regular_file "$COPYLEFT_SOURCE_RECEIPT" "public copyleft source-package receipt"

bash "$RELEASE_EVIDENCE_VERIFIER" "$DMG_PATH" >/dev/null
verify_dmg_developer_id_signature "$DMG_PATH" "$MANIFEST_PATH"

python3 - "$MANIFEST_PATH" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
payload = json.loads(manifest_path.read_text(encoding="utf-8"))

def require(condition, message):
    if not condition:
        raise SystemExit(message)

require(payload.get("releaseKind") == "commercial-notarized-dmg", "public release must use commercial-notarized-dmg manifest")
require(payload.get("notarized") is True, "public release manifest must be notarized")
require(payload.get("stapled") is True, "public release manifest must be stapled")
require(payload.get("gatekeeperAssessed") is True, "public release manifest must be Gatekeeper assessed")
notarization = payload.get("notarization")
require(isinstance(notarization, dict), "public release manifest must include notarization evidence")
require(notarization.get("notarytoolStatus") == "Accepted", "public release manifest must include accepted notarytool status")
require(re.fullmatch(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", notarization.get("submissionId", "")), "public release manifest must include a notary submission id")
require(notarization.get("staplerValidated") is True, "public release manifest must include stapler validation evidence")
print("Public release asset manifest is commercial-notarized-dmg.")
PY

hdiutil verify "$DMG_PATH" >/dev/null || fail "public release DMG failed hdiutil verify"
verify_mounted_public_dmg "$DMG_PATH" "$MANIFEST_PATH"
xcrun stapler validate "$DMG_PATH" >/dev/null ||
  fail "public release DMG failed stapler validation"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH" >/dev/null ||
  fail "public release DMG failed Gatekeeper assessment"

printf 'Public release asset verification passed: %s\n' "$DMG_PATH"
