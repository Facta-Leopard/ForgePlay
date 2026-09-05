#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_ROOT="${FORGEPLAY_RUNTIME_ROOT:-$REPO_ROOT/Resources/Runners/ForgePlayRuntime}"
WINE="$RUNTIME_ROOT/wine/bin/wine"
WINESERVER="$RUNTIME_ROOT/wine/bin/wineserver"
FIXTURE_ROOT="$SCRIPT_DIR/Fixtures/WineGameRendererPolicy"
TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
BUILD_ROOT="$(mktemp -d "$TEMP_ROOT/forgeplay-game-renderer-d3dmetal.XXXXXX")"
PREFIX="$BUILD_ROOT/prefix"
SERVER_ROOT="$BUILD_ROOT/server"
GAME_ROOT="$BUILD_ROOT/SteamLibrary/steamapps/common/RendererD3DMetalProbe"
D3DMETAL_ROOT="$RUNTIME_ROOT/Frameworks/renderer/d3dmetal"
D3DMETAL_WINE="$D3DMETAL_ROOT/wine"
D3DMETAL_EXTERNAL="$D3DMETAL_ROOT/external"
NGX_BRIDGE_ROOT="$BUILD_ROOT/d3dmetal-ngx-bridge"
NGX_BRIDGE_WINE="$NGX_BRIDGE_ROOT/wine"
NGX_BRIDGE_WINDOWS="$NGX_BRIDGE_WINE/x86_64-windows"
NGX_BRIDGE_UNIX="$NGX_BRIDGE_WINE/x86_64-unix"
NGX_BRIDGE_EXTERNAL="$NGX_BRIDGE_ROOT/external"
D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET="../../external/libd3dshared.dylib"
BASE_WINE_DLL="$RUNTIME_ROOT/wine/lib/wine"
OBSERVATION_FILE="$BUILD_ROOT/process-observation.log"
TRACE_FILE="$BUILD_ROOT/wine-trace.log"
NVIDIA_COMPATIBILITY=0
RENDERER_SELECTION="d3dMetal"
if [[ -n "${FORGEPLAY_D3DM_VENDOR_ID_OVERRIDE:-}" ]]; then
  NVIDIA_COMPATIBILITY=1
  RENDERER_SELECTION="d3dMetalNVIDIA"
fi

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

windows_path() {
  local path="$1"
  printf 'Z:%s' "${path//\//\\}"
}

probe_output_value() {
  local field="$1"
  /usr/bin/awk -F= -v field="$field" \
    '$1 == field { print substr($0, length(field) + 2); exit }' "$OUTPUT_FILE"
}

run_base_wine() {
  WINEPREFIX="$PREFIX" \
  WINE_SERVER_ROOT="$SERVER_ROOT" \
  WINEDEBUG="-all" \
  FORGEPLAY_GAME_RENDERER_POLICY_ENABLED="1" \
  FORGEPLAY_GAME_RENDERER_POLICY="d3dMetal" \
  FORGEPLAY_GAME_RENDERER_REQUESTED="$RENDERER_SELECTION" \
  FORGEPLAY_GAME_RENDERER_ENV_D3DM_VENDOR_ID="$VENDOR_ID_CONTROL" \
  FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NVIDIA_IDENTITY_PROFILE="$IDENTITY_PROFILE_CONTROL" \
  FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NVIDIA_IDENTITY_VENDOR_ID="$IDENTITY_VENDOR_CONTROL" \
  FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NVIDIA_IDENTITY_DEVICE_ID="$IDENTITY_DEVICE_CONTROL" \
  FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NVIDIA_IDENTITY_DEVICE_NAME="$IDENTITY_NAME_CONTROL" \
  FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NVIDIA_IDENTITY_DRIVER_VERSION="$IDENTITY_DRIVER_CONTROL" \
  FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NVIDIA_IDENTITY_DISPLAY_DRIVER_VERSION="$IDENTITY_DISPLAY_DRIVER_CONTROL" \
  FORGEPLAY_PROCESS_OBSERVATION_FILE="$(windows_path "$OBSERVATION_FILE")" \
    "$WINE" "$@"
}

run_bounded_wineboot() {
  local timeout_marker="$BUILD_ROOT/wineboot-timeout"
  local wineboot_pid
  local watchdog_pid
  local wineboot_status

  WINEPREFIX="$PREFIX" \
  WINE_SERVER_ROOT="$SERVER_ROOT" \
  WINEARCH="win64" \
  WINEDLLOVERRIDES="mscoree,mshtml=" \
  WINEDEBUG="-all" \
    "$WINE" wineboot -u >/dev/null 2>&1 &
  wineboot_pid=$!
  (
    /bin/sleep 120
    if /bin/kill -0 "$wineboot_pid" >/dev/null 2>&1; then
      : >"$timeout_marker"
      /bin/kill -TERM "$wineboot_pid" >/dev/null 2>&1 || true
    fi
  ) &
  watchdog_pid=$!

  if wait "$wineboot_pid"; then
    wineboot_status=0
  else
    wineboot_status=$?
  fi
  /bin/kill -TERM "$watchdog_pid" >/dev/null 2>&1 || true
  wait "$watchdog_pid" >/dev/null 2>&1 || true
  if [[ -f "$timeout_marker" ]]; then
    fail "fresh D3DMetal probe prefix initialization exceeded 120 seconds"
  fi
  [[ "$wineboot_status" -eq 0 ]] ||
    fail "fresh D3DMetal probe prefix initialization failed with status $wineboot_status"
}

