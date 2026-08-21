#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:-}"

fail() {
  printf 'error: invalid bundled project documents: %s\n' "$*" >&2
  exit 1
}

[[ -n "$INPUT_PATH" ]] ||
  fail "usage: verify-project-documents.sh <project root | Resources directory | app bundle>"
[[ -d "$INPUT_PATH" && ! -L "$INPUT_PATH" ]] ||
  fail "input must be a non-symlink directory: $INPUT_PATH"

if [[ "$INPUT_PATH" == *.app ]]; then
  RESOURCE_ROOT="$INPUT_PATH/Contents/Resources"
elif [[ -d "$INPUT_PATH/Resources" && ! -L "$INPUT_PATH/Resources" ]]; then
  RESOURCE_ROOT="$INPUT_PATH/Resources"
else
  RESOURCE_ROOT="$INPUT_PATH"
fi

[[ -d "$RESOURCE_ROOT" && ! -L "$RESOURCE_ROOT" ]] ||
  fail "Resources must be a non-symlink directory: $RESOURCE_ROOT"

verify_document() {
  local file_name="$1"
  local expected_sha256="$2"
  local nested_path="$RESOURCE_ROOT/Documents/$file_name"
  local flat_path="$RESOURCE_ROOT/$file_name"
  local document_path=""
  local candidate_count=0
  local link_count actual_sha256

  for candidate in "$nested_path" "$flat_path"; do
    if [[ -e "$candidate" || -L "$candidate" ]]; then
      candidate_count=$((candidate_count + 1))
      document_path="$candidate"
    fi
  done

  [[ "$candidate_count" == "1" ]] ||
    fail "$file_name must exist in exactly one supported bundle location; found $candidate_count"
  [[ -f "$document_path" && ! -L "$document_path" ]] ||
    fail "$file_name must be a non-symlink regular file"
  link_count="$(stat -f '%l' "$document_path" 2>/dev/null)" ||
    fail "$file_name link count could not be inspected"
  [[ "$link_count" == "1" ]] || fail "$file_name must not be hardlinked"
  actual_sha256="$(shasum -a 256 "$document_path" | awk '{print $1}')" ||
    fail "$file_name SHA-256 could not be computed"
  [[ "$actual_sha256" == "$expected_sha256" ]] ||
    fail "$file_name differs from the maintainer-provided source document"
}

verify_document \
  "WHY_FORGEPLAY_EXISTS_KO.md" \
  "6da204408dd1a2aebff9d3e13d109363e52eb8d6b67c8bde097a8581c1da7f71"
verify_document \
  "WHY_FORGEPLAY_EXISTS_EN.md" \
  "f32860a9d4ba0e9fadb6728b8aca541594be04f3db784960539402c338626a7a"

printf 'Bundled ForgePlay project documents verified: %s\n' "$RESOURCE_ROOT"
