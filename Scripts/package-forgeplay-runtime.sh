#!/bin/bash
set -euo pipefail

readonly FORGEPLAY_SYSTEM_TOOL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PATH="$FORGEPLAY_SYSTEM_TOOL_PATH"
export PATH
unset CDPATH

SCRIPT_DIR_INPUT="${FORGEPLAY_VALIDATION_SCRIPT_DIR:-$(/usr/bin/dirname "${BASH_SOURCE[0]}")}"
[[ "$SCRIPT_DIR_INPUT" = /* && -d "$SCRIPT_DIR_INPUT" && ! -L "$SCRIPT_DIR_INPUT" ]] || {
  printf 'error: validation script directory override is unsafe\n' >&2
  exit 1
}
SCRIPT_DIR="$(cd "$SCRIPT_DIR_INPUT" && /bin/pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"
MODE="package"
RUNTIME_DEPENDENCY_LOCK="$REPO_ROOT/Config/ForgePlayRuntimeDependencies.lock.json"
RUNTIME_DEPENDENCY_MATERIALIZER="$SCRIPT_DIR/materialize-locked-runtime-dependencies.py"
GSTREAMER_PAYLOAD_LOCK="$REPO_ROOT/Config/ForgePlayGStreamerPayload.lock.json"
GSTREAMER_PAYLOAD_MATERIALIZER="$SCRIPT_DIR/materialize-locked-gstreamer-runtime.py"
RUNTIME_SBOM_TOOL="$SCRIPT_DIR/runtime-sbom.py"
RUNTIME_CORE_IDENTITY_TOOL="$SCRIPT_DIR/runtime-core-payload-identity.py"
RUNTIME_FILE_INVENTORY_TOOL="$SCRIPT_DIR/verify-bundled-runtime-capability.sh"
MACHO_RUNTIME_CLOSURE_VERIFIER="$SCRIPT_DIR/verify-macho-runtime-closure.py"
D3DMETAL_NGX_BRIDGE_VALIDATOR="$SCRIPT_DIR/validate-d3dmetal-ngx-bridge.sh"
COMPILER_CAPSULE_TOOL="$SCRIPT_DIR/build-forgeplay-wine-runtime.sh"
RENDERER_PAYLOAD_LOCK="$REPO_ROOT/Config/ForgePlayRendererPayload.lock.json"
RENDERER_PAYLOAD_MATERIALIZER="$SCRIPT_DIR/materialize-locked-renderer.py"
CLEAN_WINE_MARKER_VERIFIER="$SCRIPT_DIR/verify-clean-wine-runtime-markers.py"
BUILD_PATH_VERIFIER="$SCRIPT_DIR/verify-wine-runtime-build-paths.py"
RUNTIME_PATCH_PROVENANCE_LOCK="$REPO_ROOT/Config/ForgePlayRuntimePatchProvenance.lock.json"
RUNTIME_SOURCE_IDENTITY_LOCK="$REPO_ROOT/Config/ForgePlayRuntimeSourceIdentity.lock.json"
RUNTIME_PATCH_PROVENANCE_VERIFIER="$SCRIPT_DIR/verify-forgeplay-runtime-patch-provenance.py"
OWNED_DIRECTORY_QUARANTINE_TOOL="$SCRIPT_DIR/quarantine-owned-directory.py"
PUBLIC_SOURCE_EXPORT_VERIFIER="$SCRIPT_DIR/verify-open-source-export.sh"
PUBLIC_RUNTIME_BUILD_RECEIPT_TOOL="$SCRIPT_DIR/verify-public-runtime-build-receipt.py"
RUNTIME_MANIFEST_TEMPLATE="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/RuntimeManifest.json"
RUNTIME_PATCH_SOURCE_ROOT="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches"
HOMEBREW_X86_PREFIX="${FORGEPLAY_HOMEBREW_X86_PREFIX:-/usr/local}"
GSTREAMER_SDK_INPUT="${FORGEPLAY_GSTREAMER_SDK_ROOT:-}"
RUNTIME_POLICY_SOURCE_INPUT="${FORGEPLAY_RUNTIME_POLICY_SOURCE:-}"
TRUSTED_GIT_REPOSITORY_INPUT="${FORGEPLAY_TRUSTED_GIT_REPOSITORY:-}"
PUBLIC_RUNTIME_BUILD_RECEIPT_INPUT="${FORGEPLAY_PUBLIC_RUNTIME_BUILD_RECEIPT:-}"
PUBLIC_COMPILER_CAPSULE_MANIFEST_INPUT="${FORGEPLAY_PUBLIC_COMPILER_CAPSULE_MANIFEST:-}"
PUBLIC_BUILD_TOOL_CAPSULE_MANIFEST_INPUT="${FORGEPLAY_PUBLIC_BUILD_TOOL_CAPSULE_MANIFEST:-}"
# These snapshot bounds mirror the producer-side verification limits in
# build-forgeplay-wine-runtime.sh. They cap serialized manifests, not the
# compiler or build-tool capsule payloads described by those manifests.
readonly PUBLIC_COMPILER_CAPSULE_MANIFEST_MAX_BYTES=67108864
readonly PUBLIC_BUILD_TOOL_CAPSULE_MANIFEST_MAX_BYTES=67108864

case "${1:-}" in
  --validate-wine-source|--validate-wine-source-fixture|--validate-wine-runtime-payload)
    MODE="${1#--}"
    shift
    ;;
  --public-source-package)
    MODE="public-source-package"
    shift
    ;;
esac
if [[ -n "${FORGEPLAY_VALIDATION_SCRIPT_DIR:-}" && "$MODE" == "package" ]]; then
  printf 'error: validation script directory override is unavailable during packaging\n' >&2
  exit 1
fi

INSTALL_ROOT="${1:-}"
OUTPUT_ROOT="${2:-}"
WINE_SOURCE_INPUT="${FORGEPLAY_WINE_SOURCE:-}"
WINE_SOURCE_ARCHIVE_URL="${FORGEPLAY_WINE_SOURCE_ARCHIVE_URL:-https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz}"
WINE_SOURCE_SIGNATURE_URL="${FORGEPLAY_WINE_SOURCE_SIGNATURE_URL:-https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz.sign}"
WINE_SOURCE_ARCHIVE_SHA256="d3bc091192d985846c9f20065cc81f21331f01e22b736b131e3449e1306671bc"
WINE_SOURCE_SIGNING_KEY_FINGERPRINT="DA23579A74D4AD9AF9D3F945CEFAC8EAAF17519D"
EXPECTED_WINE_SOURCE_TREE_SHA256="$(/usr/bin/python3 - "$RUNTIME_SOURCE_IDENTITY_LOCK" <<'PY'
import json
import re
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
digest = value.get("currentFinalPatchedSourceTree", {}).get("sha256")
if value.get("schemaVersion") != 2 or not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
    raise SystemExit("runtime source identity lock does not contain one valid current source digest")
print(digest)
PY
)"
# Canonical runtime source payload: ordered Wine patches plus the reviewed
# behavior contract. License sidecars are shipped and verified separately;
# they are not inputs to the patched-source identity.
EXPECTED_WINE_PATCH_SET_SHA256="11af77aa6a1ce172505faa641c9ef5783ad10878ed552e0b55ab234a6dac1a07"
NANUM_GOTHIC_REGULAR_SHA256="76f45ef4a6bcff344c837c95a7dcc26e017e38b5846d5ae0cdcb5b86be2e2d31"
NANUM_GOTHIC_BOLD_SHA256="21f9d3a7f1ca82ca1dc9a288e30138b4f1feb6e71fc89b5a9181fed174b6bbe2"
NANUM_GOTHIC_OFL_SHA256="eeacf16032901d0ed0456876ec77b8f0fda6b3fecec7d972f8543eb602e6c30f"
NANUM_GOTHIC_SOURCE_IDENTITY_SHA256="c1fbfce859af7446bde6e2f88877cafc92535fde63f7cce9ae0003d29399926c"
FORGEPLAY_WINE_MODIFICATIONS_SHA256="613ab79178fece6ea534589d64c1e9716b7a8a5c8730eebb4ea067fdd46ff081"
LGPL_2_1_LICENSE_SHA256="e237fa56668030e928551ddd60f05df5fe957f75eab874bbd017e085ed722e7c"
APPLE_GPTK_LICENSE_SHA256="5abb2d059be217663b00e8fd37e14411d374e11d17e3b744eebd49b8d17118c8"
APPLE_GPTK_ACKNOWLEDGEMENTS_SHA256="6f3aa835f6d0d06f89997d0a346a209e39a8105521fd939e096c5b24dc0cb0a6"
D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET="../../external/libd3dshared.dylib"
D3DMETAL_SHARED_UNIX_MODULES=(d3d10 d3d11 d3d12 dxgi nvapi nvapi64 nvngx-on-metalfx)
WINE_DEVELOPMENT_ONLY_BIN_ENTRIES=(
  function_grep.pl
  widl
  winebuild
  winecpp
  winedump
  wineg++
  winegcc
  winemaker
  wmc
  wrc
)
WINE_RUNTIME_BIN_ALLOWLIST=(
  msidb
  msiexec
  notepad
  regedit
  regsvr32
  wine
  wineboot
  winecfg
  wineconsole
  winedbg
  winefile
  winemine
  winepath
  wineserver
)
WINE_SOURCE_ROOT=""
WINE_SOURCE_TREE_SHA256=""
RUNTIME_PATCH_ORDER=()
RUNTIME_PATCH_LICENSE_SIDECARS=()
RUNTIME_BEHAVIOR_CONTRACTS=()
PATCH_PROJECTION_WORKSPACE=""
PATCH_PROJECTION_WORKSPACE_ID=""
RUNTIME_PATCH_PROJECTION=""
RUNTIME_PATCH_PROJECTION_LOCK=""
STAGING=""
STAGING_ID=""
PUBLIC_SOURCE_RELEASE_COMMIT=""
PUBLIC_SOURCE_INVENTORY_SHA256=""
RUNTIME_POLICY_SOURCE=""
TRUSTED_GIT_REPOSITORY=""
PUBLIC_RUNTIME_BUILD_RECEIPT=""
PUBLIC_COMPILER_CAPSULE_MANIFEST=""
PUBLIC_BUILD_TOOL_CAPSULE_MANIFEST=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

directory_identity() {
  /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null
}

bind_output_runtime_root_state() {
  local output_root="$1"
  local output_parent="$2"
  local expected_parent_identity="$3"

  /usr/bin/python3 - \
    "$output_root" \
    "$output_parent" \
    "$expected_parent_identity" <<'PY'
import os
import stat
import sys

output, parent, expected_parent = sys.argv[1:]


def parse_identity(value):
    fields = value.split(":")
    if len(fields) != 2 or any(not field.isdigit() for field in fields):
        raise SystemExit("output runtime parent identity is invalid")
    return tuple(map(int, fields))


def identity(metadata):
    return metadata.st_dev, metadata.st_ino


if (
    not os.path.isabs(output)
    or not os.path.isabs(parent)
    or os.path.normpath(output) != output
    or os.path.normpath(parent) != parent
    or os.path.dirname(output) != parent
    or os.path.basename(output) in {"", ".", ".."}
):
    raise SystemExit("output runtime root binding is not an exact parent/basename path")

parent_fd = os.open(parent, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY)
try:
    parent_metadata = os.fstat(parent_fd)
    if not stat.S_ISDIR(parent_metadata.st_mode) or identity(parent_metadata) != parse_identity(expected_parent):
        raise SystemExit("output runtime parent identity changed while binding output state")
    try:
        output_metadata = os.stat(
            os.path.basename(output),
            dir_fd=parent_fd,
            follow_symlinks=False,
        )
    except FileNotFoundError:
        if identity(os.fstat(parent_fd)) != identity(parent_metadata):
            raise SystemExit("output runtime parent identity changed while binding absent output")
        print("absent")
    else:
        if stat.S_ISLNK(output_metadata.st_mode):
            raise SystemExit(f"output runtime root must not contain symlink path components: {output}")
        if not stat.S_ISDIR(output_metadata.st_mode):
            raise SystemExit(f"existing output runtime root must be a non-symlink directory: {output}")
        if identity(os.fstat(parent_fd)) != identity(parent_metadata):
            raise SystemExit("output runtime parent identity changed while binding existing output")
        print(f"present:{output_metadata.st_dev}:{output_metadata.st_ino}")
finally:
    os.close(parent_fd)
PY
}

regular_file_identity() {
  /usr/bin/stat -f '%d:%i:%l:%z:%m:%c' "$1" 2>/dev/null
}

revalidate_bound_install_inputs() {
  local index path actual
  [[ "$(directory_identity "$INSTALL_ROOT")" == "$INSTALL_ROOT_ID" ]] ||
    fail "Wine install root identity changed during packaging"
  for ((index = 0; index < ${#INSTALL_BOUND_PATHS[@]}; index++)); do
    path="${INSTALL_BOUND_PATHS[$index]}"
    actual="$(regular_file_identity "$path")" ||
      fail "bound Wine install input disappeared during packaging: $path"
    [[ "$actual" == "${INSTALL_BOUND_IDENTITIES[$index]}" ]] ||
      fail "bound Wine install input changed during packaging: $path"
  done
}

cleanup_owned_directory() {
  local owned_path="$1"
  local expected_identity="$2"
  local parent="$3"
  local expected_parent_identity="$4"
  local label="$5"

  [[ -n "$owned_path" && -n "$expected_identity" ]] || return 0
  [[ -d "$owned_path" && ! -L "$owned_path" ]] || return 0
  if [[ "$(directory_identity "$owned_path" || true)" != "$expected_identity" ]]; then
    printf 'warning: refusing to clean substituted %s: %s\n' "$label" "$owned_path" >&2
    return 1
  fi
  if [[ "$(directory_identity "$parent" || true)" != "$expected_parent_identity" ]]; then
    printf 'warning: refusing to clean %s through a substituted parent: %s\n' \
      "$label" "$parent" >&2
    return 1
  fi
  if [[ ! -f "$OWNED_DIRECTORY_QUARANTINE_TOOL" ||
        -L "$OWNED_DIRECTORY_QUARANTINE_TOOL" ]]; then
    printf 'warning: quarantine cleanup helper is unavailable for %s: %s\n' \
      "$label" "$OWNED_DIRECTORY_QUARANTINE_TOOL" >&2
    return 1
  fi
  if ! /usr/bin/python3 "$OWNED_DIRECTORY_QUARANTINE_TOOL" \
      --tree "$owned_path" \
      --tree-identity "$expected_identity" \
      --parent "$parent" \
      --parent-identity "$expected_parent_identity" \
      --label "$label"; then
    printf 'warning: unable to quarantine-clean owned %s: %s\n' \
      "$label" "$owned_path" >&2
    return 1
  fi
}

cleanup() {
  local cleanup_failed=0
  if [[ -n "${STAGING:-}" ]]; then
    cleanup_owned_directory \
      "$STAGING" \
      "${STAGING_ID:-}" \
      "${OUTPUT_PARENT:-/}" \
      "${OUTPUT_PARENT_ID:-}" \
      "runtime staging root" || cleanup_failed=1
  fi
  if [[ -n "${PATCH_PROJECTION_WORKSPACE:-}" ]]; then
    cleanup_owned_directory \
      "$PATCH_PROJECTION_WORKSPACE" \
      "${PATCH_PROJECTION_WORKSPACE_ID:-}" \
      "${PATCH_PROJECTION_PARENT:-/}" \
      "${PATCH_PROJECTION_PARENT_ID:-}" \
      "runtime patch projection" || cleanup_failed=1
  fi
  if [[ "$cleanup_failed" -ne 0 ]]; then
    printf 'warning: one or more owned packaging directories could not be cleaned\n' >&2
  fi
  return 0
}

create_runtime_patch_projection() {
  local temp_input="${TMPDIR:-/tmp}"
  [[ "$temp_input" = /* && -d "$temp_input" && ! -L "$temp_input" ]] ||
    fail "temporary root must be an absolute non-symlink directory"
  reject_symlink_parent_components "$temp_input" "temporary root"
  PATCH_PROJECTION_PARENT="$(cd "$temp_input" && /bin/pwd -P)"
  reject_symlink_parent_components "$PATCH_PROJECTION_PARENT" "temporary root"
  PATCH_PROJECTION_PARENT_ID="$(directory_identity "$PATCH_PROJECTION_PARENT")" ||
    fail "temporary root identity is unavailable"
  PATCH_PROJECTION_WORKSPACE="$(/usr/bin/mktemp -d "$PATCH_PROJECTION_PARENT/forgeplay-runtime-patches.XXXXXXXX")" ||
    fail "could not create private runtime patch projection"
  /bin/chmod 700 "$PATCH_PROJECTION_WORKSPACE" ||
    fail "could not protect runtime patch projection"
  PATCH_PROJECTION_WORKSPACE_ID="$(directory_identity "$PATCH_PROJECTION_WORKSPACE")" ||
    fail "runtime patch projection identity is unavailable"
  [[ "$(directory_identity "$PATCH_PROJECTION_PARENT")" == "$PATCH_PROJECTION_PARENT_ID" ]] ||
    fail "temporary root changed while the patch projection was created"
  trap cleanup EXIT

  RUNTIME_PATCH_PROJECTION="$PATCH_PROJECTION_WORKSPACE/payload"
  local manifest_snapshot="$PATCH_PROJECTION_WORKSPACE/RuntimeManifest.json"
  local lock_snapshot="$PATCH_PROJECTION_WORKSPACE/PatchProvenance.lock.json"
  RUNTIME_PATCH_PROJECTION_LOCK="$lock_snapshot"
  local patch_order_file="$PATCH_PROJECTION_WORKSPACE/patch-order.txt"
  local sidecar_order_file="$PATCH_PROJECTION_WORKSPACE/sidecar-order.txt"
  local contract_order_file="$PATCH_PROJECTION_WORKSPACE/contract-order.txt"
  /bin/mkdir -m 700 "$RUNTIME_PATCH_PROJECTION"

  /usr/bin/python3 - \
    "$RUNTIME_MANIFEST_TEMPLATE" \
    "$RUNTIME_PATCH_PROVENANCE_LOCK" \
    "$RUNTIME_PATCH_SOURCE_ROOT" \
    "$manifest_snapshot" \
    "$lock_snapshot" \
    "$RUNTIME_PATCH_PROJECTION" \
    "$patch_order_file" \
    "$sidecar_order_file" \
    "$contract_order_file" <<'PY' || fail "runtime patch projection could not be created and revalidated"
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import PurePosixPath

(
    manifest_source,
    lock_source,
    patch_source_root,
    manifest_snapshot,
    lock_snapshot,
    projection_root,
    patch_order_path,
    sidecar_order_path,
    contract_order_path,
) = sys.argv[1:]
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
CHUNK = 1024 * 1024


def identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def safe_name(value, label, suffix):
    parsed = PurePosixPath(value) if isinstance(value, str) else None
    if (
        parsed is None
        or parsed.is_absolute()
        or len(parsed.parts) != 1
        or parsed.name != value
        or SAFE_NAME.fullmatch(value) is None
        or not value.endswith(suffix)
    ):
        raise SystemExit(f"{label} must be a safe {suffix} basename: {value!r}")
    return value


def snapshot(source, destination, label, maximum_bytes, expected_digest=None, directory_fd=None):
    source_fd = os.open(
        source,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        dir_fd=directory_fd,
    )
    try:
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise SystemExit(f"{label} must be a single-link regular file")
        if before.st_size < 0 or before.st_size > maximum_bytes:
            raise SystemExit(f"{label} exceeds its bounded snapshot size")
        destination_fd = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
        )
        digest = hashlib.sha256()
        total = 0
        try:
            while True:
                payload = os.read(source_fd, min(CHUNK, maximum_bytes - total + 1))
                if not payload:
                    break
                total += len(payload)
                if total > maximum_bytes:
                    raise SystemExit(f"{label} exceeded its bounded snapshot size")
                digest.update(payload)
                view = memoryview(payload)
                while view:
                    written = os.write(destination_fd, view)
                    if written <= 0:
                        raise SystemExit(f"{label} snapshot write made no progress")
                    view = view[written:]
            if identity(before) != identity(os.fstat(source_fd)) or total != before.st_size:
                raise SystemExit(f"{label} changed while its snapshot was copied")
            os.fsync(destination_fd)
            os.fchmod(destination_fd, 0o444)
            staged = os.fstat(destination_fd)
            if (
                not stat.S_ISREG(staged.st_mode)
                or staged.st_nlink != 1
                or stat.S_IMODE(staged.st_mode) != 0o444
                or staged.st_size != total
            ):
                raise SystemExit(f"{label} snapshot metadata is invalid")
        finally:
            os.close(destination_fd)
    finally:
        os.close(source_fd)
    actual_digest = digest.hexdigest()
    if expected_digest is not None and actual_digest != expected_digest:
        raise SystemExit(f"{label} digest mismatch")
    verification_fd = os.open(destination, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        verified = hashlib.sha256()
        verified_total = 0
        while True:
            payload = os.read(verification_fd, CHUNK)
            if not payload:
                break
            verified_total += len(payload)
            if verified_total > maximum_bytes:
                raise SystemExit(f"{label} snapshot exceeds its revalidation bound")
            verified.update(payload)
        metadata = os.fstat(verification_fd)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o444
            or verified_total != total
            or verified.hexdigest() != actual_digest
        ):
            raise SystemExit(f"{label} snapshot revalidation failed")
    finally:
        os.close(verification_fd)
    return actual_digest


def write_order(path, names):
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    try:
        payload = "".join(f"{name}\n" for name in names).encode("ascii")
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise SystemExit("projection order write made no progress")
            view = view[written:]
        os.fsync(descriptor)
        os.fchmod(descriptor, 0o444)
    finally:
        os.close(descriptor)


snapshot(manifest_source, manifest_snapshot, "runtime manifest", 4 * 1024 * 1024)
snapshot(lock_source, lock_snapshot, "runtime patch provenance lock", 4 * 1024 * 1024)
with open(manifest_snapshot, "rb") as handle:
    manifest = json.load(handle)
with open(lock_snapshot, "rb") as handle:
    lock = json.load(handle)
order = manifest.get("patchApplicationOrder")
patches = lock.get("patches")
sidecars = lock.get("patchLicenseSidecars")
contracts = lock.get("behaviorContracts")
if not all(isinstance(value, list) for value in (order, patches, sidecars, contracts)):
    raise SystemExit("runtime patch projection inputs must contain arrays")
if not order or len(order) != len(set(order)):
    raise SystemExit("runtime patch order must be non-empty and unique")
if order != [entry.get("path") for entry in patches if isinstance(entry, dict)]:
    raise SystemExit("runtime manifest order does not match the provenance lock")

patch_root_fd = os.open(
    patch_source_root,
    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY,
)
try:
    patch_names = []
    for entry in patches:
        if not isinstance(entry, dict):
            raise SystemExit("runtime patch entry must be an object")
        name = safe_name(entry.get("path"), "runtime patch", ".patch")
        expected_digest = entry.get("sha256")
        if not isinstance(expected_digest, str) or re.fullmatch(r"[0-9a-f]{64}", expected_digest) is None:
            raise SystemExit(f"runtime patch has an invalid digest: {name}")
        snapshot(
            name,
            os.path.join(projection_root, name),
            f"runtime patch {name}",
            64 * 1024 * 1024,
            expected_digest,
            patch_root_fd,
        )
        patch_names.append(name)

    sidecar_names = []
    for entry in sidecars:
        if not isinstance(entry, dict):
            raise SystemExit("runtime patch sidecar entry must be an object")
        patch_name = safe_name(entry.get("patchPath"), "sidecar patch", ".patch")
        name = safe_name(entry.get("path"), "runtime patch sidecar", ".patch.license")
        if name != f"{patch_name}.license" or patch_name not in patch_names:
            raise SystemExit(f"runtime patch sidecar is not bound to a packaged patch: {name}")
        expected_digest = entry.get("sha256")
        if not isinstance(expected_digest, str) or re.fullmatch(r"[0-9a-f]{64}", expected_digest) is None:
            raise SystemExit(f"runtime patch sidecar has an invalid digest: {name}")
        snapshot(
            name,
            os.path.join(projection_root, name),
            f"runtime patch sidecar {name}",
            1024 * 1024,
            expected_digest,
            patch_root_fd,
        )
        sidecar_names.append(name)

    contract_names = []
    for entry in contracts:
        if not isinstance(entry, dict):
            raise SystemExit("runtime behavior contract entry must be an object")
        name = safe_name(entry.get("path"), "runtime behavior contract", "-contract.md")
        expected_digest = entry.get("sha256")
        if not isinstance(expected_digest, str) or re.fullmatch(r"[0-9a-f]{64}", expected_digest) is None:
            raise SystemExit(f"runtime behavior contract has an invalid digest: {name}")
        snapshot(
            name,
            os.path.join(projection_root, name),
            f"runtime behavior contract {name}",
            4 * 1024 * 1024,
            expected_digest,
            patch_root_fd,
        )
        contract_names.append(name)
finally:
    os.close(patch_root_fd)

write_order(patch_order_path, patch_names)
write_order(sidecar_order_path, sidecar_names)
write_order(contract_order_path, contract_names)
PY

  local item
  while IFS= read -r item; do
    [[ -n "$item" ]] || fail "runtime patch projection contains an empty patch name"
    RUNTIME_PATCH_ORDER+=("$item")
  done < "$patch_order_file"
  while IFS= read -r item; do
    [[ -n "$item" ]] || fail "runtime patch projection contains an empty sidecar name"
    RUNTIME_PATCH_LICENSE_SIDECARS+=("$item")
  done < "$sidecar_order_file"
  while IFS= read -r item; do
    [[ -n "$item" ]] || fail "runtime patch projection contains an empty contract name"
    RUNTIME_BEHAVIOR_CONTRACTS+=("$item")
  done < "$contract_order_file"
  [[ "${#RUNTIME_PATCH_ORDER[@]}" -gt 0 ]] || fail "runtime patch projection is empty"
}

binary_contains_text() {
  local path="$1"
  local text="$2"
  /usr/bin/python3 - "$path" "$text" <<'PY'
import os
import stat
import sys

path, marker = sys.argv[1:]
needles = (marker.encode("ascii"), marker.encode("utf-16le"))
maximum_bytes = 512 * 1024 * 1024
descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    before = os.fstat(descriptor)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size < 0
        or before.st_size > maximum_bytes
    ):
        raise SystemExit("binary marker input violates its bounded regular-file contract")
    overlap = max(map(len, needles)) - 1
    previous = b""
    total = 0
    matched = False
    while True:
        chunk = os.read(descriptor, min(1024 * 1024, maximum_bytes - total + 1))
        if not chunk:
            break
        total += len(chunk)
        if total > maximum_bytes:
            raise SystemExit("binary marker input exceeded its read bound")
        window = previous + chunk
        if any(needle in window for needle in needles):
            matched = True
        previous = window[-overlap:] if overlap > 0 else b""
    after = os.fstat(descriptor)
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    if total != before.st_size or identity(before) != identity(after):
        raise SystemExit("binary marker input changed during descriptor-bound read")
    raise SystemExit(0 if matched else 1)
finally:
    os.close(descriptor)
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
    parent="$(/usr/bin/dirname "$current")"
    [[ "$parent" != "$current" ]] || break
    current="$parent"
  done
}

resolve_trusted_tool_input() {
  local candidate="$1"
  local trusted_root="$2"
  local label="$3"

  [[ "$candidate" = /* && "$trusted_root" = /* ]] ||
    fail "$label and its trusted root must be absolute paths"
  reject_symlink_parent_components "$trusted_root" "$label trusted root"
  /usr/bin/python3 - "$candidate" "$trusted_root" "$label" <<'PY'
import os
import stat
import sys

candidate, trusted_root, label = sys.argv[1:]
trusted_root = os.path.realpath(trusted_root)
resolved = os.path.realpath(candidate)
try:
    if os.path.commonpath([trusted_root, resolved]) != trusted_root:
        raise SystemExit(f"{label} resolves outside its trusted installation root")
except ValueError:
    raise SystemExit(f"{label} does not share its trusted installation root")
try:
    metadata = os.lstat(resolved)
except OSError as error:
    raise SystemExit(f"{label} target could not be inspected: {error}")
if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink < 1 or not os.access(resolved, os.X_OK):
    raise SystemExit(f"{label} target is not an executable regular file")
print(resolved)
PY
}

validate_gstreamer_directory_symlink_descendants() {
  local root="$1"
  /usr/bin/python3 - "$root" <<'PY'
import os
import stat
import sys

root = os.path.realpath(sys.argv[1])
pending = [root]
while pending:
    directory = pending.pop()
    with os.scandir(directory) as entries:
        for entry in entries:
            metadata = entry.stat(follow_symlinks=False)
            if stat.S_ISLNK(metadata.st_mode):
                if entry.is_dir(follow_symlinks=True):
                    resolved = os.path.realpath(entry.path)
                    if os.path.commonpath([root, resolved]) != root:
                        raise SystemExit(
                            f"GStreamer SDK directory symlink escapes its root: {entry.path}"
                        )
                continue
            if stat.S_ISDIR(metadata.st_mode):
                pending.append(entry.path)
PY
}

gstreamer_file_manifest() {
  local mode="$1"
  local root="$2"
  local manifest="$3"
  local transitioned_manifest="${4:-}"
  /usr/bin/python3 - "$mode" "$root" "$manifest" "$transitioned_manifest" <<'PY'
import hashlib
import json
import os
import stat
import sys

mode, root, manifest, transitioned_manifest = sys.argv[1:]
root = os.path.abspath(os.path.normpath(root))

accepted_macho_magics = {
    bytes.fromhex(value)
    for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )
}

def token(value):
    return [value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns, value.st_uid]

def accepted_macho_magic(value):
    return isinstance(value, str) and bytes.fromhex(value) in accepted_macho_magics

def safe_file_identity(value):
    if not isinstance(value, list) or len(value) != 8 or not all(isinstance(field, int) for field in value):
        return False
    unsafe_mode = stat.S_IWGRP | stat.S_IWOTH | stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX
    return (
        stat.S_ISREG(value[2])
        and value[3] == 1
        and value[7] == os.geteuid()
        and value[2] & unsafe_mode == 0
    )

def bound_digest(path):
    descriptor = os.open(
        path,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
    )
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise SystemExit(f"GStreamer input is not a single-link regular file: {path}")
        digest = hashlib.sha256()
        total = 0
        while total < before.st_size:
            chunk = os.pread(descriptor, min(1024 * 1024, before.st_size - total), total)
            if not chunk:
                raise SystemExit(f"GStreamer input became incomplete: {path}")
            digest.update(chunk)
            total += len(chunk)
        magic = os.pread(descriptor, 4, 0)
        after = os.fstat(descriptor)
        if token(before) != token(after) or total != before.st_size:
            raise SystemExit(f"GStreamer input changed while hashing: {path}")
        return token(before), digest.hexdigest(), magic.hex()
    finally:
        os.close(descriptor)

def scan():
    root_metadata = os.lstat(root)
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        raise SystemExit("GStreamer root must be a non-symlink directory")
    rows = []
    total_bytes = 0
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            path = os.path.join(directory, name)
            metadata = os.lstat(path)
            relative = os.path.relpath(path, root)
            if stat.S_ISLNK(metadata.st_mode):
                target = os.readlink(path)
                resolved = os.path.realpath(path)
                if (
                    os.path.commonpath([root, resolved]) != root
                    or not stat.S_ISDIR(os.lstat(resolved).st_mode)
                ):
                    raise SystemExit(f"GStreamer directory symlink escapes its root: {path}")
                rows.append({
                    "path": relative,
                    "kind": "directory-symlink",
                    "identity": token(metadata),
                    "target": target,
                    "targetIdentity": token(os.lstat(resolved)),
                })
            elif not stat.S_ISDIR(metadata.st_mode):
                raise SystemExit(f"GStreamer directory entry is unsafe: {path}")
            else:
                rows.append({"path": relative, "kind": "directory", "identity": token(metadata)})
        for name in file_names:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root)
            metadata = os.lstat(path)
            if stat.S_ISLNK(metadata.st_mode):
                target = os.readlink(path)
                resolved = os.path.realpath(path)
                if os.path.commonpath([root, resolved]) != root:
                    raise SystemExit(f"GStreamer symlink escapes its root: {path}")
                target_token, sha256, magic = bound_digest(resolved)
                rows.append({"path": relative, "kind": "symlink", "identity": token(metadata), "target": target, "targetIdentity": target_token, "sha256": sha256, "machoMagic": magic})
            elif stat.S_ISREG(metadata.st_mode):
                file_token, sha256, magic = bound_digest(path)
                if token(metadata) != file_token:
                    raise SystemExit(f"GStreamer input path changed while being opened: {path}")
                rows.append({"path": relative, "kind": "file", "identity": file_token, "sha256": sha256, "machoMagic": magic})
                total_bytes += metadata.st_size
            else:
                raise SystemExit(f"GStreamer root contains an unsupported entry: {path}")
            if len(rows) > 100000 or total_bytes > 16 * 1024 * 1024 * 1024:
                raise SystemExit("GStreamer file identity manifest exceeds its bound")
    if token(os.lstat(root)) != token(root_metadata):
        raise SystemExit("GStreamer root changed while its identity manifest was captured")
    return {"schemaVersion": 2, "rootIdentity": token(root_metadata), "entries": rows}

def read_manifest(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_size > 64 * 1024 * 1024:
            raise SystemExit("GStreamer identity manifest is unsafe")
        data = bytearray()
        while len(data) < metadata.st_size:
            chunk = os.read(descriptor, metadata.st_size - len(data))
            if not chunk:
                raise SystemExit("GStreamer identity manifest became incomplete")
            data.extend(chunk)
        after = os.fstat(descriptor)
        if token(metadata) != token(after):
            raise SystemExit("GStreamer identity manifest changed while being read")
        return json.loads(data.decode())
    finally:
        os.close(descriptor)

def write_manifest_exclusive(path, payload):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, 0o400)
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise SystemExit("GStreamer identity manifest write made no progress")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

def validate_transition(before, after):
    if before.get("schemaVersion") != 2 or after.get("schemaVersion") != 2:
        raise SystemExit("GStreamer transition ledger schema is unsupported")
    before_root = before.get("rootIdentity")
    after_root = after.get("rootIdentity")
    if not isinstance(before_root, list) or not isinstance(after_root, list) or before_root[:2] != after_root[:2]:
        raise SystemExit("GStreamer root identity changed during staged transformation")
    before_rows = before.get("entries")
    after_rows = after.get("entries")
    if not isinstance(before_rows, list) or not isinstance(after_rows, list):
        raise SystemExit("GStreamer transition ledger entries are malformed")
    before_by_path = {row.get("path"): row for row in before_rows if isinstance(row, dict)}
    after_by_path = {row.get("path"): row for row in after_rows if isinstance(row, dict)}
    if len(before_by_path) != len(before_rows) or len(after_by_path) != len(after_rows):
        raise SystemExit("GStreamer transition ledger contains a duplicate or malformed path")
    if set(before_by_path) != set(after_by_path):
        raise SystemExit("GStreamer staged transformation inserted or deleted a path")
    for path in sorted(before_by_path):
        previous = before_by_path[path]
        current = after_by_path[path]
        if previous.get("kind") != current.get("kind"):
            raise SystemExit(f"GStreamer staged transformation rebound a path type: {path}")
        kind = previous.get("kind")
        previous_identity = previous.get("identity")
        current_identity = current.get("identity")
        if kind == "directory":
            if not isinstance(previous_identity, list) or not isinstance(current_identity, list) or previous_identity[:2] != current_identity[:2]:
                raise SystemExit(f"GStreamer directory identity changed during staged transformation: {path}")
            continue
        if kind != "file":
            raise SystemExit(f"GStreamer staged transformation contains a symlink or unsafe type: {path}")
        if not safe_file_identity(previous_identity) or not safe_file_identity(current_identity):
            raise SystemExit(f"GStreamer staged transformation contains an unsafe or hardlinked file: {path}")
        if previous == current:
            continue
        previous_sha256 = previous.get("sha256")
        current_sha256 = current.get("sha256")
        if (
            not isinstance(previous_sha256, str)
            or not isinstance(current_sha256, str)
            or len(previous_sha256) != 64
            or len(current_sha256) != 64
            or any(character not in "0123456789abcdef" for character in previous_sha256 + current_sha256)
        ):
            raise SystemExit(f"GStreamer staged transformation has an invalid content identity: {path}")
        if previous_sha256 == current_sha256:
            raise SystemExit(f"GStreamer staged transformation substituted a file without changing its content: {path}")
        if not accepted_macho_magic(previous.get("machoMagic")) or not accepted_macho_magic(current.get("machoMagic")):
            raise SystemExit(f"GStreamer staged transformation changed a non-Mach-O file: {path}")

actual = scan()
if mode == "capture":
    payload = (json.dumps(actual, sort_keys=True, separators=(",", ":")) + "\n").encode()
    write_manifest_exclusive(manifest, payload)
elif mode == "verify":
    expected = read_manifest(manifest)
    if actual != expected:
        raise SystemExit("GStreamer file identities or content hashes changed")
elif mode == "transition":
    if not transitioned_manifest or os.path.abspath(manifest) == os.path.abspath(transitioned_manifest):
        raise SystemExit("GStreamer transition requires a distinct post-transform ledger")
    expected = read_manifest(manifest)
    validate_transition(expected, actual)
    temporary = transitioned_manifest + ".transition.new"
    payload = (json.dumps(actual, sort_keys=True, separators=(",", ":")) + "\n").encode()
    try:
        try:
            os.lstat(transitioned_manifest)
        except FileNotFoundError:
            pass
        else:
            raise SystemExit("GStreamer post-transform ledger already exists")
        write_manifest_exclusive(temporary, payload)
        os.replace(temporary, transitioned_manifest)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
else:
    raise SystemExit("unsupported GStreamer identity manifest mode")
PY
}

atomic_publish_runtime_directory() {
  local staged_root="$1"
  local output_root="$2"
  local expected_stage_identity="$3"
  local expected_output_identity="$4"

  /usr/bin/python3 - \
    "$staged_root" \
    "$output_root" \
    "$expected_stage_identity" \
    "$expected_output_identity" <<'PY'
import ctypes
import errno
import os
import stat
import sys

stage, output, expected_stage, expected_output = sys.argv[1:]
stage_parent, stage_name = os.path.split(stage)
output_parent, output_name = os.path.split(output)
if not stage_name or not output_name:
    raise SystemExit("runtime publication basenames must be non-empty")
if os.path.realpath(stage_parent) != os.path.realpath(output_parent):
    raise SystemExit("runtime staging and output must share one canonical parent")


def token(metadata):
    return f"{metadata.st_dev}:{metadata.st_ino}"


directory_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
parent_fd = os.open(stage_parent, directory_flags)
try:
    stage_fd = os.open(stage_name, directory_flags, dir_fd=parent_fd)
    stage_metadata = os.fstat(stage_fd)
    if not stat.S_ISDIR(stage_metadata.st_mode) or token(stage_metadata) != expected_stage:
        raise SystemExit("runtime staging identity changed before publication")

    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        operation = library.renameatx_np
        exclusive_flag = 0x00000004
        swap_flag = 0x00000002
    elif hasattr(library, "renameat2"):
        operation = library.renameat2
        exclusive_flag = 0x00000001
        swap_flag = 0x00000002
    else:
        raise SystemExit("platform lacks an approved atomic publication primitive")
    operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    operation.restype = ctypes.c_int

    def rename(flag):
        result = operation(
            parent_fd,
            os.fsencode(stage_name),
            parent_fd,
            os.fsencode(output_name),
            flag,
        )
        return result, ctypes.get_errno() if result != 0 else 0

    if not expected_output:
        stage_path_metadata = os.stat(
            stage_name, dir_fd=parent_fd, follow_symlinks=False
        )
        if (
            token(stage_path_metadata) != expected_stage
            or token(os.fstat(stage_fd)) != expected_stage
        ):
            raise SystemExit("runtime staging entry changed before atomic publication")
        result, error_number = rename(exclusive_flag)
        if result != 0:
            if error_number == errno.EEXIST:
                raise SystemExit("runtime output appeared concurrently")
            raise SystemExit(f"atomic no-replace runtime publication failed with errno {error_number}")
        # The successful atomic link/rename is the publication commit point.
        # No cleanup or fallible pathname reopen is part of that transaction.
        os.close(stage_fd)
        stage_fd = -1
        sys.exit(0)

    output_fd = os.open(output_name, directory_flags, dir_fd=parent_fd)
    try:
        if token(os.fstat(output_fd)) != expected_output:
            raise SystemExit("existing runtime output identity changed before replacement")
        stage_path_metadata = os.stat(
            stage_name, dir_fd=parent_fd, follow_symlinks=False
        )
        output_path_metadata = os.stat(
            output_name, dir_fd=parent_fd, follow_symlinks=False
        )
        if (
            token(stage_path_metadata) != expected_stage
            or token(output_path_metadata) != expected_output
            or token(os.fstat(stage_fd)) != expected_stage
            or token(os.fstat(output_fd)) != expected_output
        ):
            raise SystemExit("runtime publication entries changed before atomic replacement")
        result, error_number = rename(swap_flag)
        if result != 0:
            raise SystemExit(f"atomic runtime replacement failed with errno {error_number}")
        # A successful atomic exchange is the commit point. The old Runtime is
        # now at ``stage`` and is cleaned independently by the shell caller.
    finally:
        os.close(output_fd)
    os.close(stage_fd)
    stage_fd = -1
finally:
    if 'stage_fd' in locals() and stage_fd >= 0:
        os.close(stage_fd)
    os.close(parent_fd)
PY
}

require_source_file() {
  local path="$1"
  local label="$2"
  local link_count

  [[ -f "$path" && ! -L "$path" ]] || fail "$label must be a non-symlink regular file: $path"
  link_count="$(/usr/bin/stat -f '%l' "$path" 2>/dev/null)" || fail "$label link count could not be inspected: $path"
  [[ "$link_count" == "1" ]] || fail "$label must not be hardlinked: $path"
}

snapshot_regular_input() {
  local source="$1"
  local destination="$2"
  local label="$3"
  local maximum_bytes="$4"
  local expected_identity
  expected_identity="$(regular_file_identity "$source")" ||
    fail "$label identity could not be bound before snapshot"
  /usr/bin/python3 - \
    "$source" \
    "$destination" \
    "$label" \
    "$maximum_bytes" \
    "$expected_identity" <<'PY'
import os
import stat
import sys

source, destination, label, maximum_text, expected_identity = sys.argv[1:]
maximum = int(maximum_text)
source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    before = os.fstat(source_fd)
    observed_identity = (
        f"{before.st_dev}:{before.st_ino}:"
        f"{before.st_nlink}:{before.st_size}:"
        f"{int(before.st_mtime)}:{int(before.st_ctime)}"
    )
    if observed_identity != expected_identity:
        raise SystemExit(f"{label} identity changed before descriptor binding")
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise SystemExit(f"{label} must be a single-link regular file")
    if before.st_size < 0 or before.st_size > maximum:
        raise SystemExit(f"{label} exceeds its snapshot bound")
    destination_fd = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    try:
        total = 0
        while True:
            chunk = os.read(source_fd, min(1024 * 1024, maximum - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                raise SystemExit(f"{label} exceeded its snapshot bound while copying")
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                if written <= 0:
                    raise SystemExit(f"{label} snapshot write made no progress")
                view = view[written:]
        after = os.fstat(source_fd)
        identity = lambda value: (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_nlink,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )
        if total != before.st_size or identity(before) != identity(after):
            raise SystemExit(f"{label} changed while being snapshotted")
        os.fsync(destination_fd)
        os.fchmod(destination_fd, 0o444)
    finally:
        os.close(destination_fd)
finally:
    os.close(source_fd)
PY
}

snapshot_runtime_consumption_inputs() {
  local root="$PATCH_PROJECTION_WORKSPACE/consumption-inputs"
  /bin/mkdir -m 700 "$root"

  snapshot_regular_input "$RUNTIME_PATCH_PROVENANCE_VERIFIER" "$root/patch-provenance.py" "runtime patch provenance verifier" 4194304
  RUNTIME_PATCH_PROVENANCE_VERIFIER="$root/patch-provenance.py"
  snapshot_regular_input "$OWNED_DIRECTORY_QUARANTINE_TOOL" "$root/quarantine-owned-directory.py" "owned-directory quarantine cleanup helper" 4194304
  OWNED_DIRECTORY_QUARANTINE_TOOL="$root/quarantine-owned-directory.py"
  snapshot_regular_input "$RUNTIME_SOURCE_IDENTITY_LOCK" "$root/source-identity.lock.json" "runtime source identity lock" 4194304
  RUNTIME_SOURCE_IDENTITY_LOCK="$root/source-identity.lock.json"
  if [[ "$MODE" == "public-source-package" ]]; then
    snapshot_regular_input "$PUBLIC_RUNTIME_BUILD_RECEIPT_TOOL" "$root/public-runtime-build-receipt.py" "public Runtime build receipt verifier" 4194304
    PUBLIC_RUNTIME_BUILD_RECEIPT_TOOL="$root/public-runtime-build-receipt.py"
    snapshot_regular_input "$PUBLIC_RUNTIME_BUILD_RECEIPT_INPUT" "$root/public-runtime-prepackage-receipt.json" "public Runtime pre-package receipt" 4194304
    PUBLIC_RUNTIME_BUILD_RECEIPT="$root/public-runtime-prepackage-receipt.json"
    snapshot_regular_input "$PUBLIC_COMPILER_CAPSULE_MANIFEST_INPUT" "$root/public-compiler-capsule.json" "public Runtime compiler capsule manifest" "$PUBLIC_COMPILER_CAPSULE_MANIFEST_MAX_BYTES"
    PUBLIC_COMPILER_CAPSULE_MANIFEST="$root/public-compiler-capsule.json"
    snapshot_regular_input "$PUBLIC_BUILD_TOOL_CAPSULE_MANIFEST_INPUT" "$root/public-build-tool-capsule.json" "public Runtime build-tool capsule manifest" "$PUBLIC_BUILD_TOOL_CAPSULE_MANIFEST_MAX_BYTES"
    PUBLIC_BUILD_TOOL_CAPSULE_MANIFEST="$root/public-build-tool-capsule.json"
  fi
  snapshot_regular_input "$CLEAN_WINE_MARKER_VERIFIER" "$root/clean-wine-markers.py" "clean Wine marker verifier" 4194304
  CLEAN_WINE_MARKER_VERIFIER="$root/clean-wine-markers.py"
  snapshot_regular_input "$BUILD_PATH_VERIFIER" "$root/build-paths.py" "Wine build-path verifier" 4194304
  BUILD_PATH_VERIFIER="$root/build-paths.py"
  snapshot_regular_input "$RUNTIME_DEPENDENCY_MATERIALIZER" "$root/runtime-dependencies.py" "runtime dependency materializer" 8388608
  RUNTIME_DEPENDENCY_MATERIALIZER="$root/runtime-dependencies.py"
  snapshot_regular_input "$GSTREAMER_PAYLOAD_MATERIALIZER" "$root/gstreamer.py" "GStreamer materializer" 8388608
  GSTREAMER_PAYLOAD_MATERIALIZER="$root/gstreamer.py"
  snapshot_regular_input "$RENDERER_PAYLOAD_MATERIALIZER" "$root/renderer.py" "renderer materializer" 8388608
  RENDERER_PAYLOAD_MATERIALIZER="$root/renderer.py"
  snapshot_regular_input "$RUNTIME_SBOM_TOOL" "$root/runtime-sbom.py" "runtime SBOM tool" 8388608
  RUNTIME_SBOM_TOOL="$root/runtime-sbom.py"
  snapshot_regular_input "$RUNTIME_CORE_IDENTITY_TOOL" "$root/runtime-core-payload-identity.py" "runtime core identity tool" 8388608
  RUNTIME_CORE_IDENTITY_TOOL="$root/runtime-core-payload-identity.py"
  snapshot_regular_input "$RUNTIME_FILE_INVENTORY_TOOL" "$root/runtime-file-inventory-tool.sh" "runtime file inventory tool" 8388608
  RUNTIME_FILE_INVENTORY_TOOL="$root/runtime-file-inventory-tool.sh"
  snapshot_regular_input "$MACHO_RUNTIME_CLOSURE_VERIFIER" "$root/macho-closure.py" "Mach-O closure verifier" 8388608
  MACHO_RUNTIME_CLOSURE_VERIFIER="$root/macho-closure.py"
  snapshot_regular_input "$D3DMETAL_NGX_BRIDGE_VALIDATOR" "$root/d3dmetal-ngx-bridge-validator.sh" "D3DMetal NGX bridge validator" 4194304
  D3DMETAL_NGX_BRIDGE_VALIDATOR="$root/d3dmetal-ngx-bridge-validator.sh"
  snapshot_regular_input "$COMPILER_CAPSULE_TOOL" "$root/compiler-capsule-tool.sh" "compiler capsule tool" 4194304
  COMPILER_CAPSULE_TOOL="$root/compiler-capsule-tool.sh"
  snapshot_regular_input "$RUNTIME_DEPENDENCY_LOCK" "$root/runtime-dependencies.lock.json" "runtime dependency lock" 4194304
  RUNTIME_DEPENDENCY_LOCK="$root/runtime-dependencies.lock.json"
  snapshot_regular_input "$GSTREAMER_PAYLOAD_LOCK" "$root/gstreamer.lock.json" "GStreamer payload lock" 4194304
  GSTREAMER_PAYLOAD_LOCK="$root/gstreamer.lock.json"
  snapshot_regular_input "$RENDERER_PAYLOAD_LOCK" "$root/renderer.lock.json" "renderer payload lock" 4194304
  RENDERER_PAYLOAD_LOCK="$root/renderer.lock.json"
  RUNTIME_MANIFEST_TEMPLATE="$PATCH_PROJECTION_WORKSPACE/RuntimeManifest.json"
}

require_file_sha256() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local actual

  actual="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')" ||
    fail "$label SHA-256 could not be computed: $path"
  [[ "$actual" == "$expected" ]] ||
    fail "$label SHA-256 mismatch: expected $expected, found $actual"
}

validate_wine_vulkan_build_contract() {
  local wine_root="$1"
  local relative_path
  local win32u="$wine_root/lib/wine/x86_64-unix/win32u.so"

  [[ "$wine_root" = /* && -d "$wine_root" && ! -L "$wine_root" ]] ||
    fail "Wine Vulkan payload root must be an absolute non-symlink directory: $wine_root"
  reject_symlink_parent_components "$wine_root" "Wine Vulkan payload root"
  for relative_path in \
    lib/wine/x86_64-unix/win32u.so \
    lib/wine/x86_64-unix/winevulkan.so \
    lib/wine/i386-windows/winevulkan.dll \
    lib/wine/x86_64-windows/winevulkan.dll; do
    require_source_file \
      "$wine_root/$relative_path" \
      "Vulkan-enabled Wine payload $relative_path"
  done

  binary_contains_text "$win32u" 'libvulkan.1.dylib' ||
    fail "Wine win32u host backend is missing the required Vulkan loader binding"
  if binary_contains_text "$win32u" 'Wine was built without Vulkan support.'; then
    fail "Wine win32u host backend was compiled without Vulkan support"
  fi
}

validate_runtime_required_wine_payload() {
  local wine_root="$1"
  local relative_path

  [[ "$wine_root" = /* && -d "$wine_root" && ! -L "$wine_root" ]] ||
    fail "Wine payload root must be an absolute non-symlink directory: $wine_root"
  reject_symlink_parent_components "$wine_root" "Wine payload root"
  for relative_path in \
    lib/wine/i386-windows/dmsynth.dll \
    lib/wine/i386-windows/icu.dll \
    lib/wine/x86_64-windows/dmsynth.dll \
    lib/wine/x86_64-windows/icu.dll \
    lib/wine/x86_64-windows/wineboot.exe; do
    require_source_file \
      "$wine_root/$relative_path" \
      "runtime-required Wine payload $relative_path"
  done
  validate_wine_vulkan_build_contract "$wine_root"

  /usr/bin/python3 - "$wine_root" <<'PY'
import os
import stat
import struct
import sys

root = os.path.realpath(sys.argv[1])
expected_machines = {
    "lib/wine/i386-windows/dmsynth.dll": 0x014C,
    "lib/wine/i386-windows/icu.dll": 0x014C,
    "lib/wine/x86_64-windows/dmsynth.dll": 0x8664,
    "lib/wine/x86_64-windows/icu.dll": 0x8664,
    "lib/wine/x86_64-windows/wineboot.exe": 0x8664,
}
expected_wineboot_languages = {
    0x0001, 0x0002, 0x0003, 0x0005, 0x0006, 0x0007, 0x0008, 0x0009,
    0x000A, 0x000B, 0x000C, 0x000D, 0x000E, 0x0010, 0x0011, 0x0012,
    0x0013, 0x0015, 0x0018, 0x0019, 0x001A, 0x001B, 0x001D, 0x001E,
    0x001F, 0x0022, 0x0024, 0x0027, 0x0029, 0x0037, 0x0049, 0x005B,
    0x0404, 0x0409, 0x0414, 0x0416, 0x0804, 0x0816, 0x241A, 0x281A,
    0x8018, 0x80B9, 0x8210,
}
maximum_payload_bytes = 256 * 1024 * 1024


def read_stable(relative):
    path = os.path.join(root, relative)
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size < 512
            or before.st_size > maximum_payload_bytes
        ):
            raise SystemExit(f"runtime-required Wine payload is unsafe: {relative}")
        data = bytearray()
        while len(data) < before.st_size:
            chunk = os.read(descriptor, min(1024 * 1024, before.st_size - len(data)))
            if not chunk:
                raise SystemExit(f"runtime-required Wine payload became incomplete: {relative}")
            data.extend(chunk)
        after = os.fstat(descriptor)
        identity = lambda value: (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_nlink,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )
        if identity(before) != identity(after):
            raise SystemExit(f"runtime-required Wine payload changed while read: {relative}")
        return bytes(data)
    finally:
        os.close(descriptor)


def u16(data, offset, label):
    if offset < 0 or offset + 2 > len(data):
        raise SystemExit(f"{label} contains a truncated PE field")
    return struct.unpack_from("<H", data, offset)[0]


def u32(data, offset, label):
    if offset < 0 or offset + 4 > len(data):
        raise SystemExit(f"{label} contains a truncated PE field")
    return struct.unpack_from("<I", data, offset)[0]


def pe_layout(data, relative):
    label = f"runtime-required Wine payload {relative}"
    if len(data) < 64 or data[:2] != b"MZ":
        raise SystemExit(f"{label} is not a PE image")
    pe_offset = u32(data, 0x3C, label)
    if pe_offset + 24 > len(data) or data[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise SystemExit(f"{label} has an invalid PE header")
    coff_offset = pe_offset + 4
    machine = u16(data, coff_offset, label)
    if machine != expected_machines[relative]:
        raise SystemExit(
            f"{label} has machine 0x{machine:04x}, expected 0x{expected_machines[relative]:04x}"
        )
    section_count = u16(data, coff_offset + 2, label)
    optional_size = u16(data, coff_offset + 16, label)
    if section_count < 1 or section_count > 96:
        raise SystemExit(f"{label} has an invalid PE section count")
    optional_offset = coff_offset + 20
    section_offset = optional_offset + optional_size
    if section_offset + section_count * 40 > len(data):
        raise SystemExit(f"{label} has a truncated PE section table")
    return optional_offset, optional_size, section_offset, section_count


payloads = {relative: read_stable(relative) for relative in expected_machines}
for relative, data in payloads.items():
    pe_layout(data, relative)

wineboot_relative = "lib/wine/x86_64-windows/wineboot.exe"
wineboot = payloads[wineboot_relative]
optional_offset, optional_size, section_offset, section_count = pe_layout(
    wineboot, wineboot_relative
)
label = "runtime-required Wine payload wineboot.exe"
magic = u16(wineboot, optional_offset, label)
directory_offset = optional_offset + (112 if magic == 0x20B else 96 if magic == 0x10B else -1)
if directory_offset < optional_offset or directory_offset + 24 > optional_offset + optional_size:
    raise SystemExit(f"{label} has no complete PE resource directory entry")
resource_rva = u32(wineboot, directory_offset + 16, label)
resource_size = u32(wineboot, directory_offset + 20, label)
if resource_rva == 0 or resource_size < 16 or resource_size > len(wineboot):
    raise SystemExit(f"{label} has an invalid PE resource directory")

resource_offset = None
resource_raw_limit = None
for index in range(section_count):
    current = section_offset + index * 40
    virtual_size = u32(wineboot, current + 8, label)
    virtual_address = u32(wineboot, current + 12, label)
    raw_size = u32(wineboot, current + 16, label)
    raw_offset = u32(wineboot, current + 20, label)
    if virtual_address <= resource_rva < virtual_address + max(virtual_size, raw_size):
        resource_offset = raw_offset + resource_rva - virtual_address
        resource_raw_limit = raw_offset + raw_size
        break
if (
    resource_offset is None
    or resource_raw_limit is None
    or resource_offset + resource_size > min(resource_raw_limit, len(wineboot))
):
    raise SystemExit(f"{label} resource directory escapes its PE section")


def resource_entries(relative_offset, depth):
    if relative_offset < 0 or relative_offset + 16 > resource_size:
        raise SystemExit(f"{label} resource directory offset is invalid")
    absolute = resource_offset + relative_offset
    named = u16(wineboot, absolute + 12, label)
    identified = u16(wineboot, absolute + 14, label)
    count = named + identified
    if count > 4096 or relative_offset + 16 + count * 8 > resource_size:
        raise SystemExit(f"{label} resource directory entry count is invalid")
    rows = []
    for index in range(count):
        name, target = struct.unpack_from("<II", wineboot, absolute + 16 + index * 8)
        is_directory = bool(target & 0x80000000)
        target_offset = target & 0x7FFFFFFF
        if target_offset >= resource_size:
            raise SystemExit(f"{label} resource target escapes its directory")
        rows.append((name, target_offset, is_directory))
    return rows


languages = set()
for _, type_target, type_is_directory in resource_entries(0, 0):
    if not type_is_directory:
        raise SystemExit(f"{label} resource type does not lead to a directory")
    for _, name_target, name_is_directory in resource_entries(type_target, 1):
        if not name_is_directory:
            raise SystemExit(f"{label} resource name does not lead to a language directory")
        for language, data_target, data_is_directory in resource_entries(name_target, 2):
            if language & 0x80000000 or data_is_directory or data_target + 16 > resource_size:
                raise SystemExit(f"{label} has an invalid language resource leaf")
            languages.add(language & 0xFFFF)

if languages != expected_wineboot_languages:
    missing = ",".join(f"0x{value:04x}" for value in sorted(expected_wineboot_languages - languages))
    extra = ",".join(f"0x{value:04x}" for value in sorted(languages - expected_wineboot_languages))
    raise SystemExit(
        "wineboot.exe does not contain the complete canonical Wine 11.12 language resource set "
        f"(found={len(languages)} expected={len(expected_wineboot_languages)} "
        f"missing=[{missing}] extra=[{extra}])"
    )
PY
}

verify_runtime_source_identity_policy() {
  require_source_file "$RUNTIME_SOURCE_IDENTITY_LOCK" "runtime source identity lock"
  /usr/bin/python3 - \
    "$RUNTIME_SOURCE_IDENTITY_LOCK" \
    "$EXPECTED_WINE_SOURCE_TREE_SHA256" \
    "$WINE_SOURCE_ARCHIVE_SHA256" <<'PY'
import json
import re
import sys
from pathlib import Path

lock_path, current, archive = sys.argv[1:]
value = json.loads(Path(lock_path).read_text(encoding="utf-8"))
if not isinstance(value, dict) or set(value) != {
    "currentFinalPatchedSourceTree",
    "schemaVersion",
    "upstreamSource",
}:
    raise SystemExit("runtime source identity lock schema is invalid")
if value["schemaVersion"] != 2:
    raise SystemExit("runtime source identity lock version is unsupported")
if value["upstreamSource"] != {
    "archiveSHA256": archive,
    "project": "Wine",
    "version": "11.12",
}:
    raise SystemExit("runtime source identity upstream authority changed")
if value["currentFinalPatchedSourceTree"] != {
    "hashAlgorithm": "forgeplay-source-tree-sha256-v1",
    "sha256": current,
}:
    raise SystemExit("current final patched source identity changed")
if any(re.fullmatch(r"[0-9a-f]{64}", item) is None for item in (current, archive)):
    raise SystemExit("runtime source identity contains an invalid digest")
PY
}

validate_public_source_urls() {
  /usr/bin/python3 - "$WINE_SOURCE_ARCHIVE_URL" "$WINE_SOURCE_SIGNATURE_URL" <<'PY'
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
  /usr/bin/python3 - "$source_root" <<'PY'
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

  version="$(/usr/bin/tr -d '\r\n' < "$WINE_SOURCE_ROOT/VERSION")"
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
  LC_ALL=C /usr/bin/grep -aFq 'Cross-process child window Metal swapchains are not implemented' "$driver" ||
    LC_ALL=C /usr/bin/grep -aFq 'DC for window %p of other process: not implemented' "$driver"
}

winemac_driver_has_supported_steam_cef_surface_marker() {
  local driver="$1"
  LC_ALL=C /usr/bin/grep -aFq 'DC for window %p of other process; using client surface pixel format %d' "$driver"
}

winemac_driver_exports_metal_window_surface_contract() {
  local driver="$1"
  LC_ALL=C /usr/bin/nm -gU "$driver" 2>/dev/null |
    /usr/bin/awk '$NF == "_macdrv_functions" { found = 1 } END { exit(found ? 0 : 1) }'
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
  link_target="$(/usr/bin/readlink "$link_path")"
  [[ "$link_target" == "$D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET" ]] ||
    fail "D3DMetal $module.so has an unsafe or incorrect link target: $link_path -> $link_target"
  [[ "$link_path" -ef "$shared_library" ]] ||
    fail "D3DMetal $module.so does not resolve to the staged shared library: $link_path"
}

materialize_d3dmetal_nvapi_aliases() {
  local renderer_root="$STAGING/Frameworks/renderer/d3dmetal"
  [[ -d "$renderer_root" ]] || return 0

  local windows_modules="$renderer_root/wine/x86_64-windows"
  local unix_modules="$renderer_root/wine/x86_64-unix"
  local source_windows_module="$windows_modules/nvapi64.dll"
  local windows_alias="$windows_modules/nvapi.dll"
  local unix_alias="$unix_modules/nvapi.so"

  require_staged_renderer_file \
    "$source_windows_module" \
    "D3DMetal NVAPI 64-bit Windows module"
  [[ -d "$windows_modules" && ! -L "$windows_modules" ]] ||
    fail "D3DMetal Windows module directory is missing or unsafe: $windows_modules"
  [[ -d "$unix_modules" && ! -L "$unix_modules" ]] ||
    fail "D3DMetal Unix module directory is missing or unsafe: $unix_modules"

  /bin/rm -f "$windows_alias"
  /bin/cp -f "$source_windows_module" "$windows_alias"
  require_staged_renderer_file "$windows_alias" "D3DMetal nvapi.dll alias"
  /usr/bin/cmp -s "$source_windows_module" "$windows_alias" ||
    fail "D3DMetal nvapi.dll alias does not match nvapi64.dll"

  /bin/rm -f "$unix_alias"
  /bin/ln -s "$D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET" "$unix_alias"
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
  link_count="$(/usr/bin/stat -f '%l' "$shared_library" 2>/dev/null)" ||
    fail "D3DMetal shared library link count could not be inspected: $shared_library"
  [[ "$link_count" == "1" ]] ||
    fail "D3DMetal shared library must not be hardlinked: $shared_library"

  for module in "${D3DMETAL_SHARED_UNIX_MODULES[@]}"; do
    module_path="$unix_modules/$module.so"
    if [[ -L "$module_path" ]]; then
      link_target="$(/usr/bin/readlink "$module_path")"
      [[ "$link_target" == "$D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET" ]] ||
        fail "D3DMetal source $module.so has an unsafe or incorrect link target: $module_path -> $link_target"
      [[ "$module_path" -ef "$shared_library" ]] ||
        fail "D3DMetal source $module.so does not resolve to its shared library: $module_path"
    elif [[ -f "$module_path" ]]; then
      link_count="$(/usr/bin/stat -f '%l' "$module_path" 2>/dev/null)" ||
        fail "D3DMetal source $module.so link count could not be inspected: $module_path"
      [[ "$link_count" == "1" ]] ||
        fail "D3DMetal source $module.so must not be hardlinked: $module_path"
      /usr/bin/cmp -s "$module_path" "$shared_library" ||
        fail "D3DMetal source $module.so is not the expected libd3dshared payload: $module_path"
    else
      fail "D3DMetal source $module.so is missing or unsafe: $module_path"
    fi

    /bin/rm -f "$module_path"
    /bin/ln -s "$D3DMETAL_SHARED_UNIX_MODULE_LINK_TARGET" "$module_path"
    require_staged_d3dmetal_shared_unix_module_link "$renderer_root" "$module"
  done
}

plist_string_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null | /usr/bin/tr -d '\r\n'
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
  /usr/bin/otool -L "$winebus" 2>/dev/null | /usr/bin/grep -Fq '/System/Library/Frameworks/IOKit.framework/' ||
    fail "Wine winebus.so must link IOKit for the macOS IOHID controller backend: $winebus"
  LC_ALL=C /usr/bin/grep -aFq 'iohid_bus_init' "$winebus" ||
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

verify_wine_kernelbase_process_policy() {
  local wine_root="$1"
  local label="$2"
  local kernelbase marker

  for kernelbase in \
    "$wine_root/lib/wine/i386-windows/kernelbase.dll" \
    "$wine_root/lib/wine/x86_64-windows/kernelbase.dll"; do
    require_source_file "$kernelbase" "$label executable-scoped process-policy module"
    for marker in \
      FORGEPLAY_PROCESS_ARGUMENT_TARGET \
      FORGEPLAY_PROCESS_ARGUMENT_APPEND \
      FORGEPLAY_PROCESS_ARGUMENT_ROOT_ONLY \
      FORGEPLAY_PROCESS_OBSERVATION_TARGET \
      FORGEPLAY_PROCESS_OBSERVATION_FILE \
      FORGEPLAY_PROCESS_V1; do
      binary_contains_text "$kernelbase" "$marker" ||
        fail "$label kernelbase lacks the executable-scoped argument/observation marker: $kernelbase: $marker"
    done
  done
}

verify_runtime_patch_provenance() {
  require_source_file "$RUNTIME_PATCH_PROJECTION_LOCK" "projected runtime patch provenance lock"
  require_source_file "$RUNTIME_PATCH_PROVENANCE_VERIFIER" "runtime patch provenance verifier"
  [[ -d "$RUNTIME_PATCH_PROJECTION" && ! -L "$RUNTIME_PATCH_PROJECTION" ]] ||
    fail "runtime patch projection is unavailable"
  PATH="$FORGEPLAY_SYSTEM_TOOL_PATH" /usr/bin/python3 "$RUNTIME_PATCH_PROVENANCE_VERIFIER" \
    --lock "$RUNTIME_PATCH_PROJECTION_LOCK" \
    --source-identity-lock "$RUNTIME_SOURCE_IDENTITY_LOCK" \
    --patch-root "$RUNTIME_PATCH_PROJECTION" ||
    fail "ForgePlay Runtime patch inventory changed without reviewed provenance"
}

verify_public_source_package_closure() {
  local public_source_authority_fields
  require_source_file "$PUBLIC_SOURCE_EXPORT_VERIFIER" "public-source export verifier"
  require_source_file "$REPO_ROOT/.forgeplay-source-export" "public-source export marker"
  require_source_file "$REPO_ROOT/SOURCE-INVENTORY.json" "public-source inventory"
  require_source_file "$PUBLIC_RUNTIME_BUILD_RECEIPT_TOOL" "public Runtime build receipt verifier"
  [[ "$TRUSTED_GIT_REPOSITORY_INPUT" = /* &&
     -d "$TRUSTED_GIT_REPOSITORY_INPUT" && ! -L "$TRUSTED_GIT_REPOSITORY_INPUT" &&
     "$(cd "$TRUSTED_GIT_REPOSITORY_INPUT" && /bin/pwd -P)" == "$TRUSTED_GIT_REPOSITORY_INPUT" ]] ||
    fail "public-source package mode requires an exact trusted Git repository"
  TRUSTED_GIT_REPOSITORY="$TRUSTED_GIT_REPOSITORY_INPUT"
  for required_input in "$PUBLIC_RUNTIME_BUILD_RECEIPT_INPUT" \
      "$PUBLIC_COMPILER_CAPSULE_MANIFEST_INPUT" "$PUBLIC_BUILD_TOOL_CAPSULE_MANIFEST_INPUT"; do
    [[ "$required_input" = /* && -f "$required_input" && ! -L "$required_input" ]] ||
      fail "public-source package mode requires absolute receipt and toolchain inputs"
  done
  PATH="$FORGEPLAY_SYSTEM_TOOL_PATH" /bin/bash "$PUBLIC_SOURCE_EXPORT_VERIFIER" \
    --project-root "$REPO_ROOT" \
    --release-authority \
    --trusted-git-repository "$TRUSTED_GIT_REPOSITORY" \
    "$REPO_ROOT" ||
    fail "public-source package mode requires an exact verified release export"
  public_source_inventory_fields="$(/usr/bin/python3 - "$REPO_ROOT/SOURCE-INVENTORY.json" <<'PY'
import json
import re
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
release_commit = value.get("releaseCommit")
inventory_sha256 = value.get("inventorySHA256")
if not isinstance(release_commit, str) or re.fullmatch(r"[0-9a-f]{40,64}", release_commit) is None:
    raise SystemExit("public-source release commit is invalid")
if not isinstance(inventory_sha256, str) or re.fullmatch(r"[0-9a-f]{64}", inventory_sha256) is None:
    raise SystemExit("public-source inventory identity is invalid")
print(release_commit, inventory_sha256)
PY
)" || fail "authenticated public-source inventory could not be read"
  read -r PUBLIC_SOURCE_RELEASE_COMMIT PUBLIC_SOURCE_INVENTORY_SHA256 <<< \
    "$public_source_inventory_fields"
  [[ -n "$PUBLIC_SOURCE_RELEASE_COMMIT" && -n "$PUBLIC_SOURCE_INVENTORY_SHA256" ]] ||
    fail "authenticated public-source inventory is incomplete"
}

verify_public_runtime_build_receipt() {
  [[ "$MODE" == "public-source-package" ]] || return 0
  /usr/bin/python3 "$PUBLIC_RUNTIME_BUILD_RECEIPT_TOOL" verify-prepackage \
    --export-root "$REPO_ROOT" \
    --source-tree-sha256 "$WINE_SOURCE_TREE_SHA256" \
    --install-root "$INSTALL_ROOT" \
    --compiler-capsule-manifest "$PUBLIC_COMPILER_CAPSULE_MANIFEST" \
    --build-tool-capsule-manifest "$PUBLIC_BUILD_TOOL_CAPSULE_MANIFEST" \
    --receipt "$PUBLIC_RUNTIME_BUILD_RECEIPT" ||
    fail "Wine install root is not the output bound by the public Runtime build receipt"
}

bind_runtime_policy_source() {
  local input="$RUNTIME_POLICY_SOURCE_INPUT"
  if [[ "$MODE" == "public-source-package" && -z "$input" ]]; then
    fail "public-source package mode requires FORGEPLAY_RUNTIME_POLICY_SOURCE for separately distributed Apple legal, font, and SDL payload inputs"
  fi
  if [[ -z "$input" ]]; then
    input="$REPO_ROOT/Resources/Runners/ForgePlayRuntime"
  fi
  [[ "$input" = /* && -d "$input" && ! -L "$input" ]] ||
    fail "FORGEPLAY_RUNTIME_POLICY_SOURCE must be an absolute non-symlink directory"
  reject_symlink_parent_components "$input" "runtime policy payload source"
  RUNTIME_POLICY_SOURCE="$(cd "$input" && /bin/pwd -P)"
  if [[ "$MODE" == "public-source-package" ]]; then
    case "$RUNTIME_POLICY_SOURCE/" in
      "$REPO_ROOT/"*)
        fail "public-source package mode requires an explicit third-party policy payload outside the source export"
        ;;
    esac
  fi
}

write_public_runtime_build_claim() {
  local manifest_path="$1"
  /usr/bin/python3 "$PUBLIC_RUNTIME_BUILD_RECEIPT_TOOL" write-claim \
    --receipt "$PUBLIC_RUNTIME_BUILD_RECEIPT" \
    --manifest "$manifest_path" \
    --output "$STAGING/PublicRuntimeBuildClaim.json"
}

if [[ "$MODE" == "validate-wine-runtime-payload" ]]; then
  [[ "$#" -eq 1 ]] ||
    fail "usage: package-forgeplay-runtime.sh --validate-wine-runtime-payload <Wine root>"
  validate_runtime_required_wine_payload "$INSTALL_ROOT" ||
    fail "Wine runtime-required payload contract is incomplete"
  printf 'Validated complete Wine runtime payload: %s\n' "$INSTALL_ROOT"
  exit 0
fi

if [[ "$MODE" == "validate-wine-source" || "$MODE" == "validate-wine-source-fixture" ]]; then
  [[ "$#" -eq 0 ]] || fail "usage: FORGEPLAY_WINE_SOURCE=<absolute source root> package-forgeplay-runtime.sh --validate-wine-source"
  verify_runtime_source_identity_policy ||
    fail "runtime source identity policy is invalid"
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

# Building a candidate is what produces the compile evidence consumed by the
# independent verification record. Keep that pre-package source validation
# path usable while retaining patch inventory, source identity, license, and
# payload-integrity validation for every Runtime package operation.
if [[ "$MODE" == "public-source-package" ]]; then
  verify_public_source_package_closure
fi
bind_runtime_policy_source
create_runtime_patch_projection
snapshot_runtime_consumption_inputs
verify_runtime_source_identity_policy ||
  fail "runtime source identity policy is invalid"
verify_runtime_patch_provenance

[[ "$#" -eq 2 && -n "$INSTALL_ROOT" && -n "$OUTPUT_ROOT" ]] ||
  fail "usage: FORGEPLAY_WINE_SOURCE=<absolute source root> FORGEPLAY_GSTREAMER_SDK_ROOT=<absolute SDK root> package-forgeplay-runtime.sh [--public-source-package] <wine install root> <output runtime root>"
[[ "$INSTALL_ROOT" = /* ]] || fail "Wine install root must be an absolute path"
[[ "$OUTPUT_ROOT" = /* ]] || fail "output runtime root must be an absolute path"
reject_symlink_parent_components "$INSTALL_ROOT" "Wine install root"
reject_symlink_parent_components "$OUTPUT_ROOT" "output runtime root"
[[ -n "$GSTREAMER_SDK_INPUT" && "$GSTREAMER_SDK_INPUT" = /* ]] ||
  fail "FORGEPLAY_GSTREAMER_SDK_ROOT must point to the extracted GStreamer 1.0 SDK root"
[[ -d "$GSTREAMER_SDK_INPUT" && ! -L "$GSTREAMER_SDK_INPUT" ]] ||
  fail "GStreamer SDK root must be a non-symlink directory: $GSTREAMER_SDK_INPUT"
reject_symlink_parent_components "$GSTREAMER_SDK_INPUT" "GStreamer SDK root"
GSTREAMER_SDK_ROOT="$(cd "$GSTREAMER_SDK_INPUT" && /bin/pwd -P)"
reject_symlink_parent_components "$GSTREAMER_SDK_ROOT" "GStreamer SDK root"
  validate_gstreamer_directory_symlink_descendants "$GSTREAMER_SDK_ROOT" ||
  fail "GStreamer SDK contains an unsafe intermediate symlink"
GSTREAMER_SDK_BOUND_DIRECTORIES=(
  "$GSTREAMER_SDK_ROOT"
  "$GSTREAMER_SDK_ROOT/lib"
  "$GSTREAMER_SDK_ROOT/lib/gstreamer-1.0"
)
GSTREAMER_SDK_BOUND_IDENTITIES=()
for gstreamer_directory in "${GSTREAMER_SDK_BOUND_DIRECTORIES[@]}"; do
  [[ -d "$gstreamer_directory" && ! -L "$gstreamer_directory" ]] ||
    fail "GStreamer SDK intermediate must be a non-symlink directory: $gstreamer_directory"
  GSTREAMER_SDK_BOUND_IDENTITIES+=("$(directory_identity "$gstreamer_directory")")
done
GSTREAMER_SDK_FILE_MANIFEST="$PATCH_PROJECTION_WORKSPACE/gstreamer-sdk-files.json"
gstreamer_file_manifest \
  capture \
  "$GSTREAMER_SDK_ROOT" \
  "$GSTREAMER_SDK_FILE_MANIFEST" ||
  fail "GStreamer SDK file identities could not be captured"

OUTPUT_PARENT="$(cd "$(/usr/bin/dirname "$OUTPUT_ROOT")" && /bin/pwd -P)"
OUTPUT_BASENAME="$(/usr/bin/basename "$OUTPUT_ROOT")"
[[ -n "$OUTPUT_BASENAME" && "$OUTPUT_BASENAME" != "." && "$OUTPUT_BASENAME" != ".." ]] ||
  fail "output runtime root basename is unsafe"
OUTPUT_ROOT="$OUTPUT_PARENT/$OUTPUT_BASENAME"
OUTPUT_PARENT_ID="$(directory_identity "$OUTPUT_PARENT")" ||
  fail "output runtime parent identity is unavailable"

/usr/bin/python3 - "$OUTPUT_ROOT" "$INSTALL_ROOT" "$GSTREAMER_SDK_ROOT" "$REPO_ROOT" <<'PY' ||
import os
import pwd
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
protected = [
    os.path.realpath(sys.argv[4]),
    os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir),
    os.path.sep,
]
for path in protected:
    if output == path or os.path.commonpath([output, path]) == output:
        raise SystemExit(f"output runtime root must not equal or contain protected path: {path}")
PY
  fail "output runtime root is unsafe"
OUTPUT_ROOT_STATE="$(bind_output_runtime_root_state \
  "$OUTPUT_ROOT" \
  "$OUTPUT_PARENT" \
  "$OUTPUT_PARENT_ID")" ||
  fail "output runtime root state could not be bound"
case "$OUTPUT_ROOT_STATE" in
  absent)
    OUTPUT_ROOT_EXPECTED_ID=""
    ;;
  present:*)
    OUTPUT_ROOT_EXPECTED_ID="${OUTPUT_ROOT_STATE#present:}"
    [[ "$OUTPUT_ROOT_EXPECTED_ID" =~ ^[0-9]+:[0-9]+$ ]] ||
      fail "existing output runtime identity is invalid"
    require_source_file "$OUTPUT_ROOT/RuntimeManifest.json" "existing output runtime manifest"
    require_source_file "$OUTPUT_ROOT/BUILD-METADATA.md" "existing output runtime build metadata"
    [[ "$(directory_identity "$OUTPUT_ROOT")" == "$OUTPUT_ROOT_EXPECTED_ID" ]] ||
      fail "existing output runtime identity changed while validating metadata"
    ;;
  *)
    fail "output runtime root state is invalid"
    ;;
esac
[[ -x "$INSTALL_ROOT/bin/wine" ]] || fail "Wine install root must contain bin/wine: $INSTALL_ROOT"
[[ -d "$INSTALL_ROOT/lib/wine" ]] || fail "Wine install root must contain lib/wine: $INSTALL_ROOT"
validate_runtime_required_wine_payload "$INSTALL_ROOT" ||
  fail "Wine install root omits a runtime-required component or canonical language resource"
for winegstreamer_file in \
  "$INSTALL_ROOT/lib/wine/x86_64-unix/winegstreamer.so" \
  "$INSTALL_ROOT/lib/wine/i386-windows/winegstreamer.dll" \
  "$INSTALL_ROOT/lib/wine/x86_64-windows/winegstreamer.dll" \
  "$INSTALL_ROOT/lib/wine/i386-windows/mfplat.dll" \
  "$INSTALL_ROOT/lib/wine/x86_64-windows/mfplat.dll"; do
  require_source_file "$winegstreamer_file" "Wine GStreamer Media Foundation module"
done
for winegstreamer_caps_binary_marker in \
  'Unable to get audio info from non-fixed or invalid caps.' \
  'Unable to get video info from non-fixed or invalid caps.' \
  'Non-fixed caps intersection result:'; do
  binary_contains_text \
    "$INSTALL_ROOT/lib/wine/x86_64-unix/winegstreamer.so" \
    "$winegstreamer_caps_binary_marker" ||
    fail "Wine GStreamer module is missing the fixed/non-fixed caps contract: $winegstreamer_caps_binary_marker"
done
for mfplat_binary in \
  "$INSTALL_ROOT/lib/wine/i386-windows/mfplat.dll" \
  "$INSTALL_ROOT/lib/wine/x86_64-windows/mfplat.dll"; do
  binary_contains_text \
    "$mfplat_binary" \
    'is unavailable, using a system-memory video buffer.' ||
    fail "Wine Media Foundation module is missing the unsupported-video system-memory fallback: $mfplat_binary"
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
/usr/bin/python3 "$BUILD_PATH_VERIFIER" "$INSTALL_ROOT/bin" "$INSTALL_ROOT/lib/wine" ||
  fail "Wine install root contains a developer-machine build path; use build-forgeplay-wine-runtime.sh"
/usr/bin/python3 "$CLEAN_WINE_MARKER_VERIFIER" "$WINE_NTDLL_UNIX" "$WINE_SERVER_BINARY" ||
  fail "Wine runtime retains a removed contract; rebuild clean Wine 11.12 before packaging"
verify_wine_kernelbase_process_policy "$INSTALL_ROOT" "Wine install root"
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
require_source_file "$WINEMAC_DRIVER" "Wine macOS driver"
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
INSTALL_ROOT_ID="$(directory_identity "$INSTALL_ROOT")" ||
  fail "Wine install root identity is unavailable"
INSTALL_BOUND_PATHS=(
  "$INSTALL_ROOT/bin/wine"
  "$WINE_SERVER_BINARY"
  "$WINE_NTDLL_UNIX"
  "$WINEMAC_DRIVER"
  "$INSTALL_ROOT/lib/wine/i386-windows/dmsynth.dll"
  "$INSTALL_ROOT/lib/wine/i386-windows/icu.dll"
  "$INSTALL_ROOT/lib/wine/x86_64-windows/dmsynth.dll"
  "$INSTALL_ROOT/lib/wine/x86_64-windows/icu.dll"
  "$INSTALL_ROOT/lib/wine/x86_64-windows/wineboot.exe"
)
INSTALL_BOUND_IDENTITIES=()
for install_bound_path in "${INSTALL_BOUND_PATHS[@]}"; do
  require_source_file "$install_bound_path" "bound Wine install input"
  INSTALL_BOUND_IDENTITIES+=("$(regular_file_identity "$install_bound_path")")
done
[[ -f "$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-steam-cef-other-process-opengl-surface.patch" ]] ||
  fail "ForgePlay Steam CEF Wine patch source is missing from the repository"
[[ -f "$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-forgeplay-metal-window-surface-contract.patch" ]] ||
  fail "independent ForgePlay Metal renderer window-surface contract patch is missing from the repository"
[[ -f "$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-forgeplay-d3dmetal-bridge.patch" ]] ||
  fail "independent ForgePlay D3DMetal bridge patch is missing from the repository"
[[ -f "$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-forgeplay-d3dmetal-bridge-contract.md" ]] ||
  fail "ForgePlay D3DMetal public behavior contract is missing from the repository"
MEDIA_OUTPUT_PATCH="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-media-foundation-video-output-negotiation.patch"
require_source_file "$MEDIA_OUTPUT_PATCH" "ForgePlay Media Foundation video-output negotiation patch"
for media_output_source_marker in \
  'gst_caps_is_fixed(caps) && gst_audio_info_from_caps' \
  'gst_caps_is_fixed(caps) && gst_video_info_from_caps' \
  'if (!gst_caps_is_fixed(caps))' \
  'gst_caps_can_intersect(candidate_caps, desired_caps)' \
  'diff --git a/dlls/mfplat/sample.c b/dlls/mfplat/sample.c' \
  'ID3D11Device_CheckFormatSupport' \
  'DXGI_FORMAT_UNKNOWN' \
  'D3D11_FORMAT_SUPPORT_TEXTURE2D' \
  'using a system-memory video buffer.'; do
  /usr/bin/grep -Fq "$media_output_source_marker" "$MEDIA_OUTPUT_PATCH" ||
    fail "ForgePlay Media Foundation video-output patch is missing its source marker: $media_output_source_marker"
done
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
  /usr/bin/grep -Fq "$game_mode_scope_source_marker" "$GAME_MODE_TARGET_SCOPE_PATCH" ||
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
  /usr/bin/grep -Fq "$external_storage_source_marker" "$EXTERNAL_STORAGE_GRANT_PATCH" ||
    fail "ForgePlay external-storage grant activation patch is missing its source marker: $external_storage_source_marker"
done

MANUAL_RENDERER_SELECTION_PATCH="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-manual-steam-renderer-selection.patch"
require_source_file "$MANUAL_RENDERER_SELECTION_PATCH" "ForgePlay manual Steam renderer selection patch"
for manual_renderer_source_marker in \
  'manual-session-selection-missing' \
  'manual-session-d3dmetal' \
  'd3dmetal_nvidia[] = L"d3dMetalNVIDIA"' \
  'L"FORGEPLAY_GAME_RENDERER_REQUESTED", policy' \
  'manual-session-dxmt' \
  'manual-session-d9vk' \
  'manual-session-dxvk' \
  'host-policy;manual-selection' \
  'process-creation-rejected'; do
  /usr/bin/grep -Fq "$manual_renderer_source_marker" "$MANUAL_RENDERER_SELECTION_PATCH" ||
    fail "ForgePlay manual renderer patch is missing its source marker: $manual_renderer_source_marker"
done

STEAM_RENDERER_CONTROL_PLANE_PATCH="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-steam-renderer-control-plane-persistence.patch"
require_source_file "$STEAM_RENDERER_CONTROL_PLANE_PATCH" "ForgePlay Steam renderer control-plane persistence patch"
for steam_renderer_control_source_marker in \
  is_forgeplay_steam_common_redistributable_path \
  'L"_CommonRedist"' \
  'Host-owned manual selection' \
  'component and DLL-path controls must survive a Steam self-reexec'; do
  /usr/bin/grep -Fq "$steam_renderer_control_source_marker" "$STEAM_RENDERER_CONTROL_PLANE_PATCH" ||
    fail "ForgePlay Steam renderer control-plane patch is missing its source marker: $steam_renderer_control_source_marker"
done

STEAM_SESSION_COMPATIBILITY_PATCH="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-steam-session-compatibility-controls.patch"
require_source_file "$STEAM_SESSION_COMPATIBILITY_PATCH" "ForgePlay Steam session compatibility controls patch"
for compatibility_source_marker in \
  'dlls/kernelbase/process.c' \
  'D3DM_VENDOR_ID' \
  'forgeplay_renderer_path_separator' \
  'FORGEPLAY_GAME_RENDERER_BASE_HELPER_SUFFIX_RULES_V1' \
  'FORGEPLAY_NETWORK_PROFILE_REQUESTED' \
  'dlls/ntdll/loader.c' \
  'FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP_V1' \
  'nvapi_QueryInterface' \
  'dlls/ntdll/unix/process.c' \
  'FORGEPLAY_AUDIO_INPUT_MODE' \
  'dlls/nsi/nsi.c' \
  'wifi-identity' \
  'ethernet-identity' \
  'dlls/ntdll/unix/socket.c' \
  'case IP_RECVTOS:' \
  'fill_control_message( WS_IPPROTO_IP, WS_IP_TOS' \
  'dlls/winecoreaudio.drv/coreaudio.c' \
  'params->flow == eCapture'; do
  /usr/bin/grep -Fq "$compatibility_source_marker" "$STEAM_SESSION_COMPATIBILITY_PATCH" ||
    fail "ForgePlay Steam session compatibility patch is missing its source marker: $compatibility_source_marker"
done

MANAGED_PROCESS_JOURNAL_PATCH="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-managed-darwin-process-journal.patch"
require_source_file "$MANAGED_PROCESS_JOURNAL_PATCH" "ForgePlay managed Darwin process journal patch"
for managed_process_source_marker in \
  'forgeplay_record_managed_wine_process( "wine-loader" )' \
  'forgeplay_record_managed_wine_process( "wineserver" )' \
  'FORGEPLAY_MANAGED_WINE_PROCESS_EVIDENCE_FILE' \
  'FORGEPLAY_MANAGED_APPLICATION_OWNER_PID' \
  'FORGEPLAY_MANAGED_APPLICATION_OWNER_START_US' \
  'FORGEPLAY_MANAGED_WINE_OWNER_V1' \
  forgeplay_start_application_owner_monitor \
  'EVFILT_PROC' \
  'NOTE_EXIT' \
  'The managed-process identity belongs to the trusted Unix launch' \
  'process_started_at_unix_microseconds'; do
  /usr/bin/grep -Fq "$managed_process_source_marker" "$MANAGED_PROCESS_JOURNAL_PATCH" ||
    fail "ForgePlay managed Darwin process journal patch is missing its source marker: $managed_process_source_marker"
done
validate_wine_source_root 1
verify_public_runtime_build_receipt
WINEGSTREAMER_FORMAT_SOURCE="$WINE_SOURCE_ROOT/dlls/winegstreamer/wg_format.c"
for winegstreamer_format_source_marker in \
  'gst_caps_is_fixed(caps) && gst_audio_info_from_caps' \
  'gst_caps_is_fixed(caps) && gst_video_info_from_caps'; do
  /usr/bin/grep -Fq "$winegstreamer_format_source_marker" "$WINEGSTREAMER_FORMAT_SOURCE" ||
    fail "corresponding Wine source is missing the fixed raw caps contract: $winegstreamer_format_source_marker"
done
WINEGSTREAMER_PARSER_SOURCE="$WINE_SOURCE_ROOT/dlls/winegstreamer/wg_parser.c"
for winegstreamer_parser_source_marker in \
  'if (!gst_caps_is_fixed(caps))' \
  'gst_caps_can_intersect(candidate_caps, desired_caps)'; do
  /usr/bin/grep -Fq "$winegstreamer_parser_source_marker" "$WINEGSTREAMER_PARSER_SOURCE" ||
    fail "corresponding Wine source is missing the non-fixed ACCEPT_CAPS contract: $winegstreamer_parser_source_marker"
done
MFPLAT_SAMPLE_SOURCE="$WINE_SOURCE_ROOT/dlls/mfplat/sample.c"
for mfplat_sample_source_marker in \
  'ID3D11Device_CheckFormatSupport' \
  'allocator->frame_desc.dxgi_format == DXGI_FORMAT_UNKNOWN ? E_INVALIDARG' \
  'D3D11_FORMAT_SUPPORT_TEXTURE2D' \
  'service->d3d11_device = NULL' \
  'using a system-memory video buffer.'; do
  /usr/bin/grep -Fq "$mfplat_sample_source_marker" "$MFPLAT_SAMPLE_SOURCE" ||
    fail "corresponding Wine source is missing the planar-video system-memory fallback: $mfplat_sample_source_marker"
done
GAME_MODE_TARGET_SCOPE_PROCESS_SOURCE="$WINE_SOURCE_ROOT/dlls/ntdll/unix/process.c"
for game_mode_scope_source_marker in \
  forgeplay_game_mode_image_path_is_eligible \
  eligible_game_target \
  FORGEPLAY_GAME_MODE_DIRECT_TARGET \
  '&params->ImagePathName'; do
  /usr/bin/grep -Fq "$game_mode_scope_source_marker" "$GAME_MODE_TARGET_SCOPE_PROCESS_SOURCE" ||
    fail "corresponding Wine source is missing the resolved Game Mode target boundary: $game_mode_scope_source_marker"
done
GAME_MODE_TARGET_SCOPE_WINEMAC_SOURCE="$WINE_SOURCE_ROOT/dlls/winemac.drv/window.c"
for game_mode_scope_source_marker in \
  FORGEPLAY_GAME_MODE_HOST_ROUTED \
  'preserving fixed Game Mode host application icon'; do
  /usr/bin/grep -Fq "$game_mode_scope_source_marker" "$GAME_MODE_TARGET_SCOPE_WINEMAC_SOURCE" ||
    fail "corresponding Wine source does not preserve the fixed Game Mode host icon: $game_mode_scope_source_marker"
done
GAME_MODE_TARGET_SCOPE_LOADER_SOURCE="$WINE_SOURCE_ROOT/dlls/ntdll/unix/loader.c"
for game_mode_scope_source_marker in \
  FORGEPLAY_GAME_MODE_DIRECT_TARGET \
  loader_route_skipped_game_mode_not_requested \
  loader_route_skipped_non_game_target \
  'unsetenv( "FORGEPLAY_STEAM_GAME_PROCESS" )'; do
  /usr/bin/grep -Fq "$game_mode_scope_source_marker" "$GAME_MODE_TARGET_SCOPE_LOADER_SOURCE" ||
    fail "corresponding Wine source is missing the Game Mode direct-target boundary: $game_mode_scope_source_marker"
done
MANUAL_RENDERER_SOURCE="$WINE_SOURCE_ROOT/dlls/kernelbase/process.c"
for manual_renderer_source_marker in \
  'manual-session-selection-missing' \
  'manual-session-d3dmetal' \
  'd3dmetal_nvidia[] = L"d3dMetalNVIDIA"' \
  'L"FORGEPLAY_GAME_RENDERER_REQUESTED", policy' \
  'manual-session-dxmt' \
  'manual-session-d9vk' \
  'manual-session-dxvk' \
  'L"process-creation-rejected"' \
  'status = STATUS_NOT_SUPPORTED;'; do
  /usr/bin/grep -Fq "$manual_renderer_source_marker" "$MANUAL_RENDERER_SOURCE" ||
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
  if /usr/bin/grep -Fq "$forbidden_manual_renderer_source_marker" "$MANUAL_RENDERER_SOURCE"; then
    fail "corresponding Wine source retains removed automatic/mixed renderer routing: $forbidden_manual_renderer_source_marker"
  fi
done
for steam_renderer_control_source_marker in \
  is_forgeplay_steam_common_redistributable_path \
  'L"_CommonRedist"' \
  'Host-owned manual selection' \
  'component and DLL-path controls must survive a Steam self-reexec'; do
  /usr/bin/grep -Fq "$steam_renderer_control_source_marker" "$MANUAL_RENDERER_SOURCE" ||
    fail "corresponding Wine source is missing Steam renderer control-plane persistence: $steam_renderer_control_source_marker"
done
for preserved_manual_control in \
  'L"FORGEPLAY_GAME_RENDERER_COMPONENTS_X64"' \
  'L"FORGEPLAY_GAME_RENDERER_COMPONENTS_X86"' \
  'L"FORGEPLAY_GAME_RENDERER_DLL_PATH_X64"' \
  'L"FORGEPLAY_GAME_RENDERER_DLL_PATH_X86"'; do
  if /usr/bin/sed -n '/renderer_state_variables\[\] =/,/^    };/p' "$MANUAL_RENDERER_SOURCE" |
      /usr/bin/grep -Fq "$preserved_manual_control"; then
    fail "corresponding Wine source still scrubs a host-owned manual renderer control during Steam re-exec: $preserved_manual_control"
  fi
done
for compatibility_source_marker in \
  'FORGEPLAY_GAME_RENDERER_ENV_D3DM_VENDOR_ID' \
  'FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP' \
  'forgeplay_renderer_path_separator' \
  'FORGEPLAY_GAME_RENDERER_BASE_HELPER_SUFFIX_RULES_V1' \
  'FORGEPLAY_GAME_RENDERER_ENV_FORGEPLAY_NETWORK_PROFILE' \
  'FORGEPLAY_NETWORK_PROFILE_REQUESTED' \
  'FORGEPLAY_AUDIO_INPUT_MODE'; do
  /usr/bin/grep -Fq "$compatibility_source_marker" "$MANUAL_RENDERER_SOURCE" ||
    fail "corresponding Wine source is missing a Steam session compatibility control: $compatibility_source_marker"
done
for compatibility_source in \
  "$WINE_SOURCE_ROOT/dlls/ntdll/loader.c" \
  "$WINE_SOURCE_ROOT/dlls/ntdll/unix/process.c" \
  "$WINE_SOURCE_ROOT/dlls/nsi/nsi.c" \
  "$WINE_SOURCE_ROOT/dlls/winecoreaudio.drv/coreaudio.c"; do
  require_source_file "$compatibility_source" "Steam session compatibility source"
done
for compatibility_source_marker in \
  FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP_V1 \
  nvapi_QueryInterface \
  forgeplay_thread_init_func; do
  /usr/bin/grep -Fq "$compatibility_source_marker" "$WINE_SOURCE_ROOT/dlls/ntdll/loader.c" ||
    fail "corresponding Wine ntdll loader source is missing an NVAPI bootstrap control: $compatibility_source_marker"
done
for compatibility_source_marker in \
  D3DM_VENDOR_ID \
  FORGEPLAY_D3DMETAL_NVAPI_BOOTSTRAP \
  FORGEPLAY_NETWORK_PROFILE \
  FORGEPLAY_AUDIO_INPUT_MODE; do
  /usr/bin/grep -Fq "$compatibility_source_marker" "$WINE_SOURCE_ROOT/dlls/ntdll/unix/process.c" ||
    fail "corresponding Wine ntdll source is missing a child compatibility environment control: $compatibility_source_marker"
done
for compatibility_source_marker in \
  FORGEPLAY_NETWORK_PROFILE \
  wifi-identity \
  ethernet-identity \
  forgeplay_normalize_network_adapter_types; do
  /usr/bin/grep -Fq "$compatibility_source_marker" "$WINE_SOURCE_ROOT/dlls/nsi/nsi.c" ||
    fail "corresponding Wine NSI source is missing a network presentation control: $compatibility_source_marker"
done
for compatibility_source_marker in \
  FORGEPLAY_AUDIO_INPUT_MODE \
  'params->flow == eCapture' \
  'params->result = S_OK'; do
  /usr/bin/grep -Fq "$compatibility_source_marker" "$WINE_SOURCE_ROOT/dlls/winecoreaudio.drv/coreaudio.c" ||
    fail "corresponding Wine CoreAudio source is missing an input visibility control: $compatibility_source_marker"
done

[[ "$(directory_identity "$OUTPUT_PARENT")" == "$OUTPUT_PARENT_ID" ]] ||
  fail "output runtime parent changed before staging"
STAGING="$(/usr/bin/mktemp -d "$OUTPUT_PARENT/.${OUTPUT_BASENAME}.forgeplay-package.XXXXXXXX")" ||
  fail "could not create private runtime staging root"
/bin/chmod 700 "$STAGING" || fail "could not protect runtime staging root"
STAGING_ID="$(directory_identity "$STAGING")" || fail "runtime staging identity is unavailable"
[[ "$(directory_identity "$OUTPUT_PARENT")" == "$OUTPUT_PARENT_ID" ]] ||
  fail "output runtime parent changed while staging was created"
trap cleanup EXIT
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

is_macho() {
  local path="$1"
  /usr/bin/file "$path" 2>/dev/null | /usr/bin/grep -q 'Mach-O'
}

copy_renderer_license_files() {
  local renderer_name="$1"
  local renderer_source="$2"
  local target="$STAGING/Legal/$renderer_name"
  [[ -d "$renderer_source" ]] || return 0
  /bin/mkdir -p "$target"
  /usr/bin/find "$renderer_source" -maxdepth 2 -type f \( \
      -iname 'LICENSE*' -o \
      -iname 'COPYING*' -o \
      -iname 'NOTICE*' \
    \) -exec /bin/cp -fL {} "$target/" \;
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
  /bin/mkdir -p "$STAGING/Frameworks"
  /usr/bin/python3 "$RENDERER_PAYLOAD_MATERIALIZER" \
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
  local runtime_info_source="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Info.plist"
  local wine_modifications_source="$REPO_ROOT/LICENSES/ForgePlayWine/FORGEPLAY-MODIFICATIONS.md"
  local wine_modifications_target="$STAGING/Legal/Wine/FORGEPLAY-MODIFICATIONS.md"
  local apple_legal_source="$RUNTIME_POLICY_SOURCE/Legal/AppleGPTK"
  local apple_legal_target="$STAGING/Legal/AppleGPTK"
  local apple_license="$apple_legal_source/License.rtf"
  local apple_acknowledgements="$apple_legal_source/Acknowledgements.rtf"
  local game_mode_legal_source="$REPO_ROOT/LICENSES/ForgePlayGameMode"
  local game_mode_legal_target="$STAGING/Legal/ForgePlayGameMode"
  local gpl_license_source="$REPO_ROOT/LICENSES/GPL-3.0-only.txt"
  local lgpl_license_source="$REPO_ROOT/LICENSES/LGPL-2.1-or-later.txt"
  [[ -f "$runtime_info_source" && ! -L "$runtime_info_source" ]] ||
    fail "runtime support Info.plist is missing or unsafe: $runtime_info_source"
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
  require_source_file "$gpl_license_source" "GPL-3.0-only license text"
  require_source_file "$lgpl_license_source" "LGPL-2.1-or-later license text"
  require_source_file "$wine_modifications_source" "ForgePlay Wine modifications notice"
  require_file_sha256 \
    "$lgpl_license_source" \
    "$LGPL_2_1_LICENSE_SHA256" \
    "LGPL-2.1-or-later license text"
  require_file_sha256 \
    "$wine_modifications_source" \
    "$FORGEPLAY_WINE_MODIFICATIONS_SHA256" \
    "ForgePlay Wine modifications notice"
  for game_mode_notice in \
    GAME_MODE_FILE_LICENSES.json \
    GAME_MODE_LICENSE_SCOPE.md \
    GAME_MODE_NOTICE \
    GAME_MODE_SYMBOL_MANIFEST.md; do
    require_source_file "$game_mode_legal_source/$game_mode_notice" \
      "ForgePlay Game Mode license material"
  done

  /bin/mkdir -p "$STAGING/Frameworks"
  /bin/cp -f "$runtime_info_source" "$STAGING/Info.plist"
  /bin/mkdir -p "$apple_legal_target"
  /bin/cp -f "$apple_license" "$apple_legal_target/License.rtf"
  /bin/cp -f "$apple_acknowledgements" "$apple_legal_target/Acknowledgements.rtf"
  /bin/mkdir -p "$game_mode_legal_target"
  /bin/cp -f "$gpl_license_source" "$game_mode_legal_target/GPL-3.0-only.txt"
  /bin/cp -f "$lgpl_license_source" "$game_mode_legal_target/LGPL-2.1-or-later.txt"
  /bin/mkdir -p "${wine_modifications_target%/*}"
  /bin/cp -f "$wine_modifications_source" "$wine_modifications_target"
  for game_mode_notice in \
    GAME_MODE_FILE_LICENSES.json \
    GAME_MODE_LICENSE_SCOPE.md \
    GAME_MODE_NOTICE \
    GAME_MODE_SYMBOL_MANIFEST.md; do
    /bin/cp -f "$game_mode_legal_source/$game_mode_notice" \
      "$game_mode_legal_target/$game_mode_notice"
  done
}

copy_font_compatibility_payload() {
  local source="$RUNTIME_POLICY_SOURCE"
  local source_fonts="$source/wine/share/wine/fonts"
  local source_license="$source/Legal/NanumGothic/OFL.txt"
  local source_identity="$source/Legal/NanumGothic/SOURCE-IDENTITY.json"
  local target_fonts="$STAGING/wine/share/wine/fonts"
  local target_license="$STAGING/Legal/NanumGothic/OFL.txt"
  local target_identity="$STAGING/Legal/NanumGothic/SOURCE-IDENTITY.json"
  local regular_source="$source_fonts/NanumGothic-Regular.ttf"
  local bold_source="$source_fonts/NanumGothic-Bold.ttf"

  require_source_file "$regular_source" "Nanum Gothic Regular font payload"
  require_source_file "$bold_source" "Nanum Gothic Bold font payload"
  require_source_file "$source_license" "Nanum Gothic OFL license"
  require_source_file "$source_identity" "Nanum Gothic source identity"
  require_file_sha256 "$regular_source" "$NANUM_GOTHIC_REGULAR_SHA256" "Nanum Gothic Regular font payload"
  require_file_sha256 "$bold_source" "$NANUM_GOTHIC_BOLD_SHA256" "Nanum Gothic Bold font payload"
  require_file_sha256 "$source_license" "$NANUM_GOTHIC_OFL_SHA256" "Nanum Gothic OFL license"
  require_file_sha256 "$source_identity" "$NANUM_GOTHIC_SOURCE_IDENTITY_SHA256" "Nanum Gothic source identity"

  /bin/mkdir -p "$target_fonts" "$(/usr/bin/dirname "$target_license")"
  /bin/rm -f \
    "$target_fonts/NanumGothic-Regular.ttf" \
    "$target_fonts/NanumGothic-Bold.ttf" \
    "$target_license" \
    "$target_identity"
  /bin/cp -f "$regular_source" "$target_fonts/NanumGothic-Regular.ttf"
  /bin/cp -f "$bold_source" "$target_fonts/NanumGothic-Bold.ttf"
  /bin/cp -f "$source_license" "$target_license"
  /bin/cp -f "$source_identity" "$target_identity"

  require_source_file \
    "$target_fonts/NanumGothic-Regular.ttf" \
    "staged Nanum Gothic Regular font payload"
  require_source_file \
    "$target_fonts/NanumGothic-Bold.ttf" \
    "staged Nanum Gothic Bold font payload"
  require_source_file "$target_license" "staged Nanum Gothic OFL license"
  require_source_file "$target_identity" "staged Nanum Gothic source identity"
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
  require_file_sha256 \
    "$target_identity" \
    "$NANUM_GOTHIC_SOURCE_IDENTITY_SHA256" \
    "staged Nanum Gothic source identity"
}

copy_steam_compat_payload() {
  local source="$RUNTIME_POLICY_SOURCE/SteamCompat/sdl2-compat"
  local target="$STAGING/SteamCompat/sdl2-compat"
  [[ -d "$source" && ! -L "$source" ]] ||
    fail "sdl2-compat payload source is missing or unsafe: $source"
  [[ ! -e "$target" && ! -L "$target" ]] ||
    fail "sdl2-compat payload target is already occupied: $target"

  /bin/mkdir -p "$(/usr/bin/dirname "$target")"
  /usr/bin/python3 - "$source" "$target" <<'PY' ||
import hashlib
import os
import stat
import sys

source, target = map(os.path.abspath, sys.argv[1:])
expected_directories = {
    "2.32.70",
    "2.32.70/win32-x86",
}
expected_files = {
    "2.32.70/win32-x86/INSTALL.md": "c4c1440031fdaed80290fa069e753d589c68a51c760e09357bf7eac45a22a5c5",
    "2.32.70/win32-x86/LICENSE.txt": "0164aec3168ca9606c1f6066e879b4e8c7f2e46a838391f284348ab0aa1eabf2",
    "2.32.70/win32-x86/README.md": "c22f8bd62edef57356f4b18efa2c38a4594242b1f6197d03aebf97a9724df110",
    "2.32.70/win32-x86/SDL2.dll": "4745d609ce00c47fba2d9790ea08f943c4bfaf33bc6b749f21313f592b566cd0",
    "2.32.70/win32-x86/SDL3.dll": "7f85f7c0fb1189050405acd39bd1e36a8f94fff5952c513497a9dcafcb86a9b0",
    "2.32.70/win32-x86/git-hash.txt": "4a1fdf15a33c44057d36eab2c40d1331526ede0fc8f3d5a8a424a6ab84a162e9",
}
maximum_file_bytes = 128 * 1024 * 1024
maximum_total_bytes = 256 * 1024 * 1024


def identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_uid,
    )


def stable_file(path, relative):
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
            or before.st_size > maximum_file_bytes
        ):
            raise SystemExit(f"sdl2-compat source file is unsafe: {relative}")
        payload = bytearray()
        offset = 0
        while offset < before.st_size:
            chunk = os.pread(descriptor, min(1024 * 1024, before.st_size - offset), offset)
            if not chunk:
                raise SystemExit(f"sdl2-compat source file became incomplete: {relative}")
            payload.extend(chunk)
            offset += len(chunk)
        after = os.fstat(descriptor)
        if identity(before) != identity(after):
            raise SystemExit(f"sdl2-compat source file changed while being read: {relative}")
        data = bytes(payload)
        if hashlib.sha256(data).hexdigest() != expected_files[relative]:
            raise SystemExit(f"sdl2-compat source file content is not reviewed: {relative}")
        return identity(before), data
    finally:
        os.close(descriptor)


def scan_source():
    root_metadata = os.lstat(source)
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        raise SystemExit("sdl2-compat source root must be a non-symlink directory")
    observed_directories = {}
    observed_files = {}
    for current_root, directory_names, file_names in os.walk(source, followlinks=False):
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            path = os.path.join(current_root, name)
            relative = os.path.relpath(path, source).replace(os.sep, "/")
            metadata = os.lstat(path)
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                raise SystemExit(f"sdl2-compat source contains an unsafe directory entry: {relative}")
            observed_directories[relative] = identity(metadata)
        for name in file_names:
            path = os.path.join(current_root, name)
            relative = os.path.relpath(path, source).replace(os.sep, "/")
            observed_files[relative] = path
    if set(observed_directories) != expected_directories:
        raise SystemExit("sdl2-compat source directory inventory is not the reviewed allowlist")
    if set(observed_files) != set(expected_files):
        raise SystemExit("sdl2-compat source file inventory is not the reviewed allowlist")

    total_bytes = 0
    payloads = {}
    file_identities = {}
    for relative in sorted(expected_files):
        file_identity, payload = stable_file(observed_files[relative], relative)
        total_bytes += len(payload)
        if total_bytes > maximum_total_bytes:
            raise SystemExit("sdl2-compat source payload exceeds its reviewed size bound")
        file_identities[relative] = file_identity
        payloads[relative] = payload
    if identity(os.lstat(source)) != identity(root_metadata):
        raise SystemExit("sdl2-compat source root changed while being read")
    return {
        "directories": observed_directories,
        "files": file_identities,
        "root": identity(root_metadata),
    }, payloads


source_snapshot, payloads = scan_source()
parent = os.path.dirname(target)
parent_metadata = os.lstat(parent)
if not stat.S_ISDIR(parent_metadata.st_mode) or stat.S_ISLNK(parent_metadata.st_mode):
    raise SystemExit("sdl2-compat target parent must be a non-symlink directory")
try:
    os.lstat(target)
except FileNotFoundError:
    pass
else:
    raise SystemExit("sdl2-compat target became occupied")
os.mkdir(target, 0o755)
for relative in sorted(expected_directories, key=lambda value: (value.count("/"), value)):
    os.mkdir(os.path.join(target, *relative.split("/")), 0o755)
for relative in sorted(expected_files):
    destination = os.path.join(target, *relative.split("/"))
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o644,
    )
    try:
        payload = payloads[relative]
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise SystemExit(f"sdl2-compat target write made no progress: {relative}")
            offset += written
        os.fchmod(descriptor, 0o644)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)

verified_snapshot, _ = scan_source()
if verified_snapshot != source_snapshot:
    raise SystemExit("sdl2-compat source changed while the reviewed payload was copied")
PY
    fail "sdl2-compat payload does not exactly match the reviewed file allowlist"
}

copy_wine_patch_files() {
  local source="$RUNTIME_PATCH_PROJECTION"
  local patch_name contract_name
  [[ -d "$source" && ! -L "$source" ]] ||
    fail "verified Wine patch projection is missing or unsafe: $source"
  [[ "${#RUNTIME_PATCH_ORDER[@]}" -gt 0 ]] || fail "verified Wine patch projection order is empty"
  /bin/mkdir -p "$STAGING/Patches"
  for patch_name in "${RUNTIME_PATCH_ORDER[@]}"; do
    require_source_file "$source/$patch_name" "ordered Wine patch"
    /bin/cp -f "$source/$patch_name" "$STAGING/Patches/$patch_name"
  done
  for contract_name in "${RUNTIME_BEHAVIOR_CONTRACTS[@]}"; do
    require_source_file "$source/$contract_name" "Wine behavior contract"
    /bin/cp -f "$source/$contract_name" "$STAGING/Patches/$contract_name"
  done
}

copy_wine_patch_license_sidecars() {
  local source="$RUNTIME_PATCH_PROJECTION"
  local sidecar
  for sidecar in "${RUNTIME_PATCH_LICENSE_SIDECARS[@]}"; do
    require_source_file "$source/$sidecar" "Wine patch license sidecar"
    /bin/cp -f "$source/$sidecar" "$STAGING/Patches/$sidecar"
  done
}

build_forgeplay_steam_launcher() {
  local source="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Sources/forgeplay_steam_launcher.c"
  local target="$STAGING/wine/lib/wine/x86_64-windows/forgeplay-steam-launcher.exe"
  local compiler="${FORGEPLAY_MINGW_CC:-}"
  local compiler_trusted_root=""
  local capsule_root="$PATCH_PROJECTION_WORKSPACE/packaging-compiler-capsule"
  local capsule_manifest="$PATCH_PROJECTION_WORKSPACE/packaging-compiler-capsule.json"
  local source_snapshot_root="$PATCH_PROJECTION_WORKSPACE/packaging-compiler-input"

  [[ -f "$source" ]] || fail "ForgePlay Steam launcher source is missing: $source"
  if [[ -z "$compiler" ]]; then
    if [[ -x "$HOMEBREW_X86_PREFIX/bin/x86_64-w64-mingw32-gcc" ]]; then
      compiler="$HOMEBREW_X86_PREFIX/bin/x86_64-w64-mingw32-gcc"
      compiler_trusted_root="$HOMEBREW_X86_PREFIX"
    fi
  fi
  if [[ -z "$compiler" && -x /opt/homebrew/bin/x86_64-w64-mingw32-gcc ]]; then
    compiler="/opt/homebrew/bin/x86_64-w64-mingw32-gcc"
    compiler_trusted_root="/opt/homebrew"
  fi
  [[ -n "$compiler" && -x "$compiler" ]] ||
    fail "x86_64-w64-mingw32-gcc is required to build the ForgePlay Steam launcher"
  [[ "$compiler" = /* ]] ||
    fail "x86_64-w64-mingw32-gcc must be an absolute executable path"
  if [[ -z "$compiler_trusted_root" ]]; then
    case "$compiler" in
      "$HOMEBREW_X86_PREFIX"/*) compiler_trusted_root="$HOMEBREW_X86_PREFIX" ;;
      /opt/homebrew/*) compiler_trusted_root="/opt/homebrew" ;;
    esac
  fi
  if [[ -n "$compiler_trusted_root" ]]; then
    compiler="$(resolve_trusted_tool_input \
      "$compiler" \
      "$compiler_trusted_root" \
      "x86_64-w64-mingw32-gcc")" ||
      fail "x86_64-w64-mingw32-gcc could not be resolved inside its trusted installation root"
  else
    [[ ! -L "$compiler" ]] ||
      fail "custom x86_64-w64-mingw32-gcc must not be a symlink"
    reject_symlink_parent_components "$compiler" "x86_64-w64-mingw32-gcc"
  fi

  /bin/mkdir -m 700 "$source_snapshot_root"
  snapshot_regular_input \
    "$source" \
    "$source_snapshot_root/forgeplay_steam_launcher.c" \
    "ForgePlay Steam launcher source" \
    4194304
  source="$source_snapshot_root/forgeplay_steam_launcher.c"
  local source_identity source_sha256
  source_identity="$(regular_file_identity "$source")" ||
    fail "packaging source capsule identity is unavailable"
  source_sha256="$(/usr/bin/shasum -a 256 "$source" | /usr/bin/awk '{print $1}')" ||
    fail "packaging source capsule SHA-256 is unavailable"

  /bin/bash "$COMPILER_CAPSULE_TOOL" \
    --materialize-compiler-capsule \
    "$capsule_root" \
    "$capsule_manifest" \
    - \
    - \
    "$compiler" \
    - \
    -
  compiler="$capsule_root/bin/x86_64-w64-mingw32-gcc"
  [[ -x "$compiler" && ! -L "$compiler" ]] ||
    fail "packaging compiler capsule did not produce the required MinGW wrapper"

  /bin/mkdir -p "$(/usr/bin/dirname "$target")"
  /bin/bash "$COMPILER_CAPSULE_TOOL" \
    --verify-compiler-capsule "$capsule_root" "$capsule_manifest"
  "$compiler" -municode -mwindows -O2 -Wall -Wextra -o "$target" "$source" -lshell32
  /bin/bash "$COMPILER_CAPSULE_TOOL" \
    --verify-compiler-capsule "$capsule_root" "$capsule_manifest"
  [[ "$(regular_file_identity "$source")" == "$source_identity" ]] ||
    fail "packaging source capsule changed through compiler spawn"
  require_file_sha256 "$source" "$source_sha256" "packaging source capsule"
  /bin/chmod 755 "$target"
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
    /usr/bin/cmp -s \
      "$d3dmetal_root/wine/x86_64-windows/nvapi64.dll" \
      "$d3dmetal_root/wine/x86_64-windows/nvapi.dll" ||
      fail "D3DMetal nvapi.dll must be an exact alias of nvapi64.dll"
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
  for module in d3d10 d3d11 d3d12 dxgi nvapi nvapi64 nvngx-on-metalfx; do
    if [[ -f "$wine_unix/$module.so" ]] &&
       LC_ALL=C /usr/bin/grep -aEq "$marker_pattern" "$wine_unix/$module.so"; then
      fail "active Wine Unix module must not contain a renderer overlay: $wine_unix/$module.so"
    fi
    if [[ -f "$wine_windows/$module.dll" ]] &&
       LC_ALL=C /usr/bin/grep -aEq "$marker_pattern" "$wine_windows/$module.dll"; then
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

  /bin/rm -f "$wine_unix/libd3dshared.dylib"
  /bin/rm -rf "$wine_external/D3DMetal.framework"

  local module
  for module in nvapi nvapi64 nvngx-on-metalfx; do
    /bin/rm -f "$wine_unix/$module.so" "$wine_windows/$module.dll"
  done
}

is_runtime_wine_bin_entry() {
  local candidate="$1"
  local allowed
  for allowed in "${WINE_RUNTIME_BIN_ALLOWLIST[@]}"; do
    [[ "$candidate" == "$allowed" ]] && return 0
  done
  return 1
}

prune_development_only_wine_payload() {
  local bin_root="$STAGING/wine/bin"
  local name path unexpected=""

  [[ -d "$bin_root" && ! -L "$bin_root" ]] ||
    fail "staged Wine bin root is missing or unsafe: $bin_root"
  for name in "${WINE_DEVELOPMENT_ONLY_BIN_ENTRIES[@]}"; do
    path="$bin_root/$name"
    if [[ -e "$path" || -L "$path" ]]; then
      [[ -f "$path" || -L "$path" ]] ||
        fail "development-only Wine entry is not a removable file: $path"
      /bin/rm -f -- "$path"
    fi
    [[ ! -e "$path" && ! -L "$path" ]] ||
      fail "development-only Wine entry remained in the Runtime: $path"
  done

  while IFS= read -r -d '' path; do
    name="${path##*/}"
    if ! is_runtime_wine_bin_entry "$name"; then
      unexpected="$path"
      break
    fi
  done < <(/usr/bin/find "$bin_root" -mindepth 1 -maxdepth 1 -print0)
  if [[ -n "$unexpected" ]]; then
    fail "Wine bin payload contains an undeclared Runtime or development entry: $unexpected"
  fi
  for name in "${WINE_RUNTIME_BIN_ALLOWLIST[@]}"; do
    path="$bin_root/$name"
    [[ -f "$path" || -L "$path" ]] ||
      fail "Wine Runtime bin allowlist entry is missing: $path"
  done
}

