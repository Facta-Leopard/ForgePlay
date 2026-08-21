#!/usr/bin/env bash
set -euo pipefail

SOURCE_APP="${1:-}"
TARGET_APP="${2:-}"
SIGNING_IDENTITY="${3:-}"

fail() {
  printf 'error: preserved Apple D3DMetal restoration failed: %s\n' "$*" >&2
  exit 1
}

require_software_signing_authority() {
  local path="$1"
  local label="$2"
  local details

  details="$(codesign -dv --verbose=4 "$path" 2>&1)" ||
    fail "$label signing details could not be read"
  grep -Fq 'Authority=Software Signing' <<< "$details" ||
    fail "$label is not Apple software-signed"
}

[[ -n "$SOURCE_APP" && -n "$TARGET_APP" ]] ||
  fail "usage: restore-preserved-apple-d3dmetal-signatures.sh <archive app> <exported app> [Developer ID identity]"
[[ -d "$SOURCE_APP" && ! -L "$SOURCE_APP" ]] ||
  fail "archive app is missing or unsafe: $SOURCE_APP"
[[ -d "$TARGET_APP" && ! -L "$TARGET_APP" ]] ||
  fail "exported app is missing or unsafe: $TARGET_APP"

RUNTIME_RELATIVE_PATH="Contents/Resources/Runners/ForgePlayRuntime"
D3DMETAL_RELATIVE_PATH="Frameworks/renderer/d3dmetal/external"
SOURCE_D3DMETAL_ROOT="$SOURCE_APP/$RUNTIME_RELATIVE_PATH/$D3DMETAL_RELATIVE_PATH"
TARGET_D3DMETAL_ROOT="$TARGET_APP/$RUNTIME_RELATIVE_PATH/$D3DMETAL_RELATIVE_PATH"
SOURCE_FRAMEWORK="$SOURCE_D3DMETAL_ROOT/D3DMetal.framework"
TARGET_FRAMEWORK="$TARGET_D3DMETAL_ROOT/D3DMetal.framework"
SOURCE_SHARED_LIBRARY="$SOURCE_D3DMETAL_ROOT/libd3dshared.dylib"
TARGET_SHARED_LIBRARY="$TARGET_D3DMETAL_ROOT/libd3dshared.dylib"

[[ -d "$SOURCE_FRAMEWORK" && ! -L "$SOURCE_FRAMEWORK" ]] ||
  fail "archive Apple D3DMetal framework is missing or unsafe"
[[ -f "$SOURCE_SHARED_LIBRARY" && ! -L "$SOURCE_SHARED_LIBRARY" ]] ||
  fail "archive Apple libd3dshared is missing or unsafe"
[[ -d "$TARGET_D3DMETAL_ROOT" && ! -L "$TARGET_D3DMETAL_ROOT" ]] ||
  fail "exported D3DMetal root is missing or unsafe"
[[ -d "$TARGET_FRAMEWORK" && ! -L "$TARGET_FRAMEWORK" ]] ||
  fail "exported D3DMetal framework is missing or unsafe"
[[ -f "$TARGET_SHARED_LIBRARY" && ! -L "$TARGET_SHARED_LIBRARY" ]] ||
  fail "exported libd3dshared is missing or unsafe"

codesign --verify --strict "$SOURCE_FRAMEWORK" >/dev/null 2>&1 ||
  fail "archive Apple D3DMetal framework signature is invalid"
codesign --verify --strict "$SOURCE_SHARED_LIBRARY" >/dev/null 2>&1 ||
  fail "archive Apple libd3dshared signature is invalid"
require_software_signing_authority \
  "$SOURCE_FRAMEWORK" \
  "archive D3DMetal framework"
require_software_signing_authority \
  "$SOURCE_SHARED_LIBRARY" \
  "archive libd3dshared"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  TARGET_SIGNING_DETAILS="$(codesign -dv --verbose=4 "$TARGET_APP" 2>&1)" ||
    fail "exported app signing details could not be read"
  SIGNING_IDENTITY="$(
    sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' \
      <<< "$TARGET_SIGNING_DETAILS"
  )"
fi
[[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] ||
  fail "exported app Developer ID signing identity could not be resolved"

ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/forgeplay-export-entitlements.XXXXXX")"
cleanup() {
  rm -f "$ENTITLEMENTS"
}
trap cleanup EXIT

codesign -d --entitlements :- "$TARGET_APP" > "$ENTITLEMENTS" 2>/dev/null ||
  fail "exported app entitlements could not be read"
plutil -lint "$ENTITLEMENTS" >/dev/null ||
  fail "exported app entitlements are invalid"

# Xcode's Developer ID export re-signs nested frameworks, including Apple's
# redistributable D3DMetal payload. Restore only the Apple-signed payload from
# the already-validated archive, then refresh the outer app resource seal.
find "$TARGET_FRAMEWORK" -depth -delete
/usr/bin/ditto "$SOURCE_FRAMEWORK" "$TARGET_FRAMEWORK"
rm -f "$TARGET_SHARED_LIBRARY"
/usr/bin/ditto "$SOURCE_SHARED_LIBRARY" "$TARGET_SHARED_LIBRARY"

codesign --verify --strict "$TARGET_FRAMEWORK" >/dev/null 2>&1 ||
  fail "restored Apple D3DMetal framework signature is invalid"
codesign --verify --strict "$TARGET_SHARED_LIBRARY" >/dev/null 2>&1 ||
  fail "restored Apple libd3dshared signature is invalid"

codesign \
  --force \
  --sign "$SIGNING_IDENTITY" \
  --timestamp \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  "$TARGET_APP" >/dev/null

codesign --verify --deep --strict "$TARGET_APP" >/dev/null 2>&1 ||
  fail "exported app is invalid after restoring Apple D3DMetal signatures"
require_software_signing_authority \
  "$TARGET_FRAMEWORK" \
  "restored D3DMetal framework"
require_software_signing_authority \
  "$TARGET_SHARED_LIBRARY" \
  "restored libd3dshared"

printf 'Restored preserved Apple D3DMetal signatures after Developer ID export: %s\n' "$TARGET_APP"
