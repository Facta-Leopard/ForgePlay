#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"

fail() {
  printf 'error: invalid release app metadata: %s\n' "$*" >&2
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

require_plist_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$("$PLIST_BUDDY" -c "Print :$key" "$INFO_PLIST" 2>/dev/null || true)"
  if [[ "$actual" != "$expected" ]]; then
    fail "$key must be $expected, got ${actual:-<missing>}"
  fi
}

require_copyright_notice() {
  local actual
  actual="$("$PLIST_BUDDY" -c 'Print :NSHumanReadableCopyright' "$INFO_PLIST" 2>/dev/null || true)"
  [[ -n "$actual" ]] || fail "NSHumanReadableCopyright is missing"
  [[ "$actual" != *'$('* ]] || fail "NSHumanReadableCopyright contains an unresolved build setting: $actual"
  [[ "${#actual}" -le 200 ]] || fail "NSHumanReadableCopyright is too long"
  [[ "$actual" == *"ForgePlay"* ]] || fail "NSHumanReadableCopyright must identify ForgePlay"
}

validate_filename_component() {
  local key="$1"
  local value="$2"
  [[ -n "$value" ]] || fail "$key is empty"
  [[ "${#value}" -le 64 ]] || fail "$key is too long"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || fail "$key is not safe for release artifact names: $value"
  [[ "$value" != "." && "$value" != ".." ]] || fail "$key must not be dot or dot-dot"
}

validate_numeric_version() {
  local key="$1"
  local value="$2"
  validate_filename_component "$key" "$value"
  [[ "$value" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] ||
    fail "$key must contain one to three dot-separated integer components: $value"
}

validate_bundle_identifier() {
  local value="$1"
  local component
  [[ -n "$value" ]] || fail "CFBundleIdentifier is missing"
  [[ "$value" != *'$('* ]] || fail "CFBundleIdentifier contains an unresolved build setting: $value"
  [[ "$value" == *.* ]] || fail "CFBundleIdentifier should use a reverse-DNS style value: $value"
  [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] ||
    fail "CFBundleIdentifier contains unsafe characters: $value"

  IFS='.' read -r -a components <<< "$value"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || fail "CFBundleIdentifier contains an empty component: $value"
    [[ "$component" =~ ^[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9]$ || "$component" =~ ^[A-Za-z0-9]$ ]] ||
      fail "CFBundleIdentifier component is not DNS-label safe: $component"
  done
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

require_bundle_executable() {
  local macos_dir="$CONTENTS_DIR/MacOS"
  local executable="$macos_dir/ForgePlay"
  require_non_symlink_directory "$macos_dir" "Contents/MacOS"
  require_non_symlink_regular_file "$executable" "Contents/MacOS/ForgePlay"
  require_not_hardlinked "$executable" "Contents/MacOS/ForgePlay"
  [[ -x "$executable" ]] || fail "Contents/MacOS/ForgePlay must be executable"
}

[[ -n "$APP_PATH" ]] || fail "app path is required"
require_non_symlink_directory "$APP_PATH" "app bundle"

CONTENTS_DIR="$APP_PATH/Contents"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
[[ -x "$PLIST_BUDDY" ]] || fail "PlistBuddy is required"
require_non_symlink_directory "$CONTENTS_DIR" "Contents"
require_non_symlink_regular_file "$INFO_PLIST" "Info.plist"
require_not_hardlinked "$INFO_PLIST" "Info.plist"

require_plist_value "CFBundleName" "ForgePlay"
require_plist_value "CFBundleDisplayName" "ForgePlay"
require_plist_value "CFBundleInfoDictionaryVersion" "6.0"
require_plist_value "CFBundlePackageType" "APPL"
require_plist_value "CFBundleExecutable" "ForgePlay"
require_plist_value "CFBundleDevelopmentRegion" "ko"
require_plist_value "LSMinimumSystemVersion" "26.0"
require_plist_value "LSApplicationCategoryType" "public.app-category.utilities"
require_plist_value "NSPrincipalClass" "NSApplication"
require_copyright_notice

bundle_identifier="$("$PLIST_BUDDY" -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
validate_bundle_identifier "$bundle_identifier"

version="$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
build="$("$PLIST_BUDDY" -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || true)"
validate_numeric_version "CFBundleShortVersionString" "$version"
validate_numeric_version "CFBundleVersion" "$build"
require_bundle_executable
