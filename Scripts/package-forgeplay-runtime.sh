#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
MODE="package"
RUNTIME_DEPENDENCY_LOCK="$REPO_ROOT/Config/ForgePlayRuntimeDependencies.lock.json"
RUNTIME_DEPENDENCY_MATERIALIZER="$SCRIPT_DIR/materialize-locked-runtime-dependencies.py"
GSTREAMER_PAYLOAD_LOCK="$REPO_ROOT/Config/ForgePlayGStreamerPayload.lock.json"
GSTREAMER_PAYLOAD_MATERIALIZER="$SCRIPT_DIR/materialize-locked-gstreamer-runtime.py"
RUNTIME_SBOM_TOOL="$SCRIPT_DIR/runtime-sbom.py"
RUNTIME_CORE_IDENTITY_TOOL="$SCRIPT_DIR/runtime-core-payload-identity.py"
MACHO_RUNTIME_CLOSURE_VERIFIER="$SCRIPT_DIR/verify-macho-runtime-closure.py"
RENDERER_PAYLOAD_LOCK="$REPO_ROOT/Config/ForgePlayRendererPayload.lock.json"
RENDERER_PAYLOAD_MATERIALIZER="$SCRIPT_DIR/materialize-locked-renderer.py"
CLEAN_WINE_MARKER_VERIFIER="$SCRIPT_DIR/verify-clean-wine-runtime-markers.py"
BUILD_PATH_VERIFIER="$SCRIPT_DIR/verify-wine-runtime-build-paths.py"
RUNTIME_PATCH_PROVENANCE_LOCK="$REPO_ROOT/Config/ForgePlayRuntimePatchProvenance.lock.json"
RUNTIME_PATCH_PROVENANCE_VERIFIER="$SCRIPT_DIR/verify-forgeplay-runtime-patch-provenance.py"
HOMEBREW_X86_PREFIX="${FORGEPLAY_HOMEBREW_X86_PREFIX:-/usr/local}"
GSTREAMER_SDK_INPUT="${FORGEPLAY_GSTREAMER_SDK_ROOT:-}"

if [[ "${1:-}" == "--validate-wine-source" || "${1:-}" == "--validate-wine-source-fixture" ]]; then
  MODE="${1#--}"
  shift
fi

INSTALL_ROOT="${1:-}"
OUTPUT_ROOT="${2:-}"
WINE_SOURCE_INPUT="${FORGEPLAY_WINE_SOURCE:-}"
WINE_SOURCE_ARCHIVE_URL="${FORGEPLAY_WINE_SOURCE_ARCHIVE_URL:-https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz}"
WINE_SOURCE_SIGNATURE_URL="${FORGEPLAY_WINE_SOURCE_SIGNATURE_URL:-https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz.sign}"
WINE_SOURCE_ARCHIVE_SHA256="d3bc091192d985846c9f20065cc81f21331f01e22b736b131e3449e1306671bc"
WINE_SOURCE_SIGNING_KEY_FINGERPRINT="DA23579A74D4AD9AF9D3F945CEFAC8EAAF17519D"
EXPECTED_WINE_SOURCE_TREE_SHA256="01f174c44664cbc3a4f931b536080facef0a70d6bfa2c5603182abdba18ddc73"
EXPECTED_WINE_PATCH_SET_SHA256="1c5d85142f26f7d588133852f4710594c34ea7360bbe616cefccb1d33ff1d1c3"
NANUM_GOTHIC_REGULAR_SHA256="76f45ef4a6bcff344c837c95a7dcc26e017e38b5846d5ae0cdcb5b86be2e2d31"
NANUM_GOTHIC_BOLD_SHA256="21f9d3a7f1ca82ca1dc9a288e30138b4f1feb6e71fc89b5a9181fed174b6bbe2"
NANUM_GOTHIC_OFL_SHA256="eeacf16032901d0ed0456876ec77b8f0fda6b3fecec7d972f8543eb602e6c30f"
APPLE_GPTK_LICENSE_SHA256="5abb2d059be217663b00e8fd37e14411d374e11d17e3b744eebd49b8d17118c8"
APPLE_GPTK_ACKNOWLEDGEMENTS_SHA256="6f3aa835f6d0d06f89997d0a346a209e39a8105521fd939e096c5b24dc0cb0a6"
D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET="../../external/libd3dshared.dylib"
D3DMETAL_SHARED_UNIX_MODULES=(d3d10 d3d11 d3d12 dxgi nvapi64 nvngx-on-metalfx)
WINE_SOURCE_ROOT=""
WINE_SOURCE_TREE_SHA256=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
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

