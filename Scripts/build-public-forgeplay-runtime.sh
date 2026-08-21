#!/bin/bash
set -euo pipefail

readonly FORGEPLAY_SYSTEM_TOOL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PATH="$FORGEPLAY_SYSTEM_TOOL_PATH"
export PATH
unset CDPATH

SOURCE_EXPORT=""
TRUSTED_GIT_REPOSITORY=""
WINE_SOURCE_ARCHIVE=""
GSTREAMER_SDK_ROOT=""
RENDERER_SOURCE=""
RUNTIME_POLICY_SOURCE=""
TRANSACTION_ROOT=""

fail() {
  printf 'error: public Runtime build failed: %s\n' "$*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --source-export) SOURCE_EXPORT="${2:-}"; shift 2 ;;
    --trusted-git-repository) TRUSTED_GIT_REPOSITORY="${2:-}"; shift 2 ;;
    --wine-source-archive) WINE_SOURCE_ARCHIVE="${2:-}"; shift 2 ;;
    --gstreamer-sdk-root) GSTREAMER_SDK_ROOT="${2:-}"; shift 2 ;;
    --renderer-source) RENDERER_SOURCE="${2:-}"; shift 2 ;;
    --runtime-policy-source) RUNTIME_POLICY_SOURCE="${2:-}"; shift 2 ;;
    --transaction-root) TRANSACTION_ROOT="${2:-}"; shift 2 ;;
    *) fail "unknown or incomplete option: $1" ;;
  esac
done

[[ -n "$SOURCE_EXPORT" && -n "$TRUSTED_GIT_REPOSITORY" &&
   -n "$WINE_SOURCE_ARCHIVE" && -n "$GSTREAMER_SDK_ROOT" &&
   -n "$RENDERER_SOURCE" && -n "$RUNTIME_POLICY_SOURCE" &&
   -n "$TRANSACTION_ROOT" ]] || fail "all public Runtime build inputs are required"

