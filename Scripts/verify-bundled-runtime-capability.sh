#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:-}"
RELEASE_RUNTIME_INVENTORY_ONLY=0
REQUIRE_APP_STORE_RUNTIME="${FORGEPLAY_REQUIRE_APP_STORE_RUNTIME:-0}"
REQUIRE_DIRECT_DMG_RUNTIME="${FORGEPLAY_REQUIRE_DIRECT_DMG_RUNTIME:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACHO_RUNTIME_CLOSURE_VERIFIER="$SCRIPT_DIR/verify-macho-runtime-closure.py"
D3DMETAL_NGX_BRIDGE_VALIDATOR="$SCRIPT_DIR/validate-d3dmetal-ngx-bridge.sh"
RUNTIME_DEPENDENCY_LOCK="$SCRIPT_DIR/../Config/ForgePlayRuntimeDependencies.lock.json"
RENDERER_PAYLOAD_LOCK="$SCRIPT_DIR/../Config/ForgePlayRendererPayload.lock.json"
GSTREAMER_PAYLOAD_LOCK="$SCRIPT_DIR/../Config/ForgePlayGStreamerPayload.lock.json"
RUNTIME_SBOM_TOOL="$SCRIPT_DIR/runtime-sbom.py"
RUNTIME_CORE_IDENTITY_TOOL="$SCRIPT_DIR/runtime-core-payload-identity.py"
CLEAN_WINE_MARKER_VERIFIER="$SCRIPT_DIR/verify-clean-wine-runtime-markers.py"
BUILD_PATH_VERIFIER="$SCRIPT_DIR/verify-wine-runtime-build-paths.py"
RUNTIME_PATCH_PROVENANCE_LOCK="$SCRIPT_DIR/../Config/ForgePlayRuntimePatchProvenance.lock.json"
RUNTIME_SOURCE_IDENTITY_LOCK="$SCRIPT_DIR/../Config/ForgePlayRuntimeSourceIdentity.lock.json"
RUNTIME_PATCH_PROVENANCE_VERIFIER="$SCRIPT_DIR/verify-forgeplay-runtime-patch-provenance.py"
RUNTIME_PAYLOAD_POLICY_VALIDATOR="$SCRIPT_DIR/package-forgeplay-runtime.sh"
NANUM_GOTHIC_REGULAR_SHA256="76f45ef4a6bcff344c837c95a7dcc26e017e38b5846d5ae0cdcb5b86be2e2d31"
NANUM_GOTHIC_BOLD_SHA256="21f9d3a7f1ca82ca1dc9a288e30138b4f1feb6e71fc89b5a9181fed174b6bbe2"
NANUM_GOTHIC_OFL_SHA256="eeacf16032901d0ed0456876ec77b8f0fda6b3fecec7d972f8543eb602e6c30f"
NANUM_GOTHIC_SOURCE_IDENTITY_SHA256="c1fbfce859af7446bde6e2f88877cafc92535fde63f7cce9ae0003d29399926c"
FORGEPLAY_WINE_MODIFICATIONS_SHA256="613ab79178fece6ea534589d64c1e9716b7a8a5c8730eebb4ea067fdd46ff081"
GPL_3_ONLY_LICENSE_SHA256="3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"
LGPL_2_1_LICENSE_SHA256="e237fa56668030e928551ddd60f05df5fe957f75eab874bbd017e085ed722e7c"
APPLE_GPTK_LICENSE_SHA256="5abb2d059be217663b00e8fd37e14411d374e11d17e3b744eebd49b8d17118c8"
APPLE_GPTK_ACKNOWLEDGEMENTS_SHA256="6f3aa835f6d0d06f89997d0a346a209e39a8105521fd939e096c5b24dc0cb0a6"
APPLE_GPTK_FRAMEWORK_LICENSE_SHA256="553d0035773ddd1590045f8fdc3a4c6ead31e36336721aeca8421e88ed1c9f80"
APPLE_D3DMETAL_CODE_RESOURCES_SHA256="6a588e946d35ac02c53c0f1c62fe3b21f0e7709795f39e79c1d5afa3637a9416"
D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET="../../external/libd3dshared.dylib"
D3DMETAL_SHARED_UNIX_MODULES=(d3d10 d3d11 d3d12 dxgi nvapi nvapi64 nvngx-on-metalfx)
WINE_RUNTIME_BIN_ALLOWLIST=(
  msidb
  msiexec
  notepad
  regedit
  regsvr32
  wine
  wine.bin
  wineboot
  winecfg
  wineconsole
  winedbg
  winefile
  winemine
  winepath
  wineserver
  wineserver.bin
)

fail() {
  printf 'error: invalid bundled runtime capability: %s\n' "$*" >&2
  exit 1
}

require_boolean_flag() {
  local value="$1"
  local name="$2"
  case "$value" in
    0|1) ;;
    *) fail "$name must be 0 or 1" ;;
  esac
}

binary_contains_text() {
  local path="$1"
  local text="$2"
  python3 - "$path" "$text" <<'PY'
import sys
from pathlib import Path

data = Path(sys.argv[1]).read_bytes()
needle = sys.argv[2].encode("ascii")
raise SystemExit(0 if needle in data or sys.argv[2].encode("utf-16le") in data else 1)
PY
}

winemac_driver_has_unsupported_steam_cef_surface_marker() {
  local driver="$1"
  LC_ALL=C grep -aFq 'Cross-process child window Metal swapchains are not implemented' "$driver" ||
    LC_ALL=C grep -aFq 'DC for window %p of other process: not implemented' "$driver"
}

winemac_driver_has_supported_steam_cef_surface_marker() {
  local driver="$1"
  LC_ALL=C grep -aFq 'DC for window %p of other process; using client surface pixel format %d' "$driver"
}

winemac_driver_exports_metal_window_surface_contract() {
  local driver="$1"
  LC_ALL=C nm -gU "$driver" 2>/dev/null |
    awk '$NF == "_macdrv_functions" { found = 1 } END { exit(found ? 0 : 1) }'
}

require_non_symlink_directory() {
  local path="$1"
  local label="$2"
  [[ -d "$path" && ! -L "$path" ]] || fail "$label must be a non-symlink directory: $path"
}

require_non_symlink_regular_file() {
  local path="$1"
  local label="$2"
  local link_count
  [[ -f "$path" && ! -L "$path" ]] || fail "$label must be a non-symlink regular file: $path"
  link_count="$(stat -f '%l' "$path" 2>/dev/null)" || fail "$label link count could not be inspected: $path"
  [[ "$link_count" == "1" ]] || fail "$label must not be hardlinked: $path"
}

require_non_symlink_executable_file() {
  local path="$1"
  local label="$2"
  require_non_symlink_regular_file "$path" "$label"
  [[ -x "$path" ]] || fail "$label must be executable: $path"
}

verify_runtime_wine_bin_allowlist() {
  local bin_root="$1"
  local path name allowed found unexpected=""

  while IFS= read -r -d '' path; do
    name="${path##*/}"
    found=0
    for allowed in "${WINE_RUNTIME_BIN_ALLOWLIST[@]}"; do
      if [[ "$name" == "$allowed" ]]; then
        found=1
        break
      fi
    done
    if [[ "$found" -ne 1 ]]; then
      unexpected="$path"
      break
    fi
  done < <(find "$bin_root" -mindepth 1 -maxdepth 1 -print0)
  if [[ -n "$unexpected" ]]; then
    fail "Wine bin payload contains an undeclared Runtime or development entry: $unexpected"
  fi
  for allowed in "${WINE_RUNTIME_BIN_ALLOWLIST[@]}"; do
    require_non_symlink_executable_file \
      "$bin_root/$allowed" \
      "Wine Runtime bin allowlist entry $allowed"
  done
}

is_allowed_d3dmetal_shared_unix_module_link_path() {
  local path="$1"
  local module
  for module in "${D3DMETAL_SHARED_UNIX_MODULES[@]}"; do
    if [[ "$path" == "$D3DMETAL_RENDERER_ROOT/wine/x86_64-unix/$module.so" ]]; then
      return 0
    fi
  done
  return 1
}

is_allowed_d3dmetal_framework_alias_path() {
  local path="$1"
  case "$path" in
    "$D3DMETAL_FRAMEWORK/D3DMetal"|\
    "$D3DMETAL_FRAMEWORK/Resources"|\
    "$D3DMETAL_FRAMEWORK/Versions/Current")
      return 0
      ;;
  esac
  return 1
}

require_exact_relative_symlink() {
  local path="$1"
  local expected_target="$2"
  local expected_path="$3"
  local label="$4"
  local actual_target

  [[ -L "$path" ]] || fail "$label must be a symbolic link: $path"
  actual_target="$(readlink "$path")" ||
    fail "$label target could not be read: $path"
  [[ "$actual_target" == "$expected_target" ]] ||
    fail "$label has an incorrect target: $path -> $actual_target"
  [[ "$path" -ef "$expected_path" ]] ||
    fail "$label does not resolve to the canonical D3DMetal framework payload: $path"
}

verify_d3dmetal_framework_alias_contract() {
  local executable_alias="$D3DMETAL_FRAMEWORK/D3DMetal"
  local resources_alias="$D3DMETAL_FRAMEWORK/Resources"
  local current_alias="$D3DMETAL_FRAMEWORK/Versions/Current"
  local canonical_executable="$D3DMETAL_FRAMEWORK/Versions/A/D3DMetal"
  local canonical_resources="$D3DMETAL_FRAMEWORK/Versions/A/Resources"

  require_non_symlink_directory \
    "$D3DMETAL_FRAMEWORK" \
    "D3DMetal framework"
  require_non_symlink_directory \
    "$D3DMETAL_FRAMEWORK/Versions/A" \
    "D3DMetal canonical framework version"
  require_non_symlink_executable_file \
    "$canonical_executable" \
    "D3DMetal canonical framework executable"
  require_non_symlink_directory \
    "$canonical_resources" \
    "D3DMetal canonical framework Resources"

  if [[ -L "$executable_alias" || -L "$resources_alias" || -L "$current_alias" ]]; then
    require_exact_relative_symlink \
      "$current_alias" \
      "A" \
      "$D3DMETAL_FRAMEWORK/Versions/A" \
      "D3DMetal current-version alias"
    require_exact_relative_symlink \
      "$executable_alias" \
      "Versions/Current/D3DMetal" \
      "$canonical_executable" \
      "D3DMetal executable alias"
    require_exact_relative_symlink \
      "$resources_alias" \
      "Versions/Current/Resources" \
      "$canonical_resources" \
      "D3DMetal Resources alias"
    return
  fi

  [[ ! -e "$current_alias" && ! -L "$current_alias" ]] ||
    fail "materialized D3DMetal framework must not contain Versions/Current"
  require_non_symlink_executable_file \
    "$executable_alias" \
    "D3DMetal materialized executable alias"
  require_non_symlink_directory \
    "$resources_alias" \
    "D3DMetal materialized Resources alias"
}

require_d3dmetal_shared_unix_module_link() {
  local module="$1"
  local link_path="$D3DMETAL_RENDERER_ROOT/wine/x86_64-unix/$module.so"
  local shared_library="$D3DMETAL_RENDERER_ROOT/external/libd3dshared.dylib"
  local link_target

  require_non_symlink_directory \
    "$D3DMETAL_RENDERER_ROOT/wine/x86_64-unix" \
    "D3DMetal Unix module directory"
  require_non_symlink_directory \
    "$D3DMETAL_RENDERER_ROOT/external" \
    "D3DMetal external library directory"
  require_non_symlink_regular_file "$shared_library" "D3DMetal shared library"
  [[ -L "$link_path" ]] ||
    fail "D3DMetal $module.so must be a symbolic link to the single shared library: $link_path"
  link_target="$(readlink "$link_path")"
  [[ "$link_target" == "$D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET" ]] ||
    fail "D3DMetal $module.so has an unsafe or incorrect link target: $link_path -> $link_target"
  [[ "$link_path" -ef "$shared_library" ]] ||
    fail "D3DMetal $module.so does not resolve to the bundled shared library: $link_path"
}

verify_d3dmetal_shared_unix_module_contract() {
  local module
  for module in "${D3DMETAL_SHARED_UNIX_MODULES[@]}"; do
    require_d3dmetal_shared_unix_module_link "$module"
  done
  require_non_symlink_regular_file \
    "$D3DMETAL_RENDERER_ROOT/wine/x86_64-windows/nvapi64.dll" \
    "D3DMetal nvapi64.dll"
  require_non_symlink_regular_file \
    "$D3DMETAL_RENDERER_ROOT/wine/x86_64-windows/nvapi.dll" \
    "D3DMetal nvapi.dll alias"
  cmp -s \
    "$D3DMETAL_RENDERER_ROOT/wine/x86_64-windows/nvapi64.dll" \
    "$D3DMETAL_RENDERER_ROOT/wine/x86_64-windows/nvapi.dll" ||
    fail "D3DMetal nvapi.dll must be an exact alias of nvapi64.dll"
}

require_file_sha256() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local actual

  require_non_symlink_regular_file "$path" "$label"
  actual="$(shasum -a 256 "$path" | awk '{print $1}')" ||
    fail "$label SHA-256 could not be computed: $path"
  [[ "$actual" == "$expected" ]] ||
    fail "$label SHA-256 mismatch: expected $expected, found $actual"
}

plist_string_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null | tr -d '\r\n'
}