add_rpath_if_needed() {
  local macho="$1"
  local rpath="$2"
  if ! /usr/bin/otool -l "$macho" 2>/dev/null | /usr/bin/awk '/cmd LC_RPATH/{seen=1} seen && /path /{print $2; seen=0}' | /usr/bin/grep -Fxq "$rpath"; then
    local output
    if ! output="$(/usr/bin/install_name_tool -add_rpath "$rpath" "$macho" 2>&1)"; then
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
        if ! output="$(/usr/bin/install_name_tool -delete_rpath "$rpath" "$winegstreamer" 2>&1)"; then
          fail "unable to remove build-time GStreamer LC_RPATH $rpath: $output"
        fi
        ;;
    esac
  done < <(
    /usr/bin/otool -l "$winegstreamer" 2>/dev/null |
      /usr/bin/awk '/cmd LC_RPATH/{seen=1; next} seen && /path /{print $2; seen=0}' |
      /usr/bin/sort -u
  )
  add_rpath_if_needed "$winegstreamer" "@loader_path/../../../gstreamer/lib"
}

sanitize_gstreamer_private_build_paths() {
  local root="$STAGING/wine/gstreamer"
  [[ -d "$root" && ! -L "$root" ]] ||
    fail "staged GStreamer root is missing or unsafe before build-path sanitization: $root"
  /usr/bin/python3 - "$root" <<'PY' ||
import os
import re
import stat
import struct
import sys

root = os.path.realpath(sys.argv[1])
maximum_file_bytes = 1024 * 1024 * 1024
mh_magic_64 = 0xFEEDFACF
patterns = (
    re.compile(rb"/Users/([^/\x00-\x1f\x7f]{1,255})/"),
    re.compile(rb"/Volumes/([^/\x00-\x1f\x7f]{1,255})/"),
)
private_prefixes = (b"/Users/", b"/Volumes/")


def neutral_prefix(match):
    # `/opt/` is a non-account, non-volume build prefix. Fill the remaining
    # component deterministically while preserving every byte offset.
    token_length = len(match.group(0)) - len(b"/opt//")
    seed = b"forgeplay-sdk-"
    token = (seed * ((token_length + len(seed) - 1) // len(seed)))[:token_length]
    replacement = b"/opt/" + token + b"/"
    if len(replacement) != len(match.group(0)):
        raise SystemExit("GStreamer private build-path replacement changed length")
    return replacement


def stable_identity(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_uid,
    )


for current_root, directory_names, file_names in os.walk(root, followlinks=False):
    directory_names.sort()
    file_names.sort()
    for name in directory_names:
        path = os.path.join(current_root, name)
        metadata = os.lstat(path)
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise SystemExit("GStreamer build-path sanitization encountered an unsafe directory")
    for name in file_names:
        path = os.path.join(current_root, name)
        descriptor = os.open(
            path,
            os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK,
        )
        try:
            before = os.fstat(descriptor)
            if (
                not stat.S_ISREG(before.st_mode)
                or before.st_nlink != 1
                or before.st_uid != os.geteuid()
                or before.st_size < 0
                or before.st_size > maximum_file_bytes
            ):
                raise SystemExit("GStreamer build-path sanitization encountered an unsafe file")
            data = bytearray()
            offset = 0
            while offset < before.st_size:
                chunk = os.pread(descriptor, min(1024 * 1024, before.st_size - offset), offset)
                if not chunk:
                    raise SystemExit("GStreamer file became incomplete during build-path sanitization")
                data.extend(chunk)
                offset += len(chunk)
            original = bytes(data)
            if not any(prefix in original for prefix in private_prefixes):
                continue
            if len(original) < 4 or struct.unpack_from("<I", original, 0)[0] != mh_magic_64:
                raise SystemExit("private GStreamer build path occurs outside a supported Mach-O payload")
            sanitized = original
            for pattern in patterns:
                sanitized = pattern.sub(neutral_prefix, sanitized)
            if len(sanitized) != len(original) or any(
                prefix in sanitized for prefix in private_prefixes
            ):
                raise SystemExit("GStreamer private build path was not sanitized completely")
            offset = 0
            while offset < len(sanitized):
                written = os.pwrite(descriptor, sanitized[offset:offset + 1024 * 1024], offset)
                if written <= 0:
                    raise SystemExit("GStreamer build-path sanitization write made no progress")
                offset += written
            os.fsync(descriptor)
            after = os.fstat(descriptor)
            if stable_identity(before) != stable_identity(after):
                raise SystemExit("GStreamer file identity changed during build-path sanitization")
        finally:
            os.close(descriptor)
PY
    fail "staged GStreamer private build paths could not be sanitized safely"
}

adhoc_sign_wine_macho_files() {
  local phase="$1"
  while IFS= read -r -d '' macho; do
    is_macho "$macho" || continue
    /bin/chmod u+w "$macho"
    local output
    if ! output="$(/usr/bin/codesign --force --sign - --timestamp=none "$macho" 2>&1)"; then
      fail "unable to ad-hoc sign Mach-O during $phase: $macho: $output"
    fi
    /usr/bin/codesign --verify --strict "$macho" >/dev/null 2>&1 ||
      fail "Mach-O signature verification failed during $phase: $macho"
  done < <(/usr/bin/find "$STAGING/wine" -type f -print0)
}

rewrite_macho_references() {
  while IFS= read -r -d '' macho; do
    is_macho "$macho" || continue
    /bin/chmod u+w "$macho"
    if [[ "$macho" == "$STAGING"/wine/lib/*.dylib ]]; then
      local output
      if ! output="$(/usr/bin/install_name_tool -id "@rpath/$(/usr/bin/basename "$macho")" "$macho" 2>&1)"; then
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
      if ! output="$(/usr/bin/install_name_tool -change "$dependency" "@rpath/$(/usr/bin/basename "$dependency")" "$macho" 2>&1)"; then
        fail "unable to rewrite Mach-O dependency $dependency for $macho: $output"
      fi
    done < <(/usr/bin/otool -L "$macho" 2>/dev/null | /usr/bin/awk 'NR > 1 { print $1 }')
  done < <(/usr/bin/find "$STAGING/wine" -type f -print0)
}

normalize_runtime_support_macho_references() {
  local support_root="$STAGING/Frameworks"
  [[ -d "$support_root" ]] || fail "runtime support Frameworks are missing: $support_root"

  while IFS= read -r -d '' macho; do
    is_macho "$macho" || continue
    /bin/chmod u+w "$macho"

    local install_name
    install_name="$(/usr/bin/otool -D "$macho" 2>/dev/null | /usr/bin/sed -n '2p' | /usr/bin/tr -d '[:space:]')"
    case "$install_name" in
      /usr/local/*|/opt/*|/Users/*|/Volumes/*)
        local output
        if ! output="$(/usr/bin/install_name_tool -id "@rpath/$(/usr/bin/basename "$install_name")" "$macho" 2>&1)"; then
          fail "unable to rewrite runtime support install name for $macho: $output"
        fi
        ;;
    esac

    while IFS= read -r dependency; do
      case "$dependency" in
        /usr/local/*|/opt/*|/Users/*|/Volumes/*)
          local output
          if ! output="$(/usr/bin/install_name_tool -change "$dependency" "@rpath/$(/usr/bin/basename "$dependency")" "$macho" 2>&1)"; then
            fail "unable to rewrite runtime support dependency $dependency for $macho: $output"
          fi
          ;;
      esac
    done < <(/usr/bin/otool -L "$macho" 2>/dev/null | /usr/bin/awk 'NR > 1 { print $1 }')

    while IFS= read -r rpath; do
      case "$rpath" in
        /usr/local/*|/opt/*|/Users/*|/Volumes/*)
          local output
          if ! output="$(/usr/bin/install_name_tool -delete_rpath "$rpath" "$macho" 2>&1)"; then
            fail "unable to remove runtime support LC_RPATH $rpath from $macho: $output"
          fi
          ;;
      esac
    done < <(
      /usr/bin/otool -l "$macho" 2>/dev/null |
        /usr/bin/awk '/cmd LC_RPATH/{seen=1; next} seen && /path /{print $2; seen=0}' |
        /usr/bin/sort -u
    )

    local sign_output
    if ! sign_output="$(/usr/bin/codesign --force --sign - --timestamp=none "$macho" 2>&1)"; then
      fail "unable to ad-hoc sign normalized runtime support Mach-O $macho: $sign_output"
    fi
    /usr/bin/codesign --verify --strict "$macho" >/dev/null 2>&1 ||
      fail "normalized runtime support Mach-O signature verification failed: $macho"
  done < <(/usr/bin/find "$support_root" -maxdepth 1 -type f -print0)
}

install_wine_loader_entrypoint() {
  local source="$STAGING/wine/lib/wine/x86_64-unix/wine"
  local target="$STAGING/wine/bin/wine"
  [[ -x "$source" ]] || fail "Wine x86_64 loader is missing: $source"

  /bin/cp -f "$source" "$target"
  /bin/chmod 755 "$target"
}

install_runtime_entrypoints() {
  local launcher
  for launcher in wine wineserver; do
    local launcher_path="$STAGING/wine/bin/$launcher"
    local binary_path="$launcher_path.bin"
    [[ -x "$launcher_path" ]] || fail "runtime launcher is missing before entrypoint install: $launcher_path"
    if [[ ! -f "$binary_path" ]]; then
      /bin/mv "$launcher_path" "$binary_path"
    fi
    /bin/chmod 755 "$binary_path"
    /bin/cat > "$launcher_path" <<'ENTRYPOINT'
#!/bin/sh
set -eu
case "$0" in
  /*) LAUNCHER_PATH="$0" ;;
  */*) LAUNCHER_PATH="$(/bin/pwd -P)/$0" ;;
  *) LAUNCHER_PATH="$(/bin/pwd -P)/$0" ;;
esac
BIN_DIR_INPUT=${LAUNCHER_PATH%/*}
LAUNCHER_NAME=${LAUNCHER_PATH##*/}
bound_runtime_root_unavailable() {
  /bin/echo "ForgePlay Runtime bound-root capability is unavailable" >&2
  exit 78
}
revalidate_bound_runtime_root() {
  if [ ! -d "/dev/fd/$FORGEPLAY_BOUND_RUNTIME_ROOT_FD" ] ||
     [ ! -d "$RUNTIME_ROOT" ] || [ -L "$RUNTIME_ROOT" ]; then
    bound_runtime_root_unavailable
  fi
  if ! BOUND_RUNTIME_ROOT_INODE="$(/usr/bin/stat -f '%i' "/dev/fd/$FORGEPLAY_BOUND_RUNTIME_ROOT_FD")"; then
    bound_runtime_root_unavailable
  fi
  if ! RUNTIME_ROOT_IDENTITY="$(/usr/bin/stat -f '%d:%i' "$RUNTIME_ROOT")"; then
    bound_runtime_root_unavailable
  fi
  EXPECTED_RUNTIME_ROOT_INODE=${FORGEPLAY_BOUND_RUNTIME_ROOT_IDENTITY##*:}
  if [ "$BOUND_RUNTIME_ROOT_INODE" != "$EXPECTED_RUNTIME_ROOT_INODE" ] ||
     [ "$RUNTIME_ROOT_IDENTITY" != "$FORGEPLAY_BOUND_RUNTIME_ROOT_IDENTITY" ]; then
    bound_runtime_root_unavailable
  fi
}
if [ -n "${FORGEPLAY_BOUND_RUNTIME_ROOT_FD:-}" ]; then
  case "$FORGEPLAY_BOUND_RUNTIME_ROOT_FD" in
    *[!0-9]*|'')
      /bin/echo "ForgePlay Runtime bound-root descriptor is invalid" >&2
      exit 78
      ;;
  esac
  if [ "$FORGEPLAY_BOUND_RUNTIME_ROOT_FD" -lt 200 ] ||
     [ "$FORGEPLAY_BOUND_RUNTIME_ROOT_FD" -gt 4096 ] ||
     [ ! -d "/dev/fd/$FORGEPLAY_BOUND_RUNTIME_ROOT_FD" ]; then
    bound_runtime_root_unavailable
  fi
  case "${FORGEPLAY_BOUND_RUNTIME_ROOT_IDENTITY:-}" in
    ''|:*|*:|*:*:*|*[!0-9:]*) bound_runtime_root_unavailable ;;
  esac
  case "${FORGEPLAY_BOUND_RUNTIME_ROOT_PATH:-}" in
    /*) RUNTIME_ROOT="$FORGEPLAY_BOUND_RUNTIME_ROOT_PATH" ;;
    *) bound_runtime_root_unavailable ;;
  esac
  revalidate_bound_runtime_root
  # macOS exposes an inherited directory descriptor as a non-traversable
  # devfs node. Keep it as the identity anchor and consume the F_GETPATH
  # projection only after matching the descriptor inode and full path identity.
  WINE_ROOT="$RUNTIME_ROOT/wine"
  BIN_DIR="$WINE_ROOT/bin"
else
  BIN_DIR="$(CDPATH= cd -- "$BIN_DIR_INPUT" && /bin/pwd -P)"
  WINE_ROOT="$(CDPATH= cd -- "$BIN_DIR/.." && /bin/pwd -P)"
  RUNTIME_ROOT="$(CDPATH= cd -- "$WINE_ROOT/.." && /bin/pwd -P)"
fi
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
GSTREAMER_ROOT="$WINE_ROOT/gstreamer"
if [ -e "$GSTREAMER_ROOT" ] || [ -L "$GSTREAMER_ROOT" ]; then
  if [ ! -d "$GSTREAMER_ROOT" ] || [ -L "$GSTREAMER_ROOT" ] ||
     [ ! -d "$GSTREAMER_LIB" ] || [ -L "$GSTREAMER_LIB" ] ||
     [ ! -d "$GSTREAMER_PLUGINS" ] || [ -L "$GSTREAMER_PLUGINS" ]; then
    /bin/echo "ForgePlay Runtime GStreamer containment check failed" >&2
    exit 78
  fi
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
if [ "$LAUNCHER_NAME" = "wine" ]; then
  if [ ! -f "$WINE_ROOT/lib/wine/x86_64-unix/wine" ] ||
     [ -L "$WINE_ROOT/lib/wine/x86_64-unix/wine" ] ||
     [ ! -x "$WINE_ROOT/lib/wine/x86_64-unix/wine" ]; then
    /bin/echo "ForgePlay Runtime Wine loader identity is unavailable" >&2
    exit 78
  fi
  if [ -n "${FORGEPLAY_BOUND_RUNTIME_ROOT_FD:-}" ]; then
    revalidate_bound_runtime_root
  fi
  exec "$WINE_ROOT/lib/wine/x86_64-unix/wine" "$@"
fi
if [ ! -f "$BIN_DIR/$LAUNCHER_NAME.bin" ] ||
   [ -L "$BIN_DIR/$LAUNCHER_NAME.bin" ] ||
   [ ! -x "$BIN_DIR/$LAUNCHER_NAME.bin" ]; then
  /bin/echo "ForgePlay Runtime entrypoint identity is unavailable" >&2
  exit 78
fi
if [ -n "${FORGEPLAY_BOUND_RUNTIME_ROOT_FD:-}" ]; then
  revalidate_bound_runtime_root
fi
exec "$BIN_DIR/$LAUNCHER_NAME.bin" "$@"
ENTRYPOINT
    /bin/chmod 755 "$launcher_path"
  done
}

require_exact_staged_d3dmetal_framework_alias() {
  local path="$1"
  local expected_target="$2"
  local expected_path="$3"
  local label="$4"
  local actual_target

  [[ -L "$path" ]] || fail "$label must be a symbolic link: $path"
  actual_target="$(/usr/bin/readlink "$path")" ||
    fail "$label target could not be read: $path"
  [[ "$actual_target" == "$expected_target" ]] ||
    fail "$label has an incorrect target: $path -> $actual_target"
  [[ "$path" -ef "$expected_path" ]] ||
    fail "$label does not resolve to the canonical D3DMetal framework payload: $path"
}

materialize_d3dmetal_framework_aliases() {
  local framework="$STAGING/Frameworks/renderer/d3dmetal/external/D3DMetal.framework"
  local versions="$framework/Versions"
  local canonical_version="$versions/A"
  local canonical_executable="$canonical_version/D3DMetal"
  local canonical_resources="$canonical_version/Resources"
  local current_version="$versions/Current"
  local alias_executable="$framework/D3DMetal"
  local alias_resources="$framework/Resources"

  [[ -d "$framework" && ! -L "$framework" ]] ||
    fail "staged D3DMetal framework is missing or unsafe: $framework"
  [[ -d "$versions" && ! -L "$versions" ]] ||
    fail "staged D3DMetal Versions directory is missing or unsafe: $versions"
  [[ -d "$canonical_version" && ! -L "$canonical_version" ]] ||
    fail "staged D3DMetal canonical version is missing or unsafe: $canonical_version"
  require_staged_renderer_file \
    "$canonical_executable" \
    "staged D3DMetal canonical executable"
  [[ -x "$canonical_executable" ]] ||
    fail "staged D3DMetal canonical executable is not executable: $canonical_executable"
  [[ -d "$canonical_resources" && ! -L "$canonical_resources" ]] ||
    fail "staged D3DMetal canonical Resources are missing or unsafe: $canonical_resources"

  if [[ -L "$alias_executable" || -L "$alias_resources" || -L "$current_version" ]]; then
    require_exact_staged_d3dmetal_framework_alias \
      "$current_version" \
      "A" \
      "$canonical_version" \
      "D3DMetal current-version alias"
    require_exact_staged_d3dmetal_framework_alias \
      "$alias_executable" \
      "Versions/Current/D3DMetal" \
      "$canonical_executable" \
      "D3DMetal executable alias"
    require_exact_staged_d3dmetal_framework_alias \
      "$alias_resources" \
      "Versions/Current/Resources" \
      "$canonical_resources" \
      "D3DMetal Resources alias"

    # The unsigned Runtime uses the established portable layout: the public
    # aliases are exact materialized copies and Versions/Current is absent.
    # Developer ID signing later restores Apple's canonical three-link graph.
    /bin/rm -f "$alias_executable" "$alias_resources" "$current_version"
    /bin/cp -p "$canonical_executable" "$alias_executable"
    /bin/mkdir -m 755 "$alias_resources"
    /usr/bin/ditto "$canonical_resources" "$alias_resources"
  fi

  [[ ! -e "$current_version" && ! -L "$current_version" ]] ||
    fail "materialized D3DMetal framework must not contain Versions/Current: $current_version"
  require_staged_renderer_file \
    "$alias_executable" \
    "materialized D3DMetal executable alias"
  [[ -x "$alias_executable" ]] ||
    fail "materialized D3DMetal executable alias is not executable: $alias_executable"
  [[ -d "$alias_resources" && ! -L "$alias_resources" ]] ||
    fail "materialized D3DMetal Resources alias is missing or unsafe: $alias_resources"
  /usr/bin/cmp -s "$alias_executable" "$canonical_executable" ||
    fail "materialized D3DMetal executable alias does not match Versions/A"
  /usr/bin/diff -qr "$alias_resources" "$canonical_resources" >/dev/null ||
    fail "materialized D3DMetal Resources alias does not match Versions/A"
}

materialize_symlinks() {
  while IFS= read -r -d '' link_path; do
    if is_staged_d3dmetal_shared_unix_module_link_path "$link_path"; then
      local module_name
      module_name="$(/usr/bin/basename "$link_path" .so)"
      require_staged_d3dmetal_shared_unix_module_link \
        "$STAGING/Frameworks/renderer/d3dmetal" \
        "$module_name"
      continue
    fi

    local link_target
    link_target="$(/usr/bin/readlink "$link_path")"
    [[ -n "$link_target" ]] || fail "unable to read symlink target: $link_path"

    local resolved_target canonical_target
    if [[ "$link_target" == /* ]]; then
      resolved_target="$link_target"
    else
      resolved_target="$(/usr/bin/dirname "$link_path")/$link_target"
    fi
    canonical_target="$(/usr/bin/python3 - "$resolved_target" "${RUNTIME_SYMLINK_SOURCE_ROOTS[@]}" <<'PY'
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
      /bin/rm -f "$link_path"
      /bin/mkdir -p "$link_path"
      /usr/bin/ditto "$canonical_target" "$link_path"
    elif [[ -f "$canonical_target" && ! -L "$canonical_target" ]]; then
      /bin/rm -f "$link_path"
      /bin/cp -f "$canonical_target" "$link_path"
      /bin/chmod u+w "$link_path"
    else
      fail "staged symlink target is missing: $link_path -> $link_target"
    fi
  done < <(/usr/bin/find "$STAGING" -type l -print0)
}

[[ -d "$STAGING" && ! -L "$STAGING" ]] || fail "runtime staging path is unavailable: $STAGING"
[[ "$(directory_identity "$STAGING")" == "$STAGING_ID" ]] ||
  fail "runtime staging identity changed before materialization"
revalidate_bound_install_inputs
/usr/bin/ditto "$INSTALL_ROOT" "$STAGING/wine"
revalidate_bound_install_inputs

prune_development_only_wine_payload
/usr/bin/find "$STAGING/wine" -type f \( -name '*.a' -o -name '*.la' \) -delete
/bin/rm -rf "$STAGING/wine/include" "$STAGING/wine/share/man" "$STAGING/wine/lib/pkgconfig"
copy_runtime_policy_and_legal_payload
copy_font_compatibility_payload
copy_steam_compat_payload
materialize_locked_renderer_payload
materialize_d3dmetal_nvapi_aliases
normalize_d3dmetal_shared_unix_module_links
materialize_d3dmetal_framework_aliases
materialize_symlinks
install_wine_loader_entrypoint
verify_locked_renderer_payload
require_source_file "$D3DMETAL_NGX_BRIDGE_VALIDATOR" "D3DMetal NGX bridge validator"
/bin/bash "$D3DMETAL_NGX_BRIDGE_VALIDATOR" \
  "$STAGING/Frameworks/renderer/d3dmetal"
verify_staged_winebus_iohid_backend
verify_staged_forced_font_replacements
verify_wine_kernelbase_process_policy "$STAGING/wine" "staged Wine Runtime"
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
/usr/bin/find "$STAGING/wine/lib" -maxdepth 1 -type f -name '*.dylib' -delete
/usr/bin/python3 "$RUNTIME_DEPENDENCY_MATERIALIZER" \
  "$RUNTIME_DEPENDENCY_LOCK" \
  "$HOMEBREW_X86_PREFIX" \
  "$STAGING"
for ((gstreamer_index = 0; gstreamer_index < ${#GSTREAMER_SDK_BOUND_DIRECTORIES[@]}; gstreamer_index++)); do
  [[ "$(directory_identity "${GSTREAMER_SDK_BOUND_DIRECTORIES[$gstreamer_index]}")" == "${GSTREAMER_SDK_BOUND_IDENTITIES[$gstreamer_index]}" ]] ||
    fail "GStreamer SDK intermediate changed before materialization"
done
gstreamer_file_manifest \
  verify \
  "$GSTREAMER_SDK_ROOT" \
  "$GSTREAMER_SDK_FILE_MANIFEST" ||
  fail "GStreamer SDK files changed before materialization"
/usr/bin/python3 "$GSTREAMER_PAYLOAD_MATERIALIZER" \
  "$GSTREAMER_PAYLOAD_LOCK" \
  "$GSTREAMER_SDK_ROOT" \
  "$STAGING"
for ((gstreamer_index = 0; gstreamer_index < ${#GSTREAMER_SDK_BOUND_DIRECTORIES[@]}; gstreamer_index++)); do
  [[ "$(directory_identity "${GSTREAMER_SDK_BOUND_DIRECTORIES[$gstreamer_index]}")" == "${GSTREAMER_SDK_BOUND_IDENTITIES[$gstreamer_index]}" ]] ||
    fail "GStreamer SDK intermediate changed during materialization"
done
gstreamer_file_manifest \
  verify \
  "$GSTREAMER_SDK_ROOT" \
  "$GSTREAMER_SDK_FILE_MANIFEST" ||
  fail "GStreamer SDK files changed during materialization"
STAGED_GSTREAMER_DIRECTORIES=(
  "$STAGING/wine/gstreamer"
  "$STAGING/wine/gstreamer/lib"
  "$STAGING/wine/gstreamer/lib/gstreamer-1.0"
)
STAGED_GSTREAMER_IDENTITIES=()
for gstreamer_directory in "${STAGED_GSTREAMER_DIRECTORIES[@]}"; do
  [[ -d "$gstreamer_directory" && ! -L "$gstreamer_directory" ]] ||
    fail "staged GStreamer intermediate must be a non-symlink directory: $gstreamer_directory"
  STAGED_GSTREAMER_IDENTITIES+=("$(directory_identity "$gstreamer_directory")")
done
validate_gstreamer_directory_symlink_descendants "$STAGING/wine/gstreamer" ||
  fail "staged GStreamer payload contains an unsafe intermediate symlink"
normalize_winegstreamer_runtime_search_path
STAGED_GSTREAMER_PRE_TRANSFORM_MANIFEST="$PATCH_PROJECTION_WORKSPACE/staged-gstreamer-files.pre-transform.json"
STAGED_GSTREAMER_POST_TRANSFORM_MANIFEST="$PATCH_PROJECTION_WORKSPACE/staged-gstreamer-files.post-transform.json"
gstreamer_file_manifest \
  capture \
  "$STAGING/wine/gstreamer" \
  "$STAGED_GSTREAMER_PRE_TRANSFORM_MANIFEST" ||
  fail "staged pre-transform GStreamer file identities could not be captured"

sanitize_gstreamer_private_build_paths
adhoc_sign_wine_macho_files "pre-rewrite code-signature reservation"
rewrite_macho_references
adhoc_sign_wine_macho_files "post-rewrite validation"
normalize_runtime_support_macho_references
install_runtime_entrypoints
/usr/bin/python3 "$MACHO_RUNTIME_CLOSURE_VERIFIER" "$STAGING/wine" ||
  fail "locked Wine Mach-O dependency closure is incomplete"
/usr/bin/xattr -dr com.apple.quarantine "$STAGING" 2>/dev/null || true
gstreamer_file_manifest \
  transition \
  "$STAGING/wine/gstreamer" \
  "$STAGED_GSTREAMER_PRE_TRANSFORM_MANIFEST" \
  "$STAGED_GSTREAMER_POST_TRANSFORM_MANIFEST" ||
  fail "staged GStreamer transformation violated the payload transition contract"

/bin/mkdir -p "$STAGING/Legal/Wine"
/bin/cp -f "$WINE_SOURCE_ROOT/LICENSE" "$STAGING/Legal/Wine/LICENSE"
/bin/cp -f "$WINE_SOURCE_ROOT/COPYING.LIB" "$STAGING/Legal/Wine/COPYING.LIB"
/bin/cp -f "$WINE_SOURCE_ROOT/AUTHORS" "$STAGING/Legal/Wine/AUTHORS"
copy_wine_patch_files
/bin/mkdir -p "$STAGING/Sources"
/bin/cp -f \
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
  wine-11.12-executable-scoped-process-observation.patch \
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
  wine-11.12-steam-game-cef-browser-process-policy.patch \
  wine-11.12-steam-session-compatibility-controls.patch \
  wine-11.12-helldivers2-process-policy.patch \
  wine-11.12-heap-zero-memory.patch \
  wine-11.12-media-foundation-video-output-negotiation.patch; do
  if [[ -f "$STAGING/Patches/$patch_name" ]]; then
    WINE_PATCH_METADATA+=$'\n  - `Patches/'"$patch_name"'`'
  fi
done
WINE_PATCH_METADATA+=$'\n- Wine patch license sidecars:'
for patch_sidecar in "${RUNTIME_PATCH_LICENSE_SIDECARS[@]}"; do
  WINE_PATCH_METADATA+=$'\n  - `Patches/'"$patch_sidecar"'`'
done
WINE_PATCH_SET_SHA256="$(source_tree_sha256 "$STAGING/Patches")" ||
  fail "ForgePlay Wine patch-set fingerprint could not be computed"
[[ "$WINE_PATCH_SET_SHA256" =~ ^[0-9a-f]{64}$ ]] ||
  fail "ForgePlay Wine patch-set fingerprint is invalid"
[[ "$WINE_PATCH_SET_SHA256" == "$EXPECTED_WINE_PATCH_SET_SHA256" ]] ||
  fail "ForgePlay Wine patch set changed without updating its canonical fingerprint and source notice"
copy_wine_patch_license_sidecars

RUNTIME_LAUNCHER_SHA256="$(/usr/bin/shasum -a 256 "$STAGING/wine/bin/wine" | /usr/bin/awk '{print $1}')"
WINE_INF_SHA256="$(/usr/bin/shasum -a 256 "$STAGING/wine/share/wine/wine.inf" | /usr/bin/awk '{print $1}')"
WINEBOOT_SHA256="$(/usr/bin/shasum -a 256 "$STAGING/wine/lib/wine/x86_64-windows/wineboot.exe" | /usr/bin/awk '{print $1}')"
PREFIX_COMPATIBILITY_FINGERPRINT="$({
  printf 'forgeplay-prefix-compatibility-v1\n'
  printf 'wineVersion=11.12\n'
  printf 'architecture=win64\n'
  printf 'wineInfSHA256=%s\n' "$WINE_INF_SHA256"
  printf 'winebootSHA256=%s\n' "$WINEBOOT_SHA256"
} | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
PROVISIONAL_RUNNER_BUILD_FINGERPRINT="$({
  printf 'forgeplay-runtime-build-v1\n'
  printf 'sourceTreeSHA256=%s\n' "$WINE_SOURCE_TREE_SHA256"
  printf 'patchSetSHA256=%s\n' "$WINE_PATCH_SET_SHA256"
  printf 'runnerLauncherSHA256=%s\n' "$RUNTIME_LAUNCHER_SHA256"
  printf 'prefixCompatibilityFingerprint=%s\n' "$PREFIX_COMPATIBILITY_FINGERPRINT"
} | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"

/usr/bin/python3 - \
  "$STAGING/RuntimeManifest.json" \
  "$WINE_SOURCE_TREE_SHA256" \
  "$WINE_PATCH_SET_SHA256" \
  "$RUNTIME_LAUNCHER_SHA256" \
  "$WINE_INF_SHA256" \
  "$WINEBOOT_SHA256" \
  "$PREFIX_COMPATIBILITY_FINGERPRINT" \
  "$PROVISIONAL_RUNNER_BUILD_FINGERPRINT" \
  "$RUNTIME_MANIFEST_TEMPLATE" <<'PY'
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
    manifest_template,
) = sys.argv[1:]
manifest = {
    "architecture": "win64",
    "patchApplicationOrder": json.loads(Path(manifest_template).read_text(encoding="utf-8"))["patchApplicationOrder"],
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

gstreamer_file_manifest \
  verify \
  "$STAGING/wine/gstreamer" \
  "$STAGED_GSTREAMER_POST_TRANSFORM_MANIFEST" ||
  fail "staged GStreamer files changed before SBOM generation"
/usr/bin/python3 "$RUNTIME_SBOM_TOOL" generate \
  "$STAGING" \
  "$RUNTIME_DEPENDENCY_LOCK" \
  "$RENDERER_PAYLOAD_LOCK" \
  "$GSTREAMER_PAYLOAD_LOCK" \
  "$STAGING/RuntimeSBOM.json"
/usr/bin/python3 - \
  "$STAGED_GSTREAMER_POST_TRANSFORM_MANIFEST" \
  "$STAGING/RuntimeSBOM.json" <<'PY' ||
import json
import re
import sys

ledger_path, sbom_path = sys.argv[1:]
with open(ledger_path, "r", encoding="utf-8") as handle:
    ledger = json.load(handle)
with open(sbom_path, "r", encoding="utf-8") as handle:
    sbom = json.load(handle)
rows = ledger.get("entries")
entries = sbom.get("hostSupportPayload")
if (
    ledger.get("schemaVersion") != 2
    or sbom.get("schemaVersion") != 2
    or not isinstance(rows, list)
    or not isinstance(entries, list)
):
    raise SystemExit("GStreamer ledger or runtime SBOM is malformed")
consumed = {}
for row in rows:
    path = row.get("path") if isinstance(row, dict) else None
    if isinstance(path, str) and path.endswith(".dylib"):
        if row.get("kind") != "file" or re.fullmatch(r"[0-9a-f]{64}", row.get("sha256", "")) is None:
            raise SystemExit(f"runtime-loaded GStreamer payload is not an authenticated regular file: {path!r}")
        full_path = f"wine/gstreamer/{path}"
        if full_path in consumed:
            raise SystemExit(f"GStreamer ledger contains a duplicate runtime path: {full_path}")
        consumed[full_path] = row["sha256"]
sbom_entries = {}
for entry in entries:
    path = entry.get("path") if isinstance(entry, dict) else None
    if (
        isinstance(path, str)
        and path.startswith("wine/gstreamer/")
        and path.endswith(".dylib")
    ):
        if path in sbom_entries:
            raise SystemExit(f"runtime SBOM contains a duplicate GStreamer path: {path}")
        sbom_entries[path] = entry
if not consumed or set(consumed) != set(sbom_entries):
    raise SystemExit("runtime-loaded GStreamer files do not exactly match the SBOM")
unexpected_consumption_paths = sorted(
    entry.get("path")
    for entry in entries
    if isinstance(entry, dict)
    and (
        "consumptionHashAlgorithm" in entry
        or "consumptionSHA256" in entry
    )
    and entry.get("path") not in consumed
)
if unexpected_consumption_paths:
    raise SystemExit(
        "non-GStreamer SBOM entries carry consumption identities: "
        + ", ".join(repr(path) for path in unexpected_consumption_paths)
    )
for path in sorted(consumed):
    entry = sbom_entries[path]
    if entry.get("type") != "file" or re.fullmatch(r"[0-9a-f]{64}", entry.get("contentSHA256", "")) is None:
        raise SystemExit(f"GStreamer SBOM entry is not an authenticated file: {path}")
    if entry.get("consumptionHashAlgorithm") != "sha256-macho-signature-independent-v1":
        raise SystemExit(f"GStreamer SBOM entry has an unsupported consumption identity algorithm: {path}")
    consumption_sha256 = entry.get("consumptionSHA256")
    if re.fullmatch(r"[0-9a-f]{64}", consumption_sha256 or "") is None:
        raise SystemExit(f"GStreamer SBOM entry is missing its consumption identity: {path}")
PY
  fail "runtime GStreamer signature-independent identities could not be bound into the SBOM"
gstreamer_file_manifest \
  verify \
  "$STAGING/wine/gstreamer" \
  "$STAGED_GSTREAMER_POST_TRANSFORM_MANIFEST" ||
  fail "staged GStreamer files changed after SBOM generation"
HOST_SUPPORT_SBOM_SHA256="$(/usr/bin/shasum -a 256 "$STAGING/RuntimeSBOM.json" | /usr/bin/awk '{print $1}')"
HOST_SUPPORT_PAYLOAD_FINGERPRINT="$(/usr/bin/python3 - "$STAGING/RuntimeSBOM.json" <<'PY'
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
CORE_IDENTITY_JSON="$(/usr/bin/python3 "$RUNTIME_CORE_IDENTITY_TOOL" generate "$STAGING")" ||
  fail "runtime core payload identity could not be generated"
CORE_PAYLOAD_HASH_ALGORITHM="$(/usr/bin/python3 - "$CORE_IDENTITY_JSON" <<'PY'
import json
import sys

print(json.loads(sys.argv[1])["corePayloadHashAlgorithm"])
PY
)" || fail "runtime core payload hash algorithm could not be read"
CORE_PAYLOAD_JSON="$(/usr/bin/python3 - "$CORE_IDENTITY_JSON" <<'PY'
import json
import sys

print(json.dumps(json.loads(sys.argv[1])["corePayloadSHA256"], sort_keys=True, separators=(",", ":")))
PY
)" || fail "runtime core payload map could not be read"
CORE_PAYLOAD_FINGERPRINT="$(/usr/bin/python3 - "$CORE_IDENTITY_JSON" <<'PY'
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
} | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"

/usr/bin/python3 - \
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
  "$CORE_PAYLOAD_FINGERPRINT" \
  "$RUNTIME_MANIFEST_TEMPLATE" <<'PY'
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
    manifest_template,
) = sys.argv[1:]
manifest = {
    "architecture": "win64",
    "corePayloadFingerprint": core_payload_fingerprint,
    "corePayloadHashAlgorithm": core_payload_hash_algorithm,
    "corePayloadSHA256": json.loads(core_payload_json),
    "hostSupportPayloadFingerprint": payload_fingerprint,
    "hostSupportSBOMPath": "RuntimeSBOM.json",
    "hostSupportSBOMSHA256": sbom_sha256,
    "patchApplicationOrder": json.loads(Path(manifest_template).read_text(encoding="utf-8"))["patchApplicationOrder"],
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

if [[ "$MODE" == "public-source-package" ]]; then
  PUBLIC_SOURCE_AUTHORITY_METADATA="- Packaging source claim: public-source-release-export-v1
- Release attestation status: unsigned build claim awaiting release attestation
- Public source release commit: $PUBLIC_SOURCE_RELEASE_COMMIT
- Public source inventory SHA-256: $PUBLIC_SOURCE_INVENTORY_SHA256"
else
  PUBLIC_SOURCE_AUTHORITY_METADATA="- Packaging source authority: internal-reviewed-source-provenance-v1"
fi

/bin/cat > "$STAGING/BUILD-METADATA.md" <<'EOF'
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
$PUBLIC_SOURCE_AUTHORITY_METADATA
- Build input: validated `FORGEPLAY_WINE_SOURCE`; its local filesystem path is intentionally excluded
- Build-path hygiene: the canonical builder uses a logical `/forgeplay-runtime` prefix, staged `DESTDIR`, and compiler file-prefix mapping; `/Users/` and `/Volumes/` developer paths are rejected from the compiled Wine payload before packaging
- Wine payload policy: the canonical builder performs the complete upstream install so both i386/x86_64 `dmsynth.dll` and `icu.dll` plus all Wine 11.12 `wineboot.exe` language resources are retained; packaging then removes only the explicit development-tool denylist and rejects undeclared `wine/bin` entries
$WINE_PATCH_METADATA
- Runtime identity: deterministic \`RuntimeManifest.json\` records the Wine source, patch set, launcher, \`wine.inf\`, \`wineboot\`, routing-critical Wine modules, host-support SBOM, complete Runtime file inventory, build, and prefix-compatibility SHA-256 values. \`RuntimeFileInventory.json\` enumerates every non-claim path, type, executable bit, symlink target, and code-signature-normalized file-content hash; its three self-referential claim files are bound through the inventory-to-manifest-to-public-build-claim chain. The raw pre-sign tree is exact. Its \`signedReleasePathTransforms\` authority permits only \`apple-d3dmetal-framework-canonical-alias-v1\`, which replaces the reviewed flat D3DMetal aliases with Apple's exact three canonical framework symlinks while preserving the same \`Versions/A\` payload. Mach-O identities exclude only normalized code-signature metadata and the replaceable signature blob so packaging and final distribution signing verify the same executable payload. \`RuntimeSBOM.json\` records every bundled host-support file or approved internal symlink with its content hash, source, version, and license paths. Packaging time and filesystem mtimes are excluded.
- Wine attribution and modification licensing: source validation requires Wine's \`LICENSE\`, \`COPYING.LIB\`, and \`AUTHORS\` files, and packaging copies all three into \`Legal/Wine\`. The tracked \`Legal/Wine/FORGEPLAY-MODIFICATIONS.md\` records the exact 25-patch identity and the current LGPL/GPL boundary; the Game Mode legal directory carries both unmodified license texts and the exact conversion scope.
- App Sandbox IPC: Wine client and wineserver honor \`WINE_SERVER_ROOT\` and \`WINE_MACH_SERVICE_NAME\`; sandbox builds use the app container and App Group IPC namespace, peer processes reopen the held server lock without truncating it, and Wine unlinks temporary executable-mapping backing files before probing or sharing them.
- Wine synchronization: upstream Wine 11.12 standard wineserver synchronization path only; no out-of-tree synchronization backend is applied
- D3DMetal Wine contract: the project-owned \`forgeplay_d3dmetal.c\` bridge activates only for a Steam game child in a manually selected exact D3DMetal session, loads the explicitly bundled shared library, registers PE image ranges through the public non-native-code-region ABI, and preserves Wine 11.12's upstream Unix-call table. That D3DMetal route enables ForgePlay's scoped macOS/x86_64 native pthread context, synchronizes the mutable Windows static-TLS pointer through Darwin's Win64-reserved slot, uses reentrant Apple time conversion interfaces so libc cannot overwrite the adjacent mirrored PEB slot, and restores overwritten native slots before exit; other manually selected renderers keep upstream GS switching.
- Wine host dependencies: 15 locked x86_64 Wine host dependency artifacts provide the reviewed TLS, font, Vulkan loader, and MoltenVK closure under \`wine/lib\` and \`wine/etc/vulkan/icd.d\`; every source version and SHA-256 is verified before staging
- Media Foundation: Wine's \`winegstreamer\` Unix module is built against GStreamer 1.28.5. The exact locked x86_64 core, MP4, H.264/AAC parser and decoder, Apple VideoToolbox, conversion, and libav fallback closure is isolated under \`wine/gstreamer\`; developer account and volume build prefixes embedded by the official SDK are deterministically replaced in place with equal-length neutral prefixes inside the authenticated pre/post transformation ledger; system plug-ins are disabled and the installed app has no host GStreamer dependency
- Graphics: Vulkan loader and MoltenVK runtime included with bundled Vulkan ICD JSON
- ForgePlay Steam launcher: \`wine/lib/wine/x86_64-windows/forgeplay-steam-launcher.exe\`, built from the project-owned \`Sources/forgeplay_steam_launcher.c\`; it directly invokes Win32 \`CreateProcessW\` through ForgePlay's complete \`--detach -- <Windows command...>\` interface
- Executable-scoped compatibility seam: patched i386/x86_64 \`kernelbase.dll\` can append one bounded host-selected argument string only to the matching executable basename. The optional \`FORGEPLAY_PROCESS_ARGUMENT_ROOT_ONLY=1\` scope skips Chromium \`--type=\` subprocess arguments while a separately selected observation role still records every matching launch's Windows PID and final command line. The runtime hardcodes no Steam flag set and makes no claim that any particular combination fixes a current Steam build; updater-owned executables remain unchanged.
- Steam game renderer policy: before every Steam launch the caller must select exactly one of D3DMetal Standard, D3DMetal NVIDIA/DLSS Compatibility, DXMT, D9VK, or DXVK. Both D3DMetal choices use the same exact D3DMetal renderer; the experimental NVIDIA choice additionally reports vendor ID \`0x10de\` only to routed game descendants, exposes verified \`nvapi.dll\`/Unix-module aliases derived from the locked Apple payload, and initializes NVAPI before the game entry point. It does not spoof a device ID, force DirectX 11/12, or guarantee that a game will expose DLSS. Patched i386/x86_64 \`kernelbase.dll\` applies only the selected renderer to Steam game children for the session. Missing or invalid selection is rejected; Direct3D import classification, loader-stage profiles, and mixed renderer compositions are disabled. Patched Unix and Windows \`ntdll\` expose only the selected architecture-specific renderer root, Route V2 records the plan, and Load V3 counts as proof only for an allowlist-owned path with \`path-owner=verified\`.
- Steam session network presentation: the caller must explicitly select Standard, Wi-Fi Identity, or Ethernet Identity for every Steam launch. Patched \`nsi.dll\` changes only the reported media/type fields of active non-loopback game adapters for the two compatibility identities; it does not convert TCP to UDP, UDP to TCP, alter addresses, or change the host transport.
- Steam session audio input: the caller must explicitly select input disabled or enabled for every Steam launch. Patched \`winecoreaudio.drv\` returns a successful empty capture-endpoint set before CoreAudio access when disabled, while render endpoints and audio output remain unchanged; enabled preserves the upstream capture path.
- Steam game CEF browser policy: the explicit host gate \`FORGEPLAY_STEAM_GAME_CEF_BROWSER_POLICY_ENABLED=1\` adds \`--in-process-gpu\` only to a root PE under a structural \`steamapps/common\` game path when that executable contains the generic \`libcef.dll\` runtime marker. Existing CEF \`--type=\` subprocesses, non-CEF executables, Steam infrastructure, and already-correct command lines are unchanged.
- Game Mode process-host routing: this experimental path is off by default, so ordinary Steam sessions use the standard Wine loader. When explicitly requested, a Unix-only target identity is derived independently for each child from Wine's resolved `ImagePathName`, not a mutable command line or inherited Windows variable. Every resolved executable in a structural `steamapps/common` game tree may enter the same fixed bundled ForgePlay host before PE mapping, including a long-lived game child started by a launcher; `_CommonRedist` and targets outside that tree use the standard Wine loader. Each accepted target with a rejected contract or failed host exec is logged and fails instead of silently continuing without the requested Game Mode host. Routed processes retain the fixed host process identity and icon rather than a game-derived name or PE icon.
- External-storage grants: the Unix \`ntdll\` loader and \`wineserver\` explicitly activate the project-owned grant bridge before Wine initialization. All-absent grant environment values are a normal no-op. When an external grant is requested, a partial or rejected grant emits a path-free failure record and stops Wine before Windows Steam can start. Successful activation emits a path-free \`FORGEPLAY_EXTERNAL_STORAGE_GRANT_V1\` record from each process.
- Managed Darwin process lifecycle: every launch-scoped Wine loader and wineserver appends its Darwin PID and kernel process-start time to an owner-private, bounded, path-free journal. ForgePlay accepts a record only for the matching run UUID, prefix scope, runtime fingerprint, exact bundled executable path, and unchanged process-start identity before termination; wineserver exit alone is not treated as proof that all game processes stopped. Wineserver additionally binds the launching ForgePlay PID and kernel start time and terminates itself when that exact owner exits, including force-quit and crash paths.
- DXMT macOS window bridge: patched \`winemac.so\` exports the 192-byte \`macdrv_functions\` ABI expected by DXMT and maps Wine 11.12 client/content views to Metal-backed DXGI window swapchains
- Steam SDL compatibility payload: versioned \`SteamCompat/sdl2-compat\` binaries and license material are copied from the ForgePlay runtime source tree
- Windows Korean font compatibility: exact Nanum Gothic Regular/Bold payloads are bundled under \`wine/share/wine/fonts\`; Wine GDI and DirectWrite expose an opt-in forced-family replacement for installed or private Tahoma faces; the SIL Open Font License text and exact upstream source identity are bundled under \`Legal/NanumGothic/\`
- Host support payload: runtime policy and legal resources are copied independently; arbitrary top-level \`Frameworks\` dylibs and checked-in runtime output as a Frameworks packaging input are prohibited
- Renderer payload: the four locked Apple GPTK/D3DMetal, D9VK, DXMT, and DXVK component trees are verified from the explicit build-time \`FORGEPLAY_RENDERER_SOURCE\`, then bundled under \`Frameworks/renderer\`; the installed app has no external runtime dependency. ForgePlay derives only the exact \`nvapi.dll\` filename copy and \`nvapi.so\` internal link after upstream-tree verification, validates both independently, and identifies them as derived aliases in \`RuntimeSBOM.json\`.
- Packaging: the seven D3DMetal Unix module names are exact internal links to one bundled `external/libd3dshared.dylib`; all other symlinks and every hardlink are rejected
- Packaged at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')

Configure summary:

\`\`\`
--prefix=/forgeplay-runtime (installed through a staged DESTDIR)
--enable-win64
--enable-archs=i386,x86_64
--disable-tests
--with-vulkan
--without-x --without-alsa --without-capi --without-cups --without-dbus
--without-ffmpeg --without-gphoto --without-gssapi
--without-inotify --without-krb5 --without-netapi --without-opencl
--without-oss --without-pcap --without-pcsclite --without-pulse
--without-sane --without-sdl --without-udev --without-usb --without-v4l2
--without-wayland
host C/C++/Objective-C flags and PE CROSSCFLAGS map local roots to wine-11.12/source and wine-11.12/build
\`\`\`
EOF

/bin/cat > "$STAGING/SOURCE-AVAILABILITY.md" <<'EOF'
# ForgePlay Runtime Source Availability

This package contains a modified Wine 11.12 copy. Unmodified Wine material and
ForgePlay changes not expressly converted by the packaged Game Mode scope retain
their applicable GNU Lesser General Public License 2.1 or later permissions. The
two exact Game Mode Wine patch copies identified in
\`Legal/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md\` are designated for
conversion to GPL-3.0-only under LGPL 2.1 section 3, and the resulting combined
Wine copy must be conveyed consistently with that scope.
The corresponding source is available without relying on a developer machine path:

- Upstream Wine 11.12 source archive: $WINE_SOURCE_ARCHIVE_URL
- Upstream detached signature: $WINE_SOURCE_SIGNATURE_URL
- Upstream source archive SHA-256: `$WINE_SOURCE_ARCHIVE_SHA256`
- Wine release-key fingerprint: `$WINE_SOURCE_SIGNING_KEY_FINGERPRINT`
- ForgePlay modifications: the complete patch set shipped in this package under \`Patches/\`
- Independent renderer behavior contract: \`Patches/wine-11.12-forgeplay-d3dmetal-bridge-contract.md\`
- Validated corresponding source tree SHA-256: \`$WINE_SOURCE_TREE_SHA256\`
- Packaged ForgePlay patch-set SHA-256: \`$WINE_PATCH_SET_SHA256\`
$PUBLIC_SOURCE_AUTHORITY_METADATA

The upstream archive and the complete packaged patch set are the machine-readable materials used to
reconstruct the modified Wine source for this runtime. The local \`FORGEPLAY_WINE_SOURCE\` build input
is validated during packaging, but its filesystem path is never written into the app bundle.
Wine's \`LICENSE\`, \`COPYING.LIB\`, and \`AUTHORS\` files are validated from that source tree and
copied into \`Legal/Wine\`. \`Legal/Wine/FORGEPLAY-MODIFICATIONS.md\` records the
exact modification snapshot and license boundary. The unmodified GPLv3 and LGPL
2.1 texts plus the path-exact Game Mode conversion notices are copied into
\`Legal/ForgePlayGameMode\`.

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
  Patches/wine-11.12-executable-scoped-process-observation.patch \
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
  Patches/wine-11.12-steam-game-cef-browser-process-policy.patch \
  Patches/wine-11.12-steam-session-compatibility-controls.patch \
  Patches/wine-11.12-helldivers2-process-policy.patch \
  Patches/wine-11.12-heap-zero-memory.patch \
  Patches/wine-11.12-media-foundation-video-output-negotiation.patch; do
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

ForgePlay's executable-scoped compatibility patch leaves updater-owned executable files unchanged.
When the host supplies both a bounded argument target and bounded append string, Wine compares only
the resolved executable basename and appends that string to the matching child command line. Missing,
oversized, or mismatched controls leave the command line unchanged. When the optional
\`FORGEPLAY_PROCESS_ARGUMENT_ROOT_ONLY=1\` control is present, a standalone Chromium \`--type=\`
argument suppresses the append for that subprocess. The observation target is selected independently
and still covers each matching role; after successful creation Wine records only its Windows PID and
final command line after applicable argument processing in the host-created per-launch observation
file. The patch hardcodes no Steam argument set, does not serialize the process environment, and does
not claim that any particular host-selected combination fixes a current Steam build.

ForgePlay's Steam game CEF browser policy is activated by the host with
\`FORGEPLAY_STEAM_GAME_CEF_BROWSER_POLICY_ENABLED=1\` for a Steam session, then applies only to a
root executable in a separator-delimited \`steamapps/common\` tree that contains the generic
\`libcef.dll\` runtime marker. It appends one \`--in-process-gpu\` argument so the CEF browser process
does not depend on Wine's incompatible out-of-process GPU startup path. CEF \`--type=\` subprocesses,
non-CEF executables, Steam infrastructure roles, and command lines that already contain the argument
remain unchanged. The executable itself is never replaced or modified.

ForgePlay's Steam game renderer process patch leaves Steam and Steam WebHelper on the base Wine
renderer environment. Before every Steam launch the user must select exactly one of D3DMetal
Standard, D3DMetal NVIDIA/DLSS Compatibility, DXMT, D9VK, or DXVK. Both D3DMetal choices route the
same exact D3DMetal modules. The experimental NVIDIA choice additionally passes
\`D3DM_VENDOR_ID=0x10de\` only through the routed game environment, provides the exact verified
\`nvapi.dll\` and Unix-module aliases required by the bundled Apple NVAPI implementation, and invokes
\`NvAPI_Initialize\` before the game entry point. It does not change the reported device ID, force
DirectX 11 or DirectX 12, or claim that a game's DLSS path will work. That single renderer is applied
to Steam game children for the whole session.
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

ForgePlay's Steam session compatibility patch requires an explicit network-presentation selection
and audio-input selection for each launch. Standard network presentation preserves Wine's upstream
adapter metadata. Wi-Fi Identity and Ethernet Identity change only the reported NDIS type and media
fields for active, connected, non-loopback adapters in routed game descendants; socket stream and
datagram semantics, addresses, DNS, gateways, and macOS transport remain unchanged. Independently
of the selected presentation, Darwin `IP_RECVTOS` ancillary data is translated into the Windows
`IP_TOS` control-message contract returned by `WSARecvMsg`; payload and transport behavior remain
unchanged. Audio input
disabled returns a successful empty capture-endpoint set before CoreAudio input enumeration while
leaving render endpoints and output untouched. Audio input enabled follows Wine's upstream
CoreAudio capture path. These values are session-scoped and are not persisted as per-game rules.

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
and accept the manifest for external storage to become accessible. A rejected or incomplete required
grant emits a bounded, path-free failure reason and stops the Wine loader or wineserver before
Windows Steam can start. A launch without an external-storage request remains unchanged. Successful
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
misreported as a clean launch session. Wineserver also binds the launching ForgePlay process PID
and kernel start time before accepting the prefix. A detached kqueue monitor terminates wineserver
when that exact application owner exits, including force-quit and crash paths where AppKit cannot
run the normal termination delegate.

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
\`Legal/NanumGothic/OFL.txt\`, and the pinned Google Fonts commit plus exact file identities are in
\`Legal/NanumGothic/SOURCE-IDENTITY.json\`; packaging fails if any of these four files is missing or differs from
the reviewed SHA-256 digest. The opt-in \`HKCU\\Software\\Wine\\Fonts\\ForcedReplacements\`
contract is implemented in both Wine GDI and DirectWrite so an installed or game-private Tahoma
family cannot bypass the managed Korean family selected by ForgePlay.

ForgePlay's runtime policy plist and legal resources are copied separately from host binaries.
The packager never copies the checked-in runtime's \`Frameworks\` directory and rejects a renderer
source rooted in that output tree. The complete renderer payload is an explicit build-time input,
verified against \`Config/ForgePlayRendererPayload.lock.json\`, and becomes part of the self-contained
app runtime rather than an external runtime dependency. After that locked-tree verification,
packaging derives only a byte-identical \`nvapi.dll\` filename copy from \`nvapi64.dll\` and an exact
\`nvapi.so\` internal link to the same canonical D3DMetal shared library. Both aliases are independently
validated and recorded as ForgePlay-derived Apple-payload aliases in \`RuntimeSBOM.json\`.

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

PACKAGED_AT="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
/usr/bin/python3 - \
  "$STAGING/BUILD-METADATA.md" \
  "$STAGING/SOURCE-AVAILABILITY.md" \
  "$WINE_SOURCE_ARCHIVE_URL" \
  "$WINE_SOURCE_SIGNATURE_URL" \
  "$WINE_SOURCE_ARCHIVE_SHA256" \
  "$WINE_SOURCE_SIGNING_KEY_FINGERPRINT" \
  "$WINE_SOURCE_TREE_SHA256" \
  "$WINE_PATCH_SET_SHA256" \
  "$WINE_PATCH_METADATA" \
  "$PUBLIC_SOURCE_AUTHORITY_METADATA" \
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
    public_source_authority_metadata,
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
    "$PUBLIC_SOURCE_AUTHORITY_METADATA": public_source_authority_metadata,
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

require_source_file "$RUNTIME_FILE_INVENTORY_TOOL" "runtime complete file inventory tool"
/bin/bash "$RUNTIME_FILE_INVENTORY_TOOL" \
  --write-runtime-file-inventory \
  "$STAGING" \
  "$STAGING/RuntimeFileInventory.json" ||
  fail "complete Runtime file inventory could not be generated"
RUNTIME_FILE_INVENTORY_SHA256="$(
  /usr/bin/shasum -a 256 "$STAGING/RuntimeFileInventory.json" | /usr/bin/awk '{print $1}'
)" || fail "complete Runtime file inventory digest could not be computed"
RUNTIME_FILE_INVENTORY_FINGERPRINT="$(/usr/bin/python3 - "$STAGING/RuntimeFileInventory.json" <<'PY'
import json
import re
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
fingerprint = value.get("payloadFingerprint")
if re.fullmatch(r"[0-9a-f]{64}", fingerprint or "") is None:
    raise SystemExit("complete Runtime file inventory fingerprint is invalid")
print(fingerprint)
PY
)" || fail "complete Runtime file inventory fingerprint could not be read"
/usr/bin/python3 - \
  "$STAGING/RuntimeManifest.json" \
  "$RUNTIME_FILE_INVENTORY_SHA256" \
  "$RUNTIME_FILE_INVENTORY_FINGERPRINT" <<'PY' ||
import json
import re
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
inventory_sha256, inventory_fingerprint = sys.argv[2:]
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
required_schema_3 = {
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
if set(manifest) != required_schema_3 or manifest.get("schemaVersion") != 3:
    raise SystemExit("provisional Runtime manifest schema is invalid")
if any(re.fullmatch(r"[0-9a-f]{64}", value) is None for value in (
    inventory_sha256,
    inventory_fingerprint,
)):
    raise SystemExit("complete Runtime inventory binding is invalid")
manifest.update({
    "runtimeFileInventoryFingerprint": inventory_fingerprint,
    "runtimeFileInventoryHashAlgorithm": "sha256-macho-code-signature-normalized-v1",
    "runtimeFileInventoryPath": "RuntimeFileInventory.json",
    "runtimeFileInventorySHA256": inventory_sha256,
})
manifest_path.write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
  fail "complete Runtime file inventory could not be bound into the Runtime manifest"

if [[ "$MODE" == "public-source-package" ]]; then
  write_public_runtime_build_claim "$STAGING/RuntimeManifest.json" ||
    fail "unsigned public Runtime build claim could not bind the final Runtime manifest"
fi

unexpected_staged_symlink=""
while IFS= read -r -d '' staged_symlink; do
  if is_staged_d3dmetal_shared_unix_module_link_path "$staged_symlink"; then
    require_staged_d3dmetal_shared_unix_module_link \
      "$STAGING/Frameworks/renderer/d3dmetal" \
      "$(/usr/bin/basename "$staged_symlink" .so)"
    continue
  fi
  unexpected_staged_symlink="$staged_symlink"
  break
done < <(/usr/bin/find "$STAGING" -type l -print0)
if [[ -n "$unexpected_staged_symlink" ]]; then
  printf '%s\n' "$unexpected_staged_symlink" >&2
  fail "staged runtime contains an unapproved symlink"
fi

hardlinked_file="$(
  /usr/bin/find "$STAGING" -type f -exec /bin/sh -c '
    for path do
      links=$(/usr/bin/stat -f "%l" "$path" 2>/dev/null || printf 0)
      if [ "$links" != "1" ]; then
        printf "%s\n" "$path"
        exit 0
      fi
    done
  ' /bin/sh {} + | /usr/bin/head -1
)"
if [[ -n "$hardlinked_file" ]]; then
  printf '%s\n' "$hardlinked_file" >&2
  fail "staged runtime contains hardlinked files"
fi

[[ "$(directory_identity "$OUTPUT_PARENT")" == "$OUTPUT_PARENT_ID" ]] ||
  fail "output runtime parent changed before publication"
[[ "$(directory_identity "$STAGING")" == "$STAGING_ID" ]] ||
  fail "runtime staging identity changed before publication"
for ((gstreamer_index = 0; gstreamer_index < ${#STAGED_GSTREAMER_DIRECTORIES[@]}; gstreamer_index++)); do
  [[ "$(directory_identity "${STAGED_GSTREAMER_DIRECTORIES[$gstreamer_index]}")" == "${STAGED_GSTREAMER_IDENTITIES[$gstreamer_index]}" ]] ||
    fail "staged GStreamer intermediate changed before publication"
done
gstreamer_file_manifest \
  verify \
  "$STAGING/wine/gstreamer" \
  "$STAGED_GSTREAMER_POST_TRANSFORM_MANIFEST" ||
  fail "staged GStreamer file identity changed before publication"
/bin/bash "$RUNTIME_FILE_INVENTORY_TOOL" \
  --verify-runtime-file-inventory \
  "$STAGING" \
  "$STAGING/RuntimeFileInventory.json" ||
  fail "staged Runtime paths, types, or content differ from the complete file inventory"
[[ "$(/usr/bin/shasum -a 256 "$STAGING/RuntimeSBOM.json" | /usr/bin/awk '{print $1}')" == "$HOST_SUPPORT_SBOM_SHA256" ]] ||
  fail "runtime SBOM changed after its manifest identity was captured"
atomic_publish_runtime_directory \
  "$STAGING" \
  "$OUTPUT_ROOT" \
  "$STAGING_ID" \
  "$OUTPUT_ROOT_EXPECTED_ID" ||
  fail "atomic identity-checked runtime publication failed"
# Publication is committed once the atomic no-replace rename or exchange
# returns success. For replacement, the previous Runtime now occupies the
# private staging pathname; its removal is post-commit housekeeping and must
# never turn a successful publication into a reported rollback/failure.
if [[ -n "$OUTPUT_ROOT_EXPECTED_ID" ]]; then
  STAGING_ID="$OUTPUT_ROOT_EXPECTED_ID"
  if ! cleanup_owned_directory \
      "$STAGING" \
      "$STAGING_ID" \
      "$OUTPUT_PARENT" \
      "$OUTPUT_PARENT_ID" \
      "previous runtime after committed publication"; then
    printf 'warning: Runtime publication committed; previous Runtime remains for recoverable cleanup: %s\n' \
      "$STAGING" >&2
  fi
fi
STAGING=""
STAGING_ID=""
cleanup_owned_directory \
  "$PATCH_PROJECTION_WORKSPACE" \
  "$PATCH_PROJECTION_WORKSPACE_ID" \
  "$PATCH_PROJECTION_PARENT" \
  "$PATCH_PROJECTION_PARENT_ID" \
  "runtime patch projection" ||
  printf 'warning: Runtime publication committed; patch projection remains for recoverable cleanup: %s\n' \
    "$PATCH_PROJECTION_WORKSPACE" >&2
PATCH_PROJECTION_WORKSPACE=""
PATCH_PROJECTION_WORKSPACE_ID=""
trap - EXIT

printf 'Packaged ForgePlay Runtime: %s\n' "$OUTPUT_ROOT"
