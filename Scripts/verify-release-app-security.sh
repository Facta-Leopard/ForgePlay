#!/usr/bin/env bash
set -euo pipefail

REQUIRE_DEVELOPER_ID="0"
APP_PATH=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
ENTITLEMENTS_PLIST="$(mktemp "$DEFAULT_TEMP_ROOT/forgeplay-release-app-entitlements.XXXXXX")"
HOST_ENTITLEMENTS_PLIST=""
RUNTIME_ENTITLEMENTS_PLIST=""

cleanup() {
  rm -f "$ENTITLEMENTS_PLIST" "$HOST_ENTITLEMENTS_PLIST" "$RUNTIME_ENTITLEMENTS_PLIST"
}
trap cleanup EXIT

fail() {
  printf 'error: invalid release app security: %s\n' "$*" >&2
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

require_non_symlink_directory() {
  local path="$1"
  local label="$2"
  reject_symlink_parent_components "$path" "$label"
  [[ -d "$path" && ! -L "$path" ]] || fail "$label must be a non-symlink directory: $path"
}

require_non_symlink_regular_file() {
  local path="$1"
  local label="$2"
  local link_count
  reject_symlink_parent_components "$path" "$label"
  [[ -f "$path" && ! -L "$path" ]] || fail "$label must be a non-symlink regular file: $path"
  link_count="$(stat -f '%l' "$path" 2>/dev/null)" || fail "$label link count could not be inspected: $path"
  [[ "$link_count" == "1" ]] || fail "$label must not be hardlinked: $path"
}

require_apple_silicon_main_executable() {
  local executable="$1"
  local architectures

  architectures="$(lipo -archs "$executable" 2>/dev/null)" ||
    fail "app executable architectures could not be inspected: $executable"
  [[ "$architectures" == "arm64" ]] ||
    fail "app executable must contain exactly one arm64 slice (found: $architectures)"
}

find_external_installer_payloads() {
  local path lower_path runtime_prefix basename link_count
  runtime_prefix="$(printf '%s' "$APP_PATH/Contents/Resources/Runners/ForgePlayRuntime/" | tr '[:upper:]' '[:lower:]')"
  while IFS= read -r path; do
    lower_path="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
    basename="$(basename "$lower_path")"
    case "$lower_path" in
      "$runtime_prefix"*.dll|"$runtime_prefix"*.exe)
        case "$basename" in
          steamsetup.exe|vc_redist*.exe|vcredist*.exe|dxsetup.exe|dotnet*setup*.exe|directx*setup*.exe|microsoftedgewebview2*setup*.exe)
            printf '%s\n' "$path"
            continue
            ;;
        esac
        if [[ -f "$path" && ! -L "$path" ]]; then
          link_count="$(stat -f '%l' "$path" 2>/dev/null || printf '0')"
          [[ "$link_count" == "1" ]] && continue
        fi
        ;;
    esac
    printf '%s\n' "$path"
  done < <(
    find "$APP_PATH/Contents" \( -type f -o -type l \) \( \
      -iname '*.exe' -o \
      -iname '*.msi' -o \
      -iname '*.dmg' -o \
      -iname '*.pkg' -o \
      -iname '*.zip' -o \
      -iname '*.7z' -o \
      -iname '*.rar' -o \
      -iname '*.dll' \
    \) -print
  )
}

