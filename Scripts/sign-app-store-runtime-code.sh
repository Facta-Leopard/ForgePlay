#!/usr/bin/env bash
set -euo pipefail

SIGNING_MODE="${1:-}"
RESOURCE_ROOT="${2:-}"
INHERIT_ENTITLEMENTS="${3:-}"

fail() {
  printf 'error: bundled runtime code signing failed: %s\n' "$*" >&2
  exit 1
}

PRESERVE_APPLE_D3DMETAL=0
DIRECT_DEVELOPER_ID=0
TIMESTAMP_ARGUMENT="--timestamp=none"
case "$SIGNING_MODE" in
  --developer-id-direct)
    PRESERVE_APPLE_D3DMETAL=1
    DIRECT_DEVELOPER_ID=1
    TIMESTAMP_ARGUMENT="--timestamp"
    ;;
  --developer-id)
    PRESERVE_APPLE_D3DMETAL=1
    TIMESTAMP_ARGUMENT="--timestamp"
    ;;
  --app-store)
    ;;
  *)
    fail "usage: sign-app-store-runtime-code.sh <--developer-id-direct | --developer-id | --app-store> <built Resources directory> <executable entitlements>"
    ;;
esac

[[ -n "$RESOURCE_ROOT" && -n "$INHERIT_ENTITLEMENTS" ]] ||
  fail "usage: sign-app-store-runtime-code.sh <--developer-id-direct | --developer-id | --app-store> <built Resources directory> <executable entitlements>"
[[ -d "$RESOURCE_ROOT" && ! -L "$RESOURCE_ROOT" ]] ||
  fail "Resources directory must be a non-symlink directory: $RESOURCE_ROOT"
[[ -f "$INHERIT_ENTITLEMENTS" && ! -L "$INHERIT_ENTITLEMENTS" ]] ||
  fail "executable entitlements must be a non-symlink regular file: $INHERIT_ENTITLEMENTS"
plutil -lint "$INHERIT_ENTITLEMENTS" >/dev/null || fail "executable entitlements are invalid"

EFFECTIVE_EXECUTABLE_ENTITLEMENTS="$INHERIT_ENTITLEMENTS"
MATERIALIZED_DIRECT_ENTITLEMENTS=""
cleanup() {
  [[ -z "$MATERIALIZED_DIRECT_ENTITLEMENTS" ]] ||
    rm -f "$MATERIALIZED_DIRECT_ENTITLEMENTS"
}
trap cleanup EXIT

if [[ "${CODE_SIGNING_ALLOWED:-NO}" != "YES" ]]; then
  printf 'Skipped bundled runtime code signing because CODE_SIGNING_ALLOWED is not YES.\n'
  exit 0
fi

SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
PRODUCT_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER:-com.forgeplay.client}"
[[ -n "$SIGNING_IDENTITY" ]] || fail "EXPANDED_CODE_SIGN_IDENTITY is empty"

if [[ "$DIRECT_DEVELOPER_ID" == "1" ]]; then
  DEVELOPMENT_TEAM_VALUE="${DEVELOPMENT_TEAM:-}"
  APPLICATION_GROUP_VALUE="${FORGEPLAY_GAME_MODE_APPLICATION_GROUP:-}"
  [[ "$DEVELOPMENT_TEAM_VALUE" =~ ^[A-Z0-9]{10}$ ]] ||
    fail "direct Developer ID runtime signing requires a 10-character DEVELOPMENT_TEAM"
  [[ "$PRODUCT_IDENTIFIER" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] ||
    fail "direct Developer ID runtime signing requires a safe product bundle identifier"
  EXPECTED_APPLICATION_GROUP="$DEVELOPMENT_TEAM_VALUE.$PRODUCT_IDENTIFIER"
  [[ "$APPLICATION_GROUP_VALUE" == "$EXPECTED_APPLICATION_GROUP" ]] ||
    fail "direct Developer ID runtime App Group must be exactly $EXPECTED_APPLICATION_GROUP"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$INHERIT_ENTITLEMENTS" 2>/dev/null || true)" == '$(FORGEPLAY_GAME_MODE_APPLICATION_GROUP)' ]] ||
    fail "direct runtime entitlement source must contain the App Group build-setting placeholder"
  [[ -z "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:1' "$INHERIT_ENTITLEMENTS" 2>/dev/null || true)" ]] ||
    fail "direct runtime entitlement source must contain exactly one App Group placeholder"

  MATERIALIZED_DIRECT_ENTITLEMENTS="$(
    mktemp "${TMPDIR:-/tmp}/forgeplay-direct-runtime-entitlements.XXXXXX"
  )" || fail "direct runtime entitlements could not be staged"
  /usr/bin/ditto "$INHERIT_ENTITLEMENTS" "$MATERIALIZED_DIRECT_ENTITLEMENTS" ||
    fail "direct runtime entitlement source could not be staged"
  /usr/libexec/PlistBuddy \
    -c "Set :com.apple.security.application-groups:0 $APPLICATION_GROUP_VALUE" \
    "$MATERIALIZED_DIRECT_ENTITLEMENTS" >/dev/null ||
    fail "direct runtime App Group could not be materialized"
  plutil -lint "$MATERIALIZED_DIRECT_ENTITLEMENTS" >/dev/null ||
    fail "materialized direct runtime entitlements are invalid"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$MATERIALIZED_DIRECT_ENTITLEMENTS")" == "$EXPECTED_APPLICATION_GROUP" ]] ||
    fail "materialized direct runtime App Group readback failed"
  EFFECTIVE_EXECUTABLE_ENTITLEMENTS="$MATERIALIZED_DIRECT_ENTITLEMENTS"
