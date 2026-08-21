#!/usr/bin/env bash
set -euo pipefail

REQUIRE_SUBMISSION_SIGNATURE="0"
REQUIRE_DEVELOPER_ID_SIGNATURE="0"
DIRECT_DMG_RUNTIME="0"
APP_PATH=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTROLLER_PERMISSIONS_VERIFIER="$SCRIPT_DIR/verify-app-store-controller-permissions.py"
LEGAL_DOCUMENT_VERIFIER="$SCRIPT_DIR/verify-legal-documents.sh"
DEFAULT_TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
ENTITLEMENTS_PLIST="$(mktemp "$DEFAULT_TEMP_ROOT/forgeplay-app-store-app-entitlements.XXXXXX")"
RUNTIME_ENTITLEMENTS_PLIST=""
HOST_ENTITLEMENTS_PLIST=""

cleanup() {
  rm -f "$ENTITLEMENTS_PLIST" "$RUNTIME_ENTITLEMENTS_PLIST" "$HOST_ENTITLEMENTS_PLIST"
}
trap cleanup EXIT

fail() {
  printf 'error: invalid sandboxed app security: %s\n' "$*" >&2
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

verify_external_storage_access_bridge() {
  local frameworks_dir="$CONTENTS_DIR/Frameworks"
  local bridge="$frameworks_dir/ForgePlayExternalStorageAccess.dylib"
  local bridge_file_description bridge_architectures
  local bridge_signing_details bridge_team_identifier
  local bridge_exported_symbols bridge_install_id_output bridge_install_id

  require_non_symlink_directory "$frameworks_dir" "app Frameworks directory"
  require_non_symlink_regular_file "$bridge" "external storage access bridge"

  bridge_file_description="$(file -b "$bridge" 2>/dev/null)" ||
    fail "external storage access bridge file type could not be inspected"
  [[ "$bridge_file_description" == Mach-O* ]] ||
    fail "external storage access bridge must be a Mach-O dynamic library"

  bridge_architectures="$(lipo -archs "$bridge" 2>/dev/null)" ||
    fail "external storage access bridge architectures could not be inspected"
  [[ "$bridge_architectures" == "x86_64" ]] ||
    fail "external storage access bridge must contain exactly one internal x86_64 slice (found: $bridge_architectures)"

  codesign --verify --strict --verbose=2 "$bridge" >/dev/null 2>&1 ||
    fail "external storage access bridge nested signature is invalid"
  bridge_signing_details="$(codesign -dv --verbose=4 "$bridge" 2>&1 || true)"
  bridge_team_identifier="$(signing_detail_value "$bridge_signing_details" TeamIdentifier)"
  [[ "$bridge_team_identifier" == "$MAIN_TEAM_IDENTIFIER" ]] || {
    printf '%s\n' "$bridge_signing_details" >&2
    fail "external storage access bridge must be signed by the ForgePlay app team"
  }

  bridge_exported_symbols="$(nm -gU "$bridge" 2>/dev/null)" ||
    fail "external storage access bridge symbols could not be read"
  awk '$NF == "_FPActivateExternalStorageGrantManifest" { found = 1 }
       END { exit(found ? 0 : 1) }' <<<"$bridge_exported_symbols" ||
    fail "external storage access bridge does not export FPActivateExternalStorageGrantManifest"

  bridge_install_id_output="$(otool -D "$bridge" 2>/dev/null)" ||
    fail "external storage access bridge install name could not be read"
  bridge_install_id="$(
    printf '%s\n' "$bridge_install_id_output" |
      sed -n '2,$p' |
      sed '/^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//'
  )"
  [[ "$bridge_install_id" == "@rpath/ForgePlayExternalStorageAccess.dylib" ]] ||
    fail "external storage access bridge install name is invalid: $bridge_install_id"

  if [[ "$REQUIRE_SUBMISSION_SIGNATURE" == "1" ]]; then
    if printf '%s\n' "$bridge_signing_details" | grep -Fq 'Authority=Apple Development'; then
      printf '%s\n' "$bridge_signing_details" >&2
      fail "App Store external storage access bridge must not use an Apple Development signature"
    fi
    printf '%s\n' "$bridge_signing_details" |
      grep -Eq 'Authority=(Apple Distribution|3rd Party Mac Developer Application)' || {
        printf '%s\n' "$bridge_signing_details" >&2
        fail "App Store external storage access bridge must use the app distribution authority"
      }
  fi
  if [[ "$REQUIRE_DEVELOPER_ID_SIGNATURE" == "1" ]]; then
    printf '%s\n' "$bridge_signing_details" | grep -Fq 'Authority=Developer ID Application' || {
      printf '%s\n' "$bridge_signing_details" >&2
      fail "direct DMG external storage access bridge must use Developer ID Application"
    }
    printf '%s\n' "$bridge_signing_details" | grep -Fq 'Timestamp=' || {
      printf '%s\n' "$bridge_signing_details" >&2
      fail "direct DMG external storage access bridge must include a secure timestamp"
    }
  fi
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

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

signing_detail_value() {
  local details="$1"
  local key="$2"
  printf '%s\n' "$details" | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

require_true_entitlement() {
  local key="$1"
  if [[ "$(plist_value "$ENTITLEMENTS_PLIST" "$key")" != "true" ]]; then
    fail "app is missing required entitlement: $key"
  fi
}

require_absent_entitlement() {
  local key="$1"
  if [[ -n "$(plist_value "$ENTITLEMENTS_PLIST" "$key")" ]]; then
    fail "app contains an entitlement forbidden by the sandboxed distribution contract: $key"
  fi
}

require_host_true_entitlement() {
  local key="$1"
  if [[ "$(plist_value "$HOST_ENTITLEMENTS_PLIST" "$key")" != "true" ]]; then
    fail "Game Mode process host is missing required entitlement: $key"
  fi
}

require_host_absent_entitlement() {
  local key="$1"
  if [[ -n "$(plist_value "$HOST_ENTITLEMENTS_PLIST" "$key")" ]]; then
    fail "Game Mode process host contains forbidden entitlement: $key"
  fi
}

is_preserved_apple_d3dmetal_code() {
  local candidate="$1"
  [[ "$DIRECT_DMG_RUNTIME" == "1" ]] || return 1
  [[ "$candidate" == "$D3DMETAL_SHARED_LIBRARY" ||
     "$candidate" == "$D3DMETAL_FRAMEWORK"/* ]]
}

verify_preserved_apple_d3dmetal_signature() {
  local candidate="$1"
  local signing_details="$2"
  local identifier

  printf '%s\n' "$signing_details" | grep -Fxq 'Authority=Software Signing' ||
    fail "preserved direct DMG D3DMetal code is missing Apple's software authority: $candidate"
  printf '%s\n' "$signing_details" |
    grep -Fxq 'Authority=Apple Code Signing Certification Authority' ||
    fail "preserved direct DMG D3DMetal code is missing Apple's code-signing authority: $candidate"
  printf '%s\n' "$signing_details" | grep -Fxq 'Authority=Apple Root CA' ||
    fail "preserved direct DMG D3DMetal code is missing Apple's root authority: $candidate"
  [[ "$(signing_detail_value "$signing_details" TeamIdentifier)" == "not set" ]] ||
    fail "preserved direct DMG D3DMetal code must retain its Apple software signature: $candidate"

  identifier="$(signing_detail_value "$signing_details" Identifier)"
  case "$candidate" in
    "$D3DMETAL_SHARED_LIBRARY")
      [[ "$identifier" == "com.apple.libd3dshared" ]] ||
        fail "preserved direct DMG libd3dshared identifier is invalid: $identifier"
      ;;
    "$D3DMETAL_FRAMEWORK"/Versions/*/D3DMetal)
      [[ "$identifier" == "com.apple.D3DMetal" ]] ||
        fail "preserved direct DMG D3DMetal identifier is invalid: $identifier"
      ;;
  esac
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --require-submission-signature)
      REQUIRE_SUBMISSION_SIGNATURE="1"
      shift
      ;;
    --require-developer-id-signature)
      REQUIRE_DEVELOPER_ID_SIGNATURE="1"
      shift
      ;;
    --direct-dmg-runtime)
      DIRECT_DMG_RUNTIME="1"
      shift
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$APP_PATH" ]] ||
        fail "usage: verify-app-store-app-security.sh [--require-submission-signature | --require-developer-id-signature] [--direct-dmg-runtime] <app bundle>"
      APP_PATH="$1"
      shift
      ;;
  esac
done

[[ "$REQUIRE_SUBMISSION_SIGNATURE" != "1" || "$REQUIRE_DEVELOPER_ID_SIGNATURE" != "1" ]] ||
  fail "App Store and Developer ID signature policies are mutually exclusive"
[[ "$DIRECT_DMG_RUNTIME" != "1" || "$REQUIRE_SUBMISSION_SIGNATURE" != "1" ]] ||
  fail "direct DMG runtime policy cannot be combined with App Store submission signing"
[[ -n "$APP_PATH" ]] ||
  fail "usage: verify-app-store-app-security.sh [--require-submission-signature | --require-developer-id-signature] [--direct-dmg-runtime] <app bundle>"
require_non_symlink_directory "$APP_PATH" "app bundle"

CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
EXECUTABLE="$MACOS_DIR/ForgePlay"
require_non_symlink_directory "$CONTENTS_DIR" "app Contents"
require_non_symlink_directory "$MACOS_DIR" "app MacOS directory"
require_non_symlink_directory "$RESOURCES_DIR" "app Resources directory"
require_non_symlink_regular_file "$EXECUTABLE" "app executable"
require_non_symlink_regular_file "$INFO_PLIST" "app Info.plist"
require_non_symlink_regular_file "$CONTROLLER_PERMISSIONS_VERIFIER" "controller permission verifier"
require_non_symlink_regular_file "$LEGAL_DOCUMENT_VERIFIER" "legal document verifier"
[[ -x "$EXECUTABLE" ]] || fail "app executable must be executable: $EXECUTABLE"
require_apple_silicon_main_executable "$EXECUTABLE"

codesign --verify --deep --strict --verbose=2 "$APP_PATH" >/dev/null 2>&1 ||
  fail "app failed codesign --verify --deep --strict"

SIGNING_DETAILS="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)"
printf '%s\n' "$SIGNING_DETAILS" | grep -Eq 'flags=.*\bruntime\b' || {
  printf '%s\n' "$SIGNING_DETAILS" >&2
  fail "app is not signed with Hardened Runtime"
}
MAIN_TEAM_IDENTIFIER="$(signing_detail_value "$SIGNING_DETAILS" TeamIdentifier)"
[[ -n "$MAIN_TEAM_IDENTIFIER" && "$MAIN_TEAM_IDENTIFIER" != "not set" ]] || {
  printf '%s\n' "$SIGNING_DETAILS" >&2
  fail "app signature does not contain a TeamIdentifier"
}
if [[ "$REQUIRE_DEVELOPER_ID_SIGNATURE" == "1" ]]; then
  printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Authority=Developer ID Application' || {
    printf '%s\n' "$SIGNING_DETAILS" >&2
    fail "direct DMG app must use Developer ID Application"
  }
  printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Timestamp=' || {
    printf '%s\n' "$SIGNING_DETAILS" >&2
    fail "direct DMG app must include a secure timestamp"
  }