require_true_entitlement() {
  local plist="$1"
  local key="$2"
  if [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)" != "true" ]]; then
    fail "app is missing required entitlement: $key"
  fi
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

signing_detail_value() {
  local details="$1"
  local key="$2"
  printf '%s\n' "$details" | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

signing_authority_chain() {
  printf '%s\n' "$1" | sed -n 's/^Authority=//p'
}

require_absent_entitlement() {
  local plist="$1"
  local key="$2"
  local label="$3"
  [[ -z "$(plist_value "$plist" "$key")" ]] ||
    fail "$label contains forbidden entitlement: $key"
}

require_exact_app_group() {
  local plist="$1"
  local expected_group="$2"
  local label="$3"
  [[ "$(plist_value "$plist" 'com.apple.security.application-groups:0')" == "$expected_group" ]] ||
    fail "$label App Group must be exactly $expected_group"
  [[ -z "$(plist_value "$plist" 'com.apple.security.application-groups:1')" ]] ||
    fail "$label must contain exactly one App Group"
}

require_exact_entitlement_count() {
  local plist="$1"
  local expected_count="$2"
  local label="$3"
  local actual_count
  actual_count="$(plutil -convert xml1 -o - "$plist" | grep -c '<key>')"
  [[ "$actual_count" == "$expected_count" ]] ||
    fail "$label contains unexpected entitlements (found $actual_count keys; expected $expected_count)"
}

verify_direct_game_mode_host() {
  local helpers_dir="$CONTENTS_DIR/Helpers"
  local host="$helpers_dir/GameModeProcessHost.app"
  local host_info="$host/Contents/Info.plist"
  local host_executable="$host/Contents/MacOS/GameModeProcessHost"
  local unexpected_helpers host_architectures host_mach_header
  local host_signing_details host_team_identifier host_authority_chain

  require_non_symlink_directory "$helpers_dir" "app Helpers directory"
  require_non_symlink_directory "$host" "direct Game Mode process host"
  require_non_symlink_regular_file "$host_info" "direct Game Mode process host Info.plist"
  require_non_symlink_regular_file "$host_executable" "direct Game Mode process host executable"
  [[ -x "$host_executable" ]] || fail "direct Game Mode process host must be executable"

  unexpected_helpers="$({
    find "$helpers_dir" -mindepth 1 -maxdepth 1 ! -name 'GameModeProcessHost.app' -print
  } 2>/dev/null || true)"
  if [[ -n "$unexpected_helpers" ]]; then
    printf '%s\n' "$unexpected_helpers" >&2
    fail "direct Release app contains an unapproved nested helper"
  fi

  [[ "$(plist_value "$host_info" CFBundleIdentifier)" == "$APP_BUNDLE_IDENTIFIER.game-mode-host" ]] ||
    fail "direct Game Mode process host bundle identifier must use the app bundle-identifier suffix"
  [[ "$(plist_value "$host_info" CFBundleExecutable)" == "GameModeProcessHost" ]] ||
    fail "direct Game Mode process host executable declaration is invalid"
  [[ "$(plist_value "$host_info" CFBundlePackageType)" == "APPL" ]] ||
    fail "direct Game Mode process host must be an application bundle"
  [[ "$(plist_value "$host_info" LSSupportsGameMode)" == "true" ]] ||
    fail "direct Game Mode process host must declare LSSupportsGameMode"

  host_architectures="$(lipo -archs "$host_executable" 2>/dev/null)" ||
    fail "direct Game Mode process host architectures could not be read"
  [[ "$host_architectures" == "x86_64" ]] ||
    fail "direct Game Mode process host must contain exactly one x86_64 slice (found: $host_architectures)"
  host_mach_header="$(otool -hv "$host_executable" 2>/dev/null)" ||
    fail "direct Game Mode process host Mach header could not be read"
  [[ "$(awk 'END { print $5 }' <<< "$host_mach_header")" == "EXECUTE" ]] ||
    fail "direct Game Mode process host must be an MH_EXECUTE Mach-O"
  if awk 'END { for (field_index = 8; field_index <= NF; field_index++) if ($field_index == "PIE") exit 0; exit 1 }' \
    <<< "$host_mach_header"; then
    fail "direct Game Mode process host must not carry the MH_PIE flag"
  fi

  codesign --verify --strict --verbose=2 "$host" >/dev/null 2>&1 ||
    fail "direct Game Mode process host signature is invalid"
  host_signing_details="$(codesign -dv --verbose=4 "$host" 2>&1 || true)"
  [[ "$(signing_detail_value "$host_signing_details" Identifier)" == "$APP_BUNDLE_IDENTIFIER.game-mode-host" ]] ||
    fail "direct Game Mode process host signature identifier is invalid"
  host_team_identifier="$(signing_detail_value "$host_signing_details" TeamIdentifier)"
  [[ "$host_team_identifier" == "$MAIN_TEAM_IDENTIFIER" ]] || {
    printf '%s\n' "$host_signing_details" >&2
    fail "direct Game Mode process host must be signed by the app team"
  }
  printf '%s\n' "$host_signing_details" | grep -Eq 'flags=.*\bruntime\b' ||
    fail "direct Game Mode process host must enable Hardened Runtime"
  if [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
    host_authority_chain="$(signing_authority_chain "$host_signing_details")"
    [[ "$host_authority_chain" == "$MAIN_AUTHORITY_CHAIN" ]] || {
      printf '%s\n' "$host_signing_details" >&2
      fail "direct Game Mode process host must use the app Developer ID authority chain"
    }
    printf '%s\n' "$host_signing_details" | grep -Eq '^Timestamp=.+' ||
      fail "direct Game Mode process host Developer ID signature has no secure timestamp"
  fi

  HOST_ENTITLEMENTS_PLIST="$(mktemp "$DEFAULT_TEMP_ROOT/forgeplay-direct-game-mode-host-entitlements.XXXXXX")"
  codesign -d --entitlements :- "$host" > "$HOST_ENTITLEMENTS_PLIST" 2>/dev/null ||
    fail "direct Game Mode process host entitlements could not be read"
  require_exact_app_group "$HOST_ENTITLEMENTS_PLIST" "$EXPECTED_APP_GROUP" "direct Game Mode process host"
  [[ "$(plist_value "$HOST_ENTITLEMENTS_PLIST" 'com.apple.security.cs.allow-unsigned-executable-memory')" == "true" ]] ||
    fail "direct Game Mode process host must allow unsigned executable memory"
  [[ "$(plist_value "$HOST_ENTITLEMENTS_PLIST" 'com.apple.security.cs.disable-library-validation')" == "true" ]] ||
    fail "direct Game Mode process host must disable library validation"
  require_absent_entitlement "$HOST_ENTITLEMENTS_PLIST" "com.apple.security.app-sandbox" "direct Game Mode process host"
  require_absent_entitlement "$HOST_ENTITLEMENTS_PLIST" "com.apple.security.inherit" "direct Game Mode process host"
  require_absent_entitlement "$HOST_ENTITLEMENTS_PLIST" "com.apple.security.get-task-allow" "direct Game Mode process host"
  require_exact_entitlement_count "$HOST_ENTITLEMENTS_PLIST" "3" "direct Game Mode process host"
  rm -f "$HOST_ENTITLEMENTS_PLIST"
  HOST_ENTITLEMENTS_PLIST=""
}

is_preserved_direct_apple_d3dmetal_code() {
  local candidate="$1"
  [[ "$candidate" == "$DIRECT_D3DMETAL_SHARED_LIBRARY" ||
     "$candidate" == "$DIRECT_D3DMETAL_FRAMEWORK"/* ]]
}

verify_preserved_direct_apple_d3dmetal_signature() {
  local candidate="$1"
  local signing_details="$2"
  printf '%s\n' "$signing_details" | grep -Fxq 'Authority=Software Signing' ||
    fail "direct Release D3DMetal code lost Apple's software signature: $candidate"
  printf '%s\n' "$signing_details" | grep -Fxq 'Authority=Apple Code Signing Certification Authority' ||
    fail "direct Release D3DMetal code lost Apple's code-signing authority: $candidate"
  printf '%s\n' "$signing_details" | grep -Fxq 'Authority=Apple Root CA' ||
    fail "direct Release D3DMetal code lost Apple's root authority: $candidate"
  [[ "$(signing_detail_value "$signing_details" TeamIdentifier)" == "not set" ]] ||
    fail "direct Release D3DMetal code must retain its Apple software signature: $candidate"
}

verify_direct_runtime_code() {
  local runtime_root="$APP_PATH/Contents/Resources/Runners/ForgePlayRuntime"
  local runtime_code runtime_signing_details runtime_team_identifier runtime_authority_chain

  DIRECT_D3DMETAL_FRAMEWORK="$runtime_root/Frameworks/renderer/d3dmetal/external/D3DMetal.framework"
  DIRECT_D3DMETAL_SHARED_LIBRARY="$runtime_root/Frameworks/renderer/d3dmetal/external/libd3dshared.dylib"

  while IFS= read -r -d '' runtime_code; do
    file -b "$runtime_code" 2>/dev/null | grep -q '^Mach-O' || continue
    codesign --verify --strict "$runtime_code" >/dev/null 2>&1 ||
      fail "direct Release runtime Mach-O signature is invalid: $runtime_code"
    runtime_signing_details="$(codesign -dv --verbose=4 "$runtime_code" 2>&1 || true)"
    if is_preserved_direct_apple_d3dmetal_code "$runtime_code"; then
      verify_preserved_direct_apple_d3dmetal_signature "$runtime_code" "$runtime_signing_details"
      continue
    fi

    runtime_team_identifier="$(signing_detail_value "$runtime_signing_details" TeamIdentifier)"
    [[ "$runtime_team_identifier" == "$MAIN_TEAM_IDENTIFIER" ]] || {
      printf '%s\n' "$runtime_signing_details" >&2
      fail "direct Release runtime Mach-O must be signed by the app team: $runtime_code"
    }
    if [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
      runtime_authority_chain="$(signing_authority_chain "$runtime_signing_details")"
      [[ "$runtime_authority_chain" == "$MAIN_AUTHORITY_CHAIN" ]] || {
        printf '%s\n' "$runtime_signing_details" >&2
        fail "direct Release runtime Mach-O must use the app Developer ID authority chain: $runtime_code"
      }
      printf '%s\n' "$runtime_signing_details" | grep -Eq '^Timestamp=.+' ||
        fail "direct Release runtime Mach-O Developer ID signature has no secure timestamp: $runtime_code"
    fi

    if file -b "$runtime_code" 2>/dev/null | grep -q '^Mach-O.*executable'; then
      printf '%s\n' "$runtime_signing_details" | grep -Eq 'flags=.*\bruntime\b' ||
        fail "direct Release runtime executable must enable Hardened Runtime: $runtime_code"
      RUNTIME_ENTITLEMENTS_PLIST="$(mktemp "$DEFAULT_TEMP_ROOT/forgeplay-direct-runtime-entitlements.XXXXXX")"
      codesign -d --entitlements :- "$runtime_code" > "$RUNTIME_ENTITLEMENTS_PLIST" 2>/dev/null ||
        fail "direct Release runtime executable entitlements could not be read: $runtime_code"
      [[ "$(plist_value "$RUNTIME_ENTITLEMENTS_PLIST" 'com.apple.security.cs.allow-unsigned-executable-memory')" == "true" ]] ||
        fail "direct Release runtime executable must allow unsigned executable memory: $runtime_code"
      [[ "$(plist_value "$RUNTIME_ENTITLEMENTS_PLIST" 'com.apple.security.cs.disable-library-validation')" == "true" ]] ||
        fail "direct Release runtime executable must disable library validation: $runtime_code"
      require_exact_app_group "$RUNTIME_ENTITLEMENTS_PLIST" "$EXPECTED_APP_GROUP" "direct Release runtime executable"
      require_absent_entitlement "$RUNTIME_ENTITLEMENTS_PLIST" "com.apple.security.app-sandbox" "direct Release runtime executable"
      require_absent_entitlement "$RUNTIME_ENTITLEMENTS_PLIST" "com.apple.security.inherit" "direct Release runtime executable"
      require_absent_entitlement "$RUNTIME_ENTITLEMENTS_PLIST" "com.apple.security.cs.allow-jit" "direct Release runtime executable"
      require_absent_entitlement "$RUNTIME_ENTITLEMENTS_PLIST" "com.apple.security.get-task-allow" "direct Release runtime executable"
      require_exact_entitlement_count "$RUNTIME_ENTITLEMENTS_PLIST" "3" "direct Release runtime executable"
      rm -f "$RUNTIME_ENTITLEMENTS_PLIST"
      RUNTIME_ENTITLEMENTS_PLIST=""
    fi
  done < <(find "$runtime_root" -type f -print0)
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --require-developer-id)
      REQUIRE_DEVELOPER_ID="1"
      shift
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$APP_PATH" ]] || fail "usage: verify-release-app-security.sh [--require-developer-id] <app bundle>"
      APP_PATH="$1"
      shift
      ;;
  esac
done

[[ -n "$APP_PATH" ]] || fail "usage: verify-release-app-security.sh [--require-developer-id] <app bundle>"
require_non_symlink_directory "$APP_PATH" "app bundle"

CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
EXECUTABLE="$APP_PATH/Contents/MacOS/ForgePlay"
require_non_symlink_directory "$CONTENTS_DIR" "app Contents"
require_non_symlink_directory "$MACOS_DIR" "app MacOS directory"
require_non_symlink_regular_file "$INFO_PLIST" "app Info.plist"
require_non_symlink_regular_file "$EXECUTABLE" "app executable"
require_apple_silicon_main_executable "$EXECUTABLE"

codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null ||
  fail "app failed codesign --verify --deep --strict"

SIGNING_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)"
printf '%s\n' "$SIGNING_DETAILS" | grep -Eq 'flags=.*\bruntime\b' || {
  printf '%s\n' "$SIGNING_DETAILS" >&2
  fail "app is not signed with Hardened Runtime"
}

if [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
  printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Authority=Developer ID Application' || {
    printf '%s\n' "$SIGNING_DETAILS" >&2
    fail "app is not signed with Developer ID Application"
  }
  printf '%s\n' "$SIGNING_DETAILS" | grep -Eq '^Timestamp=.+' || {
    printf '%s\n' "$SIGNING_DETAILS" >&2
    fail "app Developer ID signature has no secure timestamp"
  }
fi

codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_PLIST" 2>/dev/null ||
  fail "app entitlements could not be read"

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS_PLIST" 2>/dev/null || true)" == "true" ]]; then
  SANDBOX_VERIFIER_ARGS=(--direct-dmg-runtime)
  if [[ "$REQUIRE_DEVELOPER_ID" == "1" ]]; then
    SANDBOX_VERIFIER_ARGS+=(--require-developer-id-signature)
  fi
  bash "$SCRIPT_DIR/verify-app-store-app-security.sh" \
    "${SANDBOX_VERIFIER_ARGS[@]}" \
    "$APP_PATH" >/dev/null
  printf 'Sandboxed DMG app security verification passed: %s\n' "$APP_PATH"
  exit 0
fi

APP_BUNDLE_IDENTIFIER="$(plist_value "$INFO_PLIST" CFBundleIdentifier)"
[[ -n "$APP_BUNDLE_IDENTIFIER" && "$APP_BUNDLE_IDENTIFIER" != *'$('* ]] ||
  fail "direct Release app bundle identifier must be concrete"
case "$(printf '%s' "$APP_BUNDLE_IDENTIFIER" | tr '[:upper:]' '[:lower:]')" in
  *.app)
    fail "direct Release bundle identifier must not end in .app"
    ;;
esac
MAIN_TEAM_IDENTIFIER="$(signing_detail_value "$SIGNING_DETAILS" TeamIdentifier)"
[[ -n "$MAIN_TEAM_IDENTIFIER" && "$MAIN_TEAM_IDENTIFIER" != "not set" ]] || {
  printf '%s\n' "$SIGNING_DETAILS" >&2
  fail "direct Release signature does not contain a TeamIdentifier"
}
EXPECTED_APP_GROUP="$MAIN_TEAM_IDENTIFIER.$APP_BUNDLE_IDENTIFIER"
require_exact_app_group "$ENTITLEMENTS_PLIST" "$EXPECTED_APP_GROUP" "direct Release app"
MAIN_AUTHORITY_CHAIN="$(signing_authority_chain "$SIGNING_DETAILS")"
if [[ "$REQUIRE_DEVELOPER_ID" == "1" && -z "$MAIN_AUTHORITY_CHAIN" ]]; then
  fail "direct Release app Developer ID authority chain could not be read"
fi

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$ENTITLEMENTS_PLIST" 2>/dev/null || true)" == "true" ]]; then
  fail "app contains com.apple.security.get-task-allow"
fi

require_true_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.cs.allow-jit"
require_true_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.cs.disable-library-validation"
require_true_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.files.user-selected.read-write"
require_true_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.device.audio-input"
require_true_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.network.client"
require_absent_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.app-sandbox" "direct Release app"
require_absent_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.inherit" "direct Release app"
require_absent_entitlement "$ENTITLEMENTS_PLIST" "com.apple.security.get-task-allow" "direct Release app"
require_exact_entitlement_count "$ENTITLEMENTS_PLIST" "6" "direct Release app"

verify_direct_game_mode_host

PROHIBITED_PAYLOADS="$(find_external_installer_payloads)"
if [[ -n "$PROHIBITED_PAYLOADS" ]]; then
  printf '%s\n' "$PROHIBITED_PAYLOADS" >&2
  fail "app bundle contains external installer/runtime payloads"
fi

RUNTIME_CONTAINER="$APP_PATH/Contents/Resources/Runners"
UNEXPECTED_RUNNERS="$({
  find "$RUNTIME_CONTAINER" -mindepth 1 -maxdepth 1 ! -name 'ForgePlayRuntime' -print
} 2>/dev/null || true)"
if [[ -n "$UNEXPECTED_RUNNERS" ]]; then
  printf '%s\n' "$UNEXPECTED_RUNNERS" >&2
  fail "app bundle contains an unapproved Windows runner"
fi

DEBUG_MARKERS="$(LC_ALL=C strings -a "$EXECUTABLE" | grep -E 'FORGEPLAY_QA_|debugLayoutFixture|Debug startup failure fixture' || true)"
if [[ -n "$DEBUG_MARKERS" ]]; then
  printf '%s\n' "$DEBUG_MARKERS" >&2
  fail "app executable contains DEBUG QA launch hooks"
fi

bash "$SCRIPT_DIR/verify-bundled-runtime-capability.sh" "$APP_PATH" >/dev/null
verify_direct_runtime_code

printf 'Release app security verification passed: %s\n' "$APP_PATH"
