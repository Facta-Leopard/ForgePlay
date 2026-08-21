#!/usr/bin/env bash
set -euo pipefail

EXPECTED_DOCUMENTS=(
  "ForgePlayPrivacy.md"
  "ForgePlaySupport.md"
  "ForgePlayThirdPartyNotices.md"
)
EXPECTED_LOCALIZATIONS=(en ko es de ja zh-Hans zh-Hant fr)
LOCALIZED_LICENSE_NOTICE="ForgePlayLicenseNotice.md"
INPUT_PATH=""

fail() {
  printf 'error: invalid legal documents: %s\n' "$*" >&2
  exit 1
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
  [[ -d "$path" && ! -L "$path" ]] || fail "$label must be a non-symlink directory: $path"
}

document_path() {
  local input="$1"
  local file_name="$2"
  local candidate candidate_count=0 selected_candidate=""

  if [[ -d "$input" && "$input" == *.app ]]; then
    for candidate in \
      "$input/Contents/Resources/Legal/$file_name" \
      "$input/Contents/Resources/$file_name"; do
      if [[ -e "$candidate" || -L "$candidate" ]]; then
        candidate_count=$((candidate_count + 1))
        selected_candidate="$candidate"
        if [[ "$candidate" == */Legal/"$file_name" ]]; then
          require_non_symlink_directory "${candidate%/$file_name}" "Legal document directory"
        fi
      fi
    done
  else
    for candidate in \
      "$input/Resources/Legal/$file_name" \
      "$input/Legal/$file_name" \
      "$input/$file_name"; do
      if [[ -e "$candidate" || -L "$candidate" ]]; then
        candidate_count=$((candidate_count + 1))
        selected_candidate="$candidate"
        if [[ "$candidate" == */Legal/"$file_name" ]]; then
          require_non_symlink_directory "${candidate%/$file_name}" "Legal document directory"
        fi
      fi
    done
  fi

  [[ "$candidate_count" == "1" ]] ||
    fail "$file_name must exist in exactly one supported legal-document location; found $candidate_count"
  printf '%s\n' "$selected_candidate"
}

require_snippet() {
  local path="$1"
  local snippet="$2"
  grep -Fq "$snippet" "$path" || fail "$(basename "$path") is missing required notice: $snippet"
}

validate_document() {
  local input="$1"
  local file_name="$2"
  local path
  path="$(document_path "$input" "$file_name")" || fail "missing $file_name"
  [[ -f "$path" && ! -L "$path" ]] || fail "$file_name must be a non-symlink regular file"
  require_not_hardlinked "$path" "$file_name"
  [[ "$(wc -c < "$path" | tr -d ' ')" -ge 400 ]] || fail "$file_name is too small to be a useful product notice"

  case "$file_name" in
    ForgePlayPrivacy.md)
      require_snippet "$path" "does not include advertising tracking"
      require_snippet "$path" "Apple Foundation Models on this Mac"
      require_snippet "$path" "does not send AI diagnostic logs to an external AI endpoint"
      require_snippet "$path" "does not use an API key for AI diagnostics"
      require_snippet "$path" "Steam account names"
      require_snippet "$path" "does not ask for, store, or transmit Steam account passwords"
      ;;
    ForgePlaySupport.md)
      require_snippet "$path" "support bundle"
      require_snippet "$path" "Steam account identifiers"
      require_snippet "$path" "Do not send Steam passwords"
      require_snippet "$path" "does not host runtime installers on an app server"
      ;;
    ForgePlayThirdPartyNotices.md)
      require_snippet "$path" "current Developer ID DMG configuration includes an Apple GPTK/D3DMetal evaluation renderer payload"
      require_snippet "$path" "The App Store candidate excludes that optional Apple payload"
      require_snippet "$path" "does not make a licensing determination"
      require_snippet "$path" "does not claim ownership of Apple GPTK or D3DMetal"
      require_snippet "$path" "Wine-based ForgePlay Runtime"
      require_snippet "$path" "does not redistribute these installers"
      require_snippet "$path" "Steam login happens in Steam's own UI"
      ;;
    *)
      fail "unsupported legal document: $file_name"
      ;;
  esac
}

localized_notice_path() {
  local input="$1"
  local localization="$2"

  if [[ -d "$input" && "$input" == *.app ]]; then
    printf '%s\n' "$input/Contents/Resources/$localization.lproj/$LOCALIZED_LICENSE_NOTICE"
  elif [[ -d "$input/Resources" && ! -L "$input/Resources" ]]; then
    printf '%s\n' "$input/Resources/$localization.lproj/$LOCALIZED_LICENSE_NOTICE"
  else
    printf '%s\n' "$input/$localization.lproj/$LOCALIZED_LICENSE_NOTICE"
  fi
}

validate_localized_license_notice() {
  local input="$1"
  local localization="$2"
  local path directory
  path="$(localized_notice_path "$input" "$localization")"
  directory="$(dirname "$path")"

  require_non_symlink_directory "$directory" "$localization localized resource directory"
  [[ -f "$path" && ! -L "$path" ]] ||
    fail "$localization localized license notice must be a non-symlink regular file"
  require_not_hardlinked "$path" "$localization localized license notice"
  [[ "$(wc -c < "$path" | tr -d ' ')" -ge 700 ]] ||
    fail "$localization localized license notice is too small"
  require_snippet "$path" "GPL-3.0-only"
  require_snippet "$path" "Copyright (C) 2026 Facta-Leopard"
  require_snippet "$path" "https://github.com/Facta-Leopard/ForgePlay"
  require_snippet "$path" "LICENSE.md"
  require_snippet "$path" "LICENSES/GPL-3.0-only.txt"
  require_snippet "$path" "LICENSES/LGPL-2.1-or-later.txt"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$INPUT_PATH" ]] ||
        fail "usage: verify-legal-documents.sh <project root | Resources | app bundle>"
      INPUT_PATH="$1"
      shift
      ;;
  esac
done

[[ -n "$INPUT_PATH" ]] ||
  fail "usage: verify-legal-documents.sh <project root | Resources | app bundle>"
if [[ "$INPUT_PATH" == *.app ]]; then
  [[ ! -L "$INPUT_PATH" && -d "$INPUT_PATH" ]] || fail "app bundle must be a non-symlink directory"
  CONTENTS_DIR="$INPUT_PATH/Contents"
  RESOURCES_DIR="$CONTENTS_DIR/Resources"
  [[ ! -L "$CONTENTS_DIR" && -d "$CONTENTS_DIR" ]] || fail "Contents must be a non-symlink directory"
  [[ ! -L "$RESOURCES_DIR" && -d "$RESOURCES_DIR" ]] || fail "Contents/Resources must be a non-symlink directory"
fi

for file_name in "${EXPECTED_DOCUMENTS[@]}"; do
  validate_document "$INPUT_PATH" "$file_name"
done

for localization in "${EXPECTED_LOCALIZATIONS[@]}"; do
  validate_localized_license_notice "$INPUT_PATH" "$localization"
done
