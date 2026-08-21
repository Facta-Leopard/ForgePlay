#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_CONFIG="$ROOT_DIR/Config/ForgePlay.local.xcconfig"
XCODEGEN_PATH="${FORGEPLAY_XCODEGEN_PATH:-}"

if [[ -n "$XCODEGEN_PATH" ]]; then
  XCODEGEN_PARENT="$(dirname "$XCODEGEN_PATH")"
  XCODEGEN_BASENAME="$(basename "$XCODEGEN_PATH")"
  if [[ "$XCODEGEN_PATH" != /* || ! -f "$XCODEGEN_PATH" ||
        ! -x "$XCODEGEN_PATH" || -L "$XCODEGEN_PATH" ||
        ! -d "$XCODEGEN_PARENT" || -L "$XCODEGEN_PARENT" ||
        "$(cd "$XCODEGEN_PARENT" 2>/dev/null && pwd -P)/$XCODEGEN_BASENAME" != "$XCODEGEN_PATH" ]]; then
    printf 'error: FORGEPLAY_XCODEGEN_PATH must be an exact absolute non-symlink executable: %s\n' \
      "$XCODEGEN_PATH" >&2
    exit 1
  fi
else
  XCODEGEN_PATH="$(command -v xcodegen 2>/dev/null || true)"
  if [[ -z "$XCODEGEN_PATH" ]]; then
    printf 'error: xcodegen is required to regenerate ForgePlay.xcodeproj\n' >&2
    exit 1
  fi
fi

if [[ ( -e "$LOCAL_CONFIG" || -L "$LOCAL_CONFIG" ) && ( ! -f "$LOCAL_CONFIG" || -L "$LOCAL_CONFIG" ) ]]; then
  printf 'error: user-owned local Xcode config must be a non-symlink regular file: %s\n' "$LOCAL_CONFIG" >&2
  exit 1
fi

# XcodeGen groups custom copy destinations in Swift dictionaries. Pin Swift's
# hashing policy so repeated generation from one source graph is byte-identical.
/usr/bin/env -u SWIFT_HASH_SEED \
  SWIFT_DETERMINISTIC_HASHING=1 \
  "$XCODEGEN_PATH" generate --spec "$ROOT_DIR/project.yml"