fi
verify_external_storage_access_bridge

codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS_PLIST" 2>/dev/null ||
  fail "app entitlements could not be read"

APP_BUNDLE_IDENTIFIER="$(plist_value "$INFO_PLIST" CFBundleIdentifier)"
[[ -n "$APP_BUNDLE_IDENTIFIER" && "$APP_BUNDLE_IDENTIFIER" != *'$('* ]] ||
  fail "app bundle identifier must be concrete"
if [[ "$DIRECT_DMG_RUNTIME" != "1" ]]; then
  case "$(printf '%s' "$APP_BUNDLE_IDENTIFIER" | tr '[:upper:]' '[:lower:]')" in
    *.app)
      fail "App Store bundle identifier must not end in .app"
      ;;
  esac
fi
EXPECTED_APP_GROUP="$MAIN_TEAM_IDENTIFIER.$APP_BUNDLE_IDENTIFIER"
SIGNED_APP_GROUP="$(plist_value "$ENTITLEMENTS_PLIST" 'com.apple.security.application-groups:0')"
[[ "$SIGNED_APP_GROUP" == "$EXPECTED_APP_GROUP" ]] ||
  fail "signed App Group must match the app team and bundle identifier: expected $EXPECTED_APP_GROUP"
[[ -z "$(plist_value "$ENTITLEMENTS_PLIST" 'com.apple.security.application-groups:1')" ]] ||
  fail "signed app must contain exactly one ForgePlay App Group"