for input in "$SOURCE_EXPORT" "$TRUSTED_GIT_REPOSITORY" "$GSTREAMER_SDK_ROOT" \
    "$RENDERER_SOURCE" "$RUNTIME_POLICY_SOURCE"; do
  [[ "$input" = /* && -d "$input" && ! -L "$input" &&
     "$(cd "$input" && /bin/pwd -P)" == "$input" ]] ||
    fail "directory input must be an exact absolute non-symlink directory: $input"
done
[[ "$WINE_SOURCE_ARCHIVE" = /* && -f "$WINE_SOURCE_ARCHIVE" &&
   ! -L "$WINE_SOURCE_ARCHIVE" ]] ||
  fail "Wine source archive must be an absolute non-symlink regular file"
[[ "$TRANSACTION_ROOT" = /* && ! -e "$TRANSACTION_ROOT" && ! -L "$TRANSACTION_ROOT" ]] ||
  fail "transaction root must be a fresh absolute path"
TRANSACTION_PARENT="$(/usr/bin/dirname "$TRANSACTION_ROOT")"
[[ -d "$TRANSACTION_PARENT" && ! -L "$TRANSACTION_PARENT" &&
   "$(cd "$TRANSACTION_PARENT" && /bin/pwd -P)" == "$TRANSACTION_PARENT" ]] ||
  fail "transaction parent must be an exact absolute non-symlink directory"

/usr/bin/python3 - "$TRANSACTION_ROOT" "$SOURCE_EXPORT" "$TRUSTED_GIT_REPOSITORY" \
  "$WINE_SOURCE_ARCHIVE" "$GSTREAMER_SDK_ROOT" "$RENDERER_SOURCE" \
  "$RUNTIME_POLICY_SOURCE" <<'PY'
import os
import sys

transaction, *inputs = map(os.path.normpath, sys.argv[1:])
for candidate in inputs:
    if os.path.commonpath([transaction, candidate]) in {transaction, candidate}:
        raise SystemExit("transaction root must be disjoint from every authenticated input")
PY

EXPORT_VERIFIER="$SOURCE_EXPORT/Scripts/verify-open-source-export.sh"
MATERIALIZER="$SOURCE_EXPORT/Scripts/materialize-forgeplay-wine-11.12-source.sh"
BUILDER="$SOURCE_EXPORT/Scripts/build-forgeplay-wine-runtime.sh"
PACKAGER="$SOURCE_EXPORT/Scripts/package-forgeplay-runtime.sh"
RECEIPT_TOOL="$SOURCE_EXPORT/Scripts/verify-public-runtime-build-receipt.py"
for tool in "$EXPORT_VERIFIER" "$MATERIALIZER" "$BUILDER" "$PACKAGER" "$RECEIPT_TOOL"; do
  [[ -f "$tool" && ! -L "$tool" ]] || fail "exported command-graph tool is unavailable: $tool"
done

# Source-export provenance is accepted only after the exact export is checked
# against an independent trusted Git object database. This does not promote
# the resulting unsigned Runtime candidate to official release authority.
/bin/bash "$EXPORT_VERIFIER" \
  --project-root "$SOURCE_EXPORT" \
  --release-authority \
  --trusted-git-repository "$TRUSTED_GIT_REPOSITORY" \
  "$SOURCE_EXPORT" || fail "public source export verification failed"

/bin/mkdir -m 700 "$TRANSACTION_ROOT"
/bin/mkdir -m 700 "$TRANSACTION_ROOT/output"
SOURCE_ROOT="$TRANSACTION_ROOT/source-wine-11.12"
BUILD_ROOT="$TRANSACTION_ROOT/build"
INSTALL_ROOT="$TRANSACTION_ROOT/install"
OUTPUT_ROOT="$TRANSACTION_ROOT/output/ForgePlayRuntime"
RECEIPT_PATH="$TRANSACTION_ROOT/public-runtime-prepackage-receipt.json"

/bin/bash "$MATERIALIZER" "$WINE_SOURCE_ARCHIVE" "$SOURCE_ROOT"
FORGEPLAY_GSTREAMER_SDK_ROOT="$GSTREAMER_SDK_ROOT" \
  /bin/bash "$BUILDER" "$SOURCE_ROOT" "$BUILD_ROOT" "$INSTALL_ROOT"

CURRENT_SOURCE_SHA256="$(/usr/bin/python3 - \
  "$SOURCE_EXPORT/Config/ForgePlayRuntimeSourceIdentity.lock.json" <<'PY'
import json
import re
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
digest = value.get("currentFinalPatchedSourceTree", {}).get("sha256")
if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
    raise SystemExit("current final patched source identity is invalid")
print(digest)
PY
)" || fail "current source identity could not be read"

/usr/bin/python3 "$RECEIPT_TOOL" create-prepackage \
  --export-root "$SOURCE_EXPORT" \
  --source-tree-sha256 "$CURRENT_SOURCE_SHA256" \
  --install-root "$INSTALL_ROOT" \
  --compiler-capsule-manifest "$BUILD_ROOT/.forgeplay-compiler-capsule.json" \
  --build-tool-capsule-manifest "$BUILD_ROOT/.forgeplay-build-tool-capsule.json" \
  --receipt "$RECEIPT_PATH" || fail "public Runtime build receipt could not be created"

# Packaging remains in the same fresh build transaction. The public packager
# independently re-hashes the install root and both toolchain capsules against
# this receipt before it may publish the unsigned PublicRuntimeBuildClaim.json.
FORGEPLAY_TRUSTED_GIT_REPOSITORY="$TRUSTED_GIT_REPOSITORY" \
FORGEPLAY_PUBLIC_RUNTIME_BUILD_RECEIPT="$RECEIPT_PATH" \
FORGEPLAY_PUBLIC_COMPILER_CAPSULE_MANIFEST="$BUILD_ROOT/.forgeplay-compiler-capsule.json" \
FORGEPLAY_PUBLIC_BUILD_TOOL_CAPSULE_MANIFEST="$BUILD_ROOT/.forgeplay-build-tool-capsule.json" \
FORGEPLAY_WINE_SOURCE="$SOURCE_ROOT" \
FORGEPLAY_GSTREAMER_SDK_ROOT="$GSTREAMER_SDK_ROOT" \
FORGEPLAY_RENDERER_SOURCE="$RENDERER_SOURCE" \
FORGEPLAY_RUNTIME_POLICY_SOURCE="$RUNTIME_POLICY_SOURCE" \
TMPDIR="$TRANSACTION_ROOT" \
  /bin/bash "$PACKAGER" --public-source-package "$INSTALL_ROOT" "$OUTPUT_ROOT"

/usr/bin/python3 "$RECEIPT_TOOL" verify-runtime \
  --runtime-root "$OUTPUT_ROOT" \
  --source-inventory "$SOURCE_EXPORT/SOURCE-INVENTORY.json" ||
  fail "published Runtime does not match its public build receipt"

printf '%s\n' "$OUTPUT_ROOT"
