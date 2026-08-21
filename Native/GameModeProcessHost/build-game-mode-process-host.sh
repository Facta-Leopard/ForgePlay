#!/bin/bash
# SPDX-FileCopyrightText: 2026 Facta-Leopard
# SPDX-License-Identifier: GPL-3.0-only
#
# ForgePlay Game Mode
# Original source: https://github.com/Facta-Leopard/ForgePlay

set -euo pipefail
export LC_ALL=C

script_directory="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_directory/../.." && pwd -P)"
runtime_core_identity_tool="$repository_root/Scripts/runtime-core-payload-identity.py"
expected_loader_source_sha256="ab7df8fbca3308fba27b7f3e081526ca772ec81b39733d1b16f4374ef720e857"

fail() {
    echo "GameModeProcessHost build contract failed: $*" >&2
    exit 1
}

usage() {
    echo "Usage: $0 --runtime-root PATH --wine-source-root PATH --output-app PATH --bundle-identifier ID --application-group ID --icon-file PATH --signing-identity ID --provisioning-profile PATH --marketing-version VERSION --build-version VERSION" >&2
    exit 64
}

runtime_root=""
wine_source_root=""
output_app=""
bundle_identifier=""
application_group=""
icon_file=""
signing_identity=""
provisioning_profile=""
marketing_version=""
build_version=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runtime-root) [[ $# -ge 2 ]] || usage; runtime_root="$2"; shift 2 ;;
        --wine-source-root) [[ $# -ge 2 ]] || usage; wine_source_root="$2"; shift 2 ;;
        --output-app) [[ $# -ge 2 ]] || usage; output_app="$2"; shift 2 ;;
        --bundle-identifier) [[ $# -ge 2 ]] || usage; bundle_identifier="$2"; shift 2 ;;
        --application-group) [[ $# -ge 2 ]] || usage; application_group="$2"; shift 2 ;;
        --icon-file) [[ $# -ge 2 ]] || usage; icon_file="$2"; shift 2 ;;
        --signing-identity) [[ $# -ge 2 ]] || usage; signing_identity="$2"; shift 2 ;;
        --provisioning-profile) [[ $# -ge 2 ]] || usage; provisioning_profile="$2"; shift 2 ;;
        --marketing-version) [[ $# -ge 2 ]] || usage; marketing_version="$2"; shift 2 ;;
        --build-version) [[ $# -ge 2 ]] || usage; build_version="$2"; shift 2 ;;
        *) usage ;;
    esac
done

for required_value in \
    "$runtime_root" \
    "$wine_source_root" \
    "$output_app" \
    "$bundle_identifier" \
    "$application_group" \
    "$icon_file" \
    "$signing_identity" \
    "$provisioning_profile" \
    "$marketing_version" \
    "$build_version"; do
    [[ -n "$required_value" ]] || usage
done

[[ "$(basename "$output_app")" == "GameModeProcessHost.app" ]] || \
    fail "output bundle name must be GameModeProcessHost.app"
[[ ! -e "$output_app" ]] || fail "output already exists; refusing to overwrite it"
output_parent="$(dirname "$output_app")"
[[ -d "$output_parent" && ! -L "$output_parent" ]] || \
    fail "output parent must already be a safe directory"
output_parent="$(cd "$output_parent" && pwd -P)"
output_app="$output_parent/GameModeProcessHost.app"
[[ "$bundle_identifier" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{2,254}$ ]] || \
    fail "bundle identifier is outside the fixed identifier grammar"
[[ "$application_group" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{2,254}$ ]] || \
    fail "application group is outside the signed identifier grammar"
normalized_bundle_identifier="$(printf '%s' "$bundle_identifier" | /usr/bin/tr '[:upper:]' '[:lower:]')"
normalized_application_group="$(printf '%s' "$application_group" | /usr/bin/tr '[:upper:]' '[:lower:]')"
[[ "$normalized_bundle_identifier" == com.forgeplay.* ]] || \
    fail "host bundle identifier must be ForgePlay-owned"
[[ "$normalized_application_group" == *com.forgeplay.* ]] || \
    fail "host application group must be ForgePlay-owned"
[[ "$marketing_version" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || \
    fail "marketing version is invalid"
[[ "$build_version" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || \
    fail "build version is invalid"
[[ "$signing_identity" != "-" ]] || \
    fail "ad-hoc signing cannot satisfy the app-group host contract"

for command_path in \
    /usr/bin/codesign \
    /usr/bin/awk \
    /usr/bin/find \
    /usr/bin/grep \
    /usr/bin/install \
    /usr/bin/lipo \
    /usr/bin/nm \
    /usr/bin/otool \
    /usr/bin/plutil \
    /usr/bin/python3 \
    /usr/bin/security \
    /usr/bin/sed \
    /usr/bin/shasum \
    /usr/bin/stat \
    /usr/bin/tr \
    /usr/bin/xcrun \
    /usr/libexec/PlistBuddy; do
    [[ -x "$command_path" ]] || fail "required build tool is unavailable: $command_path"
done

[[ -d "$runtime_root" && ! -L "$runtime_root" ]] || fail "runtime root is unsafe"
[[ -d "$wine_source_root" && ! -L "$wine_source_root" ]] || fail "Wine source root is unsafe"
runtime_root="$(cd "$runtime_root" && pwd -P)"
wine_source_root="$(cd "$wine_source_root" && pwd -P)"

[[ -f "$icon_file" && ! -L "$icon_file" && "${icon_file##*.}" == "icns" ]] || \
    fail "a regular ForgePlay .icns resource is required"
[[ -f "$provisioning_profile" && ! -L "$provisioning_profile" ]] || \
    fail "a regular host provisioning profile is required"

manifest="$runtime_root/RuntimeManifest.json"
source_availability="$runtime_root/SOURCE-AVAILABILITY.md"
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "RuntimeManifest.json is unavailable"
[[ -f "$source_availability" && ! -L "$source_availability" ]] || \
    fail "Runtime source-availability record is unavailable"
[[ -f "$runtime_core_identity_tool" && ! -L "$runtime_core_identity_tool" ]] || \
    fail "Runtime core payload identity tool is unavailable"

work_directory="$(/usr/bin/mktemp -d "$output_parent/.forgeplay-game-mode-host.XXXXXX")"
cleanup() {
    if [[ -n "${work_directory:-}" && -d "$work_directory" ]]; then
        /bin/rm -rf "$work_directory"
    fi
}
trap cleanup EXIT INT TERM

manifest_plist="$work_directory/RuntimeManifest.plist"
/usr/bin/plutil -convert xml1 -o "$manifest_plist" "$manifest" || \
    fail "Runtime manifest could not be normalized"

manifest_value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$manifest_plist" 2>/dev/null || \
        fail "Runtime manifest field is missing: $1"
}

is_sha256() {
    [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

source_tree_fingerprint() {
    local source_root="$1"
    local aggregate="$work_directory/source-tree-identity.bin"
    local source_file_list="$work_directory/source-tree-files.bin"
    local symlink_list="$work_directory/source-tree-symlinks.txt"
    local source_file relative_path file_sha256

    /usr/bin/find -s "$source_root" \
        \( -name .git -o -path '*/.git/*' -o -name .DS_Store -o -name configure \
           -o -name '*.orig' -o -name '*.rej' \) -prune -o \
        -type l -print -quit > "$symlink_list" || \
        fail "Wine source tree could not be inspected for symlinks"
    if [[ -s "$symlink_list" ]]; then
        fail "Wine source tree contains a symlink outside excluded metadata"
    fi

    /usr/bin/find -s "$source_root" \
        \( -name .git -o -path '*/.git/*' -o -name .DS_Store -o -name configure \
           -o -name '*.orig' -o -name '*.rej' \) -prune -o \
        -type f -print0 > "$source_file_list" || \
        fail "Wine source tree file enumeration failed"
    : > "$aggregate"
    while IFS= read -r -d '' source_file; do
        relative_path="${source_file#"$source_root"/}"
        file_sha256="$(/usr/bin/shasum -a 256 "$source_file" | /usr/bin/awk '{print $1}')" || \
            fail "Wine source file could not be hashed: $relative_path"
        printf '%s\0%s\n' "$relative_path" "$file_sha256" >> "$aggregate"
    done < "$source_file_list"
    [[ -s "$aggregate" ]] || fail "Wine source tree has no fingerprintable files"
    /usr/bin/shasum -a 256 "$aggregate" | /usr/bin/awk '{print $1}'
}

schema_version="$(manifest_value schemaVersion)"
runtime_identifier="$(manifest_value runtimeIdentifier)"
wine_version="$(manifest_value wineVersion)"
architecture="$(manifest_value architecture)"
source_tree_sha256="$(manifest_value sourceTreeSHA256)"
patch_set_sha256="$(manifest_value patchSetSHA256)"
runtime_build_fingerprint="$(manifest_value runnerBuildFingerprint)"
runtime_core_fingerprint="$(manifest_value corePayloadFingerprint)"
runtime_core_hash_algorithm="$(manifest_value corePayloadHashAlgorithm)"

[[ "$schema_version" == "3" ]] || fail "schema-3 Runtime is required"
[[ "$wine_version" == "11.12" ]] || fail "exact Wine 11.12 Runtime is required"
[[ "$architecture" == "win64" ]] || fail "exact win64 Runtime identity is required"
[[ "$runtime_identifier" == "com.forgeplay.runtime.wine-11.12" ]] || \
    fail "unexpected Runtime identifier"
is_sha256 "$source_tree_sha256" || fail "source-tree fingerprint is invalid"
is_sha256 "$patch_set_sha256" || fail "patch-set fingerprint is invalid"
is_sha256 "$runtime_build_fingerprint" || fail "build fingerprint is invalid"
is_sha256 "$runtime_core_fingerprint" || fail "core fingerprint is invalid"
[[ "$runtime_core_hash_algorithm" == "sha256-macho-signature-independent-v1" ]] || \
    fail "core payload hash algorithm is invalid"

if /usr/bin/grep -Fq "newer than the checked-in runtime binaries" "$source_availability"; then
    fail "Runtime source and packaged binaries are explicitly out of sync"
fi
/usr/bin/grep -Fq "Wine 11.12" "$source_availability" || \
    fail "Runtime source-availability version is invalid"
/usr/bin/grep -Fq "$source_tree_sha256" "$source_availability" || \
    fail "Runtime source-tree fingerprint is not in the availability record"
/usr/bin/grep -Fq "$patch_set_sha256" "$source_availability" || \
    fail "Runtime patch-set fingerprint is not in the availability record"

[[ "$(tr -d '\r\n' < "$wine_source_root/VERSION")" == "Wine version 11.12" ]] || \
    fail "Wine source VERSION does not identify 11.12"
for source_file in LICENSE COPYING.LIB AUTHORS loader/main.c; do
    [[ -f "$wine_source_root/$source_file" && ! -L "$wine_source_root/$source_file" ]] || \
        fail "corresponding Wine source file is unavailable: $source_file"
done
loader_source_sha256="$(/usr/bin/shasum -a 256 "$wine_source_root/loader/main.c" | /usr/bin/awk '{print $1}')"
[[ "$loader_source_sha256" == "$expected_loader_source_sha256" ]] || \
    fail "Wine loader source differs from the reviewed 11.12 input"
computed_source_tree_sha256="$(source_tree_fingerprint "$wine_source_root")"
[[ "$computed_source_tree_sha256" == "$source_tree_sha256" ]] || \
    fail "Wine source tree does not match the Runtime manifest"

/usr/bin/python3 "$runtime_core_identity_tool" verify "$runtime_root" "$manifest" || \
    fail "Runtime core payload identity does not match the packaged executable payload"

[[ "$(/usr/bin/lipo -archs "$runtime_root/wine/bin/wine.bin")" == "x86_64" ]] || \
    fail "Wine loader is not a thin x86_64 Mach-O"
[[ "$(/usr/bin/lipo -archs "$runtime_root/wine/lib/wine/x86_64-unix/ntdll.so")" == "x86_64" ]] || \
    fail "Wine ntdll is not a thin x86_64 Mach-O"
/usr/bin/nm -gU "$runtime_root/wine/lib/wine/x86_64-unix/ntdll.so" \
    > "$work_directory/ntdll-symbols.txt"
/usr/bin/grep -Eq '[[:space:]]___wine_main$' "$work_directory/ntdll-symbols.txt" || \
    fail "exact Wine ntdll does not export __wine_main"

manifest_sha256="$(/usr/bin/shasum -a 256 "$manifest" | /usr/bin/awk '{print $1}')"
is_sha256 "$manifest_sha256" || fail "Runtime manifest fingerprint failed"

rendered_info="$work_directory/Info.plist"
rendered_entitlements="$work_directory/GameModeProcessHost.entitlements"
/usr/bin/sed \
    -e "s|__FORGEPLAY_HOST_BUNDLE_IDENTIFIER__|$bundle_identifier|g" \
    -e "s|__FORGEPLAY_MARKETING_VERSION__|$marketing_version|g" \
    -e "s|__FORGEPLAY_BUILD_VERSION__|$build_version|g" \
    "$script_directory/Info.plist.in" > "$rendered_info"
/usr/bin/sed \
    -e "s|__FORGEPLAY_APPLICATION_GROUP__|$application_group|g" \
    "$script_directory/GameModeProcessHost.entitlements.in" > "$rendered_entitlements"
/usr/bin/plutil -lint "$rendered_info" >/dev/null
/usr/bin/plutil -lint "$rendered_entitlements" >/dev/null

decoded_profile="$work_directory/provisioning-profile.plist"
/usr/bin/security cms -D -i "$provisioning_profile" > "$decoded_profile" || \
    fail "host provisioning profile could not be decoded"
profile_application_identifier="$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:application-identifier' "$decoded_profile" 2>/dev/null)" || \
    fail "profile application identifier is unavailable"
profile_team_identifier="$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.developer.team-identifier' \
    "$decoded_profile" 2>/dev/null)" || \
    fail "profile team identifier is unavailable"
[[ "$profile_team_identifier" =~ ^[A-Z0-9]{10}$ ]] || \
    fail "profile team identifier is invalid"
[[ "$profile_application_identifier" == "$profile_team_identifier.$bundle_identifier" ]] || \
    fail "profile application identifier does not match the host bundle"
profile_group="$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.security.application-groups:0' \
    "$decoded_profile" 2>/dev/null)" || fail "profile app group is unavailable"
[[ "$profile_group" == "$application_group" ]] || \
    fail "profile app group does not match the host contract"
[[ "$profile_group" == "$profile_team_identifier."* ]] || \
    fail "profile app group is outside the signing team namespace"
if /usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.security.application-groups:1' \
    "$decoded_profile" >/dev/null 2>&1; then
    fail "profile grants more than the one approved app group"
fi

staged_app="$work_directory/GameModeProcessHost.app"
macos_directory="$staged_app/Contents/MacOS"
resources_directory="$staged_app/Contents/Resources"
/usr/bin/install -d -m 0755 "$macos_directory" "$resources_directory/Legal/Wine"
/usr/bin/install -m 0644 "$rendered_info" "$staged_app/Contents/Info.plist"
/usr/bin/install -m 0644 "$icon_file" "$resources_directory/AppIcon.icns"
/usr/bin/install -m 0644 "$wine_source_root/COPYING.LIB" \
    "$resources_directory/Legal/Wine/COPYING.LIB"
/usr/bin/install -m 0644 "$script_directory/SOURCE-CONTRACT.md" \
    "$resources_directory/Legal/Wine/GameModeProcessHost-SOURCE-CONTRACT.md"
/usr/bin/install -m 0644 "$provisioning_profile" \
    "$staged_app/Contents/embedded.provisionprofile"

sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
compiler="$(/usr/bin/xcrun --sdk macosx --find clang)"
host_binary="$macos_directory/GameModeProcessHost"

compile_arguments=(
    -arch x86_64
    -isysroot "$sdk_path"
    -mmacosx-version-min=26.0
    -fobjc-arc
    -fvisibility=hidden
    -Wall
    -Wextra
    -Wpedantic
    -Werror
    -Wno-deprecated-declarations
    -I "$script_directory"
    "-DFORGEPLAY_GAME_MODE_HOST_BUNDLE_IDENTIFIER=\"$bundle_identifier\""
    '-DFORGEPLAY_GAME_MODE_COORDINATION_PROFILE="sandbox-app-group"'
    -DFORGEPLAY_GAME_MODE_PRODUCTION_IDENTITY=1
    -DFORGEPLAY_GAME_MODE_HOST_RUNNABLE=1
    -DFORGEPLAY_GAME_MODE_COORDINATION_SANDBOX_APP_GROUP=1
    -DFORGEPLAY_GAME_MODE_COORDINATION_DIRECT_USER_DOMAIN=0
    "-DFORGEPLAY_GAME_MODE_APPLICATION_GROUP=\"$application_group\""
    "-DFORGEPLAY_GAME_MODE_RUNTIME_IDENTIFIER=\"$runtime_identifier\""
    "-DFORGEPLAY_GAME_MODE_RUNTIME_MANIFEST_SHA256=\"$manifest_sha256\""
    "-DFORGEPLAY_GAME_MODE_RUNTIME_BUILD_FINGERPRINT=\"$runtime_build_fingerprint\""
    "-DFORGEPLAY_GAME_MODE_RUNTIME_CORE_FINGERPRINT=\"$runtime_core_fingerprint\""
    "-DFORGEPLAY_GAME_MODE_WINE_SOURCE_TREE_SHA256=\"$source_tree_sha256\""
    "-DFORGEPLAY_GAME_MODE_WINE_PATCH_SET_SHA256=\"$patch_set_sha256\""
    "-DFORGEPLAY_GAME_MODE_WINE_LOADER_SOURCE_SHA256=\"$loader_source_sha256\""
    "$script_directory/GameModeProcessHost.m"
    "$script_directory/GameModeRuntimeIdentity.m"
    "$script_directory/GameModeApplicationGroup.m"
    "$script_directory/GameModeInheritedExecution.m"
    "$script_directory/PrefixExecutionLease.m"
    -framework Foundation
    -framework Security
    -Wl,-no_pie
    -Wl,-image_base,0x200000000
    -Wl,-no_huge
    -Wl,-no_fixup_chains
    -Wl,-segalign,0x1000
    -Wl,-pagezero_size,0x1000
    -Wl,-segaddr,WINE_RESERVE,0x1000
    -Wl,-segaddr,WINE_TOP_DOWN,0x7ff000000000
    -Wl,-headerpad_max_install_names
    "-Wl,-sectcreate,__TEXT,__info_plist,$rendered_info"
    -Wl,-exported_symbol,_wine_main_preload_info
    "-Wl,-rpath,@executable_path/../../../../Resources/Runners/ForgePlayRuntime/wine/lib"
    -o "$host_binary"
)
"$compiler" "${compile_arguments[@]}"
/usr/bin/chmod 0755 "$host_binary"

[[ "$(/usr/bin/lipo -archs "$host_binary")" == "x86_64" ]] || \
    fail "host output is not a thin x86_64 Mach-O"
/usr/bin/otool -hv "$host_binary" > "$work_directory/mach-header.txt"
[[ "$(awk 'END { print $5 }' "$work_directory/mach-header.txt")" == "EXECUTE" ]] || \
    fail "host output is not an executable Mach-O"
if awk 'END { for (field_index = 8; field_index <= NF; field_index++) if ($field_index == "PIE") exit 0; exit 1 }' \
    "$work_directory/mach-header.txt"; then
    fail "host output must not carry the MH_PIE flag"
fi
/usr/bin/nm -gU "$host_binary" > "$work_directory/host-symbols.txt"
/usr/bin/grep -Eq '[[:space:]]_wine_main_preload_info$' \
    "$work_directory/host-symbols.txt" || \
    fail "host does not export wine_main_preload_info"

/usr/bin/otool -l "$host_binary" > "$work_directory/load-commands.txt"
segment_value() {
    local target_segment="$1"
    local target_field="$2"
    awk -v target_segment="$target_segment" -v target_field="$target_field" '
        $1 == "segname" { segment = $2 }
        segment == target_segment && $1 == target_field { print $2; exit }
    ' "$work_directory/load-commands.txt"
}
[[ "$(segment_value __PAGEZERO vmsize)" == "0x0000000000001000" ]] || \
    fail "host page-zero contract is invalid"
[[ "$(segment_value __TEXT vmaddr)" == "0x0000000200000000" ]] || \
    fail "host image base contract is invalid"
[[ "$(segment_value WINE_RESERVE vmaddr)" == "0x0000000000001000" ]] || \
    fail "host low reservation address is invalid"
[[ "$(segment_value WINE_RESERVE vmsize)" == "0x00000001fffff000" ]] || \
    fail "host low reservation size is invalid"
[[ "$(segment_value WINE_TOP_DOWN vmaddr)" == "0x00007ff000000000" ]] || \
    fail "host top-down reservation address is invalid"
[[ "$(segment_value WINE_TOP_DOWN vmsize)" == "0x0000000001ff0000" ]] || \
    fail "host top-down reservation size is invalid"
/usr/bin/grep -Fq 'sectname __info_plist' "$work_directory/load-commands.txt" || \
    fail "host embedded plist section is unavailable"

/usr/bin/plutil -p "$host_binary" > "$work_directory/embedded-info.txt" || \
    fail "host embedded plist is unreadable"
/usr/bin/grep -Fq "\"CFBundleIdentifier\" => \"$bundle_identifier\"" \
    "$work_directory/embedded-info.txt" || fail "embedded bundle identifier is invalid"
/usr/bin/grep -Fq '"LSSupportsGameMode" => true' "$work_directory/embedded-info.txt" || \
    fail "embedded Game Mode declaration is unavailable"
/usr/bin/grep -Fq '"NSPrincipalClass" => "WineApplication"' \
    "$work_directory/embedded-info.txt" || fail "embedded principal class is invalid"
if /usr/bin/grep -Fq '"LSUIElement"' "$work_directory/embedded-info.txt"; then
    fail "embedded plist must not declare LSUIElement"
fi

/usr/bin/codesign --force --sign "$signing_identity" \
    --entitlements "$rendered_entitlements" \
    --options runtime \
    --timestamp=none \
    "$staged_app"
/usr/bin/codesign --verify --strict --verbose=2 "$staged_app"
/usr/bin/codesign -d --entitlements :- "$staged_app" \
    > "$work_directory/signed-entitlements.plist" 2>/dev/null
/usr/bin/plutil -lint "$work_directory/signed-entitlements.plist" >/dev/null
require_signed_boolean_entitlement() {
    local key="$1"
    local value
    value="$(/usr/libexec/PlistBuddy -c "Print :$key" \
        "$work_directory/signed-entitlements.plist" 2>/dev/null)" || \
        fail "signed host entitlement is unavailable: $key"
    [[ "$value" == "true" ]] || fail "signed host entitlement is not enabled: $key"
}
for entitlement_key in \
    com.apple.security.app-sandbox \
    com.apple.security.inherit \
    com.apple.security.cs.allow-unsigned-executable-memory \
    com.apple.security.cs.disable-library-validation; do
    require_signed_boolean_entitlement "$entitlement_key"
done
for entitlement_key in \
    com.apple.security.application-groups \
    com.apple.security.files.bookmarks.app-scope \
    com.apple.security.files.user-selected.executable \
    com.apple.security.files.user-selected.read-write \
    com.apple.security.network.client \
    com.apple.security.network.server \
    com.apple.security.cs.allow-jit \
    com.apple.security.get-task-allow; do
    if /usr/libexec/PlistBuddy -c "Print :$entitlement_key" \
        "$work_directory/signed-entitlements.plist" >/dev/null 2>&1; then
        fail "sandbox-inheriting host contains forbidden independent entitlement: $entitlement_key"
    fi
done
signed_entitlement_count="$(/usr/bin/plutil -convert xml1 -o - \
    "$work_directory/signed-entitlements.plist" | /usr/bin/grep -c '<key>')"
[[ "$signed_entitlement_count" == "4" ]] || \
    fail "sandbox-inheriting host may contain only app-sandbox, inherit, executable-memory, and library-validation entitlements"

[[ ! -e "$output_app" ]] || fail "output appeared during staging; refusing overwrite"
/bin/mv "$staged_app" "$output_app"
echo "Created fixed GameModeProcessHost bundle: $output_app"