require_gptk4_framework_metadata() {
  local framework="$1"
  local info_plist="$framework/Resources/Info.plist"
  local executable short_version bundle_version major_version

  require_non_symlink_regular_file "$info_plist" "D3DMetal framework Info.plist"
  executable="$(plist_string_value "$info_plist" CFBundleExecutable || true)"
  short_version="$(plist_string_value "$info_plist" CFBundleShortVersionString || true)"
  bundle_version="$(plist_string_value "$info_plist" CFBundleVersion || true)"
  [[ "$executable" == "D3DMetal" ]] ||
    fail "D3DMetal framework metadata must name the D3DMetal executable: $info_plist"
  [[ -n "$short_version" && -n "$bundle_version" ]] ||
    fail "D3DMetal framework metadata must include CFBundleShortVersionString and CFBundleVersion: $info_plist"
  if [[ "$short_version" =~ ^([0-9]+) ]]; then
    major_version="${BASH_REMATCH[1]}"
  else
    fail "D3DMetal framework version is not numeric: $short_version"
  fi
  (( 10#$major_version >= 4 )) ||
    fail "D3DMetal D3D12 payload requires GPTK 4 or newer; found $short_version"
}

verify_winebus_iohid_backend() {
  local winebus="$1"
  require_non_symlink_regular_file "$winebus" "ForgePlay Runtime Wine IOHID controller backend"
  otool -L "$winebus" 2>/dev/null | grep -Fq '/System/Library/Frameworks/IOKit.framework/' ||
    fail "Wine winebus.so must link IOKit for the macOS IOHID controller backend: $winebus"
  LC_ALL=C grep -aFq 'iohid_bus_init' "$winebus" ||
    fail "Wine winebus.so does not contain the macOS IOHID controller backend: $winebus"
}

metadata_contains() {
  local pattern="$1"
  LC_ALL=C tr '[:upper:]' '[:lower:]' < "$METADATA" | grep -Fq -- "$pattern"
}

is_macho() {
  local path="$1"
  file "$path" 2>/dev/null | grep -q 'Mach-O'
}

require_macho_rpath() {
  local path="$1"
  local expected="$2"
  local label="$3"
  is_macho "$path" || fail "$label must be a Mach-O file: $path"
  otool -l "$path" 2>/dev/null |
    awk '/cmd LC_RPATH/{seen=1; next} seen && /path /{print $2; seen=0}' |
    grep -Fxq "$expected" ||
    fail "$label is missing required LC_RPATH $expected: $path"
}

verify_macho_references_are_bundled() {
  local scan_root="$1"
  python3 "$MACHO_RUNTIME_CLOSURE_VERIFIER" "$scan_root" ||
    fail "Mach-O runtime dependency closure is incomplete"
}

verify_launcher_preserves_renderer_dll_precedence() {
  local launcher="$1"
  local label="$2"
  if LC_ALL=C grep -Fq 'export WINEDLLPATH="$(prepend_path "$WINE_ROOT/lib/wine' "$launcher"; then
    fail "$label must not prepend base Wine DLL paths ahead of renderer WINEDLLPATH: $launcher"
  fi
  LC_ALL=C grep -Fq 'export WINEDLLPATH="$(append_path "$WINE_ROOT/lib/wine:$WINE_ROOT/lib/wine/x86_64-unix' "$launcher" ||
    fail "$label must append root-first base Wine DLL paths after any renderer WINEDLLPATH: $launcher"
}

verify_wine_launcher_uses_installed_unix_loader() {
  local launcher="$1"
  LC_ALL=C grep -Fq 'exec "$WINE_ROOT/lib/wine/x86_64-unix/wine" "$@"' "$launcher" ||
    fail "ForgePlay Runtime wine launcher must execute the installed Unix loader beside ntdll.so: $launcher"
}

runtime_file_inventory() {
  local mode="$1"
  local runtime_root="$2"
  local inventory_path="$3"
  /usr/bin/python3 - "$mode" "$runtime_root" "$inventory_path" <<'PY'
import hashlib
import json
import os
import stat
import struct
import sys
from pathlib import PurePosixPath

mode, runtime_root, inventory_path = sys.argv[1:]
runtime_root = os.path.abspath(os.path.normpath(runtime_root))
inventory_path = os.path.abspath(os.path.normpath(inventory_path))

inventory_name = "RuntimeFileInventory.json"
manifest_name = "RuntimeManifest.json"
public_claim_name = "PublicRuntimeBuildClaim.json"
reserved_claim_paths = sorted((inventory_name, manifest_name, public_claim_name))
hash_algorithm = "sha256-macho-code-signature-normalized-v1"
signed_release_path_transforms = ["apple-d3dmetal-framework-canonical-alias-v1"]
fingerprint_domain = b"forgeplay-runtime-file-inventory-v1\n"
maximum_entry_count = 200000
maximum_file_bytes = 1024 * 1024 * 1024
maximum_total_bytes = 32 * 1024 * 1024 * 1024
maximum_inventory_bytes = 128 * 1024 * 1024
mh_magic_64 = 0xFEEDFACF
lc_segment_64 = 0x19
lc_code_signature = 0x1D


def fail_inventory(message):
    raise SystemExit(message)


def metadata_token(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
        value.st_uid,
    )


def validate_relative_path(value):
    if (
        not isinstance(value, str)
        or not value
        or len(value.encode("utf-8")) > 4096
        or "\\" in value
        or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        fail_inventory(f"runtime inventory path is unsafe: {value!r}")
    parsed = PurePosixPath(value)
    if parsed.is_absolute() or parsed.as_posix() != value or any(
        component in {"", ".", ".."} for component in parsed.parts
    ):
        fail_inventory(f"runtime inventory path is unsafe: {value!r}")


def stable_regular_bytes(path, label, maximum_bytes):
    descriptor = os.open(
        path,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
    )
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_uid != os.geteuid()
            or before.st_mode & (stat.S_IWGRP | stat.S_IWOTH | stat.S_ISUID | stat.S_ISGID)
            or before.st_size < 0
            or before.st_size > maximum_bytes
        ):
            fail_inventory(f"{label} is not a safe single-link regular file: {path}")
        payload = bytearray()
        offset = 0
        while offset < before.st_size:
            chunk = os.pread(descriptor, min(1024 * 1024, before.st_size - offset), offset)
            if not chunk:
                fail_inventory(f"{label} became incomplete while being read: {path}")
            payload.extend(chunk)
            offset += len(chunk)
        after = os.fstat(descriptor)
        if metadata_token(before) != metadata_token(after):
            fail_inventory(f"{label} changed while being read: {path}")
        return bytes(payload), before
    finally:
        os.close(descriptor)


def normalized_macho_content(data, relative):
    if len(data) < 32 or struct.unpack_from("<I", data, 0)[0] != mh_magic_64:
        return data

    normalized = bytearray(data)
    command_count, command_bytes = struct.unpack_from("<II", normalized, 16)
    command_offset = 32
    command_limit = command_offset + command_bytes
    if command_limit > len(normalized) or command_count > command_bytes // 8:
        fail_inventory(f"Mach-O load commands exceed the runtime file: {relative}")

    linkedit_offset = None
    signature_command = None
    signature_offset = None
    for _ in range(command_count):
        if command_offset + 8 > command_limit:
            fail_inventory(f"Mach-O load command header is truncated: {relative}")
        command, command_size = struct.unpack_from("<II", normalized, command_offset)
        if command_size < 8 or command_offset + command_size > command_limit:
            fail_inventory(f"Mach-O load command is invalid: {relative}")
        if command == lc_segment_64:
            if command_size < 72:
                fail_inventory(f"Mach-O segment command is truncated: {relative}")
            segment_name = bytes(normalized[command_offset + 8:command_offset + 24]).split(b"\0", 1)[0]
            if segment_name == b"__LINKEDIT":
                if linkedit_offset is not None:
                    fail_inventory(f"Mach-O contains duplicate __LINKEDIT segments: {relative}")
                linkedit_offset = command_offset
        elif command == lc_code_signature:
            if command_size != 16 or signature_command is not None:
                fail_inventory(f"Mach-O code-signature command is invalid: {relative}")
            data_offset, data_size = struct.unpack_from("<II", normalized, command_offset + 8)
            if (
                data_offset < command_limit
                or data_offset > len(normalized)
                or data_size == 0
                or data_size > len(normalized) - data_offset
                or data_offset + data_size != len(normalized)
            ):
                fail_inventory(f"Mach-O code-signature range is invalid: {relative}")
            signature_command = command_offset
            signature_offset = data_offset
        command_offset += command_size

    if command_offset != command_limit or linkedit_offset is None:
        fail_inventory(f"Mach-O load-command accounting is invalid: {relative}")

    normalized[linkedit_offset + 32:linkedit_offset + 40] = b"\0" * 8
    normalized[linkedit_offset + 48:linkedit_offset + 56] = b"\0" * 8
    if signature_command is None:
        return bytes(normalized)

    normalized[signature_command:command_limit - 16] = normalized[signature_command + 16:command_limit]
    normalized[command_limit - 16:command_limit] = b"\0" * 16
    struct.pack_into("<II", normalized, 16, command_count - 1, command_bytes - 16)
    return bytes(normalized[:signature_offset])


def content_identity(path, relative):
    data, metadata = stable_regular_bytes(path, "runtime payload", maximum_file_bytes)
    normalized = normalized_macho_content(data, relative)
    return {
        "contentByteCount": len(normalized),
        "contentSHA256": hashlib.sha256(normalized).hexdigest(),
        "executable": bool(metadata.st_mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)),
        "path": relative,
        "type": "file",
    }, metadata.st_size


def require_reserved_regular(path, label, maximum_bytes=maximum_inventory_bytes):
    data, _ = stable_regular_bytes(path, label, maximum_bytes)
    return data


def validate_claim_paths(for_write):
    root_metadata = os.lstat(runtime_root)
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        fail_inventory("runtime inventory root must be a non-symlink directory")
    expected_inventory = os.path.join(runtime_root, inventory_name)
    if inventory_path != expected_inventory:
        fail_inventory("runtime inventory must use the canonical RuntimeFileInventory.json path")
    require_reserved_regular(os.path.join(runtime_root, manifest_name), "runtime manifest")
    if for_write:
        for path in (inventory_path, os.path.join(runtime_root, public_claim_name)):
            try:
                os.lstat(path)
            except FileNotFoundError:
                pass
            else:
                fail_inventory(f"runtime claim path is already occupied: {path}")
    else:
        require_reserved_regular(inventory_path, "runtime file inventory")
        public_claim = os.path.join(runtime_root, public_claim_name)
        try:
            metadata = os.lstat(public_claim)
        except FileNotFoundError:
            pass
        else:
            if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                fail_inventory("public Runtime build claim has an unsafe type")
    return root_metadata


def scan_runtime(root_metadata):
    rows = []
    total_bytes = 0

    def visit(directory, prefix):
        nonlocal total_bytes
        before = os.lstat(directory)
        if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
            fail_inventory(f"runtime directory changed type while being inventoried: {prefix or '.'}")
        with os.scandir(directory) as iterator:
            entries = sorted(iterator, key=lambda entry: entry.name)
        for entry in entries:
            relative = entry.name if not prefix else f"{prefix}/{entry.name}"
            validate_relative_path(relative)
            if relative in reserved_claim_paths:
                continue
            metadata = entry.stat(follow_symlinks=False)
            if stat.S_ISDIR(metadata.st_mode):
                rows.append({"path": relative, "type": "directory"})
                visit(entry.path, relative)
            elif stat.S_ISREG(metadata.st_mode):
                row, physical_bytes = content_identity(entry.path, relative)
                rows.append(row)
                total_bytes += physical_bytes
            elif stat.S_ISLNK(metadata.st_mode):
                target = os.readlink(entry.path)
                if (
                    not target
                    or os.path.isabs(target)
                    or "\\" in target
                    or any(ord(character) < 32 or ord(character) == 127 for character in target)
                ):
                    fail_inventory(f"runtime symlink target is unsafe: {relative}")
                resolved = os.path.realpath(entry.path)
                try:
                    contained = os.path.commonpath((runtime_root, resolved)) == runtime_root
                except ValueError:
                    contained = False
                if not contained or not os.path.exists(resolved):
                    fail_inventory(f"runtime symlink escapes or is dangling: {relative}")
                rows.append({"linkTarget": target, "path": relative, "type": "symlink"})
            else:
                fail_inventory(f"runtime contains an unsupported entry type: {relative}")
            if len(rows) > maximum_entry_count or total_bytes > maximum_total_bytes:
                fail_inventory("runtime file inventory exceeds its size bound")
        after = os.lstat(directory)
        if metadata_token(before) != metadata_token(after):
            fail_inventory(f"runtime directory changed while being inventoried: {prefix or '.'}")

    visit(runtime_root, "")
    if metadata_token(os.lstat(runtime_root)) != metadata_token(root_metadata):
        fail_inventory("runtime root changed while being inventoried")
    rows.sort(key=lambda row: row["path"])
    entries_raw = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode("utf-8")
    fingerprint = hashlib.sha256(fingerprint_domain + entries_raw).hexdigest()
    return {
        "entries": rows,
        "fileContentHashAlgorithm": hash_algorithm,
        "payloadFingerprint": fingerprint,
        "reservedClaimPaths": reserved_claim_paths,
        "schemaVersion": 2,
        "signedReleasePathTransforms": signed_release_path_transforms,
    }


def project_signed_release_paths(value):
    rows = value["entries"]
    framework = "Frameworks/renderer/d3dmetal/external/D3DMetal.framework"
    canonical_version = f"{framework}/Versions/A"
    canonical_executable = f"{canonical_version}/D3DMetal"
    canonical_resources = f"{canonical_version}/Resources"
    current_version = f"{framework}/Versions/Current"
    alias_executable = f"{framework}/D3DMetal"
    alias_resources = f"{framework}/Resources"
    canonical_aliases = {
        current_version: {
            "linkTarget": "A",
            "path": current_version,
            "type": "symlink",
        },
        alias_executable: {
            "linkTarget": "Versions/Current/D3DMetal",
            "path": alias_executable,
            "type": "symlink",
        },
        alias_resources: {
            "linkTarget": "Versions/Current/Resources",
            "path": alias_resources,
            "type": "symlink",
        },
    }
    by_path = {row["path"]: row for row in rows}
    if not all(by_path.get(path) == row for path, row in canonical_aliases.items()):
        return value
    if any(row["path"].startswith(f"{current_version}/") for row in rows):
        fail_inventory("canonical Apple D3DMetal Current alias has materialized descendants")
    executable_row = by_path.get(canonical_executable)
    resources_row = by_path.get(canonical_resources)
    if executable_row is None or executable_row.get("type") != "file":
        fail_inventory("canonical Apple D3DMetal executable target is invalid")
    if resources_row != {"path": canonical_resources, "type": "directory"}:
        fail_inventory("canonical Apple D3DMetal Resources target is invalid")

    transformed_rows = [
        row for row in rows if row["path"] not in canonical_aliases
    ]
    projected_executable = dict(executable_row)
    projected_executable["path"] = alias_executable
    transformed_rows.append(projected_executable)
    resource_projection_count = 0
    for row in rows:
        relative = row["path"]
        if relative == canonical_resources:
            suffix = ""
        elif relative.startswith(f"{canonical_resources}/"):
            suffix = relative[len(canonical_resources):]
        else:
            continue
        projected = dict(row)
        projected["path"] = f"{alias_resources}{suffix}"
        transformed_rows.append(projected)
        resource_projection_count += 1
    if resource_projection_count == 0:
        fail_inventory("canonical Apple D3DMetal Resources projection is empty")
    transformed_rows.sort(key=lambda row: row["path"])
    transformed_entries_raw = json.dumps(
        transformed_rows,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    transformed = dict(value)
    transformed["entries"] = transformed_rows
    transformed["payloadFingerprint"] = hashlib.sha256(
        fingerprint_domain + transformed_entries_raw
    ).hexdigest()
    return transformed


def canonical_json(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def validate_inventory_schema(value, raw):
    if (
        not isinstance(value, dict)
        or set(value) != {
            "entries",
            "fileContentHashAlgorithm",
            "payloadFingerprint",
            "reservedClaimPaths",
            "schemaVersion",
            "signedReleasePathTransforms",
        }
        or value.get("schemaVersion") != 2
        or value.get("fileContentHashAlgorithm") != hash_algorithm
        or value.get("reservedClaimPaths") != reserved_claim_paths
        or value.get("signedReleasePathTransforms") != signed_release_path_transforms
        or raw != canonical_json(value)
    ):
        fail_inventory("runtime file inventory schema or canonical encoding is invalid")
    rows = value.get("entries")
    if not isinstance(rows, list) or len(rows) > maximum_entry_count:
        fail_inventory("runtime file inventory entries are invalid")
    paths = []
    for row in rows:
        if not isinstance(row, dict):
            fail_inventory("runtime file inventory row is invalid")
        row_type = row.get("type")
        expected_keys = {
            "directory": {"path", "type"},
            "file": {"contentByteCount", "contentSHA256", "executable", "path", "type"},
            "symlink": {"linkTarget", "path", "type"},
        }.get(row_type)
        if expected_keys is None or set(row) != expected_keys:
            fail_inventory("runtime file inventory row schema is invalid")
        validate_relative_path(row.get("path"))
        if row["path"] in reserved_claim_paths:
            fail_inventory("runtime file inventory must not enumerate a reserved claim path")
        if row_type == "file" and (
            not isinstance(row["contentByteCount"], int)
            or row["contentByteCount"] < 0
            or not isinstance(row["executable"], bool)
            or not isinstance(row["contentSHA256"], str)
            or len(row["contentSHA256"]) != 64
            or any(character not in "0123456789abcdef" for character in row["contentSHA256"])
        ):
            fail_inventory("runtime file inventory content identity is invalid")
        if row_type == "symlink" and not isinstance(row["linkTarget"], str):
            fail_inventory("runtime file inventory symlink target is invalid")
        paths.append(row["path"])
    if paths != sorted(paths) or len(paths) != len(set(paths)):
        fail_inventory("runtime file inventory paths are duplicated or unordered")
    entries_raw = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode("utf-8")
    expected_fingerprint = hashlib.sha256(fingerprint_domain + entries_raw).hexdigest()
    if value.get("payloadFingerprint") != expected_fingerprint:
        fail_inventory("runtime file inventory payload fingerprint is invalid")


def validate_public_claim_if_present():
    claim_path = os.path.join(runtime_root, public_claim_name)
    try:
        os.lstat(claim_path)
    except FileNotFoundError:
        return
    claim_raw = require_reserved_regular(claim_path, "public Runtime build claim", 16 * 1024 * 1024)
    try:
        claim = json.loads(claim_raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        fail_inventory(f"public Runtime build claim is unreadable: {error}")
    if claim_raw != canonical_json(claim) or not isinstance(claim, dict):
        fail_inventory("public Runtime build claim is not canonical JSON")
    manifest_raw = require_reserved_regular(
        os.path.join(runtime_root, manifest_name), "runtime manifest", 4 * 1024 * 1024
    )
    inventory_raw = require_reserved_regular(inventory_path, "runtime file inventory")
    try:
        manifest = json.loads(manifest_raw.decode("utf-8"))
        inventory = json.loads(inventory_raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        fail_inventory(f"public Runtime inventory authority is unreadable: {error}")
    base_manifest_keys = {
        "architecture",
        "corePayloadFingerprint",
        "corePayloadHashAlgorithm",
        "corePayloadSHA256",
        "hostSupportPayloadFingerprint",
        "hostSupportSBOMPath",
        "hostSupportSBOMSHA256",
        "patchApplicationOrder",
        "patchSetSHA256",
        "prefixCompatibilityFingerprint",
        "runnerBuildFingerprint",
        "runnerLauncherSHA256",
        "runtimeIdentifier",
        "schemaVersion",
        "sourceTreeSHA256",
        "wineInfSHA256",
        "wineVersion",
        "winebootSHA256",
    }
    inventory_manifest_keys = {
        "runtimeFileInventoryFingerprint",
        "runtimeFileInventoryHashAlgorithm",
        "runtimeFileInventoryPath",
        "runtimeFileInventorySHA256",
    }
    if (
        not isinstance(manifest, dict)
        or manifest_raw != canonical_json(manifest)
        or set(manifest) != base_manifest_keys | inventory_manifest_keys
        or manifest.get("schemaVersion") != 3
        or manifest.get("runtimeFileInventoryPath") != inventory_name
        or manifest.get("runtimeFileInventoryHashAlgorithm") != hash_algorithm
        or manifest.get("runtimeFileInventorySHA256")
        != hashlib.sha256(inventory_raw).hexdigest()
        or not isinstance(inventory, dict)
        or manifest.get("runtimeFileInventoryFingerprint")
        != inventory.get("payloadFingerprint")
    ):
        fail_inventory("public Runtime manifest does not bind the complete file inventory")
    manifest_sha256 = hashlib.sha256(manifest_raw).hexdigest()
    receipt = claim.get("runtimeBuildReceipt")
    outputs = receipt.get("runtimeOutputs") if isinstance(receipt, dict) else None
    if (
        claim.get("schemaVersion") != 2
        or claim.get("claimStatus") != "unsigned build claim awaiting release attestation"
        or claim.get("runtimeManifestSHA256") != manifest_sha256
        or not isinstance(outputs, dict)
        or outputs.get("runtimeManifestSHA256") != manifest_sha256
    ):
        fail_inventory("public Runtime build claim does not bind the final Runtime manifest")


root_metadata = validate_claim_paths(mode == "write")
actual = scan_runtime(root_metadata)
if mode == "write":
    payload = canonical_json(actual)
    descriptor = os.open(
        inventory_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o644,
    )
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                fail_inventory("runtime file inventory write made no progress")
            offset += written
        os.fchmod(descriptor, 0o644)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
elif mode in {"verify", "verify-signed-release"}:
    raw = require_reserved_regular(inventory_path, "runtime file inventory")
    try:
        expected = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        fail_inventory(f"runtime file inventory is unreadable: {error}")
    validate_inventory_schema(expected, raw)
    if mode == "verify-signed-release":
        actual = project_signed_release_paths(actual)
    if expected != actual:
        fail_inventory("runtime paths, types, or content differ from the complete file inventory")
    validate_public_claim_if_present()
else:
    fail_inventory("runtime file inventory mode is unsupported")
PY
}

verify_release_runtime_inventory_contract() {
  local runtime_root="$1"
  local manifest="$runtime_root/RuntimeManifest.json"
  local inventory="$runtime_root/RuntimeFileInventory.json"
  local public_claim="$runtime_root/PublicRuntimeBuildClaim.json"
  local sbom="$runtime_root/RuntimeSBOM.json"

  require_non_symlink_directory "$runtime_root" "public Release Runtime root"
  require_non_symlink_regular_file "$manifest" "public Release Runtime manifest"
  require_non_symlink_regular_file "$inventory" "public Release Runtime complete file inventory"
  require_non_symlink_regular_file "$public_claim" "public Release Runtime build claim"
  require_non_symlink_regular_file "$sbom" "public Release Runtime host-support SBOM"
  require_non_symlink_regular_file "$RUNTIME_DEPENDENCY_LOCK" "runtime dependency lock"
  require_non_symlink_regular_file "$RENDERER_PAYLOAD_LOCK" "runtime renderer payload lock"
  require_non_symlink_regular_file "$GSTREAMER_PAYLOAD_LOCK" "runtime GStreamer payload lock"
  require_non_symlink_regular_file "$RUNTIME_SBOM_TOOL" "runtime SBOM verifier"

  runtime_file_inventory verify-signed-release "$runtime_root" "$inventory" ||
    fail "public Release Runtime differs from its complete file inventory"

  /usr/bin/python3 - "$manifest" "$inventory" "$public_claim" "$sbom" <<'PY' ||
import hashlib
import json
import re
import sys
from pathlib import Path

manifest_path, inventory_path, claim_path, sbom_path = map(Path, sys.argv[1:])


def canonical_json(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def load_canonical(path, label):
    raw = path.read_bytes()
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"{label} is unreadable: {error}")
    if not isinstance(value, dict) or raw != canonical_json(value):
        raise SystemExit(f"{label} is not a canonical JSON object")
    return value, raw


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


def is_hash(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


manifest, manifest_raw = load_canonical(manifest_path, "public Release Runtime manifest")
inventory, inventory_raw = load_canonical(inventory_path, "public Release Runtime inventory")
claim, _ = load_canonical(claim_path, "public Release Runtime build claim")
sbom, sbom_raw = load_canonical(sbom_path, "public Release Runtime SBOM")

base_manifest_keys = {
    "architecture",
    "corePayloadFingerprint",
    "corePayloadHashAlgorithm",
    "corePayloadSHA256",
    "hostSupportPayloadFingerprint",
    "hostSupportSBOMPath",
    "hostSupportSBOMSHA256",
    "patchApplicationOrder",
    "patchSetSHA256",
    "prefixCompatibilityFingerprint",
    "runnerBuildFingerprint",
    "runnerLauncherSHA256",
    "runtimeIdentifier",
    "schemaVersion",
    "sourceTreeSHA256",
    "wineInfSHA256",
    "wineVersion",
    "winebootSHA256",
}
inventory_manifest_keys = {
    "runtimeFileInventoryFingerprint",
    "runtimeFileInventoryHashAlgorithm",
    "runtimeFileInventoryPath",
    "runtimeFileInventorySHA256",
}
if (
    set(manifest) != base_manifest_keys | inventory_manifest_keys
    or manifest.get("schemaVersion") != 3
    or manifest.get("runtimeIdentifier") != "com.forgeplay.runtime.wine-11.12"
    or manifest.get("architecture") != "win64"
    or manifest.get("runtimeFileInventoryPath") != "RuntimeFileInventory.json"
    or manifest.get("runtimeFileInventoryHashAlgorithm")
    != "sha256-macho-code-signature-normalized-v1"
):
    raise SystemExit("public Release Runtime manifest inventory extension is invalid")
for key in (
    "corePayloadFingerprint",
    "hostSupportPayloadFingerprint",
    "hostSupportSBOMSHA256",
    "patchSetSHA256",
    "prefixCompatibilityFingerprint",
    "runnerBuildFingerprint",
    "runnerLauncherSHA256",
    "runtimeFileInventoryFingerprint",
    "runtimeFileInventorySHA256",
    "sourceTreeSHA256",
    "wineInfSHA256",
    "winebootSHA256",
):
    if not is_hash(manifest.get(key)):
        raise SystemExit(f"public Release Runtime manifest digest is invalid: {key}")
if (
    manifest["runtimeFileInventorySHA256"] != sha256(inventory_raw)
    or manifest["runtimeFileInventoryFingerprint"] != inventory.get("payloadFingerprint")
    or manifest.get("hostSupportSBOMPath") != "RuntimeSBOM.json"
    or manifest["hostSupportSBOMSHA256"] != sha256(sbom_raw)
    or manifest["hostSupportPayloadFingerprint"] != sbom.get("payloadFingerprint")
):
    raise SystemExit("public Release Runtime manifest does not bind its inventory and SBOM")

prefix_input = (
    "forgeplay-prefix-compatibility-v1\n"
    f"wineVersion={manifest['wineVersion']}\n"
    f"architecture={manifest['architecture']}\n"
    f"wineInfSHA256={manifest['wineInfSHA256']}\n"
    f"winebootSHA256={manifest['winebootSHA256']}\n"
).encode("utf-8")
build_input = (
    "forgeplay-runtime-build-v3\n"
    f"sourceTreeSHA256={manifest['sourceTreeSHA256']}\n"
    f"patchSetSHA256={manifest['patchSetSHA256']}\n"
    f"runnerLauncherSHA256={manifest['runnerLauncherSHA256']}\n"
    f"prefixCompatibilityFingerprint={manifest['prefixCompatibilityFingerprint']}\n"
    f"hostSupportPayloadFingerprint={manifest['hostSupportPayloadFingerprint']}\n"
    f"corePayloadFingerprint={manifest['corePayloadFingerprint']}\n"
).encode("utf-8")
if (
    manifest["prefixCompatibilityFingerprint"] != sha256(prefix_input)
    or manifest["runnerBuildFingerprint"] != sha256(build_input)
):
    raise SystemExit("public Release Runtime must preserve the app-compatible v3 fingerprints")

claim_keys = {
    "claimStatus",
    "commandGraph",
    "corePayloadFingerprint",
    "currentFinalPatchedSourceTreeSHA256",
    "hostSupportPayloadFingerprint",
    "patchSetSHA256",
    "releaseCommit",
    "runnerBuildFingerprint",
    "runtimeBuildReceipt",
    "runtimeManifestSHA256",
    "schemaVersion",
    "sourceInventorySHA256",
}
receipt = claim.get("runtimeBuildReceipt")
outputs = receipt.get("runtimeOutputs") if isinstance(receipt, dict) else None
expected_outputs = {
    "corePayloadFingerprint": manifest["corePayloadFingerprint"],
    "hostSupportPayloadFingerprint": manifest["hostSupportPayloadFingerprint"],
    "patchSetSHA256": manifest["patchSetSHA256"],
    "runnerBuildFingerprint": manifest["runnerBuildFingerprint"],
    "runtimeManifestSHA256": sha256(manifest_raw),
    "sourceTreeSHA256": manifest["sourceTreeSHA256"],
}
if (
    set(claim) != claim_keys
    or claim.get("schemaVersion") != 2
    or claim.get("claimStatus") != "unsigned build claim awaiting release attestation"
    or not isinstance(receipt, dict)
    or receipt.get("schemaVersion") != 2
    or receipt.get("claimStatus") != "unsigned build claim awaiting release attestation"
    or outputs != expected_outputs
    or claim.get("runtimeManifestSHA256") != expected_outputs["runtimeManifestSHA256"]
    or claim.get("corePayloadFingerprint") != expected_outputs["corePayloadFingerprint"]
    or claim.get("hostSupportPayloadFingerprint") != expected_outputs["hostSupportPayloadFingerprint"]
    or claim.get("patchSetSHA256") != expected_outputs["patchSetSHA256"]
    or claim.get("runnerBuildFingerprint") != expected_outputs["runnerBuildFingerprint"]
    or claim.get("currentFinalPatchedSourceTreeSHA256") != expected_outputs["sourceTreeSHA256"]
):
    raise SystemExit("public Release Runtime build claim does not bind the final manifest")
PY
    fail "public Release Runtime inventory authority is invalid"

  /usr/bin/python3 "$RUNTIME_SBOM_TOOL" verify \
    "$runtime_root" \
    "$RUNTIME_DEPENDENCY_LOCK" \
    "$RENDERER_PAYLOAD_LOCK" \
    "$GSTREAMER_PAYLOAD_LOCK" \
    "$sbom" ||
    fail "public Release Runtime renderer/SBOM lock verification failed"
}

case "$INPUT_PATH" in
  --write-runtime-file-inventory)
    [[ "$#" -eq 3 ]] ||
      fail "usage: verify-bundled-runtime-capability.sh --write-runtime-file-inventory <Runtime root> <RuntimeFileInventory.json>"
    runtime_file_inventory write "$2" "$3" ||
      fail "complete Runtime file inventory could not be written"
    exit 0
    ;;
  --verify-runtime-file-inventory)
    [[ "$#" -eq 3 ]] ||
      fail "usage: verify-bundled-runtime-capability.sh --verify-runtime-file-inventory <Runtime root> <RuntimeFileInventory.json>"
    runtime_file_inventory verify "$2" "$3" ||
      fail "complete Runtime file inventory verification failed"
    exit 0
    ;;
  --release-runtime-inventory-only)
    [[ "$#" -eq 2 ]] ||
      fail "usage: verify-bundled-runtime-capability.sh --release-runtime-inventory-only <app bundle, resource root, or ForgePlayRuntime root>"
    RELEASE_RUNTIME_INVENTORY_ONLY=1
    INPUT_PATH="$2"
    ;;
esac

[[ -n "$INPUT_PATH" ]] || fail "usage: verify-bundled-runtime-capability.sh <app bundle, resource root, or ForgePlayRuntime root>"

require_boolean_flag "$REQUIRE_APP_STORE_RUNTIME" "FORGEPLAY_REQUIRE_APP_STORE_RUNTIME"
require_boolean_flag \
  "$REQUIRE_DIRECT_DMG_RUNTIME" \
  "FORGEPLAY_REQUIRE_DIRECT_DMG_RUNTIME"
if [[ "$REQUIRE_APP_STORE_RUNTIME" == "1" &&
      "$REQUIRE_DIRECT_DMG_RUNTIME" == "1" ]]; then
  fail "App Store and direct DMG runtime policies are mutually exclusive"
fi

APP_BUNDLE=""
if [[ -d "$INPUT_PATH/Contents/Resources" ]]; then
  APP_BUNDLE="$INPUT_PATH"
  RESOURCE_ROOT="$INPUT_PATH/Contents/Resources"
  RUNTIME_ROOT="$RESOURCE_ROOT/Runners/ForgePlayRuntime"
elif [[ -d "$INPUT_PATH/Runners" ]]; then
  RESOURCE_ROOT="$INPUT_PATH"
  RUNTIME_ROOT="$RESOURCE_ROOT/Runners/ForgePlayRuntime"
elif [[ -d "$INPUT_PATH/wine" && -f "$INPUT_PATH/RuntimeManifest.json" ]]; then
  RUNTIME_ROOT="$INPUT_PATH"
else
  fail "input must be an app bundle, resource root containing Runners, or ForgePlayRuntime root: $INPUT_PATH"
fi

if [[ "$RELEASE_RUNTIME_INVENTORY_ONLY" == "1" ]]; then
  verify_release_runtime_inventory_contract "$RUNTIME_ROOT" ||
    fail "public Release Runtime inventory-only gate failed"
  printf 'Verified public Release Runtime complete inventory and renderer/SBOM locks: %s\n' \
    "$RUNTIME_ROOT"
  exit 0
fi

require_non_symlink_regular_file \
  "$RUNTIME_PATCH_PROVENANCE_LOCK" \
  "runtime patch provenance lock"
require_non_symlink_regular_file \
  "$RUNTIME_PATCH_PROVENANCE_VERIFIER" \
  "runtime patch provenance verifier"
require_non_symlink_regular_file \
  "$RUNTIME_SOURCE_IDENTITY_LOCK" \
  "runtime source identity lock"
require_non_symlink_regular_file \
  "$RUNTIME_CORE_IDENTITY_TOOL" \
  "runtime core payload identity tool"
python3 "$RUNTIME_PATCH_PROVENANCE_VERIFIER" \
  --lock "$RUNTIME_PATCH_PROVENANCE_LOCK" \
  --source-identity-lock "$RUNTIME_SOURCE_IDENTITY_LOCK" \
  --patch-root "$RUNTIME_ROOT/Patches" ||
  fail "ForgePlay Runtime patch inventory changed without reviewed provenance"
WINE_ROOT="$RUNTIME_ROOT/wine"
GSTREAMER_ROOT="$WINE_ROOT/gstreamer"
GSTREAMER_PLUGIN_ROOT="$GSTREAMER_ROOT/lib/gstreamer-1.0"
D3DMETAL_RENDERER_ROOT="$RUNTIME_ROOT/Frameworks/renderer/d3dmetal"
D3DMETAL_FRAMEWORK="$D3DMETAL_RENDERER_ROOT/external/D3DMetal.framework"
APPLE_GPTK_LEGAL_ROOT="$RUNTIME_ROOT/Legal/AppleGPTK"
APPLE_GPTK_LICENSE="$APPLE_GPTK_LEGAL_ROOT/License.rtf"
APPLE_GPTK_ACKNOWLEDGEMENTS="$APPLE_GPTK_LEGAL_ROOT/Acknowledgements.rtf"
APPLE_GPTK_FRAMEWORK_LICENSE="$D3DMETAL_FRAMEWORK/Resources/LICENSE"
APPLE_GPTK_VERSIONED_FRAMEWORK_LICENSE="$D3DMETAL_FRAMEWORK/Versions/A/Resources/LICENSE"
APPLE_D3DMETAL_CODE_RESOURCES="$D3DMETAL_FRAMEWORK/Versions/A/_CodeSignature/CodeResources"
METADATA="$RUNTIME_ROOT/BUILD-METADATA.md"
RUNTIME_MANIFEST="$RUNTIME_ROOT/RuntimeManifest.json"
RUNTIME_FILE_INVENTORY="$RUNTIME_ROOT/RuntimeFileInventory.json"
RUNTIME_SBOM="$RUNTIME_ROOT/RuntimeSBOM.json"
SOURCE_AVAILABILITY="$RUNTIME_ROOT/SOURCE-AVAILABILITY.md"
WINE_LICENSE="$RUNTIME_ROOT/Legal/Wine/LICENSE"
WINE_LGPL="$RUNTIME_ROOT/Legal/Wine/COPYING.LIB"
WINE_AUTHORS="$RUNTIME_ROOT/Legal/Wine/AUTHORS"
WINE_MODIFICATIONS="$RUNTIME_ROOT/Legal/Wine/FORGEPLAY-MODIFICATIONS.md"
GAME_MODE_LEGAL_ROOT="$RUNTIME_ROOT/Legal/ForgePlayGameMode"
GAME_MODE_GPL="$GAME_MODE_LEGAL_ROOT/GPL-3.0-only.txt"
GAME_MODE_LGPL="$GAME_MODE_LEGAL_ROOT/LGPL-2.1-or-later.txt"
NANUM_GOTHIC_REGULAR="$WINE_ROOT/share/wine/fonts/NanumGothic-Regular.ttf"
NANUM_GOTHIC_BOLD="$WINE_ROOT/share/wine/fonts/NanumGothic-Bold.ttf"
NANUM_GOTHIC_OFL="$RUNTIME_ROOT/Legal/NanumGothic/OFL.txt"
NANUM_GOTHIC_SOURCE_IDENTITY="$RUNTIME_ROOT/Legal/NanumGothic/SOURCE-IDENTITY.json"

require_non_symlink_regular_file \
  "$RUNTIME_PAYLOAD_POLICY_VALIDATOR" \
  "Wine runtime-required payload policy validator"
WINE_ROOT_CANONICAL="$(cd "$WINE_ROOT" && pwd -P)" ||
  fail "ForgePlay Runtime Wine root could not be resolved"
/bin/bash "$RUNTIME_PAYLOAD_POLICY_VALIDATOR" \
  --validate-wine-runtime-payload \
  "$WINE_ROOT_CANONICAL" ||
  fail "ForgePlay Runtime omits a runtime-required Wine component or canonical language resource"

require_non_symlink_directory "$RUNTIME_ROOT" "ForgePlay Runtime root"
require_non_symlink_directory "$WINE_ROOT" "ForgePlay Runtime wine root"
require_non_symlink_directory "$WINE_ROOT/bin" "ForgePlay Runtime wine bin"
require_non_symlink_directory "$WINE_ROOT/lib" "ForgePlay Runtime wine lib"
require_non_symlink_directory "$RUNTIME_ROOT/Frameworks" "ForgePlay Runtime host Frameworks"
require_non_symlink_regular_file "$RUNTIME_ROOT/Info.plist" "ForgePlay Runtime policy Info.plist"
require_non_symlink_executable_file "$WINE_ROOT/bin/wine" "ForgePlay Runtime wine launcher"
require_non_symlink_executable_file "$WINE_ROOT/bin/wineserver" "ForgePlay Runtime wineserver launcher"
verify_runtime_wine_bin_allowlist "$WINE_ROOT/bin"
verify_launcher_preserves_renderer_dll_precedence "$WINE_ROOT/bin/wine" "ForgePlay Runtime wine launcher"
verify_launcher_preserves_renderer_dll_precedence "$WINE_ROOT/bin/wineserver" "ForgePlay Runtime wineserver launcher"
verify_wine_launcher_uses_installed_unix_loader "$WINE_ROOT/bin/wine"
if [[ -e "$WINE_ROOT/bin/wine.bin" ]]; then
  require_non_symlink_executable_file "$WINE_ROOT/bin/wine.bin" "ForgePlay Runtime Wine launcher target"
fi
if [[ -e "$WINE_ROOT/bin/wineserver.bin" ]]; then
  require_non_symlink_executable_file "$WINE_ROOT/bin/wineserver.bin" "ForgePlay Runtime wineserver launcher target"
fi
require_non_symlink_regular_file "$METADATA" "ForgePlay Runtime build metadata"
require_non_symlink_regular_file "$RUNTIME_MANIFEST" "ForgePlay Runtime identity manifest"
LEGACY_RUNTIME_MANIFEST=0
if [[ -e "$RUNTIME_FILE_INVENTORY" || -L "$RUNTIME_FILE_INVENTORY" ]]; then
  require_non_symlink_regular_file "$RUNTIME_FILE_INVENTORY" "ForgePlay Runtime complete file inventory"
  RUNTIME_FILE_INVENTORY_MODE="verify"
  if [[ -e "$RUNTIME_ROOT/PublicRuntimeBuildClaim.json" ||
        -L "$RUNTIME_ROOT/PublicRuntimeBuildClaim.json" ]]; then
    RUNTIME_FILE_INVENTORY_MODE="verify-signed-release"
  fi
  runtime_file_inventory \
    "$RUNTIME_FILE_INVENTORY_MODE" \
    "$RUNTIME_ROOT" \
    "$RUNTIME_FILE_INVENTORY" ||
    fail "ForgePlay Runtime paths, types, or content differ from its complete file inventory"
elif [[ -e "$RUNTIME_ROOT/PublicRuntimeBuildClaim.json" ||
        -L "$RUNTIME_ROOT/PublicRuntimeBuildClaim.json" ]]; then
  fail "public Runtime build claim requires the complete Runtime file inventory"
else
  # Checked-in/App Store Runtime schema 3 remains readable without the
  # public-release additive inventory fields. Every public-source Runtime
  # carries PublicRuntimeBuildClaim.json and must take the exact-inventory path.
  LEGACY_RUNTIME_MANIFEST=1
fi
require_non_symlink_regular_file "$RUNTIME_SBOM" "ForgePlay Runtime host-support SBOM"
require_non_symlink_regular_file "$RUNTIME_DEPENDENCY_LOCK" "ForgePlay Runtime dependency lock"
require_non_symlink_regular_file "$RENDERER_PAYLOAD_LOCK" "ForgePlay Runtime renderer payload lock"
require_non_symlink_regular_file "$GSTREAMER_PAYLOAD_LOCK" "ForgePlay Runtime GStreamer payload lock"
require_non_symlink_regular_file "$RUNTIME_SBOM_TOOL" "ForgePlay Runtime SBOM verifier"
require_non_symlink_regular_file "$SOURCE_AVAILABILITY" "ForgePlay Runtime source availability notice"
require_non_symlink_regular_file "$WINE_LICENSE" "Wine license notice"
require_non_symlink_regular_file "$WINE_LGPL" "Wine LGPL text"
require_non_symlink_regular_file "$WINE_AUTHORS" "Wine authors attribution"
require_file_sha256 \
  "$WINE_MODIFICATIONS" \
  "$FORGEPLAY_WINE_MODIFICATIONS_SHA256" \
  "ForgePlay Wine modifications notice"
require_file_sha256 \
  "$GAME_MODE_GPL" \
  "$GPL_3_ONLY_LICENSE_SHA256" \
  "ForgePlay Game Mode GPL-3.0-only license"
require_file_sha256 \
  "$GAME_MODE_LGPL" \
  "$LGPL_2_1_LICENSE_SHA256" \
  "ForgePlay Game Mode LGPL-2.1-or-later license"
for game_mode_notice in \
  GAME_MODE_FILE_LICENSES.json \
  GAME_MODE_LICENSE_SCOPE.md \
  GAME_MODE_NOTICE \
  GAME_MODE_SYMBOL_MANIFEST.md; do
  require_non_symlink_regular_file \
    "$GAME_MODE_LEGAL_ROOT/$game_mode_notice" \
    "ForgePlay Game Mode license notice"
done
require_file_sha256 \
  "$NANUM_GOTHIC_REGULAR" \
  "$NANUM_GOTHIC_REGULAR_SHA256" \
  "Nanum Gothic Regular font payload"
require_file_sha256 \
  "$NANUM_GOTHIC_BOLD" \
  "$NANUM_GOTHIC_BOLD_SHA256" \
  "Nanum Gothic Bold font payload"
require_file_sha256 \
  "$NANUM_GOTHIC_OFL" \
  "$NANUM_GOTHIC_OFL_SHA256" \
  "Nanum Gothic OFL license"
require_file_sha256 \
  "$NANUM_GOTHIC_SOURCE_IDENTITY" \
  "$NANUM_GOTHIC_SOURCE_IDENTITY_SHA256" \
  "Nanum Gothic source identity"
require_non_symlink_regular_file "$MACHO_RUNTIME_CLOSURE_VERIFIER" "Mach-O runtime closure verifier"
grep -Fq 'https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz' "$SOURCE_AVAILABILITY" ||
  fail "ForgePlay Runtime source notice must identify the corresponding Wine source archive"
grep -Fq 'Patches/' "$SOURCE_AVAILABILITY" ||
  fail "ForgePlay Runtime source notice must identify the ForgePlay Wine patch set"
grep -Fq 'Legal/Wine/FORGEPLAY-MODIFICATIONS.md' "$SOURCE_AVAILABILITY" ||
  fail "ForgePlay Runtime source notice must identify the modification-license boundary"
grep -Fq 'must be conveyed consistently with that scope.' "$SOURCE_AVAILABILITY" ||
  fail "ForgePlay Runtime source notice must preserve the reviewed LGPL/GPL boundary"
verify_winebus_iohid_backend "$WINE_ROOT/lib/wine/x86_64-unix/winebus.so"
require_non_symlink_directory "$GSTREAMER_ROOT" "ForgePlay Runtime GStreamer root"
require_non_symlink_directory "$GSTREAMER_PLUGIN_ROOT" "ForgePlay Runtime GStreamer plugin root"
for media_runtime_file in \
  "$WINE_ROOT/lib/wine/x86_64-unix/winegstreamer.so" \
  "$WINE_ROOT/lib/wine/i386-windows/winegstreamer.dll" \
  "$WINE_ROOT/lib/wine/x86_64-windows/winegstreamer.dll" \
  "$WINE_ROOT/lib/wine/i386-windows/mfplat.dll" \
  "$WINE_ROOT/lib/wine/x86_64-windows/mfplat.dll" \
  "$GSTREAMER_PLUGIN_ROOT/libgstasf.dylib" \
  "$GSTREAMER_PLUGIN_ROOT/libgstdeinterlace.dylib" \
  "$GSTREAMER_PLUGIN_ROOT/libgstisomp4.dylib" \
  "$GSTREAMER_PLUGIN_ROOT/libgstapplemedia.dylib" \
  "$GSTREAMER_PLUGIN_ROOT/libgstlibav.dylib" \
  "$GSTREAMER_PLUGIN_ROOT/libgstvideofilter.dylib"; do
  require_non_symlink_regular_file "$media_runtime_file" "ForgePlay Runtime Media Foundation payload"
done
for mfplat_binary in \
  "$WINE_ROOT/lib/wine/i386-windows/mfplat.dll" \
  "$WINE_ROOT/lib/wine/x86_64-windows/mfplat.dll"; do
  binary_contains_text \
    "$mfplat_binary" \
    'is unavailable, using a system-memory video buffer.' ||
    fail "Wine Media Foundation module is missing the unsupported-video system-memory fallback: $mfplat_binary"
done
for winegstreamer_caps_binary_marker in \
  'Unable to get audio info from non-fixed or invalid caps.' \
  'Unable to get video info from non-fixed or invalid caps.' \
  'Non-fixed caps intersection result:'; do
  binary_contains_text \
    "$WINE_ROOT/lib/wine/x86_64-unix/winegstreamer.so" \
    "$winegstreamer_caps_binary_marker" ||
    fail "Wine GStreamer module is missing the fixed/non-fixed caps contract: $winegstreamer_caps_binary_marker"
done
for runtime_launcher in "$WINE_ROOT/bin/wine" "$WINE_ROOT/bin/wineserver"; do
  grep -Fq 'export GST_PLUGIN_SYSTEM_PATH_1_0=""' "$runtime_launcher" ||
    fail "runtime launcher must disable host GStreamer system plug-ins: $runtime_launcher"
  grep -Fq 'GSTREAMER_PLUGINS="$GSTREAMER_LIB/gstreamer-1.0"' "$runtime_launcher" ||
    fail "runtime launcher must expose the isolated GStreamer plug-in root: $runtime_launcher"
done

unexpected_framework_entry="$({
  find "$RUNTIME_ROOT/Frameworks" -mindepth 1 -maxdepth 1 ! -name renderer -print
} 2>/dev/null | head -1)"
if [[ -n "$unexpected_framework_entry" ]]; then
  printf '%s\n' "$unexpected_framework_entry" >&2
  fail "Frameworks contains an undeclared top-level entry; only the locked renderer payload is allowed"
fi
if [[ -e "$RUNTIME_ROOT/Frameworks/renderer" || -L "$RUNTIME_ROOT/Frameworks/renderer" ]]; then
  require_non_symlink_directory \
    "$RUNTIME_ROOT/Frameworks/renderer" \
    "ForgePlay Runtime locked renderer payload"
fi
if grep -Fq '$RUNTIME_ROOT/Frameworks' "$WINE_ROOT/bin/wine" ||
   grep -Fq '$RUNTIME_ROOT/Frameworks' "$WINE_ROOT/bin/wineserver"; then
  fail "runtime launchers must not expose copied top-level Frameworks through DYLD fallback paths"
fi
python3 "$RUNTIME_SBOM_TOOL" verify \
  "$RUNTIME_ROOT" \
  "$RUNTIME_DEPENDENCY_LOCK" \
  "$RENDERER_PAYLOAD_LOCK" \
  "$GSTREAMER_PAYLOAD_LOCK" \
  "$RUNTIME_SBOM" || fail "ForgePlay Runtime host-support SBOM verification failed"
if [[ -d "$D3DMETAL_FRAMEWORK" ]]; then
  verify_d3dmetal_framework_alias_contract
fi

unexpected_runtime_symlink=""
while IFS= read -r -d '' runtime_symlink; do
  if is_allowed_d3dmetal_shared_unix_module_link_path "$runtime_symlink"; then
    require_d3dmetal_shared_unix_module_link "$(basename "$runtime_symlink" .so)"
    continue
  fi
  if is_allowed_d3dmetal_framework_alias_path "$runtime_symlink"; then
    continue
  fi
  unexpected_runtime_symlink="$runtime_symlink"
  break
done < <(find "$RUNTIME_ROOT" -type l -print0)
if [[ -n "$unexpected_runtime_symlink" ]]; then
  printf '%s\n' "$unexpected_runtime_symlink" >&2
  fail "ForgePlay Runtime contains an unapproved symlink"
fi

hardlinked_file="$(
  find "$RUNTIME_ROOT" -type f -exec sh -c '
    for path do
      links=$(stat -f "%l" "$path" 2>/dev/null || printf 0)
      if [ "$links" != "1" ]; then
        printf "%s\n" "$path"
        exit 0
      fi
    done
  ' sh {} + | head -1
)"
if [[ -n "$hardlinked_file" ]]; then
  printf '%s\n' "$hardlinked_file" >&2
  fail "ForgePlay Runtime must not contain hardlinked files"
