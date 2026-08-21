#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Facta-Leopard
# SPDX-License-Identifier: GPL-3.0-only
#
# ForgePlay Game Mode
# Original source: https://github.com/Facta-Leopard/ForgePlay

set -euo pipefail
export LC_ALL=C

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
manifest="$root_dir/Resources/Runners/ForgePlayRuntime/RuntimeManifest.json"
source_availability="$root_dir/Resources/Runners/ForgePlayRuntime/SOURCE-AVAILABILITY.md"
identity_output="${SCRIPT_OUTPUT_FILE_0:-${DERIVED_FILE_DIR:-}/GameModeBuildIdentity.generated.h}"
embedded_plist_output="${SCRIPT_OUTPUT_FILE_1:-${DERIVED_FILE_DIR:-}/GameModeHostEmbeddedInfo.plist}"

fail() {
  printf 'error: Game Mode host identity: %s\n' "$*" >&2
  exit 1
}

[[ -n "$identity_output" ]] || fail "derived header output is unavailable"
[[ -n "$embedded_plist_output" ]] || fail "embedded plist output is unavailable"
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "RuntimeManifest.json is unavailable"
[[ -f "$source_availability" && ! -L "$source_availability" ]] || \
  fail "Runtime source-availability record is unavailable"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/forgeplay-game-mode-identity.XXXXXX")"
cleanup() {
  if [[ -n "${work_dir:-}" && -d "$work_dir" ]]; then
    /bin/rm -rf "$work_dir"
  fi
}
trap cleanup EXIT INT TERM

manifest_plist="$work_dir/RuntimeManifest.plist"
/usr/bin/plutil -convert xml1 -o "$manifest_plist" "$manifest" || \
  fail "Runtime manifest could not be normalized"

manifest_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$manifest_plist" 2>/dev/null || return 1
}

require_sha256() {
  [[ "$2" =~ ^[0-9a-f]{64}$ ]] || fail "$1 is not a lowercase SHA-256"
}

schema_version="$(manifest_value schemaVersion)" || fail "schemaVersion is missing"
runtime_identifier="$(manifest_value runtimeIdentifier)" || fail "runtimeIdentifier is missing"
wine_version="$(manifest_value wineVersion)" || fail "wineVersion is missing"
architecture="$(manifest_value architecture)" || fail "architecture is missing"
source_tree_sha256="$(manifest_value sourceTreeSHA256)" || fail "sourceTreeSHA256 is missing"
patch_set_sha256="$(manifest_value patchSetSHA256)" || fail "patchSetSHA256 is missing"
runtime_build_fingerprint="$(manifest_value runnerBuildFingerprint)" || \
  fail "runnerBuildFingerprint is missing"
runtime_core_fingerprint="$(manifest_value corePayloadFingerprint || true)"
runtime_core_hash_algorithm="$(manifest_value corePayloadHashAlgorithm || true)"
manifest_sha256="$(/usr/bin/shasum -a 256 "$manifest" | /usr/bin/awk '{print $1}')"
requires_production_identity="${FORGEPLAY_REQUIRE_GAME_MODE_PRODUCTION_IDENTITY:-NO}"
coordination_profile="${FORGEPLAY_GAME_MODE_COORDINATION_PROFILE:-}"
code_signing_allowed="${CODE_SIGNING_ALLOWED:-YES}"
compile_only_direct_identity="NO"

case "$requires_production_identity" in
  YES|NO) ;;
  *) fail "FORGEPLAY_REQUIRE_GAME_MODE_PRODUCTION_IDENTITY must be YES or NO" ;;
esac
case "$coordination_profile" in
  sandbox-app-group|direct-user-domain) ;;
  *) fail "FORGEPLAY_GAME_MODE_COORDINATION_PROFILE must be sandbox-app-group or direct-user-domain" ;;
esac
case "$code_signing_allowed" in
  YES|NO) ;;
  *) fail "CODE_SIGNING_ALLOWED must be YES or NO" ;;
esac
if [[ "$coordination_profile" == "direct-user-domain" &&
      "$code_signing_allowed" == "NO" ]]; then
  compile_only_direct_identity="YES"
fi

[[ "$schema_version" =~ ^[0-9]+$ ]] || fail "schemaVersion is invalid"
[[ "$runtime_identifier" == "com.forgeplay.runtime.wine-11.12" ]] || \
  fail "Runtime identifier is outside the fixed host contract"
[[ "$wine_version" == "11.12" && "$architecture" == "win64" ]] || \
  fail "the fixed host requires the bundled Wine 11.12 win64 Runtime"
require_sha256 sourceTreeSHA256 "$source_tree_sha256"
require_sha256 patchSetSHA256 "$patch_set_sha256"
require_sha256 runnerBuildFingerprint "$runtime_build_fingerprint"
require_sha256 manifestSHA256 "$manifest_sha256"

if [[ "$schema_version" == "3" ]]; then
  require_sha256 corePayloadFingerprint "$runtime_core_fingerprint"
  [[ "$runtime_core_hash_algorithm" == "sha256-macho-signature-independent-v1" ]] || \
    fail "corePayloadHashAlgorithm is outside the signed Runtime contract"
elif [[ "$requires_production_identity" == "YES" &&
        "$compile_only_direct_identity" != "YES" ]]; then
  fail "distribution builds require a clean schema-3 Runtime rebuild"
else
  runtime_core_fingerprint="unavailable"
fi

if [[ "$requires_production_identity" == "YES" &&
      "$compile_only_direct_identity" != "YES" ]]; then
  if /usr/bin/grep -Fq "newer than the checked-in runtime binaries" "$source_availability"; then
    fail "Runtime sources and checked-in binaries are out of sync"
  fi