require_true_entitlement "com.apple.security.app-sandbox"
require_true_entitlement "com.apple.security.files.user-selected.read-write"
require_true_entitlement "com.apple.security.files.user-selected.executable"
require_true_entitlement "com.apple.security.files.bookmarks.app-scope"
require_true_entitlement "com.apple.security.cs.allow-unsigned-executable-memory"
require_true_entitlement "com.apple.security.network.client"
require_true_entitlement "com.apple.security.network.server"
require_true_entitlement "com.apple.security.device.usb"
require_true_entitlement "com.apple.security.device.bluetooth"
require_absent_entitlement "com.apple.security.cs.allow-jit"
require_absent_entitlement "com.apple.security.cs.disable-library-validation"
require_absent_entitlement "com.apple.security.get-task-allow"

HELPERS_DIR="$CONTENTS_DIR/Helpers"
GAME_MODE_HOST="$HELPERS_DIR/GameModeProcessHost.app"
GAME_MODE_HOST_INFO="$GAME_MODE_HOST/Contents/Info.plist"
GAME_MODE_HOST_EXECUTABLE="$GAME_MODE_HOST/Contents/MacOS/GameModeProcessHost"
require_non_symlink_directory "$HELPERS_DIR" "app Helpers directory"
require_non_symlink_directory "$GAME_MODE_HOST" "fixed Game Mode process host"
require_non_symlink_regular_file "$GAME_MODE_HOST_INFO" "Game Mode process host Info.plist"
require_non_symlink_regular_file "$GAME_MODE_HOST_EXECUTABLE" "Game Mode process host executable"
[[ -x "$GAME_MODE_HOST_EXECUTABLE" ]] || fail "Game Mode process host must be executable"

