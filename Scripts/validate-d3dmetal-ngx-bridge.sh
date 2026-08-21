#!/bin/bash
set -euo pipefail

readonly FORGEPLAY_SYSTEM_TOOL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PATH="$FORGEPLAY_SYSTEM_TOOL_PATH"
export PATH
unset CDPATH

D3DMETAL_ROOT="${1:-}"

fail() {
  printf 'error: invalid D3DMetal NGX bridge: %s\n' "$*" >&2
  exit 1
}

[[ -n "$D3DMETAL_ROOT" ]] ||
  fail "usage: validate-d3dmetal-ngx-bridge.sh <D3DMetal renderer root>"
[[ "$D3DMETAL_ROOT" = /* && -d "$D3DMETAL_ROOT" && ! -L "$D3DMETAL_ROOT" ]] ||
  fail "renderer root must be an absolute non-symlink directory: $D3DMETAL_ROOT"
D3DMETAL_ROOT="$(cd "$D3DMETAL_ROOT" && /bin/pwd -P)"

NGX_PE="$D3DMETAL_ROOT/wine/x86_64-windows/nvngx-on-metalfx.dll"
SHARED_LIBRARY="$D3DMETAL_ROOT/external/libd3dshared.dylib"

require_single_link_regular_file() {
  local path="$1"
  local label="$2"
  local link_count

  [[ -f "$path" && ! -L "$path" ]] ||
    fail "$label must be a non-symlink regular file: $path"
  link_count="$(/usr/bin/stat -f '%l' "$path" 2>/dev/null)" ||
    fail "$label link count could not be inspected: $path"
  [[ "$link_count" == "1" ]] ||
    fail "$label must not be hardlinked: $path"
}

require_single_link_regular_file "$NGX_PE" "Apple MetalFX NGX PE bridge"
require_single_link_regular_file "$SHARED_LIBRARY" "Apple D3DMetal shared library"

LLVM_OBJDUMP="$(/usr/bin/xcrun --find llvm-objdump 2>/dev/null)" ||
  fail "xcrun could not locate llvm-objdump"
[[ "$LLVM_OBJDUMP" = /* && -x "$LLVM_OBJDUMP" && ! -L "$LLVM_OBJDUMP" ]] ||
  fail "llvm-objdump is unavailable or unsafe: $LLVM_OBJDUMP"

INSPECTION="$($LLVM_OBJDUMP --private-headers "$NGX_PE" 2>/dev/null)" ||
  fail "llvm-objdump could not inspect the NGX PE bridge"

/usr/bin/grep -Fq 'file format coff-x86-64' <<<"$INSPECTION" ||
  fail "NGX bridge must be a 64-bit COFF image"
/usr/bin/grep -Eq '^[[:space:]]*DLL$' <<<"$INSPECTION" ||
  fail "NGX bridge does not carry the PE DLL characteristic"
/usr/bin/grep -Eq '^Magic[[:space:]]+020b[[:space:]]+\(PE32\+\)$' <<<"$INSPECTION" ||
  fail "NGX bridge must use the PE32+ format"
/usr/bin/grep -Eq '^Entry 4 [0-9a-fA-F]*[1-9a-fA-F][0-9a-fA-F]* [0-9a-fA-F]*[1-9a-fA-F][0-9a-fA-F]* Security Directory$' <<<"$INSPECTION" ||
  fail "NGX bridge has no embedded PE security directory"
/usr/bin/grep -Fxq ' DLL name: nvngx.dll' <<<"$INSPECTION" ||
  fail "NGX bridge internal DLL name is not nvngx.dll"

EXPECTED_EXPORTS="$(/usr/bin/sort <<'EOF'
NVSDK_NGX_D3D11_AllocateParameters
NVSDK_NGX_D3D11_CreateFeature
NVSDK_NGX_D3D11_DestroyParameters
NVSDK_NGX_D3D11_EvaluateFeature
NVSDK_NGX_D3D11_GetCapabilityParameters
NVSDK_NGX_D3D11_GetFeatureRequirements
NVSDK_NGX_D3D11_GetParameters
NVSDK_NGX_D3D11_GetScratchBufferSize
NVSDK_NGX_D3D11_Init
NVSDK_NGX_D3D11_Init_Ext
NVSDK_NGX_D3D11_Init_ProjectID
NVSDK_NGX_D3D11_ReleaseFeature
NVSDK_NGX_D3D11_Shutdown
NVSDK_NGX_D3D11_Shutdown1
NVSDK_NGX_D3D12_AllocateParameters
NVSDK_NGX_D3D12_CreateFeature
NVSDK_NGX_D3D12_DestroyParameters
NVSDK_NGX_D3D12_EvaluateFeature
NVSDK_NGX_D3D12_GetCapabilityParameters
NVSDK_NGX_D3D12_GetFeatureRequirements
NVSDK_NGX_D3D12_GetParameters
NVSDK_NGX_D3D12_GetScratchBufferSize
NVSDK_NGX_D3D12_Init
NVSDK_NGX_D3D12_Init_Ext
NVSDK_NGX_D3D12_Init_ProjectID
NVSDK_NGX_D3D12_ReleaseFeature
NVSDK_NGX_D3D12_Shutdown
NVSDK_NGX_D3D12_Shutdown1
EOF
)"
ACTUAL_EXPORTS="$(
  /usr/bin/awk '
    /^Export Table:/ { in_exports = 1; next }
    in_exports && $1 ~ /^[0-9]+$/ && $2 ~ /^0x[0-9a-fA-F]+$/ && NF == 3 {
      print $3
    }
  ' <<<"$INSPECTION" | /usr/bin/sort
)"
[[ "$ACTUAL_EXPORTS" == "$EXPECTED_EXPORTS" ]] ||
  fail "NGX bridge export table does not match the exact D3D11/D3D12 contract"

EXPECTED_IMPORT_DLLS="$(printf '%s\n' kernel32.dll ntdll.dll ucrtbase.dll user32.dll | /usr/bin/sort)"
ACTUAL_IMPORT_DLLS="$(
  /usr/bin/awk '
    /^Export Table:/ { exit }
    /^[[:space:]]*DLL Name:/ { print $3 }
  ' <<<"$INSPECTION" | /usr/bin/sort
)"
[[ "$ACTUAL_IMPORT_DLLS" == "$EXPECTED_IMPORT_DLLS" ]] ||
  fail "NGX bridge imported DLL set is not the locked MetalFX bridge contract"

EXPECTED_IMPORTS="$(/usr/bin/sort <<'EOF'
DisableThreadLibraryCalls
EnumDisplayMonitors
GetModuleHandleW
GetProcAddress
LoadLibraryA
NtQueryVirtualMemory
free
malloc
EOF
)"
ACTUAL_IMPORTS="$(
  /usr/bin/awk '
    /^Export Table:/ { exit }
    $1 ~ /^[0-9]+$/ && NF == 2 { print $2 }
  ' <<<"$INSPECTION" | /usr/bin/sort
)"
[[ "$ACTUAL_IMPORTS" == "$EXPECTED_IMPORTS" ]] ||
  fail "NGX bridge import table does not match the locked host bridge contract"

SHARED_ARCHITECTURES="$(/usr/bin/lipo -archs "$SHARED_LIBRARY" 2>/dev/null)" ||
  fail "D3DMetal shared library architecture could not be inspected"
[[ "$SHARED_ARCHITECTURES" == "x86_64" ]] ||
  fail "D3DMetal shared library must contain exactly one x86_64 slice (found: $SHARED_ARCHITECTURES)"

/usr/bin/codesign --verify --strict "$SHARED_LIBRARY" >/dev/null 2>&1 ||
  fail "D3DMetal shared library signature is invalid"
SHARED_SIGNING_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "$SHARED_LIBRARY" 2>&1)" ||
  fail "D3DMetal shared library signing identity could not be read"
/usr/bin/grep -Fxq 'Identifier=com.apple.libd3dshared' <<<"$SHARED_SIGNING_DETAILS" ||
  fail "D3DMetal shared library identifier is not com.apple.libd3dshared"

printf 'D3DMetal NGX bridge contract verified: %s\n' "$D3DMETAL_ROOT"
