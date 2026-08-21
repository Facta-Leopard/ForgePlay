#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
EXPECTED_LOCALIZATIONS=(en ko es de ja zh-Hans zh-Hant fr)

fail() {
  printf 'error: invalid release app localizations: %s\n' "$*" >&2
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

contains_expected_localization() {
  local candidate="$1"
  local expected
  for expected in "${EXPECTED_LOCALIZATIONS[@]}"; do
    [[ "$candidate" == "$expected" ]] && return 0
  done
  return 1
}

localization_advertisement_count() {
  local candidate="$1"
  local advertised
  local count=0
  for advertised in "${advertised_localizations[@]}"; do
    if [[ "$advertised" == "$candidate" ]]; then
      count=$((count + 1))
    fi
  done
  printf '%s\n' "$count"
}

require_not_hardlinked() {
  local path="$1"
  local label="$2"
  local link_count
  link_count="$(stat -f '%l' "$path" 2>/dev/null)" || fail "$label link count could not be inspected"
  [[ "$link_count" == "1" ]] || fail "$label must not be hardlinked"
}

require_non_symlink_directory() {
  local path="$1"
  local label="$2"
  reject_symlink_parent_components "$path" "$label"
  [[ -d "$path" && ! -L "$path" ]] || fail "$label must be a non-symlink directory"
}

require_non_symlink_regular_file() {
  local path="$1"
  local label="$2"
  reject_symlink_parent_components "$path" "$label"
  [[ -f "$path" && ! -L "$path" ]] || fail "$label must be a non-symlink regular file"
}

[[ -n "$APP_PATH" ]] || fail "app path is required"
require_non_symlink_directory "$APP_PATH" "app bundle"

CONTENTS_DIR="$APP_PATH/Contents"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
[[ -x "$PLIST_BUDDY" ]] || fail "PlistBuddy is required"
require_non_symlink_directory "$CONTENTS_DIR" "Contents"
require_non_symlink_regular_file "$INFO_PLIST" "Info.plist"
require_not_hardlinked "$INFO_PLIST" "Info.plist"
require_non_symlink_directory "$RESOURCES_DIR" "Contents/Resources"

advertised_localizations=()
for index in {0..64}; do
  value="$("$PLIST_BUDDY" -c "Print :CFBundleLocalizations:$index" "$INFO_PLIST" 2>/dev/null || true)"
  [[ -n "$value" ]] || break
  advertised_localizations+=("$value")
done
[[ "${#advertised_localizations[@]}" -gt 0 ]] || fail "CFBundleLocalizations is missing or empty"

for expected in "${EXPECTED_LOCALIZATIONS[@]}"; do
  [[ "$(localization_advertisement_count "$expected")" == "1" ]] ||
    fail "CFBundleLocalizations must advertise $expected exactly once"

  lproj_dir="$RESOURCES_DIR/$expected.lproj"
  strings_file="$lproj_dir/Localizable.strings"
  license_notice="$lproj_dir/ForgePlayLicenseNotice.md"
  require_non_symlink_directory "$lproj_dir" "$expected.lproj"
  require_non_symlink_regular_file "$strings_file" "$expected.lproj/Localizable.strings"
  require_not_hardlinked "$strings_file" "$expected.lproj/Localizable.strings"
  plutil -lint "$strings_file" >/dev/null || fail "$expected.lproj/Localizable.strings failed plutil lint"
  require_non_symlink_regular_file "$license_notice" "$expected.lproj/ForgePlayLicenseNotice.md"
  require_not_hardlinked "$license_notice" "$expected.lproj/ForgePlayLicenseNotice.md"
done

for advertised in "${advertised_localizations[@]}"; do
  if ! contains_expected_localization "$advertised"; then
    fail "CFBundleLocalizations contains unsupported localization: $advertised"
  fi
done

while IFS= read -r -d '' lproj_dir; do
  language="$(basename "$lproj_dir" .lproj)"
  if ! contains_expected_localization "$language"; then
    fail "app bundle contains unsupported localization bundle: $language"
  fi
  require_non_symlink_directory "$lproj_dir" "$language.lproj"
done < <(find "$RESOURCES_DIR" -maxdepth 1 -name '*.lproj' -print0)

while IFS= read -r strings_file; do
  language="$(basename "$(dirname "$strings_file")" .lproj)"
  if ! contains_expected_localization "$language"; then
    fail "app bundle contains unsupported Localizable.strings localization: $language"
  fi
done < <(find "$RESOURCES_DIR" -maxdepth 2 -type f -path "$RESOURCES_DIR/*.lproj/Localizable.strings" -print)