fi

prohibited_runtime_payload="$({
  find "$RUNTIME_ROOT" -type f \( \
    -iname 'SteamSetup.exe' -o \
    -iname 'vc_redist*.exe' -o \
    -iname 'vcredist*.exe' -o \
    -iname 'DXSETUP.exe' -o \
    -iname 'dotnet*setup*.exe' -o \
    -iname 'directx*setup*.exe' -o \
    -iname 'MicrosoftEdgeWebView2*setup*.exe' \
  \) -print
} 2>/dev/null || true)"
if [[ -n "$prohibited_runtime_payload" ]]; then
  printf '%s\n' "$prohibited_runtime_payload" >&2
  fail "ForgePlay Runtime must not bundle external Windows installers"
fi

if metadata_contains "--without-gnutls" ||
   metadata_contains "without gnutls" ||
   metadata_contains "does not include gnutls/schannel" ||
   metadata_contains "does not include gnutls"; then
  fail "ForgePlay Runtime was built without GnuTLS/Schannel; Windows Steam sign-in/update TLS is not release-ready"
fi

if metadata_contains "steam-cef-webhelper-renderer-validation-failed" ||
   metadata_contains "steam cef/webhelper ui validation: failed" ||
   metadata_contains "steam cef webhelper ui validation failed" ||
   metadata_contains "windows steam cef/webhelper rendering failed"; then
  fail "ForgePlay Runtime metadata records failed Windows Steam CEF/WebHelper UI rendering validation; do not treat this runtime as release-capable"