reject_symlink_parent_components() {
  local path="$1"
  local label="$2"
  local current parent

  [[ "$path" = /* ]] || fail "$label must be an absolute path"
  current="$path"
  while [[ "$current" != "/" ]]; do
    [[ ! -L "$current" ]] || fail "$label must not contain symlink path components: $current"
    parent="$(dirname "$current")"
    [[ "$parent" != "$current" ]] || break
    current="$parent"
  done
}

require_source_file() {
  local path="$1"
  local label="$2"
  local link_count

  [[ -f "$path" && ! -L "$path" ]] || fail "$label must be a non-symlink regular file: $path"
  link_count="$(stat -f '%l' "$path" 2>/dev/null)" || fail "$label link count could not be inspected: $path"
  [[ "$link_count" == "1" ]] || fail "$label must not be hardlinked: $path"
}

require_file_sha256() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local actual

  actual="$(shasum -a 256 "$path" | awk '{print $1}')" ||
    fail "$label SHA-256 could not be computed: $path"
  [[ "$actual" == "$expected" ]] ||
    fail "$label SHA-256 mismatch: expected $expected, found $actual"
}

validate_public_source_urls() {
  python3 - "$WINE_SOURCE_ARCHIVE_URL" "$WINE_SOURCE_SIGNATURE_URL" <<'PY'
import sys
from urllib.parse import urlsplit

for label, value in zip(
    ["source archive", "source signature"],
    sys.argv[1:],
):
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise SystemExit(f"{label} URL must be a public HTTPS URL without credentials")
    if parsed.hostname in {"localhost", "127.0.0.1", "::1"}:
        raise SystemExit(f"{label} URL must not use a local host")
PY
}

source_tree_sha256() {
  local source_root="$1"
  python3 - "$source_root" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
files = []
for path in root.rglob("*"):
    relative = path.relative_to(root)
    if (
        ".git" in relative.parts
        or path.name in {".DS_Store", "configure"}
        or path.suffix in {".orig", ".rej"}
    ):
        continue
    if path.is_symlink():
        raise SystemExit(f"Wine source tree must not contain symlinks: {relative}")
    if path.is_file():
        files.append(path)
if not files:
    raise SystemExit("Wine source tree contains no regular files")

digest = hashlib.sha256()
for path in sorted(files, key=lambda item: item.relative_to(root).as_posix()):
    relative = path.relative_to(root).as_posix().encode("utf-8")
    file_digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            file_digest.update(chunk)
    digest.update(relative)
    digest.update(b"\0")
    digest.update(file_digest.hexdigest().encode("ascii"))
    digest.update(b"\n")
print(digest.hexdigest())
PY
}

validate_wine_source_root() {
  local enforce_corresponding_source="${1:-1}"
  local required_directory version

  [[ -n "$WINE_SOURCE_INPUT" ]] || fail "FORGEPLAY_WINE_SOURCE must point to the Wine 11.12 source tree"
  [[ "$WINE_SOURCE_INPUT" = /* ]] || fail "FORGEPLAY_WINE_SOURCE must be an absolute path"
  [[ -d "$WINE_SOURCE_INPUT" && ! -L "$WINE_SOURCE_INPUT" ]] ||
    fail "FORGEPLAY_WINE_SOURCE must be a non-symlink directory: $WINE_SOURCE_INPUT"
  WINE_SOURCE_ROOT="$(cd "$WINE_SOURCE_INPUT" && pwd -P)"
  reject_symlink_parent_components "$WINE_SOURCE_ROOT" "FORGEPLAY_WINE_SOURCE"

  require_source_file "$WINE_SOURCE_ROOT/VERSION" "Wine VERSION"
  require_source_file "$WINE_SOURCE_ROOT/configure.ac" "Wine configure.ac"
  require_source_file "$WINE_SOURCE_ROOT/LICENSE" "Wine license"
  require_source_file "$WINE_SOURCE_ROOT/COPYING.LIB" "Wine LGPL text"
  require_source_file "$WINE_SOURCE_ROOT/AUTHORS" "Wine authors attribution"
  for required_directory in dlls include libs loader server tools; do
    [[ -d "$WINE_SOURCE_ROOT/$required_directory" && ! -L "$WINE_SOURCE_ROOT/$required_directory" ]] ||
      fail "Wine source tree is missing required directory: $required_directory"
  done

  version="$(tr -d '\r\n' < "$WINE_SOURCE_ROOT/VERSION")"
  [[ "$version" == "Wine version 11.12" ]] ||
    fail "FORGEPLAY_WINE_SOURCE must be Wine 11.12 source; VERSION reported: $version"
  validate_public_source_urls || fail "Wine source availability URLs are invalid"
  WINE_SOURCE_TREE_SHA256="$(source_tree_sha256 "$WINE_SOURCE_ROOT")" ||
    fail "Wine source tree fingerprint could not be computed"
  [[ "$WINE_SOURCE_TREE_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
    fail "Wine source tree fingerprint is invalid"
  if [[ "$enforce_corresponding_source" == "1" && "$WINE_SOURCE_TREE_SHA256" != "$EXPECTED_WINE_SOURCE_TREE_SHA256" ]]; then
    fail "FORGEPLAY_WINE_SOURCE does not match the canonical Wine 11.12 plus ForgePlay patch-set fingerprint"
  fi
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

require_staged_renderer_file() {
  local path="$1"
  local label="$2"
  [[ -f "$path" && ! -L "$path" ]] || fail "$label is missing from staged renderer bundle: $path"
}

is_staged_d3dmetal_shared_unix_module_link_path() {
  local path="$1"
  local module
  for module in "${D3DMETAL_SHARED_UNIX_MODULES[@]}"; do
    if [[ "$path" == "$STAGING/Frameworks/renderer/d3dmetal/wine/x86_64-unix/$module.so" ]]; then
      return 0
    fi
  done
  return 1
}

require_staged_d3dmetal_shared_unix_module_link() {
  local renderer_root="$1"
  local module="$2"
  local link_path="$renderer_root/wine/x86_64-unix/$module.so"
  local shared_library="$renderer_root/external/libd3dshared.dylib"
  local link_target

  require_staged_renderer_file "$shared_library" "D3DMetal shared library"
  [[ -L "$link_path" ]] ||
    fail "D3DMetal $module.so must be a symbolic link to the single shared library: $link_path"
  link_target="$(readlink "$link_path")"
  [[ "$link_target" == "$D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET" ]] ||
    fail "D3DMetal $module.so has an unsafe or incorrect link target: $link_path -> $link_target"
  [[ "$link_path" -ef "$shared_library" ]] ||
    fail "D3DMetal $module.so does not resolve to the staged shared library: $link_path"
}

normalize_d3dmetal_shared_unix_module_links() {
  local renderer_root="$STAGING/Frameworks/renderer/d3dmetal"
  [[ -d "$renderer_root" ]] || return 0

  local unix_modules="$renderer_root/wine/x86_64-unix"
  local shared_library="$renderer_root/external/libd3dshared.dylib"
  local module module_path link_target link_count directory
  for directory in \
    "$renderer_root" \
    "$renderer_root/wine" \
    "$unix_modules" \
    "$renderer_root/external"; do
    [[ -d "$directory" && ! -L "$directory" ]] ||
      fail "D3DMetal payload path must be a non-symlink directory: $directory"
  done
  require_staged_renderer_file "$shared_library" "D3DMetal shared library"
  link_count="$(stat -f '%l' "$shared_library" 2>/dev/null)" ||
    fail "D3DMetal shared library link count could not be inspected: $shared_library"
  [[ "$link_count" == "1" ]] ||
    fail "D3DMetal shared library must not be hardlinked: $shared_library"

  for module in "${D3DMETAL_SHARED_UNIX_MODULES[@]}"; do
    module_path="$unix_modules/$module.so"
    if [[ -L "$module_path" ]]; then
      link_target="$(readlink "$module_path")"
      [[ "$link_target" == "$D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET" ]] ||
        fail "D3DMetal source $module.so has an unsafe or incorrect link target: $module_path -> $link_target"
      [[ "$module_path" -ef "$shared_library" ]] ||
        fail "D3DMetal source $module.so does not resolve to its shared library: $module_path"
    elif [[ -f "$module_path" ]]; then
      link_count="$(stat -f '%l' "$module_path" 2>/dev/null)" ||
        fail "D3DMetal source $module.so link count could not be inspected: $module_path"
      [[ "$link_count" == "1" ]] ||
        fail "D3DMetal source $module.so must not be hardlinked: $module_path"
      cmp -s "$module_path" "$shared_library" ||
        fail "D3DMetal source $module.so is not the expected libd3dshared payload: $module_path"
    else
      fail "D3DMetal source $module.so is missing or unsafe: $module_path"
    fi

    rm -f "$module_path"
    ln -s "$D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET" "$module_path"
    require_staged_d3dmetal_shared_unix_module_link "$renderer_root" "$module"
  done
}

plist_string_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null | tr -d '\r\n'
}

require_staged_gptk4_framework_metadata() {
  local framework="$1"
  local info_plist="$framework/Resources/Info.plist"
  local executable short_version bundle_version major_version

  require_staged_renderer_file "$info_plist" "D3DMetal framework Info.plist"
  [[ -x "$framework/D3DMetal" ]] ||
    fail "D3DMetal framework executable is not executable: $framework/D3DMetal"
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

verify_staged_winebus_iohid_backend() {
  local winebus="$STAGING/wine/lib/wine/x86_64-unix/winebus.so"
  [[ -f "$winebus" && ! -L "$winebus" ]] ||
    fail "Wine IOHID controller backend is missing: $winebus"
  otool -L "$winebus" 2>/dev/null | grep -Fq '/System/Library/Frameworks/IOKit.framework/' ||
    fail "Wine winebus.so must link IOKit for the macOS IOHID controller backend: $winebus"
  LC_ALL=C grep -aFq 'iohid_bus_init' "$winebus" ||
    fail "Wine winebus.so does not contain the macOS IOHID controller backend: $winebus"
}

verify_staged_forced_font_replacements() {
  local win32u="$STAGING/wine/lib/wine/x86_64-unix/win32u.so"
  local dwrite_x86="$STAGING/wine/lib/wine/i386-windows/dwrite.dll"
  local dwrite_x86_64="$STAGING/wine/lib/wine/x86_64-windows/dwrite.dll"

  require_source_file "$win32u" "Wine GDI forced-font replacement module"
  require_source_file "$dwrite_x86" "Wine i386 DirectWrite forced-font replacement module"
  require_source_file "$dwrite_x86_64" "Wine x86_64 DirectWrite forced-font replacement module"
  for module in "$win32u" "$dwrite_x86" "$dwrite_x86_64"; do
    binary_contains_text "$module" 'ForcedReplacements' ||
      fail "Wine font module is missing ForgePlay forced-family replacement support: $module"
  done
}

verify_runtime_patch_provenance() {
  require_source_file "$RUNTIME_PATCH_PROVENANCE_LOCK" "runtime patch provenance lock"
  require_source_file "$RUNTIME_PATCH_PROVENANCE_VERIFIER" "runtime patch provenance verifier"
  python3 "$RUNTIME_PATCH_PROVENANCE_VERIFIER" \
    --lock "$RUNTIME_PATCH_PROVENANCE_LOCK" \
    --patch-root "$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches" ||
    fail "ForgePlay Runtime patch inventory changed without clean-room provenance review"
}

verify_runtime_patch_provenance

if [[ "$MODE" == "validate-wine-source" || "$MODE" == "validate-wine-source-fixture" ]]; then
  [[ "$#" -eq 0 ]] || fail "usage: FORGEPLAY_WINE_SOURCE=<absolute source root> package-forgeplay-runtime.sh --validate-wine-source"
  if [[ "$MODE" == "validate-wine-source-fixture" ]]; then
    validate_wine_source_root 0
    printf 'Wine source fixture contract valid (not packaging evidence): version=11.12 tree-sha256=%s\n' \
      "$WINE_SOURCE_TREE_SHA256"
  else
    validate_wine_source_root 1
    printf 'Wine source contract valid: version=11.12 tree-sha256=%s archive=%s\n' \
      "$WINE_SOURCE_TREE_SHA256" "$WINE_SOURCE_ARCHIVE_URL"
  fi
  exit 0
fi

[[ "$#" -eq 2 && -n "$INSTALL_ROOT" && -n "$OUTPUT_ROOT" ]] ||
  fail "usage: FORGEPLAY_WINE_SOURCE=<absolute source root> FORGEPLAY_GSTREAMER_SDK_ROOT=<absolute SDK root> package-forgeplay-runtime.sh <wine install root> <output runtime root>"
[[ "$INSTALL_ROOT" = /* ]] || fail "Wine install root must be an absolute path"
[[ "$OUTPUT_ROOT" = /* ]] || fail "output runtime root must be an absolute path"
reject_symlink_parent_components "$INSTALL_ROOT" "Wine install root"
reject_symlink_parent_components "$OUTPUT_ROOT" "output runtime root"
[[ -n "$GSTREAMER_SDK_INPUT" && "$GSTREAMER_SDK_INPUT" = /* ]] ||
  fail "FORGEPLAY_GSTREAMER_SDK_ROOT must point to the extracted GStreamer 1.0 SDK root"
[[ -d "$GSTREAMER_SDK_INPUT" && ! -L "$GSTREAMER_SDK_INPUT" ]] ||
  fail "GStreamer SDK root must be a non-symlink directory: $GSTREAMER_SDK_INPUT"
GSTREAMER_SDK_ROOT="$(cd "$GSTREAMER_SDK_INPUT" && pwd -P)"
reject_symlink_parent_components "$GSTREAMER_SDK_ROOT" "GStreamer SDK root"
python3 - "$OUTPUT_ROOT" "$INSTALL_ROOT" "$GSTREAMER_SDK_ROOT" "$REPO_ROOT" "${HOME:-/nonexistent}" <<'PY' ||
import os
import sys

output = os.path.realpath(sys.argv[1])
install = os.path.realpath(sys.argv[2])
gstreamer = os.path.realpath(sys.argv[3])
if os.path.commonpath([output, install]) in {output, install}:
    raise SystemExit(f"output runtime root must not contain or be contained by Wine install root: {install}")
if os.path.commonpath([output, gstreamer]) in {output, gstreamer}:
    raise SystemExit(
        f"output runtime root must not contain or be contained by GStreamer SDK root: {gstreamer}"
    )
protected = [os.path.realpath(path) for path in sys.argv[4:]] + [os.path.sep]
for path in protected:
    if output == path or os.path.commonpath([output, path]) == output:
        raise SystemExit(f"output runtime root must not equal or contain protected path: {path}")
PY
  fail "output runtime root is unsafe"
if [[ -e "$OUTPUT_ROOT" || -L "$OUTPUT_ROOT" ]]; then
  [[ -d "$OUTPUT_ROOT" && ! -L "$OUTPUT_ROOT" ]] ||
    fail "existing output runtime root must be a non-symlink directory: $OUTPUT_ROOT"
  require_source_file "$OUTPUT_ROOT/RuntimeManifest.json" "existing output runtime manifest"
  require_source_file "$OUTPUT_ROOT/BUILD-METADATA.md" "existing output runtime build metadata"
fi
[[ -x "$INSTALL_ROOT/bin/wine" ]] || fail "Wine install root must contain bin/wine: $INSTALL_ROOT"
[[ -d "$INSTALL_ROOT/lib/wine" ]] || fail "Wine install root must contain lib/wine: $INSTALL_ROOT"
for winegstreamer_file in \
  "$INSTALL_ROOT/lib/wine/x86_64-unix/winegstreamer.so" \
  "$INSTALL_ROOT/lib/wine/i386-windows/winegstreamer.dll" \
  "$INSTALL_ROOT/lib/wine/x86_64-windows/winegstreamer.dll"; do
  require_source_file "$winegstreamer_file" "Wine GStreamer Media Foundation module"
done
WINE_NTDLL_UNIX="$INSTALL_ROOT/lib/wine/x86_64-unix/ntdll.so"
WINE_SERVER_BINARY="$INSTALL_ROOT/bin/wineserver"
for packaged_entrypoint in wine.bin wineserver.bin; do
  [[ ! -e "$INSTALL_ROOT/bin/$packaged_entrypoint" && ! -L "$INSTALL_ROOT/bin/$packaged_entrypoint" ]] ||
    fail "Wine install root must be a clean make-install tree, not an already packaged Runtime: $INSTALL_ROOT/bin/$packaged_entrypoint"
done
require_source_file "$WINE_SERVER_BINARY" "clean Wine server binary"
[[ -x "$WINE_SERVER_BINARY" ]] || fail "clean Wine server binary must be executable: $WINE_SERVER_BINARY"
require_source_file "$CLEAN_WINE_MARKER_VERIFIER" "clean Wine marker verifier"
require_source_file "$BUILD_PATH_VERIFIER" "Wine Runtime build-path verifier"
python3 "$BUILD_PATH_VERIFIER" "$INSTALL_ROOT/bin" "$INSTALL_ROOT/lib/wine" ||
  fail "Wine install root contains a developer-machine build path; use build-forgeplay-wine-runtime.sh"
python3 "$CLEAN_WINE_MARKER_VERIFIER" "$WINE_NTDLL_UNIX" "$WINE_SERVER_BINARY" ||
  fail "Wine runtime retains a removed contract; rebuild clean Wine 11.12 before packaging"
for d3dmetal_marker in \
  FORGEPLAY_D3DMETAL_BRIDGE \
  FORGEPLAY_D3DMETAL_TARGET \
  FORGEPLAY_D3DMETAL_SHARED_LIBRARY \
  FORGEPLAY_D3DMETAL_NATIVE_THREAD_CONTEXT; do
  binary_contains_text "$WINE_NTDLL_UNIX" "$d3dmetal_marker" ||
    fail "Wine Unix ntdll lacks the independently implemented ForgePlay D3DMetal contract marker: $d3dmetal_marker"
done
for game_mode_target_binary_marker in \
  FORGEPLAY_GAME_MODE_DIRECT_TARGET \
  loader_route_skipped_non_game_target; do
  binary_contains_text "$WINE_NTDLL_UNIX" "$game_mode_target_binary_marker" ||
    fail "Wine Unix ntdll does not contain the resolved Game Mode target boundary: $game_mode_target_binary_marker"
done
for external_storage_binary in "$WINE_NTDLL_UNIX" "$WINE_SERVER_BINARY"; do
  for external_storage_marker in \
    FORGEPLAY_EXTERNAL_STORAGE_BRIDGE \
    FORGEPLAY_EXTERNAL_STORAGE_GRANT_FILE \
    FORGEPLAY_EXTERNAL_STORAGE_GRANT_SHA256 \
    FORGEPLAY_EXTERNAL_STORAGE_GRANT_RUN_ID \
    FORGEPLAY_EXTERNAL_STORAGE_GRANT_V1 \
    FPActivateExternalStorageGrantManifest; do
    binary_contains_text "$external_storage_binary" "$external_storage_marker" ||
      fail "Wine external-storage grant activation is missing from $external_storage_binary: $external_storage_marker"
  done
done
WINEMAC_DRIVER="$INSTALL_ROOT/lib/wine/x86_64-unix/winemac.so"
[[ -f "$WINEMAC_DRIVER" ]] || fail "Wine install root must contain winemac.so: $WINEMAC_DRIVER"
for game_mode_host_icon_marker in \
  FORGEPLAY_GAME_MODE_HOST_ROUTED \
  'preserving fixed Game Mode host application icon'; do
  binary_contains_text "$WINEMAC_DRIVER" "$game_mode_host_icon_marker" ||
    fail "Wine mac driver does not preserve the fixed Game Mode host icon: $game_mode_host_icon_marker"
done
if winemac_driver_has_unsupported_steam_cef_surface_marker "$WINEMAC_DRIVER"; then
  fail "Wine mac driver cannot render Windows Steam CEF child-window Metal swapchains; rebuild Wine with the ForgePlay Steam CEF child-window Metal support before packaging"
fi
if ! winemac_driver_has_supported_steam_cef_surface_marker "$WINEMAC_DRIVER"; then
  fail "Wine mac driver does not contain the required ForgePlay cross-process Steam CEF client-surface implementation; refusing to package an unproven runtime"
fi
if ! winemac_driver_exports_metal_window_surface_contract "$WINEMAC_DRIVER"; then
  fail "Wine mac driver does not export the Metal renderer window-surface contract (_macdrv_functions); D3D11/D3D12 games will fail when creating a window swapchain"
fi
[[ -f "$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-steam-cef-other-process-opengl-surface.patch" ]] ||
  fail "ForgePlay Steam CEF Wine patch source is missing from the repository"
[[ -f "$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-forgeplay-metal-window-surface-contract.patch" ]] ||
  fail "independent ForgePlay Metal renderer window-surface contract patch is missing from the repository"
[[ -f "$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-forgeplay-d3dmetal-bridge.patch" ]] ||
  fail "independent ForgePlay D3DMetal bridge patch is missing from the repository"
[[ -f "$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-forgeplay-d3dmetal-bridge-contract.md" ]] ||
  fail "ForgePlay D3DMetal public behavior contract is missing from the repository"
GAME_MODE_TARGET_SCOPE_PATCH="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-direct-target-scope.patch"
require_source_file "$GAME_MODE_TARGET_SCOPE_PATCH" "ForgePlay Game Mode direct-target scope patch"
for game_mode_scope_source_marker in \
  'diff --git a/dlls/ntdll/unix/process.c' \
  'diff --git a/dlls/ntdll/unix/loader.c' \
  'diff --git a/dlls/winemac.drv/window.c' \
  forgeplay_game_mode_image_path_is_eligible \
  eligible_game_target \
  FORGEPLAY_GAME_MODE_DIRECT_TARGET \
  FORGEPLAY_GAME_MODE_HOST_ROUTED \
  '&params->ImagePathName' \
  loader_route_skipped_non_game_target \
  'preserving fixed Game Mode host application icon' \
  'unsetenv( "FORGEPLAY_STEAM_GAME_PROCESS" )' \
  '"steamapps"' \
  '"common"' \
  '"_CommonRedist"'; do
  grep -Fq "$game_mode_scope_source_marker" "$GAME_MODE_TARGET_SCOPE_PATCH" ||
    fail "ForgePlay Game Mode target-scope patch is missing its source marker: $game_mode_scope_source_marker"
done
EXTERNAL_STORAGE_GRANT_PATCH="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-external-storage-grant-activation.patch"
require_source_file "$EXTERNAL_STORAGE_GRANT_PATCH" "ForgePlay external-storage grant activation patch"
for external_storage_source_marker in \
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
  grep -Fq "$external_storage_source_marker" "$EXTERNAL_STORAGE_GRANT_PATCH" ||
    fail "ForgePlay external-storage grant activation patch is missing its source marker: $external_storage_source_marker"
done

MANUAL_RENDERER_SELECTION_PATCH="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-manual-steam-renderer-selection.patch"
require_source_file "$MANUAL_RENDERER_SELECTION_PATCH" "ForgePlay manual Steam renderer selection patch"
for manual_renderer_source_marker in \
  'manual-session-selection-missing' \
  'manual-session-d3dmetal' \
  'manual-session-dxmt' \
  'manual-session-d9vk' \
  'manual-session-dxvk' \
  'host-policy;manual-selection' \
  'process-creation-rejected'; do
  grep -Fq "$manual_renderer_source_marker" "$MANUAL_RENDERER_SELECTION_PATCH" ||
    fail "ForgePlay manual renderer patch is missing its source marker: $manual_renderer_source_marker"
done

STEAM_RENDERER_CONTROL_PLANE_PATCH="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-steam-renderer-control-plane-persistence.patch"
require_source_file "$STEAM_RENDERER_CONTROL_PLANE_PATCH" "ForgePlay Steam renderer control-plane persistence patch"
for steam_renderer_control_source_marker in \
  is_forgeplay_steam_common_redistributable_path \
  'L"_CommonRedist"' \
  'Host-owned manual selection' \
  'component and DLL-path controls must survive a Steam self-reexec'; do
  grep -Fq "$steam_renderer_control_source_marker" "$STEAM_RENDERER_CONTROL_PLANE_PATCH" ||
    fail "ForgePlay Steam renderer control-plane patch is missing its source marker: $steam_renderer_control_source_marker"
done

MANAGED_PROCESS_JOURNAL_PATCH="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-managed-darwin-process-journal.patch"
require_source_file "$MANAGED_PROCESS_JOURNAL_PATCH" "ForgePlay managed Darwin process journal patch"
for managed_process_source_marker in \
  'forgeplay_record_managed_wine_process( "wine-loader" )' \
  'forgeplay_record_managed_wine_process( "wineserver" )' \
  'FORGEPLAY_MANAGED_WINE_PROCESS_EVIDENCE_FILE' \
  'The managed-process identity belongs to the trusted Unix launch' \
  'process_started_at_unix_microseconds'; do
  grep -Fq "$managed_process_source_marker" "$MANAGED_PROCESS_JOURNAL_PATCH" ||
    fail "ForgePlay managed Darwin process journal patch is missing its source marker: $managed_process_source_marker"
done
validate_wine_source_root 1
GAME_MODE_TARGET_SCOPE_PROCESS_SOURCE="$WINE_SOURCE_ROOT/dlls/ntdll/unix/process.c"
for game_mode_scope_source_marker in \
  forgeplay_game_mode_image_path_is_eligible \
  eligible_game_target \
  FORGEPLAY_GAME_MODE_DIRECT_TARGET \
  '&params->ImagePathName'; do
  grep -Fq "$game_mode_scope_source_marker" "$GAME_MODE_TARGET_SCOPE_PROCESS_SOURCE" ||
    fail "corresponding Wine source is missing the resolved Game Mode target boundary: $game_mode_scope_source_marker"
done
GAME_MODE_TARGET_SCOPE_WINEMAC_SOURCE="$WINE_SOURCE_ROOT/dlls/winemac.drv/window.c"
for game_mode_scope_source_marker in \
  FORGEPLAY_GAME_MODE_HOST_ROUTED \
  'preserving fixed Game Mode host application icon'; do
  grep -Fq "$game_mode_scope_source_marker" "$GAME_MODE_TARGET_SCOPE_WINEMAC_SOURCE" ||
    fail "corresponding Wine source does not preserve the fixed Game Mode host icon: $game_mode_scope_source_marker"
done
GAME_MODE_TARGET_SCOPE_LOADER_SOURCE="$WINE_SOURCE_ROOT/dlls/ntdll/unix/loader.c"
for game_mode_scope_source_marker in \
  FORGEPLAY_GAME_MODE_DIRECT_TARGET \
  loader_route_skipped_game_mode_not_requested \
  loader_route_skipped_non_game_target \
  'unsetenv( "FORGEPLAY_STEAM_GAME_PROCESS" )'; do
  grep -Fq "$game_mode_scope_source_marker" "$GAME_MODE_TARGET_SCOPE_LOADER_SOURCE" ||
    fail "corresponding Wine source is missing the Game Mode direct-target boundary: $game_mode_scope_source_marker"
done
MANUAL_RENDERER_SOURCE="$WINE_SOURCE_ROOT/dlls/kernelbase/process.c"
for manual_renderer_source_marker in \
  'manual-session-selection-missing' \
  'manual-session-d3dmetal' \
  'manual-session-dxmt' \
  'manual-session-d9vk' \
  'manual-session-dxvk' \
  'L"process-creation-rejected"' \
  'status = STATUS_NOT_SUPPORTED;'; do
  grep -Fq "$manual_renderer_source_marker" "$MANUAL_RENDERER_SOURCE" ||
    fail "corresponding Wine source is missing the manual fail-closed renderer contract: $manual_renderer_source_marker"
done
for forbidden_manual_renderer_source_marker in \
  'automatic-loader-stage' \
  'L"LOADER_X64"' \
  'L"LOADER_X86"' \
  'route->profile' \
  'forgeplay_set_deferred_renderer_route' \
  'create_forgeplay_deferred_renderer_environment' \
  'FORGEPLAY_GAME_RENDERER_AVAILABLE_PROFILES' \
  'FORGEPLAY_GAME_RENDERER_UNAVAILABLE_PROFILES'; do
  if grep -Fq "$forbidden_manual_renderer_source_marker" "$MANUAL_RENDERER_SOURCE"; then
    fail "corresponding Wine source retains removed automatic/mixed renderer routing: $forbidden_manual_renderer_source_marker"
  fi
done
for steam_renderer_control_source_marker in \
  is_forgeplay_steam_common_redistributable_path \
  'L"_CommonRedist"' \
  'Host-owned manual selection' \
  'component and DLL-path controls must survive a Steam self-reexec'; do
  grep -Fq "$steam_renderer_control_source_marker" "$MANUAL_RENDERER_SOURCE" ||
    fail "corresponding Wine source is missing Steam renderer control-plane persistence: $steam_renderer_control_source_marker"
done
for preserved_manual_control in \
  'L"FORGEPLAY_GAME_RENDERER_COMPONENTS_X64"' \
  'L"FORGEPLAY_GAME_RENDERER_COMPONENTS_X86"' \
  'L"FORGEPLAY_GAME_RENDERER_DLL_PATH_X64"' \
  'L"FORGEPLAY_GAME_RENDERER_DLL_PATH_X86"'; do
  if sed -n '/renderer_state_variables\[\] =/,/^    };/p' "$MANUAL_RENDERER_SOURCE" |
      grep -Fq "$preserved_manual_control"; then
    fail "corresponding Wine source still scrubs a host-owned manual renderer control during Steam re-exec: $preserved_manual_control"
  fi
done

STAGING="${OUTPUT_ROOT}.staging.$$"
RUNTIME_SYMLINK_SOURCE_ROOTS=(
  "$STAGING"
  "$INSTALL_ROOT"
  "/opt/homebrew"
  "/usr/local"
  "/System/Library"
  "/usr/lib"
)
if [[ -n "${FORGEPLAY_RUNTIME_SYMLINK_SOURCE_ROOTS:-}" ]]; then
  IFS=':' read -r -a additional_symlink_roots <<< "$FORGEPLAY_RUNTIME_SYMLINK_SOURCE_ROOTS"
  for additional_root in "${additional_symlink_roots[@]}"; do
    [[ "$additional_root" = /* ]] || fail "runtime symlink source root must be absolute: $additional_root"
    [[ -d "$additional_root" && ! -L "$additional_root" ]] ||
      fail "runtime symlink source root must be a non-symlink directory: $additional_root"
    reject_symlink_parent_components "$additional_root" "runtime symlink source root"
    RUNTIME_SYMLINK_SOURCE_ROOTS+=("$additional_root")
  done
fi
cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

is_macho() {
  local path="$1"
  file "$path" 2>/dev/null | grep -q 'Mach-O'
}

copy_renderer_license_files() {
  local renderer_name="$1"
  local renderer_source="$2"
  local target="$STAGING/Legal/$renderer_name"
  [[ -d "$renderer_source" ]] || return 0
  mkdir -p "$target"
  find "$renderer_source" -maxdepth 2 -type f \( \
      -iname 'LICENSE*' -o \
      -iname 'COPYING*' -o \
      -iname 'NOTICE*' \
    \) -exec cp -fL {} "$target/" \;
}

materialize_locked_renderer_payload() {
  local source="${FORGEPLAY_RENDERER_SOURCE:-}"
  [[ -n "$source" ]] ||
    fail "FORGEPLAY_RENDERER_SOURCE is a required build-time input for the self-contained runtime"
  [[ "$source" = /* ]] || fail "FORGEPLAY_RENDERER_SOURCE must be an absolute path"
  [[ -d "$source/renderer" ]] && source="$source/renderer"
  [[ -d "$source" ]] || fail "FORGEPLAY_RENDERER_SOURCE must point to a Frameworks or renderer directory: $source"
  source="$(cd "$source" && pwd -P)"
  local checked_in_runtime="$REPO_ROOT/Resources/Runners/ForgePlayRuntime"
  case "$source/" in
    "$checked_in_runtime/"*)
      fail "FORGEPLAY_RENDERER_SOURCE must be an explicit build input outside the checked-in runtime output"
      ;;
  esac

  require_source_file "$RENDERER_PAYLOAD_LOCK" "renderer payload lock"
  require_source_file "$RENDERER_PAYLOAD_MATERIALIZER" "renderer payload materializer"
  local target="$STAGING/Frameworks/renderer"
  mkdir -p "$STAGING/Frameworks"
  python3 "$RENDERER_PAYLOAD_MATERIALIZER" \
    "$RENDERER_PAYLOAD_LOCK" \
    "$source" \
    "$target"
  local renderer
  for renderer in d3dmetal dxmt d9vk dxvk cnc-ddraw; do
    if [[ -d "$target/$renderer" ]]; then
      copy_renderer_license_files "$renderer" "$target/$renderer"
    fi
  done
}

copy_runtime_policy_and_legal_payload() {
  local source="${FORGEPLAY_RUNTIME_POLICY_SOURCE:-$REPO_ROOT/Resources/Runners/ForgePlayRuntime}"
  local apple_legal_source="$source/Legal/AppleGPTK"
  local apple_legal_target="$STAGING/Legal/AppleGPTK"
  local apple_license="$apple_legal_source/License.rtf"
  local apple_acknowledgements="$apple_legal_source/Acknowledgements.rtf"
  [[ -f "$source/Info.plist" && ! -L "$source/Info.plist" ]] ||
    fail "runtime support Info.plist is missing or unsafe: $source/Info.plist"
  require_source_file "$apple_license" "Apple GPTK software license agreement"
  require_source_file "$apple_acknowledgements" "Apple GPTK acknowledgements"
  require_file_sha256 \
    "$apple_license" \
    "$APPLE_GPTK_LICENSE_SHA256" \
    "Apple GPTK software license agreement"
  require_file_sha256 \
    "$apple_acknowledgements" \
    "$APPLE_GPTK_ACKNOWLEDGEMENTS_SHA256" \
    "Apple GPTK acknowledgements"

  mkdir -p "$STAGING/Frameworks"
  cp -f "$source/Info.plist" "$STAGING/Info.plist"
  mkdir -p "$apple_legal_target"
  cp -f "$apple_license" "$apple_legal_target/License.rtf"
  cp -f "$apple_acknowledgements" "$apple_legal_target/Acknowledgements.rtf"
}

copy_font_compatibility_payload() {
  local source="${FORGEPLAY_RUNTIME_POLICY_SOURCE:-$REPO_ROOT/Resources/Runners/ForgePlayRuntime}"
  local source_fonts="$source/wine/share/wine/fonts"
  local source_license="$source/Legal/NanumGothic/OFL.txt"
  local target_fonts="$STAGING/wine/share/wine/fonts"
  local target_license="$STAGING/Legal/NanumGothic/OFL.txt"
  local regular_source="$source_fonts/NanumGothic-Regular.ttf"
  local bold_source="$source_fonts/NanumGothic-Bold.ttf"

  require_source_file "$regular_source" "Nanum Gothic Regular font payload"
  require_source_file "$bold_source" "Nanum Gothic Bold font payload"
  require_source_file "$source_license" "Nanum Gothic OFL license"
  require_file_sha256 "$regular_source" "$NANUM_GOTHIC_REGULAR_SHA256" "Nanum Gothic Regular font payload"
  require_file_sha256 "$bold_source" "$NANUM_GOTHIC_BOLD_SHA256" "Nanum Gothic Bold font payload"
  require_file_sha256 "$source_license" "$NANUM_GOTHIC_OFL_SHA256" "Nanum Gothic OFL license"

  mkdir -p "$target_fonts" "$(dirname "$target_license")"
  rm -f \
    "$target_fonts/NanumGothic-Regular.ttf" \
    "$target_fonts/NanumGothic-Bold.ttf" \
    "$target_license"
  cp -f "$regular_source" "$target_fonts/NanumGothic-Regular.ttf"
  cp -f "$bold_source" "$target_fonts/NanumGothic-Bold.ttf"
  cp -f "$source_license" "$target_license"

  require_source_file \
    "$target_fonts/NanumGothic-Regular.ttf" \
    "staged Nanum Gothic Regular font payload"
  require_source_file \
    "$target_fonts/NanumGothic-Bold.ttf" \
    "staged Nanum Gothic Bold font payload"
  require_source_file "$target_license" "staged Nanum Gothic OFL license"
  require_file_sha256 \
    "$target_fonts/NanumGothic-Regular.ttf" \
    "$NANUM_GOTHIC_REGULAR_SHA256" \
    "staged Nanum Gothic Regular font payload"
  require_file_sha256 \
    "$target_fonts/NanumGothic-Bold.ttf" \
    "$NANUM_GOTHIC_BOLD_SHA256" \
    "staged Nanum Gothic Bold font payload"
  require_file_sha256 \
    "$target_license" \
    "$NANUM_GOTHIC_OFL_SHA256" \
    "staged Nanum Gothic OFL license"
}

copy_steam_compat_payload() {
  local source="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/SteamCompat/sdl2-compat"
  local target="$STAGING/SteamCompat/sdl2-compat"
  [[ -d "$source" ]] || fail "sdl2-compat payload source is missing: $source"

  mkdir -p "$(dirname "$target")"
  ditto "$source" "$target"

  find "$target" -type f -name SDL2.dll -print -quit | grep -q . ||
    fail "sdl2-compat payload does not contain SDL2.dll: $target"
  find "$target" -type f -name SDL3.dll -print -quit | grep -q . ||
    fail "sdl2-compat payload does not contain SDL3.dll: $target"
  find "$target" -type f -iname 'LICENSE*' -print -quit | grep -q . ||
    fail "sdl2-compat payload does not contain license material: $target"
}

copy_wine_patch_files() {
  local source="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches"
  [[ -d "$source" ]] || return 0
  mkdir -p "$STAGING/Patches"
  find "$source" -maxdepth 1 -type f \( -name '*.patch' -o -name '*-contract.md' \) \
    -exec cp -f {} "$STAGING/Patches/" \;
}

build_forgeplay_steam_launcher() {
  local source="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Sources/forgeplay_steam_launcher.c"
  local target="$STAGING/wine/lib/wine/x86_64-windows/forgeplay-steam-launcher.exe"
  local compiler="${FORGEPLAY_MINGW_CC:-}"

  [[ -f "$source" ]] || fail "ForgePlay Steam launcher source is missing: $source"
  if [[ -z "$compiler" ]]; then
    compiler="$(command -v x86_64-w64-mingw32-gcc 2>/dev/null || true)"
  fi
  if [[ -z "$compiler" && -x /opt/homebrew/bin/x86_64-w64-mingw32-gcc ]]; then
    compiler="/opt/homebrew/bin/x86_64-w64-mingw32-gcc"
  fi
  [[ -n "$compiler" && -x "$compiler" ]] ||
    fail "x86_64-w64-mingw32-gcc is required to build the ForgePlay Steam launcher"

  mkdir -p "$(dirname "$target")"
  "$compiler" -municode -mwindows -O2 -Wall -Wextra -o "$target" "$source" -lshell32
  chmod 755 "$target"
}

verify_locked_renderer_payload() {
  local renderer_root="$STAGING/Frameworks/renderer"
  local d3dmetal_root="$renderer_root/d3dmetal"
  local required_renderer
  [[ -d "$renderer_root" && ! -L "$renderer_root" ]] ||
    fail "locked renderer payload root is missing or unsafe: $renderer_root"
  for required_renderer in d3dmetal d9vk dxmt dxvk; do
    [[ -d "$renderer_root/$required_renderer" && ! -L "$renderer_root/$required_renderer" ]] ||
      fail "locked renderer component is missing or unsafe: $required_renderer"
  done
  if [[ -d "$d3dmetal_root" ]]; then
    local d3dmetal_framework="$d3dmetal_root/external/D3DMetal.framework"
    local d3dmetal_module
    require_staged_renderer_file \
      "$d3dmetal_framework/D3DMetal" \
      "D3DMetal framework executable"
    require_staged_renderer_file \
      "$d3dmetal_root/external/libd3dshared.dylib" \
      "D3DMetal shared library"
    for d3dmetal_module in "${D3DMETAL_SHARED_UNIX_MODULES[@]}"; do
      require_staged_d3dmetal_shared_unix_module_link "$d3dmetal_root" "$d3dmetal_module"
    done
    for module in wine/x86_64-windows/d3d11.dll wine/x86_64-windows/dxgi.dll; do
      require_staged_renderer_file "$d3dmetal_root/$module" "D3DMetal $module"
    done

    if [[ -e "$d3dmetal_root/wine/x86_64-unix/d3d12.so" ||
          -e "$d3dmetal_root/wine/x86_64-windows/d3d12.dll" ]]; then
      require_staged_gptk4_framework_metadata "$d3dmetal_framework"
      for component in \
        external/libd3dshared.dylib \
        external/D3DMetal.framework/Resources/default.metallib \
        external/D3DMetal.framework/Resources/libdxccontainer.dylib \
        external/D3DMetal.framework/Resources/libdxcompiler.dylib \
        external/D3DMetal.framework/Resources/libdxilconv.dylib \
        external/D3DMetal.framework/Resources/libmetalirconverter.dylib \
        wine/x86_64-windows/d3d12.dll \
        wine/x86_64-windows/dxgi.dll; do
        require_staged_renderer_file "$d3dmetal_root/$component" "D3DMetal D3D12 closure $component"
      done
    fi
  fi

  local d9vk_root="$renderer_root/d9vk"
  if [[ -d "$d9vk_root" ]]; then
    local d9vk_arch
    for d9vk_arch in x86_64-windows i386-windows; do
      require_staged_renderer_file \
        "$d9vk_root/wine/$d9vk_arch/d3d9.dll" \
        "D9VK $d9vk_arch d3d9.dll"
    done
  fi

  local dxmt_root="$renderer_root/dxmt"
  if [[ -d "$dxmt_root" ]]; then
    local dxmt_component
    for dxmt_component in \
      wine/x86_64-unix/winemetal.so \
      wine/x86_64-windows/d3d10core.dll \
      wine/x86_64-windows/d3d11.dll \
      wine/x86_64-windows/dxgi.dll \
      wine/x86_64-windows/winemetal.dll \
      wine/i386-windows/d3d10core.dll \
      wine/i386-windows/d3d11.dll \
      wine/i386-windows/dxgi.dll \
      wine/i386-windows/winemetal.dll; do
      require_staged_renderer_file "$dxmt_root/$dxmt_component" "DXMT $dxmt_component"
    done
  fi

  if [[ -d "$d3dmetal_root" ]]; then
    [[ -d "$d9vk_root" ]] ||
      fail "D3DMetal composition requires D9VK i386/x86_64 Direct3D 9 modules"
    [[ -d "$dxmt_root" ]] ||
      fail "D3DMetal composition requires the DXMT i386 Direct3D 10/11 fallback and macOS window bridge"
  fi

  local dxvk_root="$renderer_root/dxvk"
  if [[ -d "$dxvk_root" ]]; then
    local arch dll
    for arch in x86_64-windows i386-windows; do
      for dll in d3d8.dll d3d9.dll d3d10core.dll d3d11.dll dxgi.dll; do
        require_staged_renderer_file "$dxvk_root/wine/$arch/$dll" "DXVK $arch $dll"
      done
    done
  fi
}

verify_active_wine_modules_do_not_embed_renderer_overlay() {
  local wine_unix="$STAGING/wine/lib/wine/x86_64-unix"
  local wine_windows="$STAGING/wine/lib/wine/x86_64-windows"
  [[ -d "$wine_unix" ]] || fail "Wine x86_64 Unix module directory is missing: $wine_unix"
  [[ -d "$wine_windows" ]] || fail "Wine x86_64 Windows module directory is missing: $wine_windows"

  local marker_pattern='D3DMetal|D3DMetalWineThread|libd3dshared|MetalFX|nvngx-on-metalfx'
  local module
  for module in d3d10 d3d11 d3d12 dxgi nvapi64 nvngx-on-metalfx; do
    if [[ -f "$wine_unix/$module.so" ]] &&
       LC_ALL=C grep -aEq "$marker_pattern" "$wine_unix/$module.so"; then
      fail "active Wine Unix module must not contain a renderer overlay: $wine_unix/$module.so"
    fi
    if [[ -f "$wine_windows/$module.dll" ]] &&
       LC_ALL=C grep -aEq "$marker_pattern" "$wine_windows/$module.dll"; then
      fail "active Wine Windows module must not contain a renderer overlay: $wine_windows/$module.dll"
    fi
  done

  [[ ! -e "$wine_unix/libd3dshared.dylib" ]] ||
    fail "D3DMetal shared library must stay under Frameworks/renderer, not active Wine modules: $wine_unix/libd3dshared.dylib"
  [[ ! -e "$STAGING/wine/lib/external/D3DMetal.framework" ]] ||
    fail "D3DMetal.framework must stay under Frameworks/renderer, not active Wine lib/external"
}

prune_active_wine_renderer_overlay_artifacts() {
  local wine_unix="$STAGING/wine/lib/wine/x86_64-unix"
  local wine_windows="$STAGING/wine/lib/wine/x86_64-windows"
  local wine_external="$STAGING/wine/lib/external"

  rm -f "$wine_unix/libd3dshared.dylib"
  rm -rf "$wine_external/D3DMetal.framework"

  local module
  for module in nvapi64 nvngx-on-metalfx; do
    rm -f "$wine_unix/$module.so" "$wine_windows/$module.dll"
  done
}

add_rpath_if_needed() {
  local macho="$1"
  local rpath="$2"
  if ! otool -l "$macho" 2>/dev/null | awk '/cmd LC_RPATH/{seen=1} seen && /path /{print $2; seen=0}' | grep -Fxq "$rpath"; then
    local output
    if ! output="$(install_name_tool -add_rpath "$rpath" "$macho" 2>&1)"; then
      fail "unable to add Mach-O rpath $rpath to $macho: $output"
    fi
  fi
}

normalize_winegstreamer_runtime_search_path() {
  local winegstreamer="$STAGING/wine/lib/wine/x86_64-unix/winegstreamer.so"
  local gstreamer_lib="$STAGING/wine/gstreamer/lib"
  local gstreamer_plugins="$gstreamer_lib/gstreamer-1.0"
  require_source_file "$winegstreamer" "staged Wine GStreamer Unix module"
  [[ -d "$gstreamer_lib" && ! -L "$gstreamer_lib" ]] ||
    fail "staged GStreamer library root is missing or unsafe: $gstreamer_lib"
  [[ -d "$gstreamer_plugins" && ! -L "$gstreamer_plugins" ]] ||
    fail "staged GStreamer plugin root is missing or unsafe: $gstreamer_plugins"

  local rpath output
  while IFS= read -r rpath; do
    case "$rpath" in
      /*)
        if ! output="$(install_name_tool -delete_rpath "$rpath" "$winegstreamer" 2>&1)"; then
          fail "unable to remove build-time GStreamer LC_RPATH $rpath: $output"
        fi
        ;;
    esac
  done < <(
    otool -l "$winegstreamer" 2>/dev/null |
      awk '/cmd LC_RPATH/{seen=1; next} seen && /path /{print $2; seen=0}' |
      sort -u
  )
  add_rpath_if_needed "$winegstreamer" "@loader_path/../../../gstreamer/lib"
}

adhoc_sign_wine_macho_files() {
  local phase="$1"
  while IFS= read -r -d '' macho; do
    is_macho "$macho" || continue
    chmod u+w "$macho"
    local output
    if ! output="$(codesign --force --sign - --timestamp=none "$macho" 2>&1)"; then
      fail "unable to ad-hoc sign Mach-O during $phase: $macho: $output"
    fi
    codesign --verify --strict "$macho" >/dev/null 2>&1 ||
      fail "Mach-O signature verification failed during $phase: $macho"
  done < <(find "$STAGING/wine" -type f -print0)
}

rewrite_macho_references() {
  while IFS= read -r -d '' macho; do
    is_macho "$macho" || continue
    chmod u+w "$macho"
    if [[ "$macho" == "$STAGING"/wine/lib/*.dylib ]]; then
      local output
      if ! output="$(install_name_tool -id "@rpath/$(basename "$macho")" "$macho" 2>&1)"; then
        fail "unable to rewrite Mach-O install name for $macho: $output"
      fi
    fi
    case "$macho" in
      "$STAGING"/wine/lib/wine/x86_64-unix/*)
        add_rpath_if_needed "$macho" "@loader_path/"
        add_rpath_if_needed "$macho" "@loader_path/../.."
        ;;
      "$STAGING"/wine/lib/*.dylib)
        add_rpath_if_needed "$macho" "@loader_path"
        ;;
    esac
    while IFS= read -r dependency; do
      [[ "$dependency" == /usr/local/* ]] || continue
      local output
      if ! output="$(install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$macho" 2>&1)"; then
        fail "unable to rewrite Mach-O dependency $dependency for $macho: $output"
      fi
    done < <(otool -L "$macho" 2>/dev/null | awk 'NR > 1 { print $1 }')
  done < <(find "$STAGING/wine" -type f -print0)
}

normalize_runtime_support_macho_references() {
  local support_root="$STAGING/Frameworks"
  [[ -d "$support_root" ]] || fail "runtime support Frameworks are missing: $support_root"

  while IFS= read -r -d '' macho; do
    is_macho "$macho" || continue
    chmod u+w "$macho"

    local install_name
    install_name="$(otool -D "$macho" 2>/dev/null | sed -n '2p' | tr -d '[:space:]')"
    case "$install_name" in
      /usr/local/*|/opt/*|/Users/*|/Volumes/*)
        local output
        if ! output="$(install_name_tool -id "@rpath/$(basename "$install_name")" "$macho" 2>&1)"; then
          fail "unable to rewrite runtime support install name for $macho: $output"
        fi
        ;;
    esac

    while IFS= read -r dependency; do
      case "$dependency" in
        /usr/local/*|/opt/*|/Users/*|/Volumes/*)
          local output
          if ! output="$(install_name_tool -change "$dependency" "@rpath/$(basename "$dependency")" "$macho" 2>&1)"; then
            fail "unable to rewrite runtime support dependency $dependency for $macho: $output"
          fi
          ;;
      esac
    done < <(otool -L "$macho" 2>/dev/null | awk 'NR > 1 { print $1 }')

    while IFS= read -r rpath; do
      case "$rpath" in
        /usr/local/*|/opt/*|/Users/*|/Volumes/*)
          local output
          if ! output="$(install_name_tool -delete_rpath "$rpath" "$macho" 2>&1)"; then
            fail "unable to remove runtime support LC_RPATH $rpath from $macho: $output"
          fi
          ;;
      esac
    done < <(
      otool -l "$macho" 2>/dev/null |
        awk '/cmd LC_RPATH/{seen=1; next} seen && /path /{print $2; seen=0}' |
        sort -u
    )

    local sign_output
    if ! sign_output="$(codesign --force --sign - --timestamp=none "$macho" 2>&1)"; then
      fail "unable to ad-hoc sign normalized runtime support Mach-O $macho: $sign_output"
    fi
    codesign --verify --strict "$macho" >/dev/null 2>&1 ||
      fail "normalized runtime support Mach-O signature verification failed: $macho"
  done < <(find "$support_root" -maxdepth 1 -type f -print0)
}

install_wine_loader_entrypoint() {
  local source="$STAGING/wine/lib/wine/x86_64-unix/wine"
  local target="$STAGING/wine/bin/wine"
  [[ -x "$source" ]] || fail "Wine x86_64 loader is missing: $source"

  cp -f "$source" "$target"
  chmod 755 "$target"
}

install_runtime_entrypoints() {
  local launcher
  for launcher in wine wineserver; do
    local launcher_path="$STAGING/wine/bin/$launcher"
    local binary_path="$launcher_path.bin"
    [[ -x "$launcher_path" ]] || fail "runtime launcher is missing before entrypoint install: $launcher_path"
    if [[ ! -f "$binary_path" ]]; then
      mv "$launcher_path" "$binary_path"
    fi
    chmod 755 "$binary_path"
    cat > "$launcher_path" <<'ENTRYPOINT'
#!/bin/sh
set -eu
BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
WINE_ROOT="$(CDPATH= cd -- "$BIN_DIR/.." && pwd -P)"
RUNTIME_ROOT="$(CDPATH= cd -- "$WINE_ROOT/.." && pwd -P)"
prepend_path() {
  new_value="$1"
  old_value="${2:-}"
  if [ -z "$old_value" ]; then
    printf '%s' "$new_value"
  else
    printf '%s:%s' "$new_value" "$old_value"
  fi
}
append_path() {
  new_value="$1"
  old_value="${2:-}"
  if [ -z "$old_value" ]; then
    printf '%s' "$new_value"
  else
    printf '%s:%s' "$old_value" "$new_value"
  fi
}
BASE_LIBS="$WINE_ROOT/lib:$WINE_ROOT/lib/wine/x86_64-unix:$WINE_ROOT/lib/wine/i386-unix"
GSTREAMER_LIB="$WINE_ROOT/gstreamer/lib"
GSTREAMER_PLUGINS="$GSTREAMER_LIB/gstreamer-1.0"
if [ -d "$GSTREAMER_PLUGINS" ]; then
  BASE_LIBS="$GSTREAMER_LIB:$BASE_LIBS"
  export GST_PLUGIN_SYSTEM_PATH_1_0=""
  export GST_PLUGIN_PATH_1_0="$GSTREAMER_PLUGINS"
fi
export DYLD_LIBRARY_PATH="$(prepend_path "$BASE_LIBS" "${DYLD_LIBRARY_PATH:-}")"
export DYLD_FALLBACK_LIBRARY_PATH="$(prepend_path "$BASE_LIBS" "${DYLD_FALLBACK_LIBRARY_PATH:-}")"
export WINEDLLPATH="$(append_path "$WINE_ROOT/lib/wine:$WINE_ROOT/lib/wine/x86_64-unix:$WINE_ROOT/lib/wine/x86_64-windows:$WINE_ROOT/lib/wine/i386-windows" "${WINEDLLPATH:-}")"
if [ -z "${VK_ICD_FILENAMES:-}" ] && [ -f "$WINE_ROOT/etc/vulkan/icd.d/MoltenVK_icd.json" ]; then
  export VK_ICD_FILENAMES="$WINE_ROOT/etc/vulkan/icd.d/MoltenVK_icd.json"
  export VK_DRIVER_FILES="$VK_ICD_FILENAMES"
fi
if [ -z "${WINESERVER:-}" ] && [ -x "$WINE_ROOT/bin/wineserver" ]; then
  export WINESERVER="$WINE_ROOT/bin/wineserver"
fi
LAUNCHER_NAME="$(basename -- "$0")"
if [ "$LAUNCHER_NAME" = "wine" ]; then
  exec "$WINE_ROOT/lib/wine/x86_64-unix/wine" "$@"
fi
exec "$BIN_DIR/$LAUNCHER_NAME.bin" "$@"
ENTRYPOINT
    chmod 755 "$launcher_path"
  done
}

materialize_symlinks() {
  while IFS= read -r -d '' link_path; do
    if is_staged_d3dmetal_shared_unix_module_link_path "$link_path"; then
      local module_name
      module_name="$(basename "$link_path" .so)"
      require_staged_d3dmetal_shared_unix_module_link \
        "$STAGING/Frameworks/renderer/d3dmetal" \
        "$module_name"
      continue
    fi

    local link_target
    link_target="$(readlink "$link_path")"
    [[ -n "$link_target" ]] || fail "unable to read symlink target: $link_path"

    local resolved_target canonical_target
    if [[ "$link_target" == /* ]]; then
      resolved_target="$link_target"
    else
      resolved_target="$(dirname "$link_path")/$link_target"
    fi
    canonical_target="$(python3 - "$resolved_target" "${RUNTIME_SYMLINK_SOURCE_ROOTS[@]}" <<'PY'
import os
import sys

target = os.path.realpath(sys.argv[1])
for candidate in sys.argv[2:]:
    root = os.path.realpath(candidate)
    try:
        if os.path.commonpath([target, root]) == root:
            print(target)
            raise SystemExit(0)
    except ValueError:
        pass
raise SystemExit(f"staged symlink target escapes trusted runtime source roots: {sys.argv[1]} -> {target}")
PY
    )" || fail "staged symlink target is outside trusted runtime source roots: $link_path -> $link_target"

    if [[ -d "$canonical_target" && ! -L "$canonical_target" ]]; then
      rm -f "$link_path"
      mkdir -p "$link_path"
      ditto "$canonical_target" "$link_path"
    elif [[ -f "$canonical_target" && ! -L "$canonical_target" ]]; then
      rm -f "$link_path"
      cp -f "$canonical_target" "$link_path"
      chmod u+w "$link_path"
    else
      fail "staged symlink target is missing: $link_path -> $link_target"
    fi
  done < <(find "$STAGING" -type l -print0)
}

[[ ! -e "$STAGING" && ! -L "$STAGING" ]] || fail "runtime staging path already exists: $STAGING"
mkdir -p "$STAGING"
ditto "$INSTALL_ROOT" "$STAGING/wine"

find "$STAGING/wine" -type f \( -name '*.a' -o -name '*.la' \) -delete
rm -rf "$STAGING/wine/include" "$STAGING/wine/share/man" "$STAGING/wine/lib/pkgconfig"
copy_runtime_policy_and_legal_payload
copy_font_compatibility_payload
copy_steam_compat_payload
materialize_locked_renderer_payload
normalize_d3dmetal_shared_unix_module_links
materialize_symlinks
install_wine_loader_entrypoint
verify_locked_renderer_payload
verify_staged_winebus_iohid_backend
verify_staged_forced_font_replacements
prune_active_wine_renderer_overlay_artifacts
verify_active_wine_modules_do_not_embed_renderer_overlay
build_forgeplay_steam_launcher

require_source_file "$RUNTIME_DEPENDENCY_LOCK" "runtime dependency lock"
require_source_file "$RUNTIME_DEPENDENCY_MATERIALIZER" "runtime dependency materializer"
require_source_file "$GSTREAMER_PAYLOAD_LOCK" "GStreamer payload lock"
require_source_file "$GSTREAMER_PAYLOAD_MATERIALIZER" "GStreamer payload materializer"
require_source_file "$RUNTIME_SBOM_TOOL" "runtime SBOM tool"
require_source_file "$RUNTIME_CORE_IDENTITY_TOOL" "runtime core payload identity tool"
require_source_file "$MACHO_RUNTIME_CLOSURE_VERIFIER" "Mach-O runtime closure verifier"
require_source_file "$RENDERER_PAYLOAD_LOCK" "renderer payload lock"
find "$STAGING/wine/lib" -maxdepth 1 -type f -name '*.dylib' -delete
python3 "$RUNTIME_DEPENDENCY_MATERIALIZER" \
  "$RUNTIME_DEPENDENCY_LOCK" \
  "$HOMEBREW_X86_PREFIX" \
  "$STAGING"
python3 "$GSTREAMER_PAYLOAD_MATERIALIZER" \
  "$GSTREAMER_PAYLOAD_LOCK" \
  "$GSTREAMER_SDK_ROOT" \
  "$STAGING"
normalize_winegstreamer_runtime_search_path

adhoc_sign_wine_macho_files "pre-rewrite code-signature reservation"
rewrite_macho_references
adhoc_sign_wine_macho_files "post-rewrite validation"
normalize_runtime_support_macho_references
install_runtime_entrypoints
python3 "$MACHO_RUNTIME_CLOSURE_VERIFIER" "$STAGING/wine" ||
  fail "locked Wine Mach-O dependency closure is incomplete"
xattr -dr com.apple.quarantine "$STAGING" 2>/dev/null || true

mkdir -p "$STAGING/Legal/Wine"
cp -f "$WINE_SOURCE_ROOT/LICENSE" "$STAGING/Legal/Wine/LICENSE"
cp -f "$WINE_SOURCE_ROOT/COPYING.LIB" "$STAGING/Legal/Wine/COPYING.LIB"
cp -f "$WINE_SOURCE_ROOT/AUTHORS" "$STAGING/Legal/Wine/AUTHORS"
copy_wine_patch_files
mkdir -p "$STAGING/Sources"
cp -f \
  "$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Sources/forgeplay_steam_launcher.c" \
  "$STAGING/Sources/forgeplay_steam_launcher.c"

WINE_PATCH_METADATA="- Wine patches:"
for patch_name in \
  wine-11.12-steam-cef-other-process-opengl-surface.patch \
  wine-11.12-forgeplay-d3dmetal-bridge.patch \
  wine-11.12-forgeplay-metal-window-surface-contract.patch \
  wine-11.12-moltenvk-portability-enumeration.patch \
  wine-11.12-prefix-scoped-wineserver-root.patch \
  wine-11.12-app-group-mach-service.patch \
  wine-11.12-app-sandbox-server-lock.patch \
  wine-11.12-app-sandbox-executable-mappings.patch \
  wine-11.12-macos-bundled-runtime-loading.patch \
  wine-11.12-executable-scoped-process-arguments.patch \
  wine-11.12-steam-game-renderer-process-policy.patch \
  wine-11.12-d3dmetal-native-thread-context.patch \
  wine-11.12-d3dmetal-native-thread-state-sync.patch \
  wine-11.12-game-mode-process-host-routing.patch \
  wine-11.12-game-mode-direct-target-scope.patch \
  wine-11.12-external-storage-grant-activation.patch \
  wine-11.12-manual-steam-renderer-selection.patch \
  wine-11.12-steam-renderer-control-plane-persistence.patch \
  wine-11.12-managed-darwin-process-journal.patch \
  wine-11.12-forced-font-family-replacements.patch \
  wine-11.12-steam-game-cef-browser-process-policy.patch; do
  if [[ -f "$STAGING/Patches/$patch_name" ]]; then
    WINE_PATCH_METADATA+=$'\n  - `Patches/'"$patch_name"'`'
  fi
done
WINE_PATCH_SET_SHA256="$(source_tree_sha256 "$STAGING/Patches")" ||
  fail "ForgePlay Wine patch-set fingerprint could not be computed"
[[ "$WINE_PATCH_SET_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  fail "ForgePlay Wine patch-set fingerprint is invalid"
[[ "$WINE_PATCH_SET_SHA256" == "$EXPECTED_WINE_PATCH_SET_SHA256" ]] ||
  fail "ForgePlay Wine patch set changed without updating its canonical fingerprint and source notice"

RUNTIME_LAUNCHER_SHA256="$(shasum -a 256 "$STAGING/wine/bin/wine" | awk '{print $1}')"
WINE_INF_SHA256="$(shasum -a 256 "$STAGING/wine/share/wine/wine.inf" | awk '{print $1}')"
WINEBOOT_SHA256="$(shasum -a 256 "$STAGING/wine/lib/wine/x86_64-windows/wineboot.exe" | awk '{print $1}')"
PREFIX_COMPATIBILITY_FINGERPRINT="$({
  printf 'forgeplay-prefix-compatibility-v1\n'
  printf 'wineVersion=11.12\n'
  printf 'architecture=win64\n'
  printf 'wineInfSHA256=%s\n' "$WINE_INF_SHA256"
  printf 'winebootSHA256=%s\n' "$WINEBOOT_SHA256"
} | shasum -a 256 | awk '{print $1}')"
PROVISIONAL_RUNNER_BUILD_FINGERPRINT="$({
  printf 'forgeplay-runtime-build-v1\n'
  printf 'sourceTreeSHA256=%s\n' "$WINE_SOURCE_TREE_SHA256"
  printf 'patchSetSHA256=%s\n' "$WINE_PATCH_SET_SHA256"
  printf 'runnerLauncherSHA256=%s\n' "$RUNTIME_LAUNCHER_SHA256"
  printf 'prefixCompatibilityFingerprint=%s\n' "$PREFIX_COMPATIBILITY_FINGERPRINT"
} | shasum -a 256 | awk '{print $1}')"

python3 - \
  "$STAGING/RuntimeManifest.json" \
  "$WINE_SOURCE_TREE_SHA256" \
  "$WINE_PATCH_SET_SHA256" \
  "$RUNTIME_LAUNCHER_SHA256" \
  "$WINE_INF_SHA256" \
  "$WINEBOOT_SHA256" \
  "$PREFIX_COMPATIBILITY_FINGERPRINT" \
  "$PROVISIONAL_RUNNER_BUILD_FINGERPRINT" <<'PY'
import json
import sys
from pathlib import Path

(
    output,
    source_tree,
    patch_set,
    launcher,
    wine_inf,
    wineboot,
    prefix_fingerprint,
    build_fingerprint,
) = sys.argv[1:]
manifest = {
    "architecture": "win64",
    "patchSetSHA256": patch_set,
    "prefixCompatibilityFingerprint": prefix_fingerprint,
    "runnerBuildFingerprint": build_fingerprint,
    "runnerLauncherSHA256": launcher,
    "runtimeIdentifier": "com.forgeplay.runtime.wine-11.12",
    "schemaVersion": 1,
    "sourceTreeSHA256": source_tree,
    "wineInfSHA256": wine_inf,
    "wineVersion": "11.12",
    "winebootSHA256": wineboot,
}
Path(output).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

python3 "$RUNTIME_SBOM_TOOL" generate \
  "$STAGING" \
  "$RUNTIME_DEPENDENCY_LOCK" \
  "$RENDERER_PAYLOAD_LOCK" \
  "$GSTREAMER_PAYLOAD_LOCK" \
  "$STAGING/RuntimeSBOM.json"
HOST_SUPPORT_SBOM_SHA256="$(shasum -a 256 "$STAGING/RuntimeSBOM.json" | awk '{print $1}')"
HOST_SUPPORT_PAYLOAD_FINGERPRINT="$(python3 - "$STAGING/RuntimeSBOM.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
value = payload.get("payloadFingerprint")
if not isinstance(value, str) or len(value) != 64:
    raise SystemExit("runtime SBOM payloadFingerprint is invalid")
print(value)
PY
)" || fail "runtime host-support payload fingerprint could not be read"
CORE_IDENTITY_JSON="$(python3 "$RUNTIME_CORE_IDENTITY_TOOL" generate "$STAGING")" ||
  fail "runtime core payload identity could not be generated"
CORE_PAYLOAD_HASH_ALGORITHM="$(python3 - "$CORE_IDENTITY_JSON" <<'PY'
import json
import sys

print(json.loads(sys.argv[1])["corePayloadHashAlgorithm"])
PY
)" || fail "runtime core payload hash algorithm could not be read"
CORE_PAYLOAD_JSON="$(python3 - "$CORE_IDENTITY_JSON" <<'PY'
import json
import sys

print(json.dumps(json.loads(sys.argv[1])["corePayloadSHA256"], sort_keys=True, separators=(",", ":")))
PY
)" || fail "runtime core payload map could not be read"
CORE_PAYLOAD_FINGERPRINT="$(python3 - "$CORE_IDENTITY_JSON" <<'PY'
import json
import sys

print(json.loads(sys.argv[1])["corePayloadFingerprint"])
PY
)" || fail "runtime core payload fingerprint could not be read"
RUNNER_BUILD_FINGERPRINT="$({
  printf 'forgeplay-runtime-build-v3\n'
  printf 'sourceTreeSHA256=%s\n' "$WINE_SOURCE_TREE_SHA256"
  printf 'patchSetSHA256=%s\n' "$WINE_PATCH_SET_SHA256"
  printf 'runnerLauncherSHA256=%s\n' "$RUNTIME_LAUNCHER_SHA256"
  printf 'prefixCompatibilityFingerprint=%s\n' "$PREFIX_COMPATIBILITY_FINGERPRINT"
  printf 'hostSupportPayloadFingerprint=%s\n' "$HOST_SUPPORT_PAYLOAD_FINGERPRINT"
  printf 'corePayloadFingerprint=%s\n' "$CORE_PAYLOAD_FINGERPRINT"
} | shasum -a 256 | awk '{print $1}')"

python3 - \
  "$STAGING/RuntimeManifest.json" \
  "$WINE_SOURCE_TREE_SHA256" \
  "$WINE_PATCH_SET_SHA256" \
  "$RUNTIME_LAUNCHER_SHA256" \
  "$WINE_INF_SHA256" \
  "$WINEBOOT_SHA256" \
  "$PREFIX_COMPATIBILITY_FINGERPRINT" \
  "$RUNNER_BUILD_FINGERPRINT" \
  "$HOST_SUPPORT_SBOM_SHA256" \
  "$HOST_SUPPORT_PAYLOAD_FINGERPRINT" \
  "$CORE_PAYLOAD_HASH_ALGORITHM" \
  "$CORE_PAYLOAD_JSON" \
  "$CORE_PAYLOAD_FINGERPRINT" <<'PY'
import json
import sys
from pathlib import Path

(
    output,
    source_tree,
    patch_set,
    launcher,
    wine_inf,
    wineboot,
    prefix_fingerprint,
    build_fingerprint,
    sbom_sha256,
    payload_fingerprint,
    core_payload_hash_algorithm,
    core_payload_json,
    core_payload_fingerprint,
) = sys.argv[1:]
manifest = {
    "architecture": "win64",
    "corePayloadFingerprint": core_payload_fingerprint,
    "corePayloadHashAlgorithm": core_payload_hash_algorithm,
    "corePayloadSHA256": json.loads(core_payload_json),
    "hostSupportPayloadFingerprint": payload_fingerprint,
    "hostSupportSBOMPath": "RuntimeSBOM.json",
    "hostSupportSBOMSHA256": sbom_sha256,
    "patchSetSHA256": patch_set,
    "prefixCompatibilityFingerprint": prefix_fingerprint,
    "runnerBuildFingerprint": build_fingerprint,
    "runnerLauncherSHA256": launcher,
    "runtimeIdentifier": "com.forgeplay.runtime.wine-11.12",
    "schemaVersion": 3,
    "sourceTreeSHA256": source_tree,
    "wineInfSHA256": wine_inf,
    "wineVersion": "11.12",
    "winebootSHA256": wineboot,
}
Path(output).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

cat > "$STAGING/BUILD-METADATA.md" <<'EOF'
# ForgePlay Runtime Build Metadata

- Wine: 11.12
- Supported ForgePlay app host: Apple Silicon arm64 only
- Bundled compatibility-runtime architecture: x86_64 Wine Unix runtime with i386/x86_64 WoW64 Windows payloads; Rosetta is required inside the arm64 app
- Upstream source archive: $WINE_SOURCE_ARCHIVE_URL
- Upstream source signature: $WINE_SOURCE_SIGNATURE_URL
- Upstream source archive SHA-256: $WINE_SOURCE_ARCHIVE_SHA256
- Wine release-key fingerprint: $WINE_SOURCE_SIGNING_KEY_FINGERPRINT
- Corresponding source tree SHA-256: $WINE_SOURCE_TREE_SHA256
- ForgePlay patch-set SHA-256: $WINE_PATCH_SET_SHA256
- Build input: validated `FORGEPLAY_WINE_SOURCE`; its local filesystem path is intentionally excluded
- Build-path hygiene: the canonical builder uses a logical `/forgeplay-runtime` prefix, staged `DESTDIR`, and compiler file-prefix mapping; `/Users/` and `/Volumes/` developer paths are rejected from the compiled Wine payload before packaging
$WINE_PATCH_METADATA
- Runtime identity: deterministic \`RuntimeManifest.json\` records the Wine source, patch set, launcher, \`wine.inf\`, \`wineboot\`, routing-critical Wine modules, host-support SBOM, build, and prefix-compatibility SHA-256 values. Mach-O core-module identities exclude only the replaceable code-signature blob and signature-size metadata so packaging and final distribution signing verify the same executable payload. \`RuntimeSBOM.json\` records every bundled host-support file or approved internal symlink with its content hash, source, version, and license paths. Packaging time and filesystem mtimes are excluded.
- Wine attribution: source validation requires Wine's \`LICENSE\`, \`COPYING.LIB\`, and \`AUTHORS\` files, and packaging copies all three into \`Legal/Wine\`.
- App Sandbox IPC: Wine client and wineserver honor \`WINE_SERVER_ROOT\` and \`WINE_MACH_SERVICE_NAME\`; sandbox builds use the app container and App Group IPC namespace, peer processes reopen the held server lock without truncating it, and Wine unlinks temporary executable-mapping backing files before probing or sharing them.
- Wine synchronization: upstream Wine 11.12 standard wineserver synchronization path only; no out-of-tree synchronization backend is applied
- D3DMetal Wine contract: the project-owned \`forgeplay_d3dmetal.c\` bridge activates only for a Steam game child in a manually selected exact D3DMetal session, loads the explicitly bundled shared library, registers PE image ranges through the public non-native-code-region ABI, and preserves Wine 11.12's upstream Unix-call table. That D3DMetal route enables ForgePlay's scoped macOS/x86_64 native pthread context, synchronizes the mutable Windows static-TLS pointer through Darwin's Win64-reserved slot, uses reentrant Apple time conversion interfaces so libc cannot overwrite the adjacent mirrored PEB slot, and restores overwritten native slots before exit; other manually selected renderers keep upstream GS switching.
- Wine host dependencies: 15 locked x86_64 Wine host dependency artifacts provide the reviewed TLS, font, Vulkan loader, and MoltenVK closure under \`wine/lib\` and \`wine/etc/vulkan/icd.d\`; every source version and SHA-256 is verified before staging
- Media Foundation: Wine's \`winegstreamer\` Unix module is built against GStreamer 1.28.5. The exact locked x86_64 core, MP4, H.264/AAC parser and decoder, Apple VideoToolbox, conversion, and libav fallback closure is isolated under \`wine/gstreamer\`; system plug-ins are disabled and the installed app has no host GStreamer dependency
- Graphics: Vulkan loader and MoltenVK runtime included with bundled Vulkan ICD JSON
- ForgePlay Steam launcher: \`wine/lib/wine/x86_64-windows/forgeplay-steam-launcher.exe\`, built from the project-owned \`Sources/forgeplay_steam_launcher.c\`; it directly invokes Win32 \`CreateProcessW\` through ForgePlay's complete \`--detach -- <Windows command...>\` interface
- Steam WebHelper launch policy: patched i386/x86_64 \`kernelbase.dll\` applies ForgePlay's executable-scoped process argument policy while Valve retains ownership of \`steamwebhelper.exe\`; successful target creation appends the Windows PID and final command line to a host-created per-launch observation file
- Steam game renderer policy: before every Steam launch the caller must select exactly one of D3DMetal, DXMT, D9VK, or DXVK. Patched i386/x86_64 \`kernelbase.dll\` applies only that renderer to Steam game children for the session. Missing or invalid selection is rejected; Direct3D import classification, loader-stage profiles, and mixed renderer compositions are disabled. Patched Unix and Windows \`ntdll\` expose only the selected architecture-specific renderer root, Route V2 records the plan, and Load V3 counts as proof only for an allowlist-owned path with \`path-owner=verified\`.
- Steam game CEF browser policy: the explicit host gate \`FORGEPLAY_STEAM_GAME_CEF_BROWSER_POLICY_ENABLED=1\` adds \`--in-process-gpu\` only to a root PE under a structural \`steamapps/common\` game path when that executable contains the generic \`libcef.dll\` runtime marker. Existing CEF \`--type=\` subprocesses, non-CEF executables, Steam infrastructure, and already-correct command lines are unchanged.
- Game Mode process-host routing: this experimental path is off by default, so ordinary Steam sessions use the standard Wine loader. When explicitly requested, a Unix-only target identity is derived independently for each child from Wine's resolved `ImagePathName`, not a mutable command line or inherited Windows variable. Every resolved executable in a structural `steamapps/common` game tree may enter the same fixed bundled ForgePlay host before PE mapping, including a long-lived game child started by a launcher; `_CommonRedist` and targets outside that tree use the standard Wine loader. Each accepted target with a rejected contract or failed host exec is logged and fails instead of silently continuing without the requested Game Mode host. Routed processes retain the fixed host process identity and icon rather than a game-derived name or PE icon.
- External-storage grants: the Unix \`ntdll\` loader and \`wineserver\` explicitly activate the project-owned grant bridge before Wine initialization. All-absent grant environment values are a normal no-op. A partial or rejected grant emits a path-free failure record and continues through Wine's normal sandbox-limited path so an optional external-storage failure cannot terminate unrelated games. Successful activation emits a path-free \`FORGEPLAY_EXTERNAL_STORAGE_GRANT_V1\` record from each process.
- Managed Darwin process lifecycle: every launch-scoped Wine loader and wineserver appends its Darwin PID and kernel process-start time to an owner-private, bounded, path-free journal. ForgePlay accepts a record only for the matching run UUID, prefix scope, runtime fingerprint, exact bundled executable path, and unchanged process-start identity before termination; wineserver exit alone is not treated as proof that all game processes stopped.
- DXMT macOS window bridge: patched \`winemac.so\` exports the 192-byte \`macdrv_functions\` ABI expected by DXMT and maps Wine 11.12 client/content views to Metal-backed DXGI window swapchains
- Steam SDL compatibility payload: versioned \`SteamCompat/sdl2-compat\` binaries and license material are copied from the ForgePlay runtime source tree
- Windows Korean font compatibility: exact Nanum Gothic Regular/Bold payloads are bundled under \`wine/share/wine/fonts\`; Wine GDI and DirectWrite expose an opt-in forced-family replacement for installed or private Tahoma faces; the SIL Open Font License text is bundled under \`Legal/NanumGothic/OFL.txt\`
- Host support payload: runtime policy and legal resources are copied independently; arbitrary top-level \`Frameworks\` dylibs and checked-in runtime output as a Frameworks packaging input are prohibited
- Renderer payload: the four locked Apple GPTK/D3DMetal, D9VK, DXMT, and DXVK component trees are verified from the explicit build-time \`FORGEPLAY_RENDERER_SOURCE\`, then bundled under \`Frameworks/renderer\`; the installed app has no external runtime dependency
- Packaging: the six D3DMetal Unix module names are exact internal links to one bundled `external/libd3dshared.dylib`; all other symlinks and every hardlink are rejected
- Packaged at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')

Configure summary:

\`\`\`
--prefix=/forgeplay-runtime (installed through a staged DESTDIR)
--enable-win64
--enable-archs=i386,x86_64
--disable-tests
--without-x --without-alsa --without-capi --without-cups --without-dbus
--without-ffmpeg --without-gphoto --without-gssapi
--without-inotify --without-krb5 --without-netapi --without-opencl
--without-oss --without-pcap --without-pcsclite --without-pulse
--without-sane --without-sdl --without-udev --without-usb --without-v4l2
--without-wayland
host C/C++/Objective-C flags and PE CROSSCFLAGS map local roots to wine-11.12/source and wine-11.12/build
\`\`\`
EOF

cat > "$STAGING/SOURCE-AVAILABILITY.md" <<'EOF'
# ForgePlay Runtime Source Availability

This package contains Wine 11.12 under the GNU Lesser General Public License 2.1 or later.
The corresponding source is available without relying on a developer machine path:

- Upstream Wine 11.12 source archive: $WINE_SOURCE_ARCHIVE_URL
- Upstream detached signature: $WINE_SOURCE_SIGNATURE_URL
- Upstream source archive SHA-256: `$WINE_SOURCE_ARCHIVE_SHA256`
- Wine release-key fingerprint: `$WINE_SOURCE_SIGNING_KEY_FINGERPRINT`
- ForgePlay modifications: the complete patch set shipped in this package under \`Patches/\`
- Independent renderer behavior contract: \`Patches/wine-11.12-forgeplay-d3dmetal-bridge-contract.md\`
- Validated corresponding source tree SHA-256: \`$WINE_SOURCE_TREE_SHA256\`
- Packaged ForgePlay patch-set SHA-256: \`$WINE_PATCH_SET_SHA256\`

The upstream archive and the complete packaged patch set are the machine-readable materials used to
reconstruct the modified Wine source for this runtime. The local \`FORGEPLAY_WINE_SOURCE\` build input
is validated during packaging, but its filesystem path is never written into the app bundle.
Wine's \`LICENSE\`, \`COPYING.LIB\`, and \`AUTHORS\` files are validated from that source tree and
copied into \`Legal/Wine\`.

To reconstruct the modified source from the public upstream archive and the patch files in this
package, download and verify the archive, extract it, and apply these patches in order:

\`\`\`sh
curl -fLO "$WINE_SOURCE_ARCHIVE_URL"
curl -fLO "$WINE_SOURCE_SIGNATURE_URL"
printf '%s  %s\n' '$WINE_SOURCE_ARCHIVE_SHA256' wine-11.12.tar.xz | shasum -a 256 -c -
gpg --status-fd 1 --verify wine-11.12.tar.xz.sign wine-11.12.tar.xz 2>/dev/null | \
  grep -F 'VALIDSIG $WINE_SOURCE_SIGNING_KEY_FINGERPRINT'
tar -xf wine-11.12.tar.xz
for patch_file in \
  Patches/wine-11.12-steam-cef-other-process-opengl-surface.patch \
  Patches/wine-11.12-forgeplay-d3dmetal-bridge.patch \
  Patches/wine-11.12-forgeplay-metal-window-surface-contract.patch \
  Patches/wine-11.12-moltenvk-portability-enumeration.patch \
  Patches/wine-11.12-prefix-scoped-wineserver-root.patch \
  Patches/wine-11.12-app-group-mach-service.patch \
  Patches/wine-11.12-app-sandbox-server-lock.patch \
  Patches/wine-11.12-app-sandbox-executable-mappings.patch \
  Patches/wine-11.12-macos-bundled-runtime-loading.patch \
  Patches/wine-11.12-executable-scoped-process-arguments.patch \
  Patches/wine-11.12-steam-game-renderer-process-policy.patch \
  Patches/wine-11.12-d3dmetal-native-thread-context.patch \
  Patches/wine-11.12-d3dmetal-native-thread-state-sync.patch \
  Patches/wine-11.12-game-mode-process-host-routing.patch \
  Patches/wine-11.12-game-mode-direct-target-scope.patch \
  Patches/wine-11.12-external-storage-grant-activation.patch \
  Patches/wine-11.12-manual-steam-renderer-selection.patch \
  Patches/wine-11.12-steam-renderer-control-plane-persistence.patch \
  Patches/wine-11.12-managed-darwin-process-journal.patch \
  Patches/wine-11.12-forced-font-family-replacements.patch \
  Patches/wine-11.12-steam-game-cef-browser-process-policy.patch; do
  patch -d wine-11.12 -p1 < "\$patch_file"
done
\`\`\`

Signature verification requires the WineHQ release-signing key and a local OpenPGP verifier. The
SHA-256 values above identify the exact validated source tree and packaged patch set; they are not
local paths and do not expose the packaging workstation. The source-tree fingerprint excludes VCS
metadata, Finder metadata, patch backup/reject files, and the generated `configure` file; it includes
`configure.ac`, which is the authoritative build-system source modified by the ForgePlay patch set.

ForgePlay's project-owned Windows Steam launcher source is copied into
\`Sources/forgeplay_steam_launcher.c\` and built into
\`wine/lib/wine/x86_64-windows/forgeplay-steam-launcher.exe\` during packaging. It directly invokes
Win32 \`CreateProcessW\` through the complete ForgePlay-owned
\`--detach -- <Windows command...>\` contract implemented in that source file.

ForgePlay's executable-scoped process argument patch keeps Valve's
\`steamwebhelper.exe\` in place and applies the Steam CEF compatibility arguments from Wine's
32-bit or 64-bit process-creation path. Steam updates can therefore replace their own executable
without deleting ForgePlay's launch policy. After successful target creation, Wine records only the
Windows PID and final target command line in the host-created per-launch observation file; it does
not serialize the process environment.

ForgePlay's Steam game CEF browser policy is activated by the host with
\`FORGEPLAY_STEAM_GAME_CEF_BROWSER_POLICY_ENABLED=1\` for a Steam session, then applies only to a
root executable in a separator-delimited \`steamapps/common\` tree that contains the generic
\`libcef.dll\` runtime marker. It appends one \`--in-process-gpu\` argument so the CEF browser process
does not depend on Wine's incompatible out-of-process GPU startup path. CEF \`--type=\` subprocesses,
non-CEF executables, Steam infrastructure roles, and command lines that already contain the argument
remain unchanged. The executable itself is never replaced or modified.

ForgePlay's Steam game renderer process patch leaves Steam and Steam WebHelper on the base Wine
renderer environment. Before every Steam launch the user must select exactly one of D3DMetal, DXMT,
D9VK, or DXVK. That single renderer is applied to Steam game children for the whole session.
Automatic Direct3D import classification, loader-stage profiles, and mixed renderer compositions
are not used. A missing or invalid manual selection is rejected instead of falling back to another
renderer. The Unix loader places only the selected renderer root ahead of Wine's compiled DLL
directory, while the Windows loader prepends only its matching i386 or x86_64 directories. Route V2
records use \`manual-session-d3dmetal\`, \`manual-session-dxmt\`, \`manual-session-d9vk\`, or
  \`manual-session-dxvk\` as the exact selection reason and describe the selected plan. A Load V3
  record proves an actual renderer load only when its
  resolved path exactly matches the active architecture-specific allowlist and reports
  \`path-owner=verified\`. Renderer state remains process-scoped and is scrubbed from Steam
  infrastructure children. The host-owned manual selection, architecture component, and matching DLL
  path controls remain available when Steam reexecutes itself, so the relaunched client can construct
  the same selected renderer for later game children. Separator-delimited \`_CommonRedist\` descendants
  are infrastructure and never enter the game-renderer route.

ForgePlay's Game Mode process-host routing is an explicit beta selection and remains off for a
standard Steam launch. It keeps Steam's game lineage separate from the selected Direct3D renderer.
The direct-target scope derives a Unix-only identity independently for each child from Wine's
resolved \`RTL_USER_PROCESS_PARAMETERS.ImagePathName\`, not a mutable command line or inherited
Windows variable. Every resolved executable in a separator-delimited \`steamapps/common\` game tree
can enter the same fixed host, including a long-lived game child started by a launcher, regardless
of account, volume, drive letter, library root, Steam App ID, or game title. \`_CommonRedist\` and
targets outside that tree clear the Game Mode target identity and continue through the standard
Wine loader. When the beta host is requested, each accepted target enters the fixed pre-signed
\`Contents/Helpers/GameModeProcessHost.app\` before PE mapping. Its argv, current directory,
inherited handles, Wine server context, and Darwin PID remain on the original Steam-created process
path. A host contract or exec failure for an accepted target remains fail-closed. The helper
retains its fixed executable, process identity, and icon; ForgePlay does not replace them with a
per-game display name or PE icon.

ForgePlay's external-storage grant activation patch runs explicitly at the start of both the Unix
\`ntdll\` loader and \`wineserver\`. If all four grant environment values are absent, Wine continues
normally. If any value is present, all four must be non-empty and the project-owned bridge must load
and accept the manifest for external storage to become accessible. A rejected or incomplete grant
emits a bounded, path-free failure reason and continues through Wine's normal sandbox-limited path;
this preserves launch for games that do not need the unavailable external root. Successful
activation emits only the bounded \`FORGEPLAY_EXTERNAL_STORAGE_GRANT_V1\` status record; it does not
log a storage path or bookmark payload.

ForgePlay's managed Darwin process journal patch appends a bounded record when the Unix Wine loader
or wineserver begins. Each record contains only the launch UUID, opaque prefix scope, runtime
fingerprint, Darwin PID, and kernel process-start time; the owner-private file path is created by the
host and is never serialized. The immutable Unix launch key
\`FORGEPLAY_MANAGED_WINE_PROCESS_EVIDENCE_FILE\` identifies that pre-created journal across every
Wine child, including children that replace their Windows environment. At shutdown ForgePlay
validates the exact bundled executable path and
the unchanged start identity before signaling that PID, then reads the journal again after
\`SIGTERM\`, \`SIGKILL\`, and the wineserver barrier. An absent or invalid journal cannot be
misreported as a clean launch session.

ForgePlay's D3DMetal bridge is implemented in the project-owned
\`dlls/ntdll/unix/forgeplay_d3dmetal.c\` source from the documented public behavior contract. The
bridge is disabled unless the selected game child carries ForgePlay's explicit activation and target
selectors. It resolves only the public non-native-code-region ABI from the bundled D3DMetal shared
library, registers loaded PE image ranges, and leaves Wine 11.12's upstream Unix-call table intact.
The manually selected exact D3DMetal route also enables ForgePlay's scoped native pthread context.
That context synchronizes the mutable Windows static-TLS pointer through Darwin's Win64-reserved
slot and uses reentrant Apple time conversion interfaces so libc cannot overwrite the adjacent
mirrored PEB slot. The original native slots are restored before thread exit. Other renderer and
deferred routes keep Wine's standard GS switching.

ForgePlay's Metal renderer window-surface contract patch independently exports the public
\`macdrv_functions\` data symbol from \`winemac.so\`. Its table exposes Wine's display-state
initialization, window-data ownership, main-thread dispatch, and Metal view/layer operations through
a renderer-neutral ABI with compile-time offset checks and balanced acquire/release behavior.

The runtime uses Wine 11.12's standard wineserver synchronization path. No separate out-of-tree
synchronization backend is applied by the ForgePlay patch set.

ForgePlay's versioned SDL compatibility payload is copied into \`SteamCompat/sdl2-compat\` with its
license material. Packaging fails when the payload is missing SDL2.dll, SDL3.dll, or a license file.

ForgePlay's Windows font compatibility payload includes the exact Nanum Gothic Regular and Bold
font files under \`wine/share/wine/fonts\`. Their SIL Open Font License text is included under
\`Legal/NanumGothic/OFL.txt\`; packaging fails if any of these three files is missing or differs from
the reviewed SHA-256 digest. The opt-in \`HKCU\\Software\\Wine\\Fonts\\ForcedReplacements\`
contract is implemented in both Wine GDI and DirectWrite so an installed or game-private Tahoma
family cannot bypass the managed Korean family selected by ForgePlay.

ForgePlay's runtime policy plist and legal resources are copied separately from host binaries.
The packager never copies the checked-in runtime's \`Frameworks\` directory and rejects a renderer
source rooted in that output tree. The complete renderer payload is an explicit build-time input,
verified against \`Config/ForgePlayRendererPayload.lock.json\`, and becomes part of the self-contained
app runtime rather than an external runtime dependency.

The package materializes the 15 exact x86_64 Wine host dependency artifacts declared in
\`Config/ForgePlayRuntimeDependencies.lock.json\` into \`wine/lib\` and \`wine/etc/vulkan/icd.d\`, and
validates every source SHA-256 before copying. It neither scans the host dynamically for extra dependencies nor exposes
arbitrary top-level \`Frameworks\` libraries through a loader fallback path. Formula license files
are copied from the same pinned Cellar versions into \`Legal/\`.

Wine Media Foundation support is backed by the exact GStreamer 1.28.5 artifacts declared in
\`Config/ForgePlayGStreamerPayload.lock.json\`. Packaging verifies each official macOS SDK source
file, thins it to x86_64, isolates the closure under \`wine/gstreamer\`, and copies the corresponding
license material into \`Legal/GStreamer\`. Runtime launchers disable system GStreamer plug-ins and
expose only this reviewed payload.

Locked game renderer payloads stay under \`Frameworks/renderer\` and are not copied into the active
Wine module directories. The App Store payload preparation step removes Apple GPTK and D3DMetal
redistributables; Windows Steam uses base Wine Vulkan/MoltenVK rather than a game renderer overlay.
EOF

PACKAGED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
python3 - \
  "$STAGING/BUILD-METADATA.md" \
  "$STAGING/SOURCE-AVAILABILITY.md" \
  "$WINE_SOURCE_ARCHIVE_URL" \
  "$WINE_SOURCE_SIGNATURE_URL" \
  "$WINE_SOURCE_ARCHIVE_SHA256" \
  "$WINE_SOURCE_SIGNING_KEY_FINGERPRINT" \
  "$WINE_SOURCE_TREE_SHA256" \
  "$WINE_PATCH_SET_SHA256" \
  "$WINE_PATCH_METADATA" \
  "$PACKAGED_AT" <<'PY'
import sys
from pathlib import Path

(
    build_metadata_path,
    source_availability_path,
    source_archive_url,
    source_signature_url,
    source_archive_sha256,
    source_signing_key_fingerprint,
    source_tree_sha256,
    patch_set_sha256,
    patch_metadata,
    packaged_at,
) = sys.argv[1:]

replacements = {
    "$WINE_SOURCE_ARCHIVE_URL": source_archive_url,
    "$WINE_SOURCE_SIGNATURE_URL": source_signature_url,
    "$WINE_SOURCE_ARCHIVE_SHA256": source_archive_sha256,
    "$WINE_SOURCE_SIGNING_KEY_FINGERPRINT": source_signing_key_fingerprint,
    "$WINE_SOURCE_TREE_SHA256": source_tree_sha256,
    "$WINE_PATCH_SET_SHA256": patch_set_sha256,
    "$WINE_PATCH_METADATA": patch_metadata,
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')": packaged_at,
}

for output_path in (build_metadata_path, source_availability_path):
    path = Path(output_path)
    content = path.read_text(encoding="utf-8")
    for placeholder, value in replacements.items():
        content = content.replace(placeholder, value)
    content = content.replace(r"\`", "`").replace(r"\$patch_file", "$patch_file")
    if any(placeholder in content for placeholder in replacements):
        raise SystemExit(f"runtime documentation placeholder was not rendered: {path}")
    path.write_text(content, encoding="utf-8")
PY

unexpected_staged_symlink=""
while IFS= read -r -d '' staged_symlink; do
  if is_staged_d3dmetal_shared_unix_module_link_path "$staged_symlink"; then
    require_staged_d3dmetal_shared_unix_module_link \
      "$STAGING/Frameworks/renderer/d3dmetal" \
      "$(basename "$staged_symlink" .so)"
    continue
  fi
  unexpected_staged_symlink="$staged_symlink"
  break
done < <(find "$STAGING" -type l -print0)
if [[ -n "$unexpected_staged_symlink" ]]; then
  printf '%s\n' "$unexpected_staged_symlink" >&2
  fail "staged runtime contains an unapproved symlink"
fi

hardlinked_file="$(
  find "$STAGING" -type f -exec sh -c '
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
  fail "staged runtime contains hardlinked files"
fi

mkdir -p "$(dirname "$OUTPUT_ROOT")"
if [[ -e "$OUTPUT_ROOT" || -L "$OUTPUT_ROOT" ]]; then
  rm -rf -- "$OUTPUT_ROOT"
fi
mv "$STAGING" "$OUTPUT_ROOT"
trap - EXIT

printf 'Packaged ForgePlay Runtime: %s\n' "$OUTPUT_ROOT"