UNEXPECTED_HELPERS="$({
  find "$HELPERS_DIR" -mindepth 1 -maxdepth 1 ! -name 'GameModeProcessHost.app' -print
} 2>/dev/null || true)"
if [[ -n "$UNEXPECTED_HELPERS" ]]; then
  printf '%s\n' "$UNEXPECTED_HELPERS" >&2
  fail "app contains an unapproved nested helper"
fi

[[ "$(plist_value "$GAME_MODE_HOST_INFO" CFBundleIdentifier)" == "$APP_BUNDLE_IDENTIFIER.game-mode-host" ]] ||
  fail "Game Mode process host bundle identifier is not derived from ForgePlay"
[[ "$(plist_value "$GAME_MODE_HOST_INFO" CFBundleExecutable)" == "GameModeProcessHost" ]] ||
  fail "Game Mode process host executable declaration is invalid"
[[ "$(plist_value "$GAME_MODE_HOST_INFO" CFBundlePackageType)" == "APPL" ]] ||
  fail "Game Mode process host must be an application bundle"
[[ "$(plist_value "$GAME_MODE_HOST_INFO" LSSupportsGameMode)" == "true" ]] ||
  fail "Game Mode process host must declare LSSupportsGameMode"
[[ "$(plist_value "$GAME_MODE_HOST_INFO" NSPrincipalClass)" == "WineApplication" ]] ||
  fail "Game Mode process host principal class is invalid"
[[ "$(plist_value "$GAME_MODE_HOST_INFO" CFBundleIconName)" == "AppIcon" ]] ||
  fail "Game Mode process host must use the ForgePlay app icon"
[[ "$(plist_value "$GAME_MODE_HOST_INFO" CFBundleIconFile)" == "AppIcon" ]] ||
  fail "Xcode-built Game Mode process host must use the AppIcon asset catalog compatibility file identity"
[[ -z "$(plist_value "$GAME_MODE_HOST_INFO" LSUIElement)" ]] ||
  fail "Game Mode process host must not be an LSUIElement"
[[ -z "$(plist_value "$GAME_MODE_HOST_INFO" LSBackgroundOnly)" ]] ||
  fail "Game Mode process host must not be background-only"