fi

HAS_GNUTLS_RUNTIME="0"
if find "$WINE_ROOT" -type f -iname 'libgnutls*.dylib' -print -quit | grep -q .; then
  HAS_GNUTLS_RUNTIME="1"
fi

HAS_FREETYPE_RUNTIME="0"
if find "$WINE_ROOT" -type f -iname 'libfreetype*.dylib' -print -quit | grep -q .; then
  HAS_FREETYPE_RUNTIME="1"
fi

HAS_SCHANNEL_X86="0"
if find "$WINE_ROOT/lib/wine" -type f -path '*/i386-windows/schannel.dll' -print -quit | grep -q .; then
  HAS_SCHANNEL_X86="1"
fi

HAS_SCHANNEL_X86_64="0"
if find "$WINE_ROOT/lib/wine" -type f -path '*/x86_64-windows/schannel.dll' -print -quit | grep -q .; then
  HAS_SCHANNEL_X86_64="1"
fi

if [[ "$HAS_GNUTLS_RUNTIME" != "1" ||
      "$HAS_SCHANNEL_X86" != "1" ||
      "$HAS_SCHANNEL_X86_64" != "1" ]]; then
  fail "ForgePlay Runtime TLS backend requires bundled GnuTLS plus both i386/x86_64 schannel.dll files; found gnutls=$HAS_GNUTLS_RUNTIME schannel_i386=$HAS_SCHANNEL_X86 schannel_x86_64=$HAS_SCHANNEL_X86_64"
