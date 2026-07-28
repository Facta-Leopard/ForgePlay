#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_INPUT="${1:-}"
BUILD_INPUT="${2:-}"
INSTALL_INPUT="${3:-}"
JOBS="${FORGEPLAY_WINE_BUILD_JOBS:-4}"
HOMEBREW_X86_PREFIX="${FORGEPLAY_HOMEBREW_X86_PREFIX:-/usr/local}"
GSTREAMER_SDK_ROOT="${FORGEPLAY_GSTREAMER_SDK_ROOT:-}"
LOGICAL_PREFIX="/forgeplay-runtime"
SOURCE_VALIDATOR="$SCRIPT_DIR/package-forgeplay-runtime.sh"
BUILD_PATH_VERIFIER="$SCRIPT_DIR/verify-wine-runtime-build-paths.py"

fail() {
  printf 'error: ForgePlay Wine Runtime build failed: %s\n' "$*" >&2
  exit 1
}

reject_symlink_parent_components() {
  local candidate="$1"
  local label="$2"
  local current parent

  [[ "$candidate" = /* ]] || fail "$label must be an absolute path"
  current="$candidate"
  while [[ "$current" != "/" ]]; do
    [[ ! -L "$current" ]] || fail "$label must not contain symlink path components: $current"
    parent="$(dirname "$current")"
    [[ "$parent" != "$current" ]] || break
    current="$parent"
  done
}

[[ "$#" -eq 3 ]] ||
  fail "usage: build-forgeplay-wine-runtime.sh <patched Wine source root> <new build root> <new install root>"
[[ "$JOBS" =~ ^[1-9][0-9]*$ && "$JOBS" -le 16 ]] ||
  fail "FORGEPLAY_WINE_BUILD_JOBS must be an integer from 1 through 16"
[[ -n "$GSTREAMER_SDK_ROOT" ]] ||
  fail "FORGEPLAY_GSTREAMER_SDK_ROOT must point to the extracted GStreamer 1.0 SDK root"
[[ -d "$GSTREAMER_SDK_ROOT" && ! -L "$GSTREAMER_SDK_ROOT" ]] ||
  fail "GStreamer SDK root must be a non-symlink directory: $GSTREAMER_SDK_ROOT"
GSTREAMER_SDK_ROOT="$(cd "$GSTREAMER_SDK_ROOT" && pwd -P)"
reject_symlink_parent_components "$GSTREAMER_SDK_ROOT" "GStreamer SDK root"
case "$GSTREAMER_SDK_ROOT" in
  *[[:space:]]*) fail "GStreamer SDK root must not contain whitespace" ;;
esac
for gstreamer_sdk_file in \
  "$GSTREAMER_SDK_ROOT/bin/pkg-config" \
  "$GSTREAMER_SDK_ROOT/include/gstreamer-1.0/gst/gst.h" \
  "$GSTREAMER_SDK_ROOT/lib/libgstreamer-1.0.0.dylib" \
  "$GSTREAMER_SDK_ROOT/lib/pkgconfig/gstreamer-1.0.pc"; do
  [[ -f "$gstreamer_sdk_file" && ! -L "$gstreamer_sdk_file" ]] ||
    fail "required GStreamer SDK file is unavailable: $gstreamer_sdk_file"
done
/usr/bin/lipo "$GSTREAMER_SDK_ROOT/lib/libgstreamer-1.0.0.dylib" -verify_arch x86_64 ||
  fail "GStreamer SDK does not provide the required x86_64 runtime architecture"
GSTREAMER_PKG_CONFIG_PATH="$GSTREAMER_SDK_ROOT/lib/pkgconfig"
for gstreamer_package in \
  gstreamer-1.0 \
  gstreamer-video-1.0 \
  gstreamer-audio-1.0 \
  gstreamer-tag-1.0; do
  PKG_CONFIG_PATH="$GSTREAMER_PKG_CONFIG_PATH" \
    "$GSTREAMER_SDK_ROOT/bin/pkg-config" --exists "$gstreamer_package" ||
    fail "GStreamer SDK is missing required pkg-config package: $gstreamer_package"
done

for required_tool in "$SOURCE_VALIDATOR" "$BUILD_PATH_VERIFIER"; do
  [[ -f "$required_tool" && ! -L "$required_tool" ]] ||
    fail "required build tool must be a non-symlink file: $required_tool"
done
for cross_compiler in \
  "$HOMEBREW_X86_PREFIX/bin/x86_64-w64-mingw32-gcc" \
  "$HOMEBREW_X86_PREFIX/bin/i686-w64-mingw32-gcc"; do
  [[ -x "$cross_compiler" ]] || fail "required MinGW cross-compiler is unavailable: $cross_compiler"
done
HOMEBREW_PKG_CONFIG="$HOMEBREW_X86_PREFIX/bin/pkg-config"
[[ -x "$HOMEBREW_PKG_CONFIG" ]] ||
  fail "required x86_64 Homebrew pkg-config is unavailable: $HOMEBREW_PKG_CONFIG"
HOMEBREW_PKG_CONFIG_PATH="$HOMEBREW_X86_PREFIX/lib/pkgconfig:$HOMEBREW_X86_PREFIX/share/pkgconfig"
FREETYPE_CFLAGS="$(
  PKG_CONFIG_PATH="$HOMEBREW_PKG_CONFIG_PATH" \
    "$HOMEBREW_PKG_CONFIG" --cflags freetype2
)" || fail "unable to resolve the x86_64 Homebrew FreeType build flags"
FREETYPE_LIBS="$(
  PKG_CONFIG_PATH="$HOMEBREW_PKG_CONFIG_PATH" \
    "$HOMEBREW_PKG_CONFIG" --libs freetype2
)" || fail "unable to resolve the x86_64 Homebrew FreeType linker flags"

[[ -d "$SOURCE_INPUT" && ! -L "$SOURCE_INPUT" ]] ||
  fail "patched Wine source root must be a non-symlink directory: $SOURCE_INPUT"
SOURCE_ROOT="$(cd "$SOURCE_INPUT" && pwd -P)"
BUILD_ROOT="$BUILD_INPUT"
INSTALL_ROOT="$INSTALL_INPUT"
reject_symlink_parent_components "$SOURCE_ROOT" "patched Wine source root"
reject_symlink_parent_components "$BUILD_ROOT" "build root"
reject_symlink_parent_components "$INSTALL_ROOT" "install root"
case "$SOURCE_ROOT$BUILD_ROOT$INSTALL_ROOT" in
  *[[:space:]]*) fail "source, build, and install roots must not contain whitespace" ;;
esac
[[ ! -e "$BUILD_ROOT" && ! -L "$BUILD_ROOT" ]] || fail "build root already exists: $BUILD_ROOT"
[[ ! -e "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]] || fail "install root already exists: $INSTALL_ROOT"

python3 - "$SOURCE_ROOT" "$BUILD_ROOT" "$INSTALL_ROOT" "$REPO_ROOT" <<'PY' ||
import os
import sys

source, build, install, repository = map(os.path.realpath, sys.argv[1:])
paths = {"source": source, "build": build, "install": install}
if len(set(paths.values())) != len(paths):
    raise SystemExit("source, build, and install roots must be distinct")
for first_name, first in paths.items():
    for second_name, second in paths.items():
        if first_name == second_name:
            continue
        if os.path.commonpath([first, second]) == first:
            raise SystemExit(f"{first_name} root must not contain {second_name} root")
if os.path.commonpath([build, repository]) in {build, repository}:
    raise SystemExit("build root must be outside the repository")
if os.path.commonpath([install, repository]) in {install, repository}:
    raise SystemExit("install root must be outside the repository")
PY
  fail "source, build, or install root relationship is unsafe"

FORGEPLAY_WINE_SOURCE="$SOURCE_ROOT" /bin/bash "$SOURCE_VALIDATOR" --validate-wine-source

mkdir -p "$BUILD_ROOT"
INSTALL_STAGE="${INSTALL_ROOT}.staging.$$"
[[ ! -e "$INSTALL_STAGE" && ! -L "$INSTALL_STAGE" ]] ||
  fail "install staging root already exists: $INSTALL_STAGE"
mkdir -p "$INSTALL_STAGE"

cleanup() {
  if [[ -d "$INSTALL_STAGE" && ! -L "$INSTALL_STAGE" ]]; then
    rm -rf -- "$INSTALL_STAGE"
  fi
}
trap cleanup EXIT

strip_installed_macho_debug_symbols() {
  local install_root="$1"
  local candidate description
  local stripped_count=0

  while IFS= read -r -d '' candidate; do
    description="$(/usr/bin/file -b "$candidate")" ||
      fail "unable to inspect installed Runtime file type: $candidate"
    case "$description" in
      Mach-O*)
        /usr/bin/strip -S "$candidate" ||
          fail "unable to remove developer-path debug metadata from installed Mach-O: $candidate"
        stripped_count=$((stripped_count + 1))
        ;;
    esac
  done < <(
    find \
      "$install_root/bin" \
      "$install_root/lib/wine" \
      -type f -print0
  )

  [[ "$stripped_count" -gt 0 ]] ||
    fail "clean Wine install contains no Mach-O files to normalize"
  printf 'Removed non-runtime debug metadata from installed Wine Mach-O files: %s\n' \
    "$stripped_count"
}

normalize_installed_winegstreamer_search_path() {
  local install_root="$1"
  local winegstreamer="$install_root/lib/wine/x86_64-unix/winegstreamer.so"
  [[ -f "$winegstreamer" && ! -L "$winegstreamer" ]] ||
    fail "GStreamer-enabled Wine build did not install winegstreamer.so"

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
  if ! otool -l "$winegstreamer" 2>/dev/null |
      awk '/cmd LC_RPATH/{seen=1; next} seen && /path /{print $2; seen=0}' |
      grep -Fxq '@loader_path/../../../gstreamer/lib'; then
    install_name_tool \
      -add_rpath '@loader_path/../../../gstreamer/lib' \
      "$winegstreamer" ||
      fail "unable to add the isolated GStreamer runtime search path"
  fi
}

BUILD_TOOL_PATH="/opt/homebrew/opt/bison/bin:$HOMEBREW_X86_PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/sbin"
PATH_MAP_FLAGS="-g -O2 -ffile-prefix-map=$SOURCE_ROOT=wine-11.12/source -ffile-prefix-map=$BUILD_ROOT=wine-11.12/build"

(
  cd "$BUILD_ROOT"
  PATH="$BUILD_TOOL_PATH" \
  CC='clang -arch x86_64' \
  CXX='clang++ -arch x86_64' \
  CFLAGS="$PATH_MAP_FLAGS" \
  CXXFLAGS="$PATH_MAP_FLAGS" \
  OBJCFLAGS="$PATH_MAP_FLAGS" \
  CROSSCFLAGS="$PATH_MAP_FLAGS" \
  FREETYPE_CFLAGS="$FREETYPE_CFLAGS" \
  FREETYPE_LIBS="$FREETYPE_LIBS" \
  PKG_CONFIG="$GSTREAMER_SDK_ROOT/bin/pkg-config" \
  PKG_CONFIG_PATH="$GSTREAMER_PKG_CONFIG_PATH" \
    "$SOURCE_ROOT/configure" \
      --prefix="$LOGICAL_PREFIX" \
      --host=x86_64-apple-darwin \
      --enable-win64 \
      --enable-archs=i386,x86_64 \
      --disable-tests \
      --without-x --without-alsa --without-capi --without-cups --without-dbus \
      --without-ffmpeg --without-gphoto --without-gssapi \
      --without-inotify --without-krb5 --without-netapi --without-opencl \
      --without-oss --without-pcap --without-pcsclite --without-pulse \
      --without-sane --without-sdl --without-udev --without-usb --without-v4l2 \
      --without-wayland
  PATH="$BUILD_TOOL_PATH" \
    make -j"$JOBS"
  PATH="$BUILD_TOOL_PATH" \
    make -j"$JOBS" DESTDIR="$INSTALL_STAGE" install
)

STAGED_INSTALL_ROOT="$INSTALL_STAGE$LOGICAL_PREFIX"
[[ -x "$STAGED_INSTALL_ROOT/bin/wine" && -x "$STAGED_INSTALL_ROOT/bin/wineserver" ]] ||
  fail "clean Wine install did not produce the required launchers: $STAGED_INSTALL_ROOT"
strip_installed_macho_debug_symbols "$STAGED_INSTALL_ROOT"
normalize_installed_winegstreamer_search_path "$STAGED_INSTALL_ROOT"
python3 "$BUILD_PATH_VERIFIER" \
  "$STAGED_INSTALL_ROOT/bin" \
  "$STAGED_INSTALL_ROOT/lib/wine"
mv "$STAGED_INSTALL_ROOT" "$INSTALL_ROOT"
trap - EXIT
cleanup

printf 'Built clean ForgePlay Wine Runtime install root: %s\n' "$INSTALL_ROOT"