fi

bundle_identifier="${PRODUCT_BUNDLE_IDENTIFIER:-}"
[[ "$bundle_identifier" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{2,254}$ ]] || \
  fail "host bundle identifier is invalid"
executable_name="${EXECUTABLE_NAME:-}"
marketing_version="${MARKETING_VERSION:-}"
build_version="${CURRENT_PROJECT_VERSION:-}"
deployment_target="${MACOSX_DEPLOYMENT_TARGET:-}"
[[ "$executable_name" == "GameModeProcessHost" ]] || fail "host executable name is invalid"
[[ "$marketing_version" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || \
  fail "host marketing version is invalid"
[[ "$build_version" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || \
  fail "host build version is invalid"
[[ "$deployment_target" =~ ^[0-9]+[.][0-9]+$ ]] || \
  fail "host deployment target is invalid"

if [[ "$compile_only_direct_identity" == "YES" ]]; then
  # Compile-only Release checks deliberately receive no usable App Group.
  # The generated runnable bit below makes the resulting host fail before it
  # can resolve any coordination state even if this sentinel path exists.
  application_group="compile-only.invalid"
elif [[ "$requires_production_identity" == "YES" ]]; then
  application_group="${FORGEPLAY_GAME_MODE_APPLICATION_GROUP:-}"
  [[ -n "$application_group" ]] ||
    fail "FORGEPLAY_GAME_MODE_APPLICATION_GROUP is unavailable"
else
  application_group="${FORGEPLAY_GAME_MODE_APPLICATION_GROUP:-development-unavailable}"
fi
if [[ "$coordination_profile" == "direct-user-domain" &&
      "$requires_production_identity" != "YES" &&
      "$compile_only_direct_identity" != "YES" ]]; then
  fail "direct-user-domain requires a production Game Mode identity"
fi
[[ "$application_group" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{2,254}$ ]] || \
  fail "host application-group identity is invalid"

mkdir -p "$(dirname "$identity_output")" "$(dirname "$embedded_plist_output")"
temporary_output="$work_dir/GameModeBuildIdentity.generated.h"
production_identity=0
host_runnable=1
if [[ "$requires_production_identity" == "YES" &&
      "$compile_only_direct_identity" != "YES" ]]; then
  production_identity=1
fi
if [[ "$compile_only_direct_identity" == "YES" ]]; then
  host_runnable=0
fi
{
  printf '%s\n' '/* Generated from the exact bundled Runtime. Do not edit. */'
  printf '#define FORGEPLAY_GAME_MODE_HOST_BUNDLE_IDENTIFIER "%s"\n' "$bundle_identifier"
  printf '#define FORGEPLAY_GAME_MODE_COORDINATION_PROFILE "%s"\n' "$coordination_profile"
  printf '#define FORGEPLAY_GAME_MODE_PRODUCTION_IDENTITY %s\n' "$production_identity"
  printf '#define FORGEPLAY_GAME_MODE_HOST_RUNNABLE %s\n' "$host_runnable"
  if [[ "$coordination_profile" == "sandbox-app-group" ]]; then
    printf '%s\n' '#define FORGEPLAY_GAME_MODE_COORDINATION_SANDBOX_APP_GROUP 1'
    printf '%s\n' '#define FORGEPLAY_GAME_MODE_COORDINATION_DIRECT_USER_DOMAIN 0'
  else
    printf '%s\n' '#define FORGEPLAY_GAME_MODE_COORDINATION_SANDBOX_APP_GROUP 0'
    printf '%s\n' '#define FORGEPLAY_GAME_MODE_COORDINATION_DIRECT_USER_DOMAIN 1'
  fi
  printf '#define FORGEPLAY_GAME_MODE_APPLICATION_GROUP "%s"\n' "$application_group"
  printf '#define FORGEPLAY_GAME_MODE_RUNTIME_IDENTIFIER "%s"\n' "$runtime_identifier"
  printf '#define FORGEPLAY_GAME_MODE_RUNTIME_MANIFEST_SHA256 "%s"\n' "$manifest_sha256"
  printf '#define FORGEPLAY_GAME_MODE_RUNTIME_BUILD_FINGERPRINT "%s"\n' "$runtime_build_fingerprint"
  printf '#define FORGEPLAY_GAME_MODE_RUNTIME_CORE_FINGERPRINT "%s"\n' "$runtime_core_fingerprint"
  printf '#define FORGEPLAY_GAME_MODE_WINE_SOURCE_TREE_SHA256 "%s"\n' "$source_tree_sha256"
  printf '#define FORGEPLAY_GAME_MODE_WINE_PATCH_SET_SHA256 "%s"\n' "$patch_set_sha256"
  printf '%s\n' '#define FORGEPLAY_GAME_MODE_WINE_LOADER_SOURCE_SHA256 "ab7df8fbca3308fba27b7f3e081526ca772ec81b39733d1b16f4374ef720e857"'
} > "$temporary_output"
/bin/mv -f "$temporary_output" "$identity_output"

temporary_plist="$work_dir/GameModeHostEmbeddedInfo.plist"
/bin/cp "$root_dir/Native/GameModeProcessHost/Info.plist" "$temporary_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $executable_name" "$temporary_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$temporary_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing_version" "$temporary_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_version" "$temporary_plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $deployment_target" "$temporary_plist"
/usr/bin/plutil -lint "$temporary_plist" >/dev/null || fail "embedded host plist is invalid"
/bin/mv -f "$temporary_plist" "$embedded_plist_output"