fi

if [[ "$HAS_FREETYPE_RUNTIME" != "1" ]]; then
  fail "ForgePlay Runtime font rendering requires bundled FreeType"
fi

WINEMAC_DRIVER="$WINE_ROOT/lib/wine/x86_64-unix/winemac.so"
require_non_symlink_regular_file "$WINEMAC_DRIVER" "Wine mac driver"
for game_mode_host_icon_marker in \
  FORGEPLAY_GAME_MODE_HOST_ROUTED \
  'preserving fixed Game Mode host application icon'; do
  binary_contains_text "$WINEMAC_DRIVER" "$game_mode_host_icon_marker" ||
    fail "ForgePlay Runtime Wine mac driver does not preserve the fixed Game Mode host icon: $game_mode_host_icon_marker"
done
if winemac_driver_has_unsupported_steam_cef_surface_marker "$WINEMAC_DRIVER"; then
  fail "ForgePlay Runtime Wine mac driver cannot render Windows Steam CEF child-window Metal swapchains; Windows Steam login is expected to be black"
fi
if ! winemac_driver_has_supported_steam_cef_surface_marker "$WINEMAC_DRIVER"; then
  fail "ForgePlay Runtime Wine mac driver does not contain the required cross-process Steam CEF client-surface implementation"
fi
if ! winemac_driver_exports_metal_window_surface_contract "$WINEMAC_DRIVER"; then
  fail "ForgePlay Runtime Wine mac driver does not export the Metal renderer window-surface contract (_macdrv_functions)"
fi
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-steam-cef-other-process-opengl-surface.patch" \
  "ForgePlay Wine Steam CEF OpenGL client-surface patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-forgeplay-metal-window-surface-contract.patch" \
  "independent ForgePlay Metal renderer window-surface contract patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-forgeplay-d3dmetal-bridge.patch" \
  "independent ForgePlay D3DMetal bridge patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-forgeplay-d3dmetal-bridge-contract.md" \
  "ForgePlay D3DMetal public behavior contract"
EXTERNAL_STORAGE_GRANT_PATCH="$RUNTIME_ROOT/Patches/wine-11.12-external-storage-grant-activation.patch"
require_non_symlink_regular_file \
  "$EXTERNAL_STORAGE_GRANT_PATCH" \
  "ForgePlay Wine external-storage grant activation patch"
for marker in \
  'diff --git a/dlls/ntdll/unix/loader.c' \
  'diff --git a/server/main.c' \
  FORGEPLAY_EXTERNAL_STORAGE_BRIDGE \
  FORGEPLAY_EXTERNAL_STORAGE_GRANT_FILE \
  FORGEPLAY_EXTERNAL_STORAGE_GRANT_SHA256 \
  FORGEPLAY_EXTERNAL_STORAGE_GRANT_RUN_ID \
  FORGEPLAY_EXTERNAL_STORAGE_GRANT_V1 \
  FPActivateExternalStorageGrantManifest \
  'RTLD_NOW | RTLD_LOCAL' \
  'status=failed reason=incomplete-environment'; do
  grep -Fq "$marker" "$EXTERNAL_STORAGE_GRANT_PATCH" ||
    fail "ForgePlay external-storage grant activation patch is missing its source marker: $marker"
done
GAME_MODE_TARGET_SCOPE_PATCH="$RUNTIME_ROOT/Patches/wine-11.12-game-mode-direct-target-scope.patch"
require_non_symlink_regular_file \
  "$GAME_MODE_TARGET_SCOPE_PATCH" \
  "ForgePlay Wine Game Mode direct-target scope patch"
for marker in \
  'diff --git a/dlls/ntdll/unix/process.c' \
  'diff --git a/dlls/ntdll/unix/loader.c' \
  'diff --git a/dlls/winemac.drv/window.c' \
  forgeplay_game_mode_image_path_is_eligible \
  eligible_game_target \
  FORGEPLAY_GAME_MODE_DIRECT_TARGET \
  FORGEPLAY_GAME_MODE_HOST_ROUTED \
  '&params->ImagePathName' \
  'preserving fixed Game Mode host application icon' \
  loader_route_skipped_game_mode_not_requested \
  loader_route_skipped_non_game_target \
  'unsetenv( "FORGEPLAY_STEAM_GAME_PROCESS" )' \
  '"steamapps"' \
  '"common"' \
  '"_CommonRedist"'; do
  grep -Fq "$marker" "$GAME_MODE_TARGET_SCOPE_PATCH" ||
    fail "ForgePlay Game Mode direct-target scope patch is missing its source marker: $marker"
done
for removed_marker in \
  parent_game_lineage \
  'direct_game_target = !parent_game_lineage'; do
  ! grep -Fq "$removed_marker" "$GAME_MODE_TARGET_SCOPE_PATCH" ||
    fail "ForgePlay Game Mode target scope still blocks launcher descendants: $removed_marker"
done
MANAGED_PROCESS_JOURNAL_PATCH="$RUNTIME_ROOT/Patches/wine-11.12-managed-darwin-process-journal.patch"
require_non_symlink_regular_file \
  "$MANAGED_PROCESS_JOURNAL_PATCH" \
  "ForgePlay Wine managed Darwin process journal patch"