fi

RUNTIME_ROOT="$RESOURCE_ROOT/Runners/ForgePlayRuntime"
[[ -d "$RUNTIME_ROOT" && ! -L "$RUNTIME_ROOT" ]] ||
  fail "ForgePlay Runtime is missing or unsafe: $RUNTIME_ROOT"
D3DMETAL_EXTERNAL_ROOT="$RUNTIME_ROOT/Frameworks/renderer/d3dmetal/external"
D3DMETAL_FRAMEWORK="$D3DMETAL_EXTERNAL_ROOT/D3DMetal.framework"
D3DMETAL_SHARED_LIBRARY="$D3DMETAL_EXTERNAL_ROOT/libd3dshared.dylib"

require_exact_relative_symlink() {
  local path="$1"
  local expected_target="$2"
  local label="$3"
  local actual_target

  [[ -L "$path" ]] || fail "$label must be a symlink: $path"
  actual_target="$(readlink "$path")" ||
    fail "$label target could not be read: $path"
  [[ "$actual_target" == "$expected_target" ]] ||
    fail "$label target is invalid: $path -> $actual_target"
}

restore_canonical_d3dmetal_framework_aliases() {
  local framework="$1"
  local versions="$framework/Versions"
  local canonical_version="$versions/A"
  local canonical_executable="$canonical_version/D3DMetal"
  local canonical_resources="$canonical_version/Resources"
  local current_version="$versions/Current"
  local alias_executable="$framework/D3DMetal"
  local alias_resources="$framework/Resources"

  [[ -d "$framework" && ! -L "$framework" ]] ||
    fail "canonical Apple D3DMetal framework is missing"
  [[ -d "$versions" && ! -L "$versions" ]] ||
    fail "Apple D3DMetal Versions directory is missing or unsafe"
  [[ -d "$canonical_version" && ! -L "$canonical_version" ]] ||
    fail "Apple D3DMetal canonical version is missing or unsafe"
  [[ -f "$canonical_executable" && ! -L "$canonical_executable" ]] ||
    fail "Apple D3DMetal canonical executable is missing or unsafe"
  [[ -d "$canonical_resources" && ! -L "$canonical_resources" ]] ||
    fail "Apple D3DMetal canonical Resources directory is missing or unsafe"

  if [[ -L "$alias_executable" || -L "$alias_resources" || -L "$current_version" ]]; then
    require_exact_relative_symlink \
      "$current_version" \
      "A" \
      "Apple D3DMetal current-version alias"
    require_exact_relative_symlink \
      "$alias_executable" \
      "Versions/Current/D3DMetal" \
      "Apple D3DMetal executable alias"
    require_exact_relative_symlink \
      "$alias_resources" \
      "Versions/Current/Resources" \
      "Apple D3DMetal Resources alias"
    return
  fi

  [[ ! -e "$current_version" ]] ||
    fail "materialized Apple D3DMetal framework has an unexpected Versions/Current entry"
  [[ -f "$alias_executable" && ! -L "$alias_executable" ]] ||
    fail "materialized Apple D3DMetal executable alias is missing or unsafe"
  [[ -d "$alias_resources" && ! -L "$alias_resources" ]] ||
    fail "materialized Apple D3DMetal Resources alias is missing or unsafe"
  cmp -s "$alias_executable" "$canonical_executable" ||
    fail "materialized Apple D3DMetal executable does not match Versions/A"
  diff -qr "$alias_resources" "$canonical_resources" >/dev/null ||
    fail "materialized Apple D3DMetal Resources do not match Versions/A"

  # The checked runtime intentionally materializes symlinks for portable source
  # and SBOM handling. Developer ID distribution must restore Apple's canonical
  # versioned-framework aliases so the preserved Apple signature remains valid.
  rm -f "$alias_executable"
  find "$alias_resources" -depth -delete
  ln -s "A" "$current_version"
  ln -s "Versions/Current/D3DMetal" "$alias_executable"
  ln -s "Versions/Current/Resources" "$alias_resources"

  require_exact_relative_symlink \
    "$current_version" \
    "A" \
    "Apple D3DMetal current-version alias"
  require_exact_relative_symlink \
    "$alias_executable" \
    "Versions/Current/D3DMetal" \
    "Apple D3DMetal executable alias"
  require_exact_relative_symlink \
    "$alias_resources" \
    "Versions/Current/Resources" \
    "Apple D3DMetal Resources alias"
}

