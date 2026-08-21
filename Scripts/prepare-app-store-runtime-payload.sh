#!/usr/bin/env bash
set -euo pipefail

RESOURCE_ROOT="${1:-}"

fail() {
  printf 'error: invalid App Store runtime payload: %s\n' "$*" >&2
  exit 1
}

[[ -n "$RESOURCE_ROOT" ]] || fail "usage: prepare-app-store-runtime-payload.sh <built app Resources directory>"
[[ -d "$RESOURCE_ROOT" && ! -L "$RESOURCE_ROOT" ]] ||
  fail "Resources directory must be a non-symlink directory: $RESOURCE_ROOT"

RUNTIME_ROOT="$RESOURCE_ROOT/Runners/ForgePlayRuntime"
D3DMETAL_ROOT="$RUNTIME_ROOT/Frameworks/renderer/d3dmetal"
D3DMETAL_LEGAL_ROOT="$RUNTIME_ROOT/Legal/d3dmetal"
APPLE_GPTK_LEGAL_ROOT="$RUNTIME_ROOT/Legal/AppleGPTK"
METADATA="$RUNTIME_ROOT/BUILD-METADATA.md"
RUNTIME_INFO_PLIST="$RUNTIME_ROOT/Info.plist"

[[ -d "$RUNTIME_ROOT" && ! -L "$RUNTIME_ROOT" ]] ||
  fail "ForgePlay Runtime is missing from built Resources: $RUNTIME_ROOT"
[[ -f "$METADATA" && ! -L "$METADATA" ]] ||
  fail "ForgePlay Runtime metadata is missing or unsafe: $METADATA"
[[ -f "$RUNTIME_INFO_PLIST" && ! -L "$RUNTIME_INFO_PLIST" ]] ||
  fail "ForgePlay Runtime policy Info.plist is missing or unsafe: $RUNTIME_INFO_PLIST"

remove_non_symlink_tree_if_present() {
  local path="$1"
  local label="$2"
  [[ -e "$path" ]] || return 0
  [[ -d "$path" && ! -L "$path" ]] ||
    fail "$label must be a non-symlink directory: $path"
  find "$path" -depth -delete
}

remove_non_symlink_tree_if_present "$D3DMETAL_ROOT" "D3DMetal payload root"
remove_non_symlink_tree_if_present "$D3DMETAL_LEGAL_ROOT" "D3DMetal legal payload root"
remove_non_symlink_tree_if_present "$APPLE_GPTK_LEGAL_ROOT" "Apple GPTK legal payload root"

/usr/bin/plutil -replace D3DMETAL -bool NO "$RUNTIME_INFO_PLIST" ||
  fail "ForgePlay Runtime policy Info.plist must declare D3DMETAL before App Store preparation"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :D3DMETAL' "$RUNTIME_INFO_PLIST" 2>/dev/null)" == "false" ]] ||
  fail "ForgePlay Runtime policy Info.plist still advertises D3DMetal after removing its payload"

METADATA_TEMP="$(mktemp "$RUNTIME_ROOT/.BUILD-METADATA.app-store.XXXXXX")"
cleanup() {
  rm -f "$METADATA_TEMP"
}
trap cleanup EXIT

awk '
  /^- Game graphics runtime: Apple GPTK Evaluation Environment/ { next }
  /^- D3DMetal overlay source:/ { next }
  /^- App Store\/commercial note: Apple GPTK\/D3DMetal/ { next }
  /^- App Store graphics runtime:/ { next }
  /^- App Store redistribution policy:/ { next }
  { print }
  END {
    print "- App Store graphics runtime: Vulkan, MoltenVK, DXVK, DXMT, and base Wine renderer payloads only"
    print "- App Store redistribution policy: Apple GPTK/D3DMetal evaluation redist excluded from this built product"
  }
' "$METADATA" > "$METADATA_TEMP"
chmod 0644 "$METADATA_TEMP"
mv "$METADATA_TEMP" "$METADATA"

REMAINING_APPLE_RENDERER="$(
  find "$RUNTIME_ROOT" \( \
    -iname '*d3dmetal*' -o \
    -iname 'libd3dshared.dylib' -o \
    -iname 'nvngx-on-metalfx*' \
  \) -print -quit
)"
[[ -z "$REMAINING_APPLE_RENDERER" ]] ||
  fail "Apple GPTK/D3DMetal payload remains in App Store runtime: $REMAINING_APPLE_RENDERER"

printf 'Prepared App Store runtime payload: %s\n' "$RUNTIME_ROOT"