for marker in \
  'forgeplay_record_managed_wine_process( "wine-loader" )' \
  'forgeplay_record_managed_wine_process( "wineserver" )' \
  FORGEPLAY_MANAGED_WINE_PROCESS_EVIDENCE_FILE \
  FORGEPLAY_MANAGED_WINE_PROCESS_RUN_ID \
  FORGEPLAY_MANAGED_WINE_PREFIX_SCOPE \
  FORGEPLAY_MANAGED_WINE_RUNTIME_FINGERPRINT \
  FORGEPLAY_MANAGED_APPLICATION_OWNER_PID \
  FORGEPLAY_MANAGED_APPLICATION_OWNER_START_US \
  FORGEPLAY_MANAGED_WINE_OWNER_V1 \
  forgeplay_start_application_owner_monitor \
  EVFILT_PROC \
  NOTE_EXIT \
  'The managed-process identity belongs to the trusted Unix launch' \
  process_started_at_unix_microseconds; do
  grep -Fq "$marker" "$MANAGED_PROCESS_JOURNAL_PATCH" ||
    fail "ForgePlay managed Darwin process journal patch is missing its source marker: $marker"
done
for marker in \
  dlls/ntdll/unix/forgeplay_d3dmetal.c \
  FORGEPLAY_D3DMETAL_BRIDGE \
  FORGEPLAY_D3DMETAL_TARGET \
  FORGEPLAY_D3DMETAL_SHARED_LIBRARY \
  supports_non_native_code_regions \
  register_non_native_code_region \
  forgeplay_d3dmetal_activate \
  forgeplay_d3dmetal_register_image; do
  grep -Fq "$marker" "$RUNTIME_ROOT/Patches/wine-11.12-forgeplay-d3dmetal-bridge.patch" ||
    fail "independent ForgePlay D3DMetal bridge patch is missing its source contract marker: $marker"
done
for marker in \
  FORGEPLAY_D3DMETAL_NATIVE_THREAD_CONTEXT \
  native_thread_context \
  forgeplay_restore_native_thread_context; do
  grep -Fq "$marker" "$RUNTIME_ROOT/Patches/wine-11.12-d3dmetal-native-thread-context.patch" ||
    fail "ForgePlay D3DMetal native thread-context patch is missing its source contract marker: $marker"
done
for marker in \
  'Instrumentation[0]' \
  forgeplay_sync_native_static_tls \
  localtime_r \
  gmtime_r \
  ctime_r \
  asctime_r; do
  grep -Fq "$marker" "$RUNTIME_ROOT/Patches/wine-11.12-d3dmetal-native-thread-state-sync.patch" ||
    fail "ForgePlay D3DMetal native thread-state synchronization patch is missing its source contract marker: $marker"
done
for marker in \
  macdrv_functions \
  metal_surface_init_display_devices \
  get_win_data \
  release_win_data \
  macdrv_on_main_thread \
  macdrv_view_create_metal_view \
  macdrv_view_get_metal_layer \
  macdrv_view_release_metal_view \
  'C_ASSERT(offsetof'; do
  grep -Fq "$marker" "$RUNTIME_ROOT/Patches/wine-11.12-forgeplay-metal-window-surface-contract.patch" ||
    fail "independent ForgePlay Metal renderer window-surface patch is missing its ABI contract marker: $marker"
done

WINE_NTDLL_UNIX="$WINE_ROOT/lib/wine/x86_64-unix/ntdll.so"
WINE_SECUR32_UNIX="$WINE_ROOT/lib/wine/x86_64-unix/secur32.so"
WINE_LOADER_UNIX="$WINE_ROOT/lib/wine/x86_64-unix/wine"
WINE_BIN_LOADER="$WINE_ROOT/bin/wine.bin"
WINESERVER_BINARY="$WINE_ROOT/bin/wineserver.bin"
WINEBOOT_BINARY="$WINE_ROOT/lib/wine/x86_64-windows/wineboot.exe"
WINE_KERNELBASE_X86="$WINE_ROOT/lib/wine/i386-windows/kernelbase.dll"
WINE_KERNELBASE_X86_64="$WINE_ROOT/lib/wine/x86_64-windows/kernelbase.dll"
WINE_NTDLL_X86="$WINE_ROOT/lib/wine/i386-windows/ntdll.dll"
WINE_NTDLL_X86_64="$WINE_ROOT/lib/wine/x86_64-windows/ntdll.dll"
WINE_NSI_X86="$WINE_ROOT/lib/wine/i386-windows/nsi.dll"
WINE_NSI_X86_64="$WINE_ROOT/lib/wine/x86_64-windows/nsi.dll"
WINE_COREAUDIO_UNIX="$WINE_ROOT/lib/wine/x86_64-unix/winecoreaudio.so"
WINE_WIN32U_UNIX="$WINE_ROOT/lib/wine/x86_64-unix/win32u.so"
WINE_DWRITE_X86="$WINE_ROOT/lib/wine/i386-windows/dwrite.dll"
WINE_DWRITE_X86_64="$WINE_ROOT/lib/wine/x86_64-windows/dwrite.dll"
require_non_symlink_regular_file "$WINE_NTDLL_UNIX" "Wine ntdll Unix module"
require_non_symlink_regular_file "$WINE_SECUR32_UNIX" "Wine secur32 Unix module"
require_non_symlink_executable_file "$WINE_LOADER_UNIX" "Wine Unix loader"
require_non_symlink_executable_file "$WINE_BIN_LOADER" "Wine bin loader"
require_non_symlink_regular_file "$WINESERVER_BINARY" "Wine server binary"
require_non_symlink_regular_file "$WINEBOOT_BINARY" "Wine prefix bootstrap binary"
require_non_symlink_regular_file "$WINE_KERNELBASE_X86" "Wine i386 kernelbase"
require_non_symlink_regular_file "$WINE_KERNELBASE_X86_64" "Wine x86_64 kernelbase"
require_non_symlink_regular_file "$WINE_NTDLL_X86" "Wine i386 ntdll"
require_non_symlink_regular_file "$WINE_NTDLL_X86_64" "Wine x86_64 ntdll"
require_non_symlink_regular_file "$WINE_NSI_X86" "Wine i386 NSI module"
require_non_symlink_regular_file "$WINE_NSI_X86_64" "Wine x86_64 NSI module"
require_non_symlink_regular_file "$WINE_COREAUDIO_UNIX" "Wine CoreAudio Unix module"
require_non_symlink_regular_file "$WINE_WIN32U_UNIX" "Wine GDI font module"
binary_contains_text "$WINE_WIN32U_UNIX" 'libvulkan.1.dylib' ||
  fail "Wine win32u host backend is missing the required Vulkan loader binding"
if binary_contains_text "$WINE_WIN32U_UNIX" 'Wine was built without Vulkan support.'; then
  fail "Wine win32u host backend was compiled without Vulkan support"
fi
require_non_symlink_regular_file "$WINE_DWRITE_X86" "Wine i386 DirectWrite font module"
require_non_symlink_regular_file "$WINE_DWRITE_X86_64" "Wine x86_64 DirectWrite font module"
python3 - "$RUNTIME_ROOT/Info.plist" <<'PY' ||
import plistlib
import sys
from pathlib import Path

policy = plistlib.loads(Path(sys.argv[1]).read_bytes())
expected_keys = {"D3DMETAL", "D9VK", "DXMT", "DXVK", "WINEDEBUG"}
if set(policy) != expected_keys:
    raise SystemExit("ForgePlay Runtime policy contains undeclared keys")
PY
  fail "ForgePlay Runtime policy must contain only the current renderer and debug contracts"
require_non_symlink_regular_file "$CLEAN_WINE_MARKER_VERIFIER" "clean Wine marker verifier"
require_non_symlink_regular_file "$BUILD_PATH_VERIFIER" "Wine Runtime build-path verifier"
python3 "$BUILD_PATH_VERIFIER" "$WINE_ROOT/bin" "$WINE_ROOT/lib/wine" ||
  fail "Wine Runtime contains a developer-machine build path"
python3 "$CLEAN_WINE_MARKER_VERIFIER" "$WINE_NTDLL_UNIX" "$WINESERVER_BINARY" ||
  fail "Wine runtime retains a removed contract; a clean Wine 11.12 rebuild is required"
for marker in \
  FORGEPLAY_D3DMETAL_BRIDGE \
  FORGEPLAY_D3DMETAL_TARGET \
  FORGEPLAY_D3DMETAL_SHARED_LIBRARY \
  supports_non_native_code_regions \
  register_non_native_code_region; do
  binary_contains_text "$WINE_NTDLL_UNIX" "$marker" ||
    fail "Wine Unix ntdll is missing the independent ForgePlay D3DMetal contract marker: $marker"
done
for binary in "$WINE_NTDLL_UNIX" "$WINESERVER_BINARY"; do
  for marker in \
    FORGEPLAY_EXTERNAL_STORAGE_BRIDGE \
    FORGEPLAY_EXTERNAL_STORAGE_GRANT_FILE \
    FORGEPLAY_EXTERNAL_STORAGE_GRANT_SHA256 \
    FORGEPLAY_EXTERNAL_STORAGE_GRANT_RUN_ID \
    FORGEPLAY_EXTERNAL_STORAGE_GRANT_V1 \
    FPActivateExternalStorageGrantManifest; do
    binary_contains_text "$binary" "$marker" ||
      fail "Wine external-storage grant activation is missing from $binary: $marker"
  done
done
for binary in "$WINE_KERNELBASE_X86" "$WINE_KERNELBASE_X86_64"; do
  binary_contains_text "$binary" 'FORGEPLAY_D3DMETAL_SHARED_LIBRARY' ||
    fail "D3DMetal shared-library selection must be promoted only at the game-process boundary: $binary"
done
for module in "$WINE_WIN32U_UNIX" "$WINE_DWRITE_X86" "$WINE_DWRITE_X86_64"; do
  binary_contains_text "$module" 'ForcedReplacements' ||
    fail "Wine font module is missing ForgePlay forced-family replacement support: $module"
done
while IFS= read -r -d '' unix_module; do
  is_macho "$unix_module" || continue
  require_macho_rpath "$unix_module" "@loader_path/../.." "Wine Unix module bundled library search path"
done < <(find "$WINE_ROOT/lib/wine/x86_64-unix" -maxdepth 1 -type f -print0)
require_macho_rpath "$WINE_BIN_LOADER" "@loader_path/../lib" "Wine bin loader bundled library search path"
LC_ALL=C grep -aFq 'unknown loader error' "$WINE_SECUR32_UNIX" ||
  fail "Wine secur32 must record the native loader error when bundled GnuTLS cannot be opened"
for binary in "$WINE_KERNELBASE_X86" "$WINE_KERNELBASE_X86_64"; do
  binary_contains_text "$binary" 'FORGEPLAY_PROCESS_ARGUMENT_TARGET' ||
    fail "ForgePlay Runtime must scope host compatibility arguments to one selected executable role: $binary"
  binary_contains_text "$binary" 'FORGEPLAY_PROCESS_ARGUMENT_APPEND' ||
    fail "ForgePlay Runtime must carry bounded host compatibility arguments outside updater-owned files: $binary"
  binary_contains_text "$binary" 'FORGEPLAY_PROCESS_ARGUMENT_ROOT_ONLY' ||
    fail "ForgePlay Runtime must support optional Chromium root-only argument scoping: $binary"
  binary_contains_text "$binary" 'FORGEPLAY_PROCESS_OBSERVATION_TARGET' ||
    fail "ForgePlay Runtime must select process observation independently from argument mutation: $binary"
  binary_contains_text "$binary" 'FORGEPLAY_PROCESS_V1' ||
    fail "ForgePlay Runtime must record the final command line for the selected executable role: $binary"
  binary_contains_text "$binary" 'ForgePlay Steam game renderer process policy for' ||
    fail "ForgePlay Runtime must evaluate the process-scoped Direct3D route at the Steam game boundary; policy support is missing from $binary"
  binary_contains_text "$binary" 'FORGEPLAY_GAME_RENDERER_ROUTE_V2' ||
    fail "ForgePlay Runtime must record the process-scoped Direct3D route decision: $binary"
  binary_contains_text "$binary" 'FORGEPLAY_GAME_RENDERER_ENVIRONMENT_V1' ||
    fail "ForgePlay Runtime must record renderer environment operation failures: $binary"
  binary_contains_text "$binary" 'FORGEPLAY_GAME_RENDERER_FALLBACK_V1' ||
    fail "ForgePlay Runtime must preserve game launch through renderer-policy fallback: $binary"
  binary_contains_text "$binary" 'FORGEPLAY_STEAM_GAME_CEF_BROWSER_POLICY_ENABLED' ||
    fail "ForgePlay Runtime must contain the opt-in Steam game CEF browser policy: $binary"
  binary_contains_text "$binary" 'enabled in-process GPU for Steam game CEF browser process' ||
    fail "ForgePlay Runtime must contain the scoped Steam game CEF browser action: $binary"
  for marker in \
    FORGEPLAY_GAME_RENDERER_ENV_D3DM_VENDOR_ID \
    FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NETWORK_PROFILE \
    FORGEPLAY_NETWORK_PROFILE_REQUESTED \
    FORGEPLAY_AUDIO_INPUT_MODE; do
    binary_contains_text "$binary" "$marker" ||
      fail "ForgePlay Runtime kernelbase is missing a Steam compatibility control: $binary: $marker"
  done
done
for marker in D3DM_VENDOR_ID FORGEPLAY_NETWORK_PROFILE FORGEPLAY_AUDIO_INPUT_MODE; do
  binary_contains_text "$WINE_NTDLL_UNIX" "$marker" ||
    fail "ForgePlay Runtime ntdll is missing child compatibility environment synchronization: $marker"
done
for binary in "$WINE_NSI_X86" "$WINE_NSI_X86_64"; do
  for marker in FORGEPLAY_NETWORK_PROFILE wifi-identity ethernet-identity; do
    binary_contains_text "$binary" "$marker" ||
      fail "ForgePlay Runtime NSI module is missing network presentation support: $binary: $marker"
  done
done
for marker in FORGEPLAY_AUDIO_INPUT_MODE disabled enabled; do
  binary_contains_text "$WINE_COREAUDIO_UNIX" "$marker" ||
    fail "ForgePlay Runtime CoreAudio module is missing audio-input visibility support: $marker"
done
LC_ALL=C grep -aFq 'synchronized ForgePlay Steam game process Unix environment' "$WINE_NTDLL_UNIX" ||
  fail "ForgePlay Runtime must synchronize each Steam game child's routed or restored host environment"
LC_ALL=C grep -aFq 'prioritized ForgePlay Steam game renderer builtin path' "$WINE_NTDLL_UNIX" ||
  fail "ForgePlay Runtime must resolve game renderer builtins before the base Wine module directory"