require_d3dmetal_framework_layout() {
  local framework="$D3DMETAL_EXTERNAL/D3DMetal.framework"
  local executable="$framework/D3DMetal"
  local resources="$framework/Resources"
  local version_a="$framework/Versions/A"
  local current="$framework/Versions/Current"
  local canonical_executable="$version_a/D3DMetal"
  local canonical_resources="$version_a/Resources"

  if [[ -f "$executable" && ! -L "$executable" ]]; then
    [[ -d "$resources" && ! -L "$resources" ]] ||
      fail "materialized D3DMetal Resources directory is missing or unsafe: $resources"
    return
  fi

  for directory in "$framework" "$framework/Versions" "$version_a" "$canonical_resources"; do
    [[ -d "$directory" && ! -L "$directory" ]] ||
      fail "canonical D3DMetal framework directory is missing or unsafe: $directory"
  done
  [[ -f "$canonical_executable" && ! -L "$canonical_executable" ]] ||
    fail "canonical D3DMetal framework executable is missing or unsafe: $canonical_executable"
  [[ -L "$current" && "$(readlink "$current")" == "A" && "$current" -ef "$version_a" ]] ||
    fail "D3DMetal current-version link is invalid: $current"
  [[ -L "$executable" &&
     "$(readlink "$executable")" == "Versions/Current/D3DMetal" &&
     "$executable" -ef "$canonical_executable" ]] ||
    fail "D3DMetal executable link is invalid: $executable"
  [[ -L "$resources" &&
     "$(readlink "$resources")" == "Versions/Current/Resources" &&
     "$resources" -ef "$canonical_resources" ]] ||
    fail "D3DMetal Resources link is invalid: $resources"
}

cleanup() {
  if [[ -x "$WINESERVER" && -d "$PREFIX" ]]; then
    WINEPREFIX="$PREFIX" WINE_SERVER_ROOT="$SERVER_ROOT" "$WINESERVER" -k >/dev/null 2>&1 || true
  fi
  if [[ "${FORGEPLAY_KEEP_TEST_ARTIFACTS:-0}" == "1" ]]; then
    printf 'test_artifacts=%s\n' "$BUILD_ROOT" >&2
  else
    rm -rf "$BUILD_ROOT"
  fi
}
trap cleanup EXIT

compiler() {
  local name="$1"
  local candidate

  candidate="$(command -v "$name" 2>/dev/null || true)"
  if [[ -z "$candidate" && -x "/opt/homebrew/bin/$name" ]]; then
    candidate="/opt/homebrew/bin/$name"
  fi
  [[ -n "$candidate" && -x "$candidate" ]] || fail "missing MinGW tool: $name"
  printf '%s' "$candidate"
}

for executable in "$WINE" "$WINESERVER"; do
  [[ -x "$executable" ]] || fail "bundled Wine executable is missing: $executable"
done
for required in \
  "$FIXTURE_ROOT/base_desktop_initializer.c" \
  "$FIXTURE_ROOT/d3dmetal_probe.c" \
  "$FIXTURE_ROOT/launcher.c" \
  "$D3DMETAL_WINE/x86_64-windows/dxgi.dll" \
  "$D3DMETAL_WINE/x86_64-windows/d3d11.dll" \
  "$D3DMETAL_WINE/x86_64-windows/d3d12.dll" \
  "$D3DMETAL_EXTERNAL/libd3dshared.dylib"; do
  [[ -f "$required" && ! -L "$required" ]] ||
    fail "D3DMetal probe dependency is missing or unsafe: $required"
done
if [[ "$NVIDIA_COMPATIBILITY" == "1" ]]; then
  for required in \
    "$D3DMETAL_WINE/x86_64-windows/nvapi.dll" \
    "$D3DMETAL_WINE/x86_64-windows/nvapi64.dll" \
    "$D3DMETAL_WINE/x86_64-windows/nvngx-on-metalfx.dll"; do
    [[ -f "$required" && ! -L "$required" ]] ||
      fail "D3DMetal NVIDIA probe dependency is missing or unsafe: $required"
  done
fi
require_d3dmetal_framework_layout

RUNTIME_ENTITLEMENTS="$BUILD_ROOT/runtime-entitlements.plist"
if codesign -d --entitlements :- "$RUNTIME_ROOT/wine/bin/wine.bin" \
    >"$RUNTIME_ENTITLEMENTS" 2>/dev/null &&
   [[ "$(/usr/libexec/PlistBuddy -c \
       'Print :com.apple.security.inherit' \
       "$RUNTIME_ENTITLEMENTS" 2>/dev/null || true)" == "true" ]]; then
  fail "distribution-signed Wine inherits the ForgePlay app sandbox and cannot be probed from a standalone shell; run this fixture against the verified unsigned runtime package"
fi

for module in dxgi d3d11 d3d12; do
  module_path="$D3DMETAL_WINE/x86_64-unix/$module.so"
  [[ -L "$module_path" ]] ||
    fail "D3DMetal $module Unix module must be a symbolic link to the shared implementation: $module_path"
  [[ "$(readlink "$module_path")" == "$D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET" ]] ||
    fail "D3DMetal $module Unix module has an unsafe link target: $module_path"
  [[ "$module_path" -ef "$D3DMETAL_EXTERNAL/libd3dshared.dylib" ]] ||
    fail "D3DMetal $module Unix module does not resolve to the bundled shared implementation: $module_path"
done
if [[ "$NVIDIA_COMPATIBILITY" == "1" ]]; then
  for module in nvapi nvapi64 nvngx-on-metalfx; do
    module_path="$D3DMETAL_WINE/x86_64-unix/$module.so"
    [[ -L "$module_path" ]] ||
      fail "D3DMetal NVIDIA $module Unix module must be a symbolic link to the shared implementation: $module_path"
    [[ "$(readlink "$module_path")" == "$D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET" ]] ||
      fail "D3DMetal NVIDIA $module Unix module has an unsafe link target: $module_path"
    [[ "$module_path" -ef "$D3DMETAL_EXTERNAL/libd3dshared.dylib" ]] ||
      fail "D3DMetal NVIDIA $module Unix module does not resolve to the bundled shared implementation: $module_path"
  done
fi

