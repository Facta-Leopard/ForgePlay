#!/usr/bin/env bash
set -euo pipefail

NOTARY_JSON_PATH="${1:-}"

fail() {
  printf 'error: invalid notary submit JSON: %s\n' "$*" >&2
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

require_file_size_at_most() {
  local path="$1"
  local label="$2"
  local max_bytes="$3"
  local byte_count
  byte_count="$(stat -f '%z' "$path" 2>/dev/null)" || fail "$label byte count could not be inspected: $path"
  [[ "$byte_count" =~ ^[0-9]+$ ]] || fail "$label byte count is not numeric: $path"
  (( byte_count <= max_bytes )) || fail "$label must be $max_bytes bytes or smaller: $path"
}

[[ -n "$NOTARY_JSON_PATH" ]] || fail "usage: verify-notary-submit-json.sh <notarytool submit JSON path>"
require_regular_file "$NOTARY_JSON_PATH" "notary submit JSON"
require_file_size_at_most "$NOTARY_JSON_PATH" "notary submit JSON" 65536

python3 - "$NOTARY_JSON_PATH" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path = Path(sys.argv[1])

def require(condition, message):
    if not condition:
        raise SystemExit(message)

try:
    payload = json.loads(log_path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"notarytool submit output is not valid JSON: {exc}")

require(isinstance(payload, dict), "notarytool submit output must be a JSON object")
status = payload.get("status")
submission_id = payload.get("id")
require(isinstance(status, str), "notarytool submit status must be a string")
require(status == "Accepted", "notarytool submit status must be Accepted")
require(isinstance(submission_id, str), "notarytool submit id must be a string")
require(
    re.fullmatch(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", submission_id) is not None,
    "notarytool submit id must be a UUID",
)
print(submission_id)
PY
