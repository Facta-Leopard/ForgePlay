#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_CONFIG="$ROOT_DIR/Config/ForgePlay.local.xcconfig"

command -v xcodegen >/dev/null 2>&1 || {
  printf 'error: xcodegen is required to regenerate ForgePlay.xcodeproj\n' >&2
  exit 1
}

if [[ ( -e "$LOCAL_CONFIG" || -L "$LOCAL_CONFIG" ) && ( ! -f "$LOCAL_CONFIG" || -L "$LOCAL_CONFIG" ) ]]; then
  printf 'error: user-owned local Xcode config must be a non-symlink regular file: %s\n' "$LOCAL_CONFIG" >&2
  exit 1
fi

xcodegen generate --spec "$ROOT_DIR/project.yml"