X86_64_CC="$(compiler x86_64-w64-mingw32-gcc)"
X86_64_OBJDUMP="$(compiler x86_64-w64-mingw32-objdump)"
mkdir -p "$PREFIX" "$SERVER_ROOT" "$GAME_ROOT"
chmod 700 "$PREFIX" "$SERVER_ROOT"
if [[ "$NVIDIA_COMPATIBILITY" == "1" ]]; then
  mkdir -p "$NGX_BRIDGE_WINDOWS" "$NGX_BRIDGE_UNIX" "$NGX_BRIDGE_EXTERNAL"
  cp "$D3DMETAL_WINE/x86_64-windows/nvngx-on-metalfx.dll" \
    "$NGX_BRIDGE_WINDOWS/nvngx.dll"
  cp "$D3DMETAL_WINE/x86_64-windows/nvngx-on-metalfx.dll" \
    "$NGX_BRIDGE_WINDOWS/_nvngx.dll"
  cp "$D3DMETAL_EXTERNAL/libd3dshared.dylib" \
    "$NGX_BRIDGE_EXTERNAL/libd3dshared.dylib"
  ln -s "../../external/libd3dshared.dylib" "$NGX_BRIDGE_UNIX/nvngx.so"
  cmp -s \
    "$D3DMETAL_WINE/x86_64-windows/nvngx-on-metalfx.dll" \
    "$NGX_BRIDGE_WINDOWS/nvngx.dll" ||
    fail "derived nvngx.dll does not match Apple's source bridge"
  cmp -s "$NGX_BRIDGE_WINDOWS/nvngx.dll" \
    "$NGX_BRIDGE_WINDOWS/_nvngx.dll" ||
    fail "derived _nvngx.dll alias does not match nvngx.dll"
  [[ "$NGX_BRIDGE_UNIX/nvngx.so" -ef "$NGX_BRIDGE_EXTERNAL/libd3dshared.dylib" ]] ||
    fail "derived nvngx.so does not resolve to its copied shared implementation"
  cmp -s \
    "$D3DMETAL_WINE/x86_64-windows/nvapi64.dll" \
    "$D3DMETAL_WINE/x86_64-windows/nvapi.dll" ||
    fail "bundled nvapi.dll does not match Apple's nvapi64 source module"
fi

"$X86_64_CC" -municode -O2 -Wall -Wextra \
  -o "$GAME_ROOT/d3dmetal-probe-x64.exe" \
  "$FIXTURE_ROOT/d3dmetal_probe.c" \
  -ladvapi32 -ld3d11 -ld3d12 -ldxgi -lsetupapi
"$X86_64_CC" -municode -O2 -Wall -Wextra \
  -o "$BUILD_ROOT/launcher.exe" "$FIXTURE_ROOT/launcher.c"
"$X86_64_CC" -municode -O2 -Wall -Wextra \
  -o "$BUILD_ROOT/base-desktop-initializer.exe" \
  "$FIXTURE_ROOT/base_desktop_initializer.c" \
  -luser32

IMPORT_TABLE="$BUILD_ROOT/d3dmetal-probe.imports.txt"
"$X86_64_OBJDUMP" -p "$GAME_ROOT/d3dmetal-probe-x64.exe" >"$IMPORT_TABLE"
grep -Eiq 'DLL Name:[[:space:]]*d3d11\.dll' "$IMPORT_TABLE" ||
  fail "D3DMetal probe lacks the required static d3d11.dll import"
grep -Eiq 'DLL Name:[[:space:]]*dxgi\.dll' "$IMPORT_TABLE" ||
  fail "D3DMetal probe lacks the required static dxgi.dll import"
grep -Eiq 'DLL Name:[[:space:]]*d3d12\.dll' "$IMPORT_TABLE" ||
  fail "D3DMetal probe lacks the required static d3d12.dll import"

