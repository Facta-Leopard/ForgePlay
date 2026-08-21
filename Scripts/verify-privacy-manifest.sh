#!/usr/bin/env bash
set -euo pipefail

EXPECTED_CATEGORIES=(
  "NSPrivacyAccessedAPICategoryFileTimestamp"
  "NSPrivacyAccessedAPICategoryDiskSpace"
  "NSPrivacyAccessedAPICategoryUserDefaults"
)

fail() {
  printf 'error: invalid privacy manifest: %s\n' "$*" >&2
  exit 1
}

is_expected_category() {
  local category="$1"
  local expected
  for expected in "${EXPECTED_CATEGORIES[@]}"; do
    [[ "$category" == "$expected" ]] && return 0
  done
  return 1
}

is_allowed_reason() {
  local category="$1"
  local reason="$2"
  case "$category" in
    NSPrivacyAccessedAPICategoryFileTimestamp)
      [[ "$reason" == "C617.1" || "$reason" == "3B52.1" ]]
      ;;
    NSPrivacyAccessedAPICategoryDiskSpace)
      [[ "$reason" == "E174.1" ]]
      ;;
    NSPrivacyAccessedAPICategoryUserDefaults)
      [[ "$reason" == "CA92.1" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

category_count() {
  local category="$1"
  local count=0
  local seen
  for seen in "${seen_categories[@]}"; do
    if [[ "$seen" == "$category" ]]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

reason_count() {
  local category="$1"
  local reason="$2"
  local count=0
  local seen
  for seen in "${seen_reasons[@]}"; do
    if [[ "$seen" == "$category|$reason" ]]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

require_empty_array() {
  local key="$1"
  local count
  count="$(plutil -extract "$key" raw -o - "$MANIFEST_PATH" 2>/dev/null || true)"
  [[ "$count" == "0" ]] || fail "$key must be present and empty"
}

require_not_hardlinked() {
  local path="$1"
  local label="$2"
  local link_count
  link_count="$(stat -f '%l' "$path" 2>/dev/null)" || fail "$label link count could not be inspected"
  [[ "$link_count" == "1" ]] || fail "$label must not be hardlinked"
}

[[ "$#" -eq 1 ]] || fail "usage: verify-privacy-manifest.sh <PrivacyInfo.xcprivacy | app bundle>"

INPUT_PATH="$1"
if [[ "$INPUT_PATH" == *.app ]]; then
  [[ ! -L "$INPUT_PATH" && -d "$INPUT_PATH" ]] || fail "app bundle must be a non-symlink directory"
  CONTENTS_DIR="$INPUT_PATH/Contents"
  RESOURCES_DIR="$CONTENTS_DIR/Resources"
  [[ ! -L "$CONTENTS_DIR" && -d "$CONTENTS_DIR" ]] || fail "Contents must be a non-symlink directory"
  [[ ! -L "$RESOURCES_DIR" && -d "$RESOURCES_DIR" ]] || fail "Contents/Resources must be a non-symlink directory"
  MANIFEST_PATH="$RESOURCES_DIR/PrivacyInfo.xcprivacy"
else
  MANIFEST_PATH="$INPUT_PATH"
fi

[[ -f "$MANIFEST_PATH" && ! -L "$MANIFEST_PATH" ]] || fail "PrivacyInfo.xcprivacy must be a non-symlink regular file"
require_not_hardlinked "$MANIFEST_PATH" "PrivacyInfo.xcprivacy"
plutil -lint "$MANIFEST_PATH" >/dev/null || fail "PrivacyInfo.xcprivacy plist syntax failed"

tracking="$(plutil -extract NSPrivacyTracking raw -o - "$MANIFEST_PATH" 2>/dev/null || true)"
[[ "$tracking" == "false" ]] || fail "NSPrivacyTracking must be false"
require_empty_array "NSPrivacyTrackingDomains"
require_empty_array "NSPrivacyCollectedDataTypes"

accessed_api_count="$(plutil -extract NSPrivacyAccessedAPITypes raw -o - "$MANIFEST_PATH" 2>/dev/null || true)"
[[ "$accessed_api_count" == "3" ]] || fail "NSPrivacyAccessedAPITypes must contain exactly the expected API categories"

seen_categories=()
seen_reasons=()

for ((api_index = 0; api_index < 32; api_index++)); do
  category="$(/usr/libexec/PlistBuddy -c "Print :NSPrivacyAccessedAPITypes:$api_index:NSPrivacyAccessedAPIType" "$MANIFEST_PATH" 2>/dev/null || true)"
  [[ -n "$category" ]] || continue
  is_expected_category "$category" || fail "unsupported accessed API category: $category"
  seen_categories+=("$category")

  reason_seen=0
  for ((reason_index = 0; reason_index < 16; reason_index++)); do
    reason="$(/usr/libexec/PlistBuddy -c "Print :NSPrivacyAccessedAPITypes:$api_index:NSPrivacyAccessedAPITypeReasons:$reason_index" "$MANIFEST_PATH" 2>/dev/null || true)"
    [[ -n "$reason" ]] || continue
    reason_seen=1
    is_allowed_reason "$category" "$reason" || fail "unsupported reason $reason for $category"
    seen_reasons+=("$category|$reason")
  done
  [[ "$reason_seen" -eq 1 ]] || fail "$category must declare at least one reason"
done

for category in "${EXPECTED_CATEGORIES[@]}"; do
  count="$(category_count "$category")"
  [[ "$count" == "1" ]] || fail "$category must appear exactly once"
done

[[ "$(reason_count "NSPrivacyAccessedAPICategoryFileTimestamp" "C617.1")" == "1" ]] ||
  fail "file timestamp reason C617.1 is required"
[[ "$(reason_count "NSPrivacyAccessedAPICategoryFileTimestamp" "3B52.1")" == "1" ]] ||
  fail "file timestamp reason 3B52.1 is required"
[[ "$(reason_count "NSPrivacyAccessedAPICategoryDiskSpace" "E174.1")" == "1" ]] ||
  fail "disk space reason E174.1 is required"
[[ "$(reason_count "NSPrivacyAccessedAPICategoryUserDefaults" "CA92.1")" == "1" ]] ||
  fail "UserDefaults reason CA92.1 is required"