[[ -z "$(plist_value "$GAME_MODE_HOST_INFO" LSMultipleInstancesProhibited)" ]] ||
  fail "Game Mode process host must permit concurrent Steam game children"
[[ "$(lipo -archs "$GAME_MODE_HOST_EXECUTABLE" 2>/dev/null)" == "x86_64" ]] ||
  fail "Game Mode process host must contain exactly one internal x86_64 slice"
HOST_MACH_HEADER="$(otool -hv "$GAME_MODE_HOST_EXECUTABLE" 2>/dev/null)" ||
  fail "Game Mode process host Mach header could not be read"
[[ "$(awk 'END { print $5 }' <<< "$HOST_MACH_HEADER")" == "EXECUTE" ]] ||
  fail "Game Mode process host must be an executable Mach-O"
if awk 'END { for (field_index = 8; field_index <= NF; field_index++) if ($field_index == "PIE") exit 0; exit 1 }' \
  <<< "$HOST_MACH_HEADER"; then
  fail "Game Mode process host must not carry the MH_PIE flag"
fi
HOST_LOAD_COMMANDS="$(otool -l "$GAME_MODE_HOST_EXECUTABLE" 2>/dev/null)" ||
  fail "Game Mode process host load commands could not be read"
[[ "$HOST_LOAD_COMMANDS" == *'sectname __info_plist'* ]] ||
  fail "Game Mode process host is missing its embedded plist section"
HOST_EMBEDDED_INFO="$(plutil -p "$GAME_MODE_HOST_EXECUTABLE" 2>/dev/null)" ||
  fail "Game Mode process host embedded plist could not be read"
for expected_identity in \
  "\"CFBundleIdentifier\" => \"$APP_BUNDLE_IDENTIFIER.game-mode-host\"" \
  '"CFBundleExecutable" => "GameModeProcessHost"' \
  '"CFBundleIconName" => "AppIcon"' \
  '"CFBundleIconFile" => "AppIcon"' \
  '"CFBundlePackageType" => "APPL"' \
  '"LSApplicationCategoryType" => "public.app-category.games"' \
  '"LSSupportsGameMode" => true' \
  '"NSPrincipalClass" => "WineApplication"'; do
  [[ "$HOST_EMBEDDED_INFO" == *"$expected_identity"* ]] ||
    fail "Game Mode process host embedded identity does not match: $expected_identity"
done
for forbidden_identity in LSUIElement LSBackgroundOnly LSMultipleInstancesProhibited; do
  [[ "$HOST_EMBEDDED_INFO" != *"\"$forbidden_identity\""* ]] ||
    fail "Game Mode process host embedded plist contains a forbidden identity key: $forbidden_identity"
done
host_segment_value() {
  local target_segment="$1"
  local target_field="$2"
  awk -v target_segment="$target_segment" -v target_field="$target_field" '
    $1 == "segname" { segment = $2 }
    segment == target_segment && $1 == target_field { print $2; exit }
  ' <<< "$HOST_LOAD_COMMANDS"
}
[[ "$(host_segment_value __PAGEZERO vmsize)" == "0x0000000000001000" ]] ||
  fail "Game Mode process host PAGEZERO layout is invalid"
[[ "$(host_segment_value __TEXT vmaddr)" == "0x0000000200000000" ]] ||
  fail "Game Mode process host TEXT image base is invalid"
[[ "$(host_segment_value WINE_RESERVE vmaddr)" == "0x0000000000001000" ]] ||
  fail "Game Mode process host WINE_RESERVE address is invalid"
[[ "$(host_segment_value WINE_RESERVE vmsize)" == "0x00000001fffff000" ]] ||
  fail "Game Mode process host WINE_RESERVE size is invalid"
[[ "$(host_segment_value WINE_TOP_DOWN vmaddr)" == "0x00007ff000000000" ]] ||
  fail "Game Mode process host WINE_TOP_DOWN address is invalid"
[[ "$(host_segment_value WINE_TOP_DOWN vmsize)" == "0x0000000001ff0000" ]] ||
  fail "Game Mode process host WINE_TOP_DOWN size is invalid"