OUTPUT_FILE="$BUILD_ROOT/d3dmetal-probe.txt"
D3DMETAL_DLL_PATH="$(windows_path "$D3DMETAL_WINE/x86_64-windows")"
PREFIX_SYSTEM32="$PREFIX/drive_c/windows/system32"
RENDERER_DLL_PATH_X64="$D3DMETAL_DLL_PATH"
WINE_DLL_PATH="$D3DMETAL_WINE:$D3DMETAL_WINE/x86_64-unix:$D3DMETAL_WINE/x86_64-windows:$BASE_WINE_DLL:$BASE_WINE_DLL/x86_64-unix:$BASE_WINE_DLL/x86_64-windows:$BASE_WINE_DLL/i386-windows"
DYLD_LIBRARY_PATH_VALUE="$RUNTIME_ROOT/wine/lib:$D3DMETAL_ROOT:$D3DMETAL_WINE/x86_64-unix:$D3DMETAL_EXTERNAL"
D3DMETAL_FRAMEWORK="$D3DMETAL_EXTERNAL/D3DMetal.framework/D3DMetal"
D3DMETAL_SHARED="$D3DMETAL_EXTERNAL/libd3dshared.dylib"
WINEDLLOVERRIDES_CONTROL="d3d10,d3d11,d3d12,dxgi=n,b;winedbg.exe=d"
METALFX_CONTROL="__FORGEPLAY_UNSET__"
NGX_PATH_CONTROL="__FORGEPLAY_UNSET__"
VENDOR_ID_CONTROL="__FORGEPLAY_UNSET__"
IDENTITY_PROFILE_CONTROL="__FORGEPLAY_UNSET__"
IDENTITY_VENDOR_CONTROL="__FORGEPLAY_UNSET__"
IDENTITY_DEVICE_CONTROL="__FORGEPLAY_UNSET__"
IDENTITY_NAME_CONTROL="__FORGEPLAY_UNSET__"
IDENTITY_DRIVER_CONTROL="__FORGEPLAY_UNSET__"
IDENTITY_DISPLAY_DRIVER_CONTROL="__FORGEPLAY_UNSET__"
if [[ "$NVIDIA_COMPATIBILITY" == "1" ]]; then
  NGX_BRIDGE_DLL_PATH="$(windows_path "$NGX_BRIDGE_WINDOWS")"
  RENDERER_DLL_PATH_X64="$D3DMETAL_DLL_PATH;$NGX_BRIDGE_DLL_PATH"
  WINE_DLL_PATH="$D3DMETAL_WINE:$NGX_BRIDGE_WINE:$D3DMETAL_WINE/x86_64-unix:$NGX_BRIDGE_UNIX:$D3DMETAL_WINE/x86_64-windows:$NGX_BRIDGE_WINDOWS:$BASE_WINE_DLL:$BASE_WINE_DLL/x86_64-unix:$BASE_WINE_DLL/x86_64-windows:$BASE_WINE_DLL/i386-windows"
  DYLD_LIBRARY_PATH_VALUE="$RUNTIME_ROOT/wine/lib:$D3DMETAL_ROOT:$NGX_BRIDGE_ROOT:$D3DMETAL_WINE/x86_64-unix:$NGX_BRIDGE_UNIX:$D3DMETAL_EXTERNAL"
  WINEDLLOVERRIDES_CONTROL="_nvngx,d3d10,d3d11,d3d12,dxgi,nvapi,nvapi64,nvngx,nvngx-on-metalfx=n,b;winedbg.exe=d"
  METALFX_CONTROL="1"
  NGX_PATH_CONTROL="$NGX_BRIDGE_WINDOWS"
  VENDOR_ID_CONTROL="$FORGEPLAY_D3DM_VENDOR_ID_OVERRIDE"
  IDENTITY_PROFILE_CONTROL="${FORGEPLAY_NVIDIA_IDENTITY_PROFILE_OVERRIDE:-rtx-4090-driver-561.09-v2}"
  IDENTITY_VENDOR_CONTROL="${FORGEPLAY_NVIDIA_IDENTITY_VENDOR_ID_OVERRIDE:-0x10de}"
  IDENTITY_DEVICE_CONTROL="${FORGEPLAY_NVIDIA_IDENTITY_DEVICE_ID_OVERRIDE:-0x2684}"
  IDENTITY_NAME_CONTROL="${FORGEPLAY_NVIDIA_IDENTITY_DEVICE_NAME_OVERRIDE:-NVIDIA GeForce RTX 4090}"
  IDENTITY_DRIVER_CONTROL="${FORGEPLAY_NVIDIA_IDENTITY_DRIVER_VERSION_OVERRIDE:-561.09}"
  IDENTITY_DISPLAY_DRIVER_CONTROL="${FORGEPLAY_NVIDIA_IDENTITY_DISPLAY_DRIVER_VERSION_OVERRIDE:-32.0.15.6109}"
  IFS=. read -r identity_version_a identity_version_b identity_version_c identity_version_d \
    <<< "$IDENTITY_DISPLAY_DRIVER_CONTROL"
  for identity_version_component in \
    "$identity_version_a" "$identity_version_b" \
    "$identity_version_c" "$identity_version_d"; do
    [[ "$identity_version_component" =~ ^[0-9]+$ ]] ||
      fail "NVIDIA display driver version is not a four-component numeric value"
    ((10#$identity_version_component <= 65535)) ||
      fail "NVIDIA display driver version component exceeds the DXGI contract"
  done
  printf -v IDENTITY_DXGI_VERSION_HIGH '0x%04x%04x' \
    "$((10#$identity_version_a))" "$((10#$identity_version_b))"
  printf -v IDENTITY_DXGI_VERSION_LOW '0x%04x%04x' \
    "$((10#$identity_version_c))" "$((10#$identity_version_d))"
  printf -v IDENTITY_DXGI_VERSION_QWORD '0x%x' \
    "$((((10#$identity_version_a) << 48) | \
        ((10#$identity_version_b) << 32) | \
        ((10#$identity_version_c) << 16) | \
        (10#$identity_version_d)))"
fi

if [[ "$NVIDIA_COMPATIBILITY" == "1" ]]; then
  run_bounded_wineboot
  mkdir -p "$PREFIX_SYSTEM32"
  cp "$D3DMETAL_WINE/x86_64-windows/nvapi.dll" \
    "$PREFIX_SYSTEM32/nvapi.dll"
  cp "$D3DMETAL_WINE/x86_64-windows/nvapi64.dll" \
    "$PREFIX_SYSTEM32/nvapi64.dll"
  cp "$NGX_BRIDGE_WINDOWS/nvngx.dll" \
    "$PREFIX_SYSTEM32/nvngx.dll"
  cp "$NGX_BRIDGE_WINDOWS/_nvngx.dll" \
    "$PREFIX_SYSTEM32/_nvngx.dll"
  WINEPREFIX="$PREFIX" \
  WINE_SERVER_ROOT="$SERVER_ROOT" \
  WINEDEBUG="-all" \
    "$WINE" reg add \
      'HKLM\Software\NVIDIA Corporation\Global\NGXCore' \
      /v FullPath /t REG_SZ /d 'C:\windows\system32' /f /reg:64 \
      >/dev/null
  WINEPREFIX="$PREFIX" \
  WINE_SERVER_ROOT="$SERVER_ROOT" \
  WINEDEBUG="-all" \
    "$WINE" reg add \
      'HKLM\Software\Wow6432Node\NVIDIA Corporation\Global\NGXCore' \
      /v FullPath /t REG_SZ /d 'C:\windows\system32' /f /reg:32 \
      >/dev/null
  WINEPREFIX="$PREFIX" \
  WINE_SERVER_ROOT="$SERVER_ROOT" \
  WINEDEBUG="-all" \
    "$WINE" reg add \
      'HKLM\System\CurrentControlSet\Services\nvlddmkm\NGXCore' \
      /v NGXPath /t REG_SZ /d 'C:\windows\system32' /f /reg:64 \
      >/dev/null
  WINEPREFIX="$PREFIX" \
  WINE_SERVER_ROOT="$SERVER_ROOT" \
  WINEDEBUG="-all" \
    "$WINE" reg query \
      'HKLM\Software\NVIDIA Corporation\Global\NGXCore' \
      /v FullPath /reg:32 \
      >"$BUILD_ROOT/ngxcore-registry-32.txt"
  WINEPREFIX="$PREFIX" \
  WINE_SERVER_ROOT="$SERVER_ROOT" \
  WINEDEBUG="-all" \
    "$WINE" reg query \
      'HKLM\Software\NVIDIA Corporation\Global\NGXCore' \
      /v FullPath /reg:64 \
      >"$BUILD_ROOT/ngxcore-registry-64.txt"
  WINEPREFIX="$PREFIX" \
  WINE_SERVER_ROOT="$SERVER_ROOT" \
  WINEDEBUG="-all" \
    "$WINESERVER" -w
fi

# A real ForgePlay game starts only after Steam has initialized the shared
# desktop on base Wine. Reproduce that process order so the probe does not ask
# a renderer-scoped game process to bootstrap Wine infrastructure on its own.
run_base_wine "$BUILD_ROOT/base-desktop-initializer.exe" >/dev/null 2>&1 ||
  fail "base Wine desktop initialization failed before D3DMetal game probe"

if ! WINEPREFIX="$PREFIX" \
WINE_SERVER_ROOT="$SERVER_ROOT" \
WINEDEBUG="+loaddll,+module,+seh" \
FORGEPLAY_GAME_RENDERER_POLICY_ENABLED="1" \
FORGEPLAY_GAME_RENDERER_POLICY="d3dMetal" \
FORGEPLAY_GAME_RENDERER_REQUESTED="$RENDERER_SELECTION" \
FORGEPLAY_GAME_RENDERER_CORRELATION_ID="d3dmetal-probe" \
FORGEPLAY_GAME_RENDERER_COMPONENTS_X64="d3dmetal" \
FORGEPLAY_GAME_RENDERER_COMPONENTS_X86="" \
FORGEPLAY_GAME_RENDERER_DLL_PATH_X64="$RENDERER_DLL_PATH_X64" \
FORGEPLAY_GAME_RENDERER_DLL_PATH_X86="" \
FORGEPLAY_GAME_RENDERER_PROVIDER_ALIAS_PATHS_X64='C:\windows\system32\nvngx.dll;C:\windows\system32\_nvngx.dll' \
FORGEPLAY_GAME_RENDERER_ENV_WINEDLLOVERRIDES="$WINEDLLOVERRIDES_CONTROL" \
FORGEPLAY_GAME_RENDERER_ENV_WINEDLLPATH="$WINE_DLL_PATH" \
FORGEPLAY_GAME_RENDERER_ENV_DYLD_LIBRARY_PATH="$DYLD_LIBRARY_PATH_VALUE" \
FORGEPLAY_GAME_RENDERER_ENV_DYLD_FALLBACK_LIBRARY_PATH="$DYLD_LIBRARY_PATH_VALUE" \
FORGEPLAY_GAME_RENDERER_ENV_DYLD_FRAMEWORK_PATH="$D3DMETAL_EXTERNAL" \
FORGEPLAY_GAME_RENDERER_ENV_D3DMETAL_FRAMEWORK_PATH="$D3DMETAL_FRAMEWORK" \
FORGEPLAY_GAME_RENDERER_ENV_D3DMETAL_SHARED_LIBRARY="$D3DMETAL_SHARED" \
FORGEPLAY_GAME_RENDERER_ENV_D3DM_WINE_UNIX_CALL="1" \
FORGEPLAY_GAME_RENDERER_ENV_D3DM_ENABLE_METALFX="$METALFX_CONTROL" \
FORGEPLAY_GAME_RENDERER_ENV_D3DM_NVNGX_PATH="$NGX_PATH_CONTROL" \
FORGEPLAY_GAME_RENDERER_ENV_D3DM_VENDOR_ID="$VENDOR_ID_CONTROL" \
FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NVIDIA_IDENTITY_PROFILE="$IDENTITY_PROFILE_CONTROL" \
FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NVIDIA_IDENTITY_VENDOR_ID="$IDENTITY_VENDOR_CONTROL" \
FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NVIDIA_IDENTITY_DEVICE_ID="$IDENTITY_DEVICE_CONTROL" \
FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NVIDIA_IDENTITY_DEVICE_NAME="$IDENTITY_NAME_CONTROL" \
FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NVIDIA_IDENTITY_DRIVER_VERSION="$IDENTITY_DRIVER_CONTROL" \
FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NVIDIA_IDENTITY_DISPLAY_DRIVER_VERSION="$IDENTITY_DISPLAY_DRIVER_CONTROL" \
FORGEPLAY_D3DMETAL_HEADLESS_PROBE="${FORGEPLAY_D3DMETAL_HEADLESS_PROBE:-0}" \
FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NETWORK_PROFILE="${FORGEPLAY_NETWORK_PROFILE_OVERRIDE:-standard}" \
FORGEPLAY_GAME_RENDERER_ENV_VK_ICD_FILENAMES="__FORGEPLAY_UNSET__" \
FORGEPLAY_GAME_RENDERER_ENV_VK_DRIVER_FILES="__FORGEPLAY_UNSET__" \
FORGEPLAY_GAME_RENDERER_ENV_DXVK_LOG_PATH="__FORGEPLAY_UNSET__" \
FORGEPLAY_GAME_RENDERER_ENV_DXVK_LOG_LEVEL="__FORGEPLAY_UNSET__" \
FORGEPLAY_GAME_RENDERER_ENV_DXVK_CONFIG="__FORGEPLAY_UNSET__" \
FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_D3DMETAL_FRAME_GENERATION="__FORGEPLAY_UNSET__" \
FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_D3DMETAL_FRAME_GENERATION_TARGET_HZ="__FORGEPLAY_UNSET__" \
FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_D3DMETAL_FRAME_CHECK="__FORGEPLAY_UNSET__" \
FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_D3DMETAL_FRAME_GENERATION_PROXY="__FORGEPLAY_UNSET__" \
FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_D3DMETAL_FRAME_GENERATION_OBSERVATION_FILE="__FORGEPLAY_UNSET__" \
FORGEPLAY_NETWORK_PROFILE_REQUESTED="${FORGEPLAY_NETWORK_PROFILE_OVERRIDE:-standard}" \
FORGEPLAY_AUDIO_INPUT_MODE="${FORGEPLAY_AUDIO_INPUT_MODE_OVERRIDE:-enabled}" \
FORGEPLAY_PROCESS_OBSERVATION_FILE="$(windows_path "$OBSERVATION_FILE")" \
  "$WINE" "$BUILD_ROOT/launcher.exe" \
    "$(windows_path "$GAME_ROOT/d3dmetal-probe-x64.exe")" \
    "$(windows_path "$OUTPUT_FILE")" \
    2>"$TRACE_FILE"; then
  [[ ! -f "$OUTPUT_FILE" ]] || cat "$OUTPUT_FILE" >&2
  tail -200 "$TRACE_FILE" >&2 || true
  fail "Wine D3DMetal probe process failed"
fi

[[ -f "$OUTPUT_FILE" ]] || fail "D3DMetal probe output is missing"
for expected in \
  'probe_architecture=64' \
  'FORGEPLAY_GAME_RENDERER_ACTIVE=1' \
  "FORGEPLAY_GAME_RENDERER_REQUESTED=$RENDERER_SELECTION" \
  'FORGEPLAY_GAME_RENDERER_APPLIED=d3dMetal' \
  'FORGEPLAY_GAME_RENDERER_PROFILE=d3dMetal' \
  'FORGEPLAY_GAME_RENDERER_D3DMETAL_BRIDGE_REQUIRED=1' \
  'FORGEPLAY_D3DMETAL_NATIVE_THREAD_CONTEXT=1' \
  'FORGEPLAY_D3DMETAL_BRIDGE=1' \
  'create_factory_hresult=0x00000000' \
  'enum_adapter_hresult=0x00000000' \
  'dxgi_check_interface_support_hresult=0x00000000' \
  'd3d11_check_interface_support_hresult=0x887a0004' \
  'create_d3d12_device_hresult=0x00000000' \
  'create_d3d12_fl12_0_hresult=0x00000000'; do
  grep -Fq "$expected" "$OUTPUT_FILE" ||
    fail "D3DMetal probe result is missing '$expected': $(cat "$OUTPUT_FILE")"
done
! grep -Fq 'd3d11_interface_driver_version_high=' "$OUTPUT_FILE" ||
  fail "D3DMetal fabricated a driver version for the unsupported ID3D11Device query"
! grep -Fq 'd3d11_interface_driver_version_low=' "$OUTPUT_FILE" ||
  fail "D3DMetal fabricated a driver version for the unsupported ID3D11Device query"
if [[ "${FORGEPLAY_D3DMETAL_HEADLESS_PROBE:-0}" != "1" ]]; then
  for expected in \
    'create_d3d11_device_hresult=0x00000000' \
    'window_created=1' \
    'create_swap_chain_hresult=0x00000000' \
    'present_hresult=0x00000000'; do
    grep -Fq "$expected" "$OUTPUT_FILE" ||
      fail "D3DMetal windowed probe result is missing '$expected': $(cat "$OUTPUT_FILE")"
  done
fi
grep -Fq "dxgi_module=$D3DMETAL_DLL_PATH\\dxgi.dll" "$OUTPUT_FILE" ||
  fail "D3DMetal dxgi.dll was not loaded from the selected renderer root"
grep -Fq "d3d11_module=$D3DMETAL_DLL_PATH\\d3d11.dll" "$OUTPUT_FILE" ||
  fail "D3DMetal d3d11.dll was not loaded from the selected renderer root"
grep -Fq "d3d12_module=$D3DMETAL_DLL_PATH\\d3d12.dll" "$OUTPUT_FILE" ||
  fail "D3DMetal d3d12.dll was not loaded from the selected renderer root"
grep -Fq 'FORGEPLAY_D3DMETAL_TARGET=d3dmetal-probe-x64.exe' "$OUTPUT_FILE" ||
  fail "D3DMetal bridge target was not scoped to the probe main image"
if [[ "$NVIDIA_COMPATIBILITY" == "1" ]]; then
  grep -Fxq "dxgi_interface_driver_version_high=$IDENTITY_DXGI_VERSION_HIGH" "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA DXGI driver-version high word is inconsistent"
  grep -Fxq "dxgi_interface_driver_version_low=$IDENTITY_DXGI_VERSION_LOW" "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA DXGI driver-version low word is inconsistent"
  for expected in \
    'D3DM_ENABLE_METALFX=1' \
    "D3DM_NVNGX_PATH=$NGX_BRIDGE_WINDOWS" \
    'ngx_exports_ready=1' \
    'ngx_init_result=0x00000001' \
    'ngx_capability_result=0x00000001' \
    'ngx_destroy_result=0x00000001' \
    'ngx_shutdown_result=0x00000001'; do
    grep -Fq "$expected" "$OUTPUT_FILE" ||
      fail "D3DMetal NVIDIA probe result is missing '$expected': $(cat "$OUTPUT_FILE")"
  done
  if [[ "${FORGEPLAY_D3DMETAL_HEADLESS_PROBE:-0}" != "1" ]]; then
    for diagnostic in \
      ngx_d3d11_init_result \
      ngx_d3d11_capability_result \
      ngx_create_result \
      ngx_evaluate_result \
      ngx_release_result \
      ngx_d3d11_destroy_result \
      ngx_d3d11_shutdown_result; do
      grep -Eq "^${diagnostic}=0x[0-9a-fA-F]{8}$" "$OUTPUT_FILE" ||
        fail "D3DMetal NVIDIA diagnostic is missing '$diagnostic': $(cat "$OUTPUT_FILE")"
    done
    grep -Eq '^ngx_evaluate_invoked=[01]$' "$OUTPUT_FILE" ||
      fail "D3DMetal NVIDIA diagnostic is missing 'ngx_evaluate_invoked': $(cat "$OUTPUT_FILE")"
    grep -Eq '^ngx_output_nonzero=[01]$' "$OUTPUT_FILE" ||
      fail "D3DMetal NVIDIA diagnostic is missing 'ngx_output_nonzero': $(cat "$OUTPUT_FILE")"
    grep -Eq '^ngx_output_checksum=[0-9]+$' "$OUTPUT_FILE" ||
      fail "D3DMetal NVIDIA diagnostic is missing 'ngx_output_checksum': $(cat "$OUTPUT_FILE")"
  fi
  grep -Fxq "adapter_vendor_id=${FORGEPLAY_D3DM_VENDOR_ID_OVERRIDE}" "$OUTPUT_FILE" ||
    fail "D3DMetal adapter vendor override did not reach the selected game process"
  grep -Fxq "adapter_device_id=$IDENTITY_DEVICE_CONTROL" "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA adapter device identity is inconsistent"
  grep -Fxq "adapter_description=$IDENTITY_NAME_CONTROL" "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA adapter description is inconsistent"
  grep -Fxq "FORGEPLAY_NVIDIA_IDENTITY_PROFILE=$IDENTITY_PROFILE_CONTROL" "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA identity profile did not reach the routed game"
  grep -Fxq "FORGEPLAY_NVIDIA_IDENTITY_VENDOR_ID=$IDENTITY_VENDOR_CONTROL" "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA identity vendor did not reach the routed game"
  grep -Fxq "FORGEPLAY_NVIDIA_IDENTITY_DEVICE_ID=$IDENTITY_DEVICE_CONTROL" "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA identity device did not reach the routed game"
  grep -Fxq "FORGEPLAY_NVIDIA_IDENTITY_DEVICE_NAME=$IDENTITY_NAME_CONTROL" "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA identity name did not reach the routed game"
  grep -Fxq "FORGEPLAY_NVIDIA_IDENTITY_DRIVER_VERSION=$IDENTITY_DRIVER_CONTROL" "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA user-mode driver identity did not reach the routed game"
  grep -Fxq "FORGEPLAY_NVIDIA_IDENTITY_DISPLAY_DRIVER_VERSION=$IDENTITY_DISPLAY_DRIVER_CONTROL" "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA display driver identity did not reach the routed game"
  grep -Fxq "setupapi_display_description=$IDENTITY_NAME_CONTROL" "$OUTPUT_FILE" ||
    fail "Wine SetupAPI display description is inconsistent with the selected NVIDIA identity"
  grep -Fiq "setupapi_display_hardware_id=PCI\\VEN_${IDENTITY_VENDOR_CONTROL#0x}&DEV_${IDENTITY_DEVICE_CONTROL#0x}" "$OUTPUT_FILE" ||
    fail "Wine SetupAPI display PCI identity is inconsistent with the selected NVIDIA identity"
  grep -Fxq "display_class_driver_version=$IDENTITY_DISPLAY_DRIVER_CONTROL" "$OUTPUT_FILE" ||
    fail "Wine Display Class driver version is inconsistent with the selected NVIDIA identity"
  grep -Fxq 'nvapi_exports_ready=1' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA NVAPI exports were unavailable"
  grep -Fxq 'nvapi_initialize_result=0' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA NVAPI initialization failed"
  grep -Fxq 'nvapi_enum_after_initialize=0' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA NVAPI enumeration failed after initialization"
  grep -Fxq 'nvapi_driver_version_result=0' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA NVAPI driver-version query failed"
  grep -Fxq 'nvapi_driver_version=56109' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA NVAPI driver version is inconsistent"
  grep -Fxq 'ngx_registry_32_open_status=0' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA NGXCore 32-bit registry view was unavailable"
  grep -Fxq 'ngx_registry_32_query_status=0' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA NGXCore FullPath was unavailable in the 32-bit registry view"
  grep -Fxq 'ngx_registry_32=C:\windows\system32' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA NGXCore 32-bit registry view returned the wrong provider directory"
  grep -Fxq 'ngx_driver_registry_open_status=0' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA driver NGXCore registry key was unavailable"
  grep -Fxq 'ngx_driver_registry_query_status=0' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA driver NGXPath was unavailable"
  grep -Fxq 'ngx_driver_registry=C:\windows\system32' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA driver NGXPath returned the wrong provider directory"
  grep -Fxq 'ngx_discovery=driverRegistry' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA probe did not use Streamline's preferred driver registry discovery"
  grep -Fxq 'ngx_registry_module_requested=C:\windows\system32\nvngx.dll' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA probe did not request the staged System32 NGX bridge by full path"
  grep -Fiq 'nvngx_registry_full_path_module=C:\windows\system32\nvngx.dll' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA staged System32 NGX bridge was not full-path loadable"
  grep -Fiq '_nvngx_full_path_module=C:\windows\system32\_nvngx.dll' "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA staged System32 _nvngx compatibility alias was not full-path loadable"
  grep -Fq "nvapi64_module=$D3DMETAL_DLL_PATH\\nvapi64.dll" "$OUTPUT_FILE" ||
    fail "D3DMetal NVIDIA nvapi64.dll was not loaded from the selected renderer root"
else
  ! grep -Fq 'adapter_description=NVIDIA GeForce RTX 4090' "$OUTPUT_FILE" ||
    fail "standard D3DMetal route leaked the NVIDIA compatibility identity"
  grep -Fxq 'D3DM_ENABLE_METALFX=' "$OUTPUT_FILE" ||
    fail "standard D3DMetal route leaked MetalFX activation"
  grep -Fxq 'D3DM_NVNGX_PATH=' "$OUTPUT_FILE" ||
    fail "standard D3DMetal route leaked an NGX provider path"
  grep -Fxq 'ngx_discovery=basename' "$OUTPUT_FILE" ||
    fail "standard D3DMetal probe did not record its negative basename lookup"
  grep -Fxq 'ngx_exports_ready=0' "$OUTPUT_FILE" ||
    fail "standard D3DMetal route unexpectedly exposed NGX exports"
  ! grep -Fq 'nvngx_basename_module=' "$OUTPUT_FILE" ||
    fail "standard D3DMetal route unexpectedly loaded an NGX module"
fi

if [[ "$NVIDIA_COMPATIBILITY" == "1" ]]; then
  run_base_wine "$BUILD_ROOT/base-desktop-initializer.exe" >/dev/null 2>&1 ||
    fail "base Wine desktop refresh failed after the D3DMetal NVIDIA game probe"
  DISPLAY_CLASS_QUERY="$BUILD_ROOT/display-class-after-base-refresh.txt"
  DIRECTX_QUERY="$BUILD_ROOT/directx-after-base-refresh.txt"
  run_base_wine reg query \
    'HKLM\System\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000' \
    /v DriverVersion >"$DISPLAY_CLASS_QUERY" ||
    fail "Display Class driver version was unavailable after the base refresh"
  run_base_wine reg query \
    'HKLM\System\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0000' \
    /v DriverDesc >>"$DISPLAY_CLASS_QUERY" ||
    fail "Display Class driver description was unavailable after the base refresh"
  grep -Fiq "$IDENTITY_DISPLAY_DRIVER_CONTROL" "$DISPLAY_CLASS_QUERY" ||
    fail "base Wine refresh replaced the NVIDIA Display Class driver version"
  grep -Fiq "$IDENTITY_NAME_CONTROL" "$DISPLAY_CLASS_QUERY" ||
    fail "base Wine refresh replaced the NVIDIA Display Class description"
  run_base_wine reg query \
    'HKLM\Software\Microsoft\DirectX' /s >"$DIRECTX_QUERY" ||
    fail "DirectX adapter registry state was unavailable after the base refresh"
  grep -Fiq "$IDENTITY_DXGI_VERSION_QWORD" "$DIRECTX_QUERY" ||
    fail "base Wine refresh replaced the NVIDIA DirectX driver version"
  grep -Fiq "$IDENTITY_NAME_CONTROL" "$DIRECTX_QUERY" ||
    fail "base Wine refresh replaced the NVIDIA DirectX description"
fi

[[ -f "$OBSERVATION_FILE" ]] || fail "D3DMetal route observation file is missing"
grep -Fq 'planned-profile=d3dMetal' "$OBSERVATION_FILE" ||
  fail "D3DMetal route plan was not recorded"
grep -Fq 'reason=manual-session-d3dmetal' "$OBSERVATION_FILE" ||
  fail "manual D3DMetal route reason was not recorded"
grep -Fq 'state=loaded | module=dxgi.dll' "$OBSERVATION_FILE" ||
  fail "D3DMetal dxgi load was not recorded"
grep -Fq 'state=loaded | module=d3d11.dll' "$OBSERVATION_FILE" ||
  fail "D3DMetal d3d11 load was not recorded"
grep -Fq 'state=loaded | module=d3d12.dll' "$OBSERVATION_FILE" ||
  fail "D3DMetal d3d12 load was not recorded"
if [[ "$NVIDIA_COMPATIBILITY" == "1" ]]; then
  ! grep -Eq 'state=(loaded|initialized) \| module=(_nvngx|nvapi|nvapi64|nvngx|nvngx-on-metalfx)\.dll.*executable=C:\\windows\\system32\\explorer\.exe' \
    "$OBSERVATION_FILE" ||
    fail "D3DMetal NVIDIA provider leaked into base Wine explorer.exe"
  grep -Fq 'state=loaded | module=nvngx.dll' "$OBSERVATION_FILE" ||
    fail "D3DMetal NVIDIA nvngx load was not recorded"
  grep -Fq 'state=loaded | module=nvapi64.dll' "$OBSERVATION_FILE" ||
    fail "D3DMetal NVIDIA nvapi64 load was not recorded"
  grep -Fq 'state=loaded | module=nvapi.dll' "$OBSERVATION_FILE" ||
    fail "D3DMetal NVIDIA internal nvapi.dll alias load was not recorded"
  grep -Fq 'state=loaded | module=_nvngx.dll' "$OBSERVATION_FILE" ||
    fail "D3DMetal NVIDIA _nvngx compatibility alias load was not recorded"
  for provider_module in nvapi64.dll nvapi.dll nvngx.dll _nvngx.dll; do
    grep -F "state=loaded | module=$provider_module" "$OBSERVATION_FILE" |
      grep -Fq 'path-owner=verified | profile=d3dMetal' ||
      fail "D3DMetal NVIDIA $provider_module ownership was not verified"
  done
else
  ! grep -Eq 'state=(loaded|initialized) \| module=(_nvngx|nvapi|nvapi64|nvngx|nvngx-on-metalfx)\.dll' \
    "$OBSERVATION_FILE" ||
    fail "standard D3DMetal route loaded an NVIDIA provider module"
fi
grep -F 'state=loaded | module=dxgi.dll' "$OBSERVATION_FILE" |
  grep -Fq 'path-owner=verified | profile=d3dMetal' ||
  fail "D3DMetal DXGI ownership was not verified against the selected profile"
! grep -Eiq 'Unhandled page fault|0xc0000005|EXCEPTION_ACCESS_VIOLATION' "$TRACE_FILE" ||
  fail "D3DMetal probe encountered an access violation"
! grep -Fq 'wined3d_dll_init Using the Vulkan renderer' "$TRACE_FILE" ||
  fail "D3DMetal probe fell back to WineD3D"

printf 'game_renderer_d3dmetal=PASS\n'
printf 'manual_session_renderer=d3dMetal\n'
printf 'native_thread_context=retained_and_tls_synchronized\n'
if [[ "${FORGEPLAY_D3DMETAL_HEADLESS_PROBE:-0}" == "1" ]]; then
  printf 'd3d11_d3d12_device_swapchain_present=headless_not_run\n'
else
  printf 'd3d11_d3d12_device_swapchain_present=x64_passed\n'
fi
if [[ "$NVIDIA_COMPATIBILITY" == "1" ]]; then
  if [[ "${FORGEPLAY_D3DMETAL_HEADLESS_PROBE:-0}" == "1" ]]; then
    printf 'ngx_metalfx_round_trip=headless_not_run\n'
  elif grep -Fxq 'ngx_d3d11_init_result=0x00000001' "$OUTPUT_FILE" &&
       grep -Fxq 'ngx_d3d11_capability_result=0x00000001' "$OUTPUT_FILE" &&
       grep -Fxq 'ngx_create_result=0x00000001' "$OUTPUT_FILE" &&
       grep -Fxq 'ngx_evaluate_invoked=1' "$OUTPUT_FILE" &&
       grep -Fxq 'ngx_evaluate_result=0x00000001' "$OUTPUT_FILE" &&
       grep -Fxq 'ngx_release_result=0x00000001' "$OUTPUT_FILE" &&
       grep -Fxq 'ngx_d3d11_destroy_result=0x00000001' "$OUTPUT_FILE" &&
       grep -Fxq 'ngx_d3d11_shutdown_result=0x00000001' "$OUTPUT_FILE" &&
       grep -Fxq 'ngx_output_nonzero=1' "$OUTPUT_FILE" &&
       grep -Eq '^ngx_output_checksum=[1-9][0-9]*$' "$OUTPUT_FILE"; then
    printf 'ngx_metalfx_round_trip=create_evaluate_output_returned\n'
  else
    printf 'ngx_metalfx_round_trip=d3d11_diagnostic_failed_nonblocking\n'
    printf 'ngx_metalfx_d3d11_diagnostic='
    printf 'evaluate_invoked=%s ' "$(probe_output_value ngx_evaluate_invoked)"
    printf 'init_result=%s ' "$(probe_output_value ngx_d3d11_init_result)"
    printf 'capability_result=%s ' "$(probe_output_value ngx_d3d11_capability_result)"
    printf 'create_result=%s ' "$(probe_output_value ngx_create_result)"
    printf 'evaluate_result=%s ' "$(probe_output_value ngx_evaluate_result)"
    printf 'release_result=%s ' "$(probe_output_value ngx_release_result)"
    printf 'destroy_result=%s ' "$(probe_output_value ngx_d3d11_destroy_result)"
    printf 'shutdown_result=%s ' "$(probe_output_value ngx_d3d11_shutdown_result)"
    printf 'output_nonzero=%s ' "$(probe_output_value ngx_output_nonzero)"
    printf 'output_checksum=%s\n' "$(probe_output_value ngx_output_checksum)"
  fi
else
  printf 'ngx_metalfx_round_trip=not_requested\n'
fi
printf 'adapter_vendor_id=%s\n' "${FORGEPLAY_D3DM_VENDOR_ID_OVERRIDE:-framework-default}"
