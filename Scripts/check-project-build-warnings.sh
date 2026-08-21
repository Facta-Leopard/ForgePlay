#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  printf 'usage: %s <project-root> <build-log>\n' "$0" >&2
  exit 64
fi

ROOT_DIR="$(cd "$1" && pwd)"
LOG_FILE="$2"
KNOWN_GAME_MODE_NO_PIE_WARNING="$ROOT_DIR/ForgePlay.xcodeproj: GameModeProcessHost: ld: warning: -no_pie is deprecated when targeting new OS versions"

if [[ ! -f "$LOG_FILE" ]]; then
  printf 'error: build log not found: %s\n' "$LOG_FILE" >&2
  exit 66
fi

warning_lines="$(
    grep -F "$ROOT_DIR/" "$LOG_FILE" 2>/dev/null |
    grep -F 'warning:' |
    grep -E '/(Sources|Tests|Native|Resources|Config|Scripts)/|/ForgePlay\.xcodeproj(:|/)|/project\.yml' |
    grep -Fvx "$KNOWN_GAME_MODE_NO_PIE_WARNING" || true
)"

if [[ -n "$warning_lines" ]]; then
  printf '%s\n' "$warning_lines" >&2
  exit 1
fi