for game_mode_marker in \
  FORGEPLAY_GAME_MODE_HOST_ENABLED \
  FORGEPLAY_GAME_MODE_DIRECT_TARGET \
  loader_contract_rejected \
  loader_exec_failed \
  loader_route_skipped_game_mode_not_requested \
  loader_route_skipped_non_game_target; do
  binary_contains_text "$WINE_NTDLL_UNIX" "$game_mode_marker" ||
    fail "ForgePlay Runtime must contain the Game Mode loader-host routing contract marker: $game_mode_marker"
done
for binary in "$WINE_NTDLL_X86" "$WINE_NTDLL_X86_64"; do
  LC_ALL=C grep -aFq 'applied ForgePlay Steam game renderer DLL search path' "$binary" ||
    fail "ForgePlay Runtime must prepend the architecture-specific renderer DLL path before game imports: $binary"
done
for binary in "$WINE_NTDLL_UNIX" "$WINESERVER_BINARY"; do
  if ! LC_ALL=C grep -aFq 'WINE_SERVER_ROOT' "$binary"; then
    fail "ForgePlay Runtime must keep Wine client/server IPC in a ForgePlay-managed writable root; WINE_SERVER_ROOT support is missing from $binary"
  fi
  if ! LC_ALL=C grep -aFq 'WINE_MACH_SERVICE_NAME' "$binary"; then
    fail "ForgePlay Runtime must register Wine Mach IPC in the App Group namespace; WINE_MACH_SERVICE_NAME support is missing from $binary"
  fi
done
LC_ALL=C grep -aFq 'wineserver: using pathless executable mapping probe' "$WINESERVER_BINARY" ||
  fail "ForgePlay Runtime must unlink temporary executable mapping files before probing them"
python3 - \
  "$RUNTIME_MANIFEST" \
  "$RUNTIME_FILE_INVENTORY" \
  "$RUNTIME_SBOM" \
  "$WINE_ROOT/bin/wine" \
  "$WINE_ROOT/share/wine/wine.inf" \
  "$WINEBOOT_BINARY" \
  "$RUNTIME_PATCH_PROVENANCE_LOCK" \
  "$METADATA" \
  "$SOURCE_AVAILABILITY" \
  "$LEGACY_RUNTIME_MANIFEST" <<'PY' || fail "ForgePlay Runtime identity manifest validation failed"
import hashlib
import json
import sys
from pathlib import Path

path_arguments = sys.argv[1:-1]
legacy_runtime_manifest = sys.argv[-1] == "1"
(
    manifest_path,
    inventory_path,
    sbom_path,
    launcher_path,
    inf_path,
    wineboot_path,
    provenance_path,
    metadata_path,
    source_availability_path,
) = map(Path, path_arguments)
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
provenance = json.loads(provenance_path.read_text(encoding="utf-8"))

def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

base_required = {
    "schemaVersion",
    "runtimeIdentifier",
    "wineVersion",
    "architecture",
    "sourceTreeSHA256",
    "patchApplicationOrder",
    "patchSetSHA256",
    "runnerLauncherSHA256",
    "wineInfSHA256",
    "winebootSHA256",
    "prefixCompatibilityFingerprint",
    "runnerBuildFingerprint",
    "hostSupportSBOMPath",
    "hostSupportSBOMSHA256",
    "hostSupportPayloadFingerprint",
    "corePayloadHashAlgorithm",
    "corePayloadSHA256",
    "corePayloadFingerprint",
}
inventory_required = {
    "runtimeFileInventoryFingerprint",
    "runtimeFileInventoryHashAlgorithm",
    "runtimeFileInventoryPath",
    "runtimeFileInventorySHA256",
}
required = base_required if legacy_runtime_manifest else base_required | inventory_required
if set(manifest) != required or manifest["schemaVersion"] != 3 or manifest["architecture"] != "win64":
    raise SystemExit("runtime manifest schema is invalid")
for key in required - {
    "schemaVersion",
    "runtimeIdentifier",
    "wineVersion",
    "architecture",
    "hostSupportSBOMPath",
    "runtimeFileInventoryHashAlgorithm",
    "runtimeFileInventoryPath",
    "corePayloadHashAlgorithm",
    "corePayloadSHA256",
    "patchApplicationOrder",
}:
    value = manifest[key]
    if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        raise SystemExit(f"runtime manifest digest is invalid: {key}")

patch_rows = provenance.get("patches")
contract_rows = provenance.get("behaviorContracts")
if not isinstance(patch_rows, list) or not isinstance(contract_rows, list):
    raise SystemExit("runtime patch provenance arrays are invalid")
patch_order = [row.get("path") for row in patch_rows if isinstance(row, dict)]
if (
    len(patch_order) != len(patch_rows)
    or not patch_order
    or len(set(patch_order)) != len(patch_order)
    or manifest["patchApplicationOrder"] != patch_order
):
    raise SystemExit("runtime manifest patch application order mismatch")

canonical_rows = [*patch_rows, *contract_rows]
canonical_paths = [row.get("path") for row in canonical_rows if isinstance(row, dict)]
if (
    len(canonical_paths) != len(canonical_rows)
    or not canonical_paths
    or len(set(canonical_paths)) != len(canonical_paths)
):
    raise SystemExit("runtime canonical patch-set identity is invalid")
patch_root = manifest_path.parent / "Patches"
patch_set = hashlib.sha256()
for relative_path in sorted(canonical_paths):
    if (
        not isinstance(relative_path, str)
        or Path(relative_path).name != relative_path
    ):
        raise SystemExit("runtime canonical patch-set path is unsafe")
    payload_path = patch_root / relative_path
    payload_digest = digest(payload_path)
    patch_set.update(relative_path.encode("utf-8"))
    patch_set.update(b"\0")
    patch_set.update(payload_digest.encode("ascii"))
    patch_set.update(b"\n")
if manifest["patchSetSHA256"] != patch_set.hexdigest():
    raise SystemExit("runtime manifest patch-set fingerprint mismatch")

metadata = metadata_path.read_text(encoding="utf-8")
source_availability = source_availability_path.read_text(encoding="utf-8")
identity_lines = (
    (
        metadata,
        f"- Corresponding source tree SHA-256: {manifest['sourceTreeSHA256']}",
    ),
    (
        metadata,
        f"- ForgePlay patch-set SHA-256: {manifest['patchSetSHA256']}",
    ),
    (
        source_availability,
        "- Validated corresponding source tree SHA-256: "
        f"`{manifest['sourceTreeSHA256']}`",
    ),
    (
        source_availability,
        "- Packaged ForgePlay patch-set SHA-256: "
        f"`{manifest['patchSetSHA256']}`",
    ),
)
if any(document.count(line) != 1 for document, line in identity_lines):
    raise SystemExit("runtime source and patch identity notices do not match the manifest")

actual = {
    "runnerLauncherSHA256": digest(launcher_path),
    "wineInfSHA256": digest(inf_path),
    "winebootSHA256": digest(wineboot_path),
}
for key, value in actual.items():
    if manifest[key] != value:
        raise SystemExit(f"runtime payload digest mismatch: {key}")

if manifest["hostSupportSBOMPath"] != "RuntimeSBOM.json":
    raise SystemExit("runtime host-support SBOM path is invalid")
if manifest["hostSupportSBOMSHA256"] != digest(sbom_path):
    raise SystemExit("runtime host-support SBOM digest mismatch")
sbom = json.loads(sbom_path.read_text(encoding="utf-8"))
if sbom.get("payloadFingerprint") != manifest["hostSupportPayloadFingerprint"]:
    raise SystemExit("runtime host-support payload fingerprint mismatch")

if not legacy_runtime_manifest:
    if manifest["runtimeFileInventoryPath"] != "RuntimeFileInventory.json":
        raise SystemExit("runtime complete file inventory path is invalid")
    if manifest["runtimeFileInventoryHashAlgorithm"] != "sha256-macho-code-signature-normalized-v1":
        raise SystemExit("runtime complete file inventory hash algorithm is invalid")
    if manifest["runtimeFileInventorySHA256"] != digest(inventory_path):
        raise SystemExit("runtime complete file inventory digest mismatch")
    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    if inventory.get("payloadFingerprint") != manifest["runtimeFileInventoryFingerprint"]:
        raise SystemExit("runtime complete file inventory fingerprint mismatch")

required_core_paths = {
    "wine/bin/wine",
    "wine/bin/wine.bin",
    "wine/bin/wineserver",
    "wine/bin/wineserver.bin",
    "wine/lib/wine/x86_64-unix/wine",
    "wine/lib/wine/x86_64-unix/ntdll.so",
    "wine/lib/wine/i386-windows/ntdll.dll",
    "wine/lib/wine/i386-windows/kernelbase.dll",
    "wine/lib/wine/i386-windows/mfplat.dll",
    "wine/lib/wine/i386-windows/winegstreamer.dll",
    "wine/lib/wine/x86_64-windows/ntdll.dll",
    "wine/lib/wine/x86_64-windows/kernelbase.dll",
    "wine/lib/wine/x86_64-windows/mfplat.dll",
    "wine/lib/wine/x86_64-windows/winegstreamer.dll",
    "wine/lib/wine/x86_64-unix/winegstreamer.so",
    "wine/lib/wine/x86_64-unix/winemac.so",
    "wine/lib/wine/i386-windows/winemac.drv",
    "wine/lib/wine/x86_64-windows/winemac.drv",
    "wine/lib/wine/x86_64-unix/winevulkan.so",
    "wine/lib/wine/i386-windows/winevulkan.dll",
    "wine/lib/wine/x86_64-windows/winevulkan.dll",
    "wine/lib/wine/x86_64-windows/forgeplay-steam-launcher.exe",
}
core_payloads = manifest["corePayloadSHA256"]
if not isinstance(core_payloads, dict) or set(core_payloads) != required_core_paths:
    raise SystemExit("runtime core payload identity set is invalid")
if manifest["corePayloadHashAlgorithm"] != "sha256-macho-signature-independent-v1":
    raise SystemExit("runtime core payload hash algorithm is invalid")
for relative_path, expected in core_payloads.items():
    if (
        not isinstance(expected, str)
        or len(expected) != 64
        or any(character not in "0123456789abcdef" for character in expected)
    ):
        raise SystemExit(f"runtime core payload digest is invalid: {relative_path}")
core_input = "forgeplay-runtime-core-payload-v2\n" + "".join(
    f"{path}={core_payloads[path]}\n" for path in sorted(core_payloads)
)
if manifest["corePayloadFingerprint"] != hashlib.sha256(core_input.encode("utf-8")).hexdigest():
    raise SystemExit("runtime core payload fingerprint mismatch")

prefix_input = (
    "forgeplay-prefix-compatibility-v1\n"
    f"wineVersion={manifest['wineVersion']}\n"
    f"architecture={manifest['architecture']}\n"
    f"wineInfSHA256={manifest['wineInfSHA256']}\n"
    f"winebootSHA256={manifest['winebootSHA256']}\n"
).encode("utf-8")
prefix_fingerprint = hashlib.sha256(prefix_input).hexdigest()
if manifest["prefixCompatibilityFingerprint"] != prefix_fingerprint:
    raise SystemExit("prefix compatibility fingerprint mismatch")

build_input = (
    "forgeplay-runtime-build-v3\n"
    f"sourceTreeSHA256={manifest['sourceTreeSHA256']}\n"
    f"patchSetSHA256={manifest['patchSetSHA256']}\n"
    f"runnerLauncherSHA256={manifest['runnerLauncherSHA256']}\n"
    f"prefixCompatibilityFingerprint={manifest['prefixCompatibilityFingerprint']}\n"
    f"hostSupportPayloadFingerprint={manifest['hostSupportPayloadFingerprint']}\n"
    f"corePayloadFingerprint={manifest['corePayloadFingerprint']}\n"
).encode("utf-8")
if manifest["runnerBuildFingerprint"] != hashlib.sha256(build_input).hexdigest():
    raise SystemExit("runner build fingerprint mismatch")
PY
python3 "$RUNTIME_CORE_IDENTITY_TOOL" verify "$RUNTIME_ROOT" "$RUNTIME_MANIFEST" ||
  fail "ForgePlay Runtime signed core payload identity validation failed"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-prefix-scoped-wineserver-root.patch" \
  "ForgePlay Wine prefix-scoped wineserver patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-app-group-mach-service.patch" \
  "ForgePlay Wine App Group Mach service patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-app-sandbox-server-lock.patch" \
  "ForgePlay Wine App Sandbox server lock patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-app-sandbox-executable-mappings.patch" \
  "ForgePlay Wine App Sandbox executable mapping patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-macos-bundled-runtime-loading.patch" \
  "ForgePlay Wine macOS bundled runtime loading patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-executable-scoped-process-observation.patch" \
  "ForgePlay Wine executable-scoped process observation patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-steam-game-renderer-process-policy.patch" \
  "ForgePlay Wine Steam game renderer process policy patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-d3dmetal-native-thread-context.patch" \
  "ForgePlay Wine D3DMetal native thread-context patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-d3dmetal-native-thread-state-sync.patch" \
  "ForgePlay Wine D3DMetal native thread-state synchronization patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-game-mode-direct-target-scope.patch" \
  "ForgePlay Wine Game Mode direct-target scope patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-external-storage-grant-activation.patch" \
  "ForgePlay Wine external-storage grant activation patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-manual-steam-renderer-selection.patch" \
  "ForgePlay Wine manual Steam renderer selection patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-managed-darwin-process-journal.patch" \
  "ForgePlay Wine managed Darwin process journal patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-forced-font-family-replacements.patch" \
  "ForgePlay Wine forced font-family replacement patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-steam-game-cef-browser-process-policy.patch" \
  "ForgePlay Wine Steam game CEF browser process policy patch"
require_non_symlink_regular_file \
  "$RUNTIME_ROOT/Patches/wine-11.12-steam-session-compatibility-controls.patch" \
  "ForgePlay Wine Steam session compatibility controls patch"

HAS_APPLE_D3DMETAL="0"
if [[ -d "$D3DMETAL_FRAMEWORK" ]]; then
  HAS_APPLE_D3DMETAL="1"
fi
if [[ -d "$D3DMETAL_RENDERER_ROOT" ]]; then
  verify_d3dmetal_shared_unix_module_contract
fi

if [[ "$HAS_APPLE_D3DMETAL" == "1" && "$REQUIRE_APP_STORE_RUNTIME" == "1" ]]; then
  fail "App Store ForgePlay Runtime must exclude Apple GPTK/D3DMetal evaluation redist"
fi