HOST_EXPORTED_SYMBOLS="$(nm -gU "$GAME_MODE_HOST_EXECUTABLE" 2>/dev/null)" ||
  fail "Game Mode process host symbols could not be read"
[[ "$HOST_EXPORTED_SYMBOLS" == *'_wine_main_preload_info'* ]] ||
  fail "Game Mode process host does not export wine_main_preload_info"

codesign --verify --strict --verbose=2 "$GAME_MODE_HOST" >/dev/null 2>&1 ||
  fail "Game Mode process host signature is invalid"
HOST_SIGNING_DETAILS="$(codesign -dv --verbose=4 "$GAME_MODE_HOST" 2>&1 || true)"
HOST_TEAM_IDENTIFIER="$(signing_detail_value "$HOST_SIGNING_DETAILS" TeamIdentifier)"
[[ "$HOST_TEAM_IDENTIFIER" == "$MAIN_TEAM_IDENTIFIER" ]] || {
  printf '%s\n' "$HOST_SIGNING_DETAILS" >&2
  fail "Game Mode process host must be signed by the ForgePlay app team"
}
printf '%s\n' "$HOST_SIGNING_DETAILS" | grep -Eq 'flags=.*\bruntime\b' ||
  fail "Game Mode process host must enable Hardened Runtime"
HOST_ENTITLEMENTS_PLIST="$(mktemp "$DEFAULT_TEMP_ROOT/forgeplay-game-mode-host-entitlements.XXXXXX")"
codesign -d --entitlements :- "$GAME_MODE_HOST" > "$HOST_ENTITLEMENTS_PLIST" 2>/dev/null ||
  fail "Game Mode process host entitlements could not be read"
require_host_true_entitlement "com.apple.security.app-sandbox"
require_host_true_entitlement "com.apple.security.inherit"
require_host_true_entitlement "com.apple.security.cs.allow-unsigned-executable-memory"
require_host_true_entitlement "com.apple.security.cs.disable-library-validation"
require_host_absent_entitlement "com.apple.security.application-groups"
require_host_absent_entitlement "com.apple.security.files.bookmarks.app-scope"
require_host_absent_entitlement "com.apple.security.files.user-selected.executable"
require_host_absent_entitlement "com.apple.security.files.user-selected.read-write"
require_host_absent_entitlement "com.apple.security.network.client"
require_host_absent_entitlement "com.apple.security.network.server"
require_host_absent_entitlement "com.apple.security.cs.allow-jit"
require_host_absent_entitlement "com.apple.security.get-task-allow"
HOST_ENTITLEMENT_COUNT="$(plutil -convert xml1 -o - "$HOST_ENTITLEMENTS_PLIST" | grep -c '<key>')"
[[ "$HOST_ENTITLEMENT_COUNT" == "4" ]] ||
  fail "Game Mode process host may contain only app-sandbox, inherit, executable-memory, and library-validation entitlements"

if [[ "$REQUIRE_SUBMISSION_SIGNATURE" == "1" ]]; then
  if printf '%s\n' "$HOST_SIGNING_DETAILS" | grep -Fq 'Authority=Apple Development'; then
    printf '%s\n' "$HOST_SIGNING_DETAILS" >&2
    fail "App Store Game Mode process host must not use an Apple Development signature"
  fi
  printf '%s\n' "$HOST_SIGNING_DETAILS" |
    grep -Eq 'Authority=(Apple Distribution|3rd Party Mac Developer Application)' || {
      printf '%s\n' "$HOST_SIGNING_DETAILS" >&2
      fail "App Store Game Mode process host must use the app distribution authority"
    }
fi
if [[ "$REQUIRE_DEVELOPER_ID_SIGNATURE" == "1" ]]; then
  printf '%s\n' "$HOST_SIGNING_DETAILS" | grep -Fq 'Authority=Developer ID Application' || {
    printf '%s\n' "$HOST_SIGNING_DETAILS" >&2
    fail "direct DMG Game Mode process host must use Developer ID Application"
  }
  printf '%s\n' "$HOST_SIGNING_DETAILS" | grep -Fq 'Timestamp=' || {
    printf '%s\n' "$HOST_SIGNING_DETAILS" >&2
    fail "direct DMG Game Mode process host must include a secure timestamp"
  }
fi