is_preserved_apple_d3dmetal_code() {
  local path="$1"
  [[ "$PRESERVE_APPLE_D3DMETAL" == "1" ]] || return 1
  [[ "$path" == "$D3DMETAL_SHARED_LIBRARY" ||
     "$path" == "$D3DMETAL_FRAMEWORK"/* ]]
}

if [[ "$PRESERVE_APPLE_D3DMETAL" == "1" ]]; then
  restore_canonical_d3dmetal_framework_aliases "$D3DMETAL_FRAMEWORK"
  [[ -f "$D3DMETAL_SHARED_LIBRARY" && ! -L "$D3DMETAL_SHARED_LIBRARY" ]] ||
    fail "Apple libd3dshared is missing"
  codesign --verify --strict "$D3DMETAL_FRAMEWORK" >/dev/null 2>&1 ||
    fail "canonical Apple D3DMetal framework signature is invalid"
  codesign --verify --strict "$D3DMETAL_SHARED_LIBRARY" >/dev/null 2>&1 ||
    fail "Apple libd3dshared signature is invalid"
fi

is_macho() {
  file -b "$1" 2>/dev/null | grep -q '^Mach-O'
}

is_macho_executable() {
  file -b "$1" 2>/dev/null | grep -q '^Mach-O.*executable'
}

framework_for_code_path() {
  local path="$1"
  [[ "$path" == *.framework/* ]] || return 1
  printf '%s.framework\n' "${path%%.framework/*}"
}

is_framework_main_executable() {
  local path="$1"
  local framework info_plist executable

  framework="$(framework_for_code_path "$path" || true)"
  [[ -n "$framework" ]] || return 1
  info_plist="$framework/Resources/Info.plist"
  [[ -f "$info_plist" && ! -L "$info_plist" ]] ||
    fail "nested framework Info.plist is missing or unsafe: $info_plist"
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null || true)"
  [[ -n "$executable" ]] ||
    fail "nested framework CFBundleExecutable is missing: $info_plist"
  [[ "$path" == "$framework/$executable" ||
     "$path" == "$framework"/Versions/*/"$executable" ]]
}

sign_library() {
  # Runtime libraries stay inside the main app's Team and Hardened Runtime
  # boundary. Executable Wine helpers are handled separately below because they
  # map Windows PE code and must inherit the parent sandbox with targeted exceptions.
  codesign --force --sign "$SIGNING_IDENTITY" "$TIMESTAMP_ARGUMENT" --options runtime "$1" >/dev/null
}

sign_executable() {
  local path="$1"
  local relative identifier_hash identifier
  relative="${path#"$RUNTIME_ROOT"/}"
  identifier_hash="$(printf '%s' "$relative" | shasum -a 256 | awk '{print substr($1, 1, 16)}')"
  identifier="$PRODUCT_IDENTIFIER.runtime.$identifier_hash"
  # Every process that maps Windows PE pages needs executable-memory and Wine tmpmap
  # library-validation exceptions on its own signature; the main app does not confer them.
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    --identifier "$identifier" \
    "$TIMESTAMP_ARGUMENT" \
    --options runtime \
    --entitlements "$EFFECTIVE_EXECUTABLE_ENTITLEMENTS" \
    "$path" >/dev/null
}

