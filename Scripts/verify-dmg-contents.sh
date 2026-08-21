#!/usr/bin/env bash
set -euo pipefail

DMG_ROOT="${1:-}"

fail() {
  printf 'error: invalid DMG contents: %s\n' "$*" >&2
  exit 1
}

if [[ -z "$DMG_ROOT" ]]; then
  fail "root path is required"
fi

if [[ -L "$DMG_ROOT" || ! -d "$DMG_ROOT" ]]; then
  fail "root must be a non-symlink directory: $DMG_ROOT"
fi

APP_PATH="$DMG_ROOT/ForgePlay.app"
APPLICATIONS_LINK="$DMG_ROOT/Applications"
CONTENTS_DIR="$APP_PATH/Contents"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

unexpected_entries="$(
  find "$DMG_ROOT" -mindepth 1 -maxdepth 1 \
    ! -name "ForgePlay.app" \
    ! -name "Applications" \
    -print
)"
if [[ -n "$unexpected_entries" ]]; then
  printf '%s\n' "$unexpected_entries" >&2
  fail "root must contain only ForgePlay.app and the Applications symlink"
fi

if [[ -L "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  fail "ForgePlay.app must be a non-symlink app bundle"
fi

if [[ -L "$CONTENTS_DIR" || ! -d "$CONTENTS_DIR" ]]; then
  fail "ForgePlay.app Contents must be a non-symlink directory"
fi

if [[ -L "$INFO_PLIST" || ! -f "$INFO_PLIST" ]]; then
  fail "ForgePlay.app is missing Contents/Info.plist"
fi
if [[ ! -x "$PLIST_BUDDY" ]]; then
  fail "PlistBuddy is required to verify ForgePlay.app identity"
fi

bundle_name="$("$PLIST_BUDDY" -c 'Print :CFBundleName' "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$bundle_name" != "ForgePlay" ]]; then
  fail "ForgePlay.app CFBundleName must be ForgePlay, got ${bundle_name:-<missing>}"
fi

display_name="$("$PLIST_BUDDY" -c 'Print :CFBundleDisplayName' "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$display_name" != "ForgePlay" ]]; then
  fail "ForgePlay.app CFBundleDisplayName must be ForgePlay, got ${display_name:-<missing>}"
fi

package_type="$("$PLIST_BUDDY" -c 'Print :CFBundlePackageType' "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$package_type" != "APPL" ]]; then
  fail "ForgePlay.app CFBundlePackageType must be APPL, got ${package_type:-<missing>}"
fi

if [[ ! -L "$APPLICATIONS_LINK" ]]; then
  fail "Applications entry must be a symlink"
fi

APPLICATIONS_TARGET="$(readlink "$APPLICATIONS_LINK")"
if [[ "$APPLICATIONS_TARGET" != "/Applications" ]]; then
  fail "Applications symlink must point to /Applications, got $APPLICATIONS_TARGET"
fi