CONTROLLER_PERMISSION_OUTPUT="$(
  python3 "$CONTROLLER_PERMISSIONS_VERIFIER" bundle \
    "$ENTITLEMENTS_PLIST" \
    "$INFO_PLIST" \
    "$RESOURCES_DIR" 2>&1
)" || {
  printf '%s\n' "$CONTROLLER_PERMISSION_OUTPUT" >&2
  fail "app controller permission metadata is incomplete"
}

if [[ "$REQUIRE_SUBMISSION_SIGNATURE" == "1" ]]; then
  if [[ "$(plist_value "$ENTITLEMENTS_PLIST" 'com.apple.security.get-task-allow')" == "true" ]]; then
    fail "App Store submission signature must not contain com.apple.security.get-task-allow"
  fi
  if printf '%s\n' "$SIGNING_DETAILS" | grep -Fq 'Authority=Apple Development'; then
    printf '%s\n' "$SIGNING_DETAILS" >&2
    fail "App Store submission signature must not be an Apple Development signature"
  fi
  printf '%s\n' "$SIGNING_DETAILS" | grep -Eq 'Authority=(Apple Distribution|3rd Party Mac Developer Application)' || {
    printf '%s\n' "$SIGNING_DETAILS" >&2
    fail "App Store submission signature must use an Apple distribution authority"
  }
fi

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

if [[ "$DIRECT_DMG_RUNTIME" == "1" ]]; then
  bash "$LEGAL_DOCUMENT_VERIFIER" "$APP_PATH" >/dev/null
  FORGEPLAY_REQUIRE_DIRECT_DMG_RUNTIME=1 \
    bash "$SCRIPT_DIR/verify-bundled-runtime-capability.sh" "$APP_PATH" >/dev/null
else
  FORGEPLAY_REQUIRE_APP_STORE_RUNTIME=1 \
    bash "$SCRIPT_DIR/verify-bundled-runtime-capability.sh" "$APP_PATH" >/dev/null
fi

