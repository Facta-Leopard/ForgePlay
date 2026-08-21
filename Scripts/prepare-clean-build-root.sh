#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  printf 'usage: %s <project-root> <build-root> <label>\n' "$0" >&2
  exit 64
fi

PROJECT_ROOT="$(cd "$1" && pwd -P)"
BUILD_ROOT="$2"
LABEL="$3"

fail() {
  printf 'error: unsafe %s build root: %s\n' "$LABEL" "$BUILD_ROOT" >&2
  printf 'reason: %s\n' "$1" >&2
  exit 1
}

[[ -n "$BUILD_ROOT" ]] || fail "path is empty"
[[ "$BUILD_ROOT" = /* ]] || fail "path must be absolute"
[[ "$BUILD_ROOT" != "/" ]] || fail "path must not be filesystem root"

HOME_REAL="$(cd "${HOME:-/}" && pwd -P)"
[[ "$BUILD_ROOT" != "$HOME_REAL" ]] || fail "path must not be the user home directory"
[[ "$BUILD_ROOT" != "$PROJECT_ROOT" ]] || fail "path must not be the project root"

if [[ -L "$BUILD_ROOT" ]]; then
  fail "path must not be a symlink"
fi

if [[ -e "$BUILD_ROOT" && ! -d "$BUILD_ROOT" ]]; then
  fail "existing path is not a directory"
fi

reject_symlink_directory_components() {
  local path="$1"
  local current="$path"
  while [[ "$current" != "/" ]]; do
    if [[ -L "$current" ]]; then
      fail "parent path must not contain symlink directory: $current"
    fi
    current="$(dirname "$current")"
  done
}

PARENT="$(dirname "$BUILD_ROOT")"
BASENAME="$(basename "$BUILD_ROOT")"
[[ -n "$BASENAME" && "$BASENAME" != "." && "$BASENAME" != ".." ]] || fail "path has no safe leaf directory"
[[ -d "$PARENT" ]] || fail "parent directory does not exist"
reject_symlink_directory_components "$PARENT"

PARENT_REAL="$(cd "$PARENT" && pwd -P)"
BUILD_ROOT_REAL="$PARENT_REAL/$BASENAME"

case "$BUILD_ROOT_REAL" in
  "$PROJECT_ROOT"|"$PROJECT_ROOT"/*)
    fail "path must not be the project root or inside the project root"
    ;;
  "$HOME_REAL"|"$HOME_REAL"/*)
    case "$BUILD_ROOT_REAL" in
      "$HOME_REAL/Library/Developer/Xcode/DerivedData"/*|"$HOME_REAL/Library/Caches"/*)
        ;;
      *)
        fail "path inside the user home directory is not allowed"
        ;;
    esac
    ;;
esac

rm -rf "$BUILD_ROOT_REAL"
mkdir -p "$BUILD_ROOT_REAL"
printf '%s\n' "$BUILD_ROOT_REAL"