sign_framework() {
  local framework="$1"
  local info_plist="$framework/Resources/Info.plist"
  local executable version version_info_plist version_executable

  [[ -d "$framework" && ! -L "$framework" ]] ||
    fail "nested framework must be a non-symlink directory: $framework"
  [[ -f "$info_plist" && ! -L "$info_plist" ]] ||
    fail "nested framework Info.plist is missing or unsafe: $info_plist"
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null || true)"
  [[ -n "$executable" ]] ||
    fail "nested framework CFBundleExecutable is missing: $info_plist"
  [[ -f "$framework/$executable" && ! -L "$framework/$executable" ]] ||
    fail "nested framework main executable is missing or unsafe: $framework/$executable"

  # A framework signature seals its Resources directory. Materialized version
  # directories are nested bundles, so sign each version after its Mach-O
  # leaves and before signing the outer framework.
  if [[ -e "$framework/Versions" || -L "$framework/Versions" ]]; then
    [[ -d "$framework/Versions" && ! -L "$framework/Versions" ]] ||
      fail "nested framework Versions must be a non-symlink directory: $framework/Versions"
    while IFS= read -r -d '' version; do
      version_info_plist="$version/Resources/Info.plist"
      [[ -f "$version_info_plist" && ! -L "$version_info_plist" ]] ||
        fail "nested framework version Info.plist is missing or unsafe: $version_info_plist"
      version_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$version_info_plist" 2>/dev/null || true)"
      [[ "$version_executable" == "$executable" ]] ||
        fail "nested framework version executable must match the outer framework: $version"
      [[ -f "$version/$version_executable" && ! -L "$version/$version_executable" ]] ||
        fail "nested framework version main executable is missing or unsafe: $version/$version_executable"
      codesign \
        --force \
        --sign "$SIGNING_IDENTITY" \
        "$TIMESTAMP_ARGUMENT" \
        --options runtime \
        "$version" >/dev/null
      codesign --verify --strict "$version" >/dev/null 2>&1 ||
        fail "signed nested framework version failed verification: $version"
    done < <(find "$framework/Versions" -mindepth 1 -maxdepth 1 -type d -print0)
  fi

  # Sign the outer bundle last so neither leaf nor version-bundle signing can
  # invalidate its resource seal.
  codesign \
    --force \
    --sign "$SIGNING_IDENTITY" \
    "$TIMESTAMP_ARGUMENT" \
    --options runtime \
    "$framework" >/dev/null
  codesign --verify --strict "$framework" >/dev/null 2>&1 ||
    fail "signed nested framework failed verification: $framework"
}

while IFS= read -r -d '' path; do
  is_macho "$path" || continue
  is_macho_executable "$path" && continue
  is_framework_main_executable "$path" && continue
  is_preserved_apple_d3dmetal_code "$path" && continue
  sign_library "$path"
done < <(find "$RUNTIME_ROOT" -type f -print0)

while IFS= read -r -d '' path; do
  is_macho_executable "$path" || continue
  is_framework_main_executable "$path" && continue
  is_preserved_apple_d3dmetal_code "$path" && continue
  sign_executable "$path"
done < <(find "$RUNTIME_ROOT" -type f -print0)

while IFS= read -r -d '' framework; do
  if [[ "$PRESERVE_APPLE_D3DMETAL" == "1" && "$framework" == "$D3DMETAL_FRAMEWORK" ]]; then
    continue
  fi
  sign_framework "$framework"
done < <(find "$RUNTIME_ROOT" -depth -type d -name '*.framework' -print0)

while IFS= read -r -d '' path; do
  is_macho "$path" || continue
  codesign --verify --strict "$path" >/dev/null 2>&1 ||
    fail "signed Mach-O failed verification: $path"
done < <(find "$RUNTIME_ROOT" -type f -print0)

if [[ "$PRESERVE_APPLE_D3DMETAL" == "1" ]]; then
  codesign --verify --strict --verbose=2 "$D3DMETAL_FRAMEWORK" >/dev/null ||
    fail "preserved Apple D3DMetal framework failed final verification"
  codesign --verify --strict --verbose=2 "$D3DMETAL_SHARED_LIBRARY" >/dev/null ||
    fail "preserved Apple libd3dshared failed final verification"
fi

printf 'Signed ForgePlay Runtime code (%s): %s\n' "$SIGNING_MODE" "$RUNTIME_ROOT"