RUNTIME_ROOT="$APP_PATH/Contents/Resources/Runners/ForgePlayRuntime"
D3DMETAL_EXTERNAL_ROOT="$RUNTIME_ROOT/Frameworks/renderer/d3dmetal/external"
D3DMETAL_FRAMEWORK="$D3DMETAL_EXTERNAL_ROOT/D3DMetal.framework"
D3DMETAL_SHARED_LIBRARY="$D3DMETAL_EXTERNAL_ROOT/libd3dshared.dylib"
while IFS= read -r -d '' runtime_code; do
  file -b "$runtime_code" 2>/dev/null | grep -q '^Mach-O' || continue
  codesign --verify --strict "$runtime_code" >/dev/null 2>&1 ||
    fail "bundled runtime Mach-O is not signed correctly: $runtime_code"
  RUNTIME_SIGNING_DETAILS="$(codesign -dv --verbose=4 "$runtime_code" 2>&1 || true)"
  if is_preserved_apple_d3dmetal_code "$runtime_code"; then
    verify_preserved_apple_d3dmetal_signature "$runtime_code" "$RUNTIME_SIGNING_DETAILS"
    continue
  fi
  RUNTIME_TEAM_IDENTIFIER="$(signing_detail_value "$RUNTIME_SIGNING_DETAILS" TeamIdentifier)"
  if [[ "$RUNTIME_TEAM_IDENTIFIER" != "$MAIN_TEAM_IDENTIFIER" ]]; then
    printf '%s\n' "$RUNTIME_SIGNING_DETAILS" >&2
    fail "bundled runtime Mach-O must be signed by app team $MAIN_TEAM_IDENTIFIER: $runtime_code"
  fi
  if [[ "$REQUIRE_SUBMISSION_SIGNATURE" == "1" ]]; then
    if printf '%s\n' "$RUNTIME_SIGNING_DETAILS" | grep -Fq 'Authority=Apple Development'; then
      printf '%s\n' "$RUNTIME_SIGNING_DETAILS" >&2
      fail "App Store runtime Mach-O must not use an Apple Development signature: $runtime_code"
    fi
    printf '%s\n' "$RUNTIME_SIGNING_DETAILS" |
      grep -Eq 'Authority=(Apple Distribution|3rd Party Mac Developer Application)' || {
        printf '%s\n' "$RUNTIME_SIGNING_DETAILS" >&2
        fail "App Store runtime Mach-O must use the app distribution authority: $runtime_code"
      }
  fi
  if [[ "$REQUIRE_DEVELOPER_ID_SIGNATURE" == "1" ]]; then
    printf '%s\n' "$RUNTIME_SIGNING_DETAILS" | grep -Fq 'Authority=Developer ID Application' || {
      printf '%s\n' "$RUNTIME_SIGNING_DETAILS" >&2
      fail "direct DMG runtime Mach-O must use Developer ID Application: $runtime_code"
    }
    printf '%s\n' "$RUNTIME_SIGNING_DETAILS" | grep -Fq 'Timestamp=' || {
      printf '%s\n' "$RUNTIME_SIGNING_DETAILS" >&2
      fail "direct DMG runtime Mach-O must include a secure timestamp: $runtime_code"
    }
  fi
  if file -b "$runtime_code" 2>/dev/null | grep -q '^Mach-O.*executable'; then
    printf '%s\n' "$RUNTIME_SIGNING_DETAILS" | grep -Eq 'flags=.*\bruntime\b' ||
      fail "bundled Wine runtime executables must enable Hardened Runtime: $runtime_code"
    RUNTIME_ENTITLEMENTS_PLIST="$(mktemp "$DEFAULT_TEMP_ROOT/forgeplay-runtime-inherit-entitlements.XXXXXX")"
    codesign -d --entitlements :- "$runtime_code" > "$RUNTIME_ENTITLEMENTS_PLIST" 2>/dev/null ||
      fail "bundled runtime executable entitlements could not be read: $runtime_code"
    [[ "$(plist_value "$RUNTIME_ENTITLEMENTS_PLIST" 'com.apple.security.app-sandbox')" == "true" ]] ||
      fail "bundled runtime executable must enable App Sandbox inheritance: $runtime_code"
    [[ "$(plist_value "$RUNTIME_ENTITLEMENTS_PLIST" 'com.apple.security.inherit')" == "true" ]] ||
      fail "bundled runtime executable must inherit the parent sandbox: $runtime_code"
    [[ "$(plist_value "$RUNTIME_ENTITLEMENTS_PLIST" 'com.apple.security.cs.allow-unsigned-executable-memory')" == "true" ]] ||
      fail "bundled runtime executable must allow mapped Windows PE executable memory: $runtime_code"
    [[ "$(plist_value "$RUNTIME_ENTITLEMENTS_PLIST" 'com.apple.security.cs.disable-library-validation')" == "true" ]] ||
      fail "bundled runtime executable must allow pathless Wine executable mappings: $runtime_code"
    RUNTIME_ENTITLEMENT_COUNT="$(plutil -convert xml1 -o - "$RUNTIME_ENTITLEMENTS_PLIST" | grep -c '<key>')"
    [[ -z "$(plist_value "$RUNTIME_ENTITLEMENTS_PLIST" 'com.apple.security.cs.allow-jit')" ]] ||
      fail "bundled runtime executable must not enable allow-jit: $runtime_code"
    [[ "$RUNTIME_ENTITLEMENT_COUNT" == "4" ]] ||
      fail "bundled runtime executable may contain only app-sandbox, inherit, executable-memory, and library-validation entitlements: $runtime_code"
    rm -f "$RUNTIME_ENTITLEMENTS_PLIST"
    RUNTIME_ENTITLEMENTS_PLIST=""
  fi
done < <(find "$RUNTIME_ROOT" -type f -print0)

DEBUG_MARKERS="$(LC_ALL=C strings -a "$EXECUTABLE" | grep -E 'FORGEPLAY_QA_|debugLayoutFixture|Debug startup failure fixture' || true)"
if [[ -n "$DEBUG_MARKERS" ]]; then
  printf '%s\n' "$DEBUG_MARKERS" >&2
  fail "app executable contains DEBUG QA launch hooks"
fi

if [[ "$DIRECT_DMG_RUNTIME" == "1" ]]; then
  printf 'Direct DMG sandboxed app security verification passed: %s\n' "$APP_PATH"
else
  printf 'App Store app security verification passed: %s\n' "$APP_PATH"
fi