if [[ "$REQUIRE_DIRECT_DMG_RUNTIME" == "1" ]]; then
  [[ "$HAS_APPLE_D3DMETAL" == "1" ]] ||
    fail "direct DMG ForgePlay Runtime must include the configured Apple GPTK/D3DMetal payload"
  [[ "$(plist_string_value "$RUNTIME_ROOT/Info.plist" D3DMETAL || true)" == "true" ]] ||
    fail "direct DMG ForgePlay Runtime policy must advertise D3DMetal"
fi

if [[ "$HAS_APPLE_D3DMETAL" == "1" ]]; then
  require_non_symlink_directory \
    "$APPLE_GPTK_LEGAL_ROOT" \
    "Apple GPTK legal payload directory"
  require_file_sha256 \
    "$APPLE_GPTK_LICENSE" \
    "$APPLE_GPTK_LICENSE_SHA256" \
    "Apple GPTK software license agreement"
  require_file_sha256 \
    "$APPLE_GPTK_ACKNOWLEDGEMENTS" \
    "$APPLE_GPTK_ACKNOWLEDGEMENTS_SHA256" \
    "Apple GPTK acknowledgements"
  require_file_sha256 \
    "$APPLE_GPTK_FRAMEWORK_LICENSE" \
    "$APPLE_GPTK_FRAMEWORK_LICENSE_SHA256" \
    "D3DMetal framework license"
  require_non_symlink_directory \
    "$D3DMETAL_FRAMEWORK/Versions/A" \
    "D3DMetal materialized framework version"
  require_non_symlink_executable_file \
    "$D3DMETAL_FRAMEWORK/Versions/A/D3DMetal" \
    "D3DMetal materialized framework version executable"
  require_file_sha256 \
    "$APPLE_GPTK_VERSIONED_FRAMEWORK_LICENSE" \
    "$APPLE_GPTK_FRAMEWORK_LICENSE_SHA256" \
    "D3DMetal materialized framework version license"
  require_file_sha256 \
    "$APPLE_D3DMETAL_CODE_RESOURCES" \
    "$APPLE_D3DMETAL_CODE_RESOURCES_SHA256" \
    "D3DMetal preserved Apple CodeResources"
  cmp -s \
    "$D3DMETAL_FRAMEWORK/Resources/Info.plist" \
    "$D3DMETAL_FRAMEWORK/Versions/A/Resources/Info.plist" ||
    fail "D3DMetal root and materialized version framework metadata must match"
  LC_ALL=C grep -aFq 'SOFTWARE LICENSE AGREEMENT FOR GAME PORTING TOOLKIT' "$APPLE_GPTK_LICENSE" ||
    fail "Apple GPTK software license agreement marker is missing: $APPLE_GPTK_LICENSE"
  LC_ALL=C grep -aFq 'Acknowledgements' "$APPLE_GPTK_ACKNOWLEDGEMENTS" ||
    fail "Apple GPTK acknowledgements marker is missing: $APPLE_GPTK_ACKNOWLEDGEMENTS"
fi

if [[ "$REQUIRE_APP_STORE_RUNTIME" == "1" ]]; then
  metadata_contains "app store redistribution policy: apple gptk/d3dmetal evaluation redist excluded" ||
    fail "App Store ForgePlay Runtime metadata must record exclusion of Apple GPTK/D3DMetal evaluation redist"
fi

HAS_VULKAN_LOADER="0"
if find "$WINE_ROOT" -type f -iname 'libvulkan*.dylib' -print -quit | grep -q .; then
  HAS_VULKAN_LOADER="1"
fi

HAS_MOLTENVK="0"
if find "$WINE_ROOT" -type f -iname 'libMoltenVK*.dylib' -print -quit | grep -q .; then
  HAS_MOLTENVK="1"
fi

HAS_VULKAN_ICD="0"
VULKAN_ICD_FILE=""
if VULKAN_ICD_FILE="$(find "$WINE_ROOT" -type f -path '*/vulkan/icd.d/*.json' -print -quit)" &&
   [[ -n "$VULKAN_ICD_FILE" ]]; then
  HAS_VULKAN_ICD="1"
fi

HAS_VULKAN_RUNTIME="0"
if [[ "$HAS_VULKAN_LOADER" == "1" && "$HAS_MOLTENVK" == "1" && "$HAS_VULKAN_ICD" == "1" ]]; then
  HAS_VULKAN_RUNTIME="1"
fi

if [[ "$HAS_VULKAN_ICD" == "1" ]] &&
   LC_ALL=C grep -Eq '(/usr/local|/opt/homebrew|/Users/)' "$VULKAN_ICD_FILE"; then
  fail "bundled Vulkan ICD must not reference developer-machine absolute paths: $VULKAN_ICD_FILE"
fi

if [[ "$HAS_VULKAN_RUNTIME" != "1" ]]; then
  fail "ForgePlay Runtime Vulkan backend requires libvulkan, libMoltenVK, and a bundled Vulkan ICD JSON; found loader=$HAS_VULKAN_LOADER moltenvk=$HAS_MOLTENVK icd=$HAS_VULKAN_ICD"
fi

HAS_D3DMETAL_D3D11_DXGI_BRIDGE="0"
if [[ -f "$D3DMETAL_FRAMEWORK/D3DMetal" ]] &&
   [[ -f "$D3DMETAL_RENDERER_ROOT/external/libd3dshared.dylib" ]] &&
   [[ -f "$D3DMETAL_RENDERER_ROOT/wine/x86_64-windows/d3d11.dll" ]] &&
   [[ -f "$D3DMETAL_RENDERER_ROOT/wine/x86_64-windows/dxgi.dll" ]]; then
  HAS_D3DMETAL_D3D11_DXGI_BRIDGE="1"
fi

if [[ "$HAS_APPLE_D3DMETAL" == "1" && "$HAS_D3DMETAL_D3D11_DXGI_BRIDGE" != "1" ]]; then
  fail "ForgePlay Runtime D3DMetal path requires isolated D3DMetal d3d11/dxgi renderer modules under Frameworks/renderer; found d3d11_dxgi_bridge=$HAS_D3DMETAL_D3D11_DXGI_BRIDGE"
fi

HAS_D3DMETAL_D3D12_CLOSURE="0"
if [[ -e "$D3DMETAL_RENDERER_ROOT/wine/x86_64-unix/d3d12.so" ||
      -e "$D3DMETAL_RENDERER_ROOT/wine/x86_64-windows/d3d12.dll" ]]; then
  [[ -f "$D3DMETAL_FRAMEWORK/D3DMetal" &&
     -x "$D3DMETAL_FRAMEWORK/D3DMetal" ]] ||
    fail "D3DMetal framework executable is missing or not executable: $D3DMETAL_FRAMEWORK/D3DMetal"
  require_gptk4_framework_metadata "$D3DMETAL_FRAMEWORK"
  for component in \
    external/libd3dshared.dylib \
    external/D3DMetal.framework/Resources/default.metallib \
    external/D3DMetal.framework/Resources/libdxccontainer.dylib \
    external/D3DMetal.framework/Resources/libdxcompiler.dylib \
    external/D3DMetal.framework/Resources/libdxilconv.dylib \
    external/D3DMetal.framework/Resources/libmetalirconverter.dylib \
    wine/x86_64-windows/d3d12.dll \
    wine/x86_64-windows/dxgi.dll; do
    require_non_symlink_regular_file \
      "$D3DMETAL_RENDERER_ROOT/$component" \
      "D3DMetal D3D12 closure $component"
  done
  HAS_D3DMETAL_D3D12_CLOSURE="1"
fi

HAS_D3DMETAL_NATIVE_D3D9_BRIDGE="0"
if [[ -d "$RUNTIME_ROOT/Frameworks/renderer/d3dmetal" ]] &&
   find "$RUNTIME_ROOT/Frameworks/renderer/d3dmetal" -type f -path '*/x86_64-unix/d3d9.so' -print -quit | grep -q . &&
   find "$RUNTIME_ROOT/Frameworks/renderer/d3dmetal" -type f -path '*/x86_64-windows/d3d9.dll' -print -quit | grep -q .; then
  HAS_D3DMETAL_NATIVE_D3D9_BRIDGE="1"
fi

HAS_D9VK_STEAM_D3D9_BRIDGE="0"
if [[ "$HAS_VULKAN_RUNTIME" == "1" ]] &&
   find "$RUNTIME_ROOT/Frameworks/renderer/d9vk" -type f -path '*/x86_64-windows/d3d9.dll' -print -quit | grep -q . &&
   find "$RUNTIME_ROOT/Frameworks/renderer/d9vk" -type f -path '*/i386-windows/d3d9.dll' -print -quit | grep -q .; then
  HAS_D9VK_STEAM_D3D9_BRIDGE="1"
  require_non_symlink_regular_file \
    "$RUNTIME_ROOT/Frameworks/renderer/d9vk/wine/x86_64-windows/d3d9.dll" \
    "D9VK x86_64 Direct3D 9 renderer"
  require_non_symlink_regular_file \
    "$RUNTIME_ROOT/Frameworks/renderer/d9vk/wine/i386-windows/d3d9.dll" \
    "D9VK i386 Direct3D 9 renderer"
fi

if [[ "$HAS_APPLE_D3DMETAL" == "1" &&
      "$HAS_D3DMETAL_D3D11_DXGI_BRIDGE" == "1" &&
      "$HAS_D3DMETAL_NATIVE_D3D9_BRIDGE" != "1" &&
      "$HAS_D9VK_STEAM_D3D9_BRIDGE" != "1" ]]; then
  fail "ForgePlay Runtime D3DMetal Steam path requires either native D3DMetal D3D9 modules or bundled D9VK i386/x86_64 d3d9.dll plus Vulkan runtime; found native_d3d9=$HAS_D3DMETAL_NATIVE_D3D9_BRIDGE d9vk_d3d9=$HAS_D9VK_STEAM_D3D9_BRIDGE vulkan_runtime=$HAS_VULKAN_RUNTIME"
fi

DXMT_RENDERER_ROOT="$RUNTIME_ROOT/Frameworks/renderer/dxmt"
HAS_DXMT_MULTIARCH_BRIDGE="0"
if [[ -d "$DXMT_RENDERER_ROOT" ]]; then
  for component in \
    wine/x86_64-unix/winemetal.so \
    wine/x86_64-windows/d3d10core.dll \
    wine/x86_64-windows/d3d11.dll \
    wine/x86_64-windows/dxgi.dll \
    wine/x86_64-windows/winemetal.dll \
    wine/i386-windows/d3d10core.dll \
    wine/i386-windows/d3d11.dll \
    wine/i386-windows/dxgi.dll \
    wine/i386-windows/winemetal.dll; do
    require_non_symlink_regular_file \
      "$DXMT_RENDERER_ROOT/$component" \
      "DXMT multi-architecture bridge $component"
  done
  HAS_DXMT_MULTIARCH_BRIDGE="1"
fi

if [[ "$HAS_APPLE_D3DMETAL" == "1" && "$HAS_DXMT_MULTIARCH_BRIDGE" != "1" ]]; then
  fail "ForgePlay Runtime D3DMetal composition requires the DXMT i386 fallback and macOS window bridge for 32-bit Direct3D 10/11 games"
fi

if [[ "$HAS_APPLE_D3DMETAL" == "1" ]]; then
  require_non_symlink_regular_file \
    "$D3DMETAL_NGX_BRIDGE_VALIDATOR" \
    "D3DMetal NGX bridge validator"
  /bin/bash "$D3DMETAL_NGX_BRIDGE_VALIDATOR" "$D3DMETAL_RENDERER_ROOT" ||
    fail "D3DMetal NGX bridge semantic contract failed"
  if [[ -e "$WINE_ROOT/lib/external/D3DMetal.framework" ]]; then
    fail "active Wine lib/external must not contain D3DMetal.framework; keep it isolated under Frameworks/renderer/d3dmetal"
  fi
  if [[ -e "$WINE_ROOT/lib/wine/x86_64-unix/libd3dshared.dylib" ]]; then
    fail "active Wine modules must not contain libd3dshared.dylib; keep it isolated under Frameworks/renderer/d3dmetal"
  fi
  for module in d3d10 d3d11 d3d12 dxgi nvapi nvapi64 nvngx-on-metalfx; do
    if [[ -f "$WINE_ROOT/lib/wine/x86_64-unix/$module.so" ]] &&
       LC_ALL=C grep -aEq 'D3DMetal|D3DMetalWineThread|libd3dshared|MetalFX|nvngx-on-metalfx' \
         "$WINE_ROOT/lib/wine/x86_64-unix/$module.so"; then
      fail "active Wine x86_64-unix/$module.so must not be a D3DMetal renderer overlay"
    fi
    if [[ -f "$WINE_ROOT/lib/wine/x86_64-windows/$module.dll" ]] &&
       LC_ALL=C grep -aEq 'D3DMetal|D3DMetalWineThread|libd3dshared|MetalFX|nvngx-on-metalfx' \
         "$WINE_ROOT/lib/wine/x86_64-windows/$module.dll"; then
      fail "active Wine x86_64-windows/$module.dll must not be a D3DMetal renderer overlay"
    fi
  done
fi

DXVK_RENDERER_ROOT="$RUNTIME_ROOT/Frameworks/renderer/dxvk"
HAS_DXVK_MULTIARCH_BRIDGE="0"
if [[ -d "$DXVK_RENDERER_ROOT" ]]; then
  for arch in x86_64-windows i386-windows; do
    for dll in d3d8.dll d3d9.dll d3d10core.dll d3d11.dll dxgi.dll; do
      require_non_symlink_regular_file \
        "$DXVK_RENDERER_ROOT/wine/$arch/$dll" \
        "DXVK $arch $dll renderer bridge"
    done
  done
  HAS_DXVK_MULTIARCH_BRIDGE="1"
fi

if metadata_contains "--without-vulkan" ||
   metadata_contains "without vulkan support" ||
   metadata_contains "built without vulkan" ||
   metadata_contains "was built without vulkan"; then
  fail "ForgePlay Runtime metadata contradicts the required Vulkan-enabled Wine build contract"
fi

verify_macho_references_are_bundled "$WINE_ROOT"
verify_macho_references_are_bundled "$RUNTIME_ROOT"

printf 'Bundled runtime capability verification passed (d3dmetal-d3d11=%s d3dmetal-d3d12=%s d9vk=%s dxmt=%s dxvk=%s iohid=1): %s\n' \
  "$HAS_D3DMETAL_D3D11_DXGI_BRIDGE" \
  "$HAS_D3DMETAL_D3D12_CLOSURE" \
  "$HAS_D9VK_STEAM_D3D9_BRIDGE" \
  "$HAS_DXMT_MULTIARCH_BRIDGE" \
  "$HAS_DXVK_MULTIARCH_BRIDGE" \
  "$RUNTIME_ROOT"
