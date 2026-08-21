#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  printf 'usage: %s <project-root> <dist-dir> <version> <build>\n' "$0" >&2
  exit 64
fi

PROJECT_ROOT="$(cd "$1" && pwd -P)"
DIST_DIR="$2"
VERSION="$3"
BUILD="$4"

fail() {
  printf 'error: unsafe DMG output path: %s\n' "$DIST_DIR" >&2
  printf 'reason: %s\n' "$1" >&2
  exit 1
}

validate_filename_component() {
  local label="$1"
  local value="$2"
  [[ -n "$value" ]] || fail "$label is empty"
  [[ "${#value}" -le 64 ]] || fail "$label is too long"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || fail "$label is not a safe filename component"
  [[ "$value" != "." && "$value" != ".." ]] || fail "$label must not be dot or dot-dot"
}

reject_symlink_directory_components() {
  local path="$1"
  local current="$path"
  while [[ "$current" != "/" ]]; do
    if [[ -L "$current" ]]; then
      fail "dist parent path must not contain symlink directory: $current"
    fi
    current="$(dirname "$current")"
  done
}

require_release_directory_contents() {
  local directory="$1"
  local dmg_path="$2"
  local dmg_name checksum_name manifest_name entry entry_name
  local -a unexpected_entries

  dmg_name="$(basename "$dmg_path")"
  checksum_name="$dmg_name.sha256"
  manifest_name="$dmg_name.release.json"
  unexpected_entries=()

  while IFS= read -r -d '' entry; do
    entry_name="$(basename "$entry")"
    if [[ "$entry_name" != "$dmg_name" &&
          "$entry_name" != "$checksum_name" &&
          "$entry_name" != "$manifest_name" ]]; then
      unexpected_entries+=("$entry_name")
    fi
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -print0)

  if [[ "${#unexpected_entries[@]}" -ne 0 ]]; then
    fail "dist directory must contain only the target DMG, checksum, and manifest sidecars before release output is written: ${unexpected_entries[*]}"
  fi
}

[[ -n "$DIST_DIR" ]] || fail "dist directory is empty"
[[ "$DIST_DIR" = /* ]] || fail "dist directory must be absolute"
[[ "$DIST_DIR" != "/" ]] || fail "dist directory must not be filesystem root"
validate_filename_component "version" "$VERSION"
validate_filename_component "build" "$BUILD"

if [[ -L "$DIST_DIR" ]]; then
  fail "dist directory must not be a symlink"
fi

if [[ -e "$DIST_DIR" && ! -d "$DIST_DIR" ]]; then
  fail "existing dist path is not a directory"
fi

PARENT="$(dirname "$DIST_DIR")"
BASENAME="$(basename "$DIST_DIR")"
[[ -n "$BASENAME" && "$BASENAME" != "." && "$BASENAME" != ".." ]] || fail "dist directory has no safe leaf directory"
[[ -d "$PARENT" ]] || fail "dist parent directory does not exist"
reject_symlink_directory_components "$PARENT"

PARENT_REAL="$(cd "$PARENT" && pwd -P)"
DIST_REAL="$PARENT_REAL/$BASENAME"

mkdir -p "$DIST_REAL"
[[ -d "$DIST_REAL" && ! -L "$DIST_REAL" ]] || fail "dist directory could not be created safely"

DMG_PATH="$DIST_REAL/ForgePlay-${VERSION}-${BUILD}.dmg"
require_release_directory_contents "$DIST_REAL" "$DMG_PATH"

if [[ -L "$DMG_PATH" ]]; then
  fail "existing DMG path must not be a symlink"
fi

if [[ -e "$DMG_PATH" ]]; then
  if [[ ! -f "$DMG_PATH" ]]; then
    fail "existing DMG path is not a regular file"
  fi
  link_count="$(stat -f '%l' "$DMG_PATH")"
  if [[ "$link_count" != "1" ]]; then
    fail "existing DMG path must not be hardlinked"
  fi
  rm -f "$DMG_PATH"
fi

printf '%s\n' "$DMG_PATH"
