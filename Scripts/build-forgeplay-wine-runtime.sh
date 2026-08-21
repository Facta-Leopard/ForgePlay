#!/bin/bash
set -euo pipefail

readonly FORGEPLAY_SYSTEM_TOOL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PATH="$FORGEPLAY_SYSTEM_TOOL_PATH"
export PATH
unset CDPATH

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"
SOURCE_INPUT="${1:-}"
BUILD_INPUT="${2:-}"
INSTALL_INPUT="${3:-}"
JOBS="${FORGEPLAY_WINE_BUILD_JOBS:-4}"
HOMEBREW_X86_PREFIX="${FORGEPLAY_HOMEBREW_X86_PREFIX:-/usr/local}"
BISON_INPUT="${FORGEPLAY_BISON:-/opt/homebrew/opt/bison/bin/bison}"
MSGFMT_INPUT="${FORGEPLAY_MSGFMT:-$HOMEBREW_X86_PREFIX/bin/msgfmt}"
GSTREAMER_SDK_ROOT="${FORGEPLAY_GSTREAMER_SDK_ROOT:-}"
LOGICAL_PREFIX="/forgeplay-runtime"
SOURCE_VALIDATOR="$SCRIPT_DIR/package-forgeplay-runtime.sh"
BUILD_PATH_VERIFIER="$SCRIPT_DIR/verify-wine-runtime-build-paths.py"
RUNTIME_MANIFEST="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/RuntimeManifest.json"
RUNTIME_DEPENDENCY_LOCK="$REPO_ROOT/Config/ForgePlayRuntimeDependencies.lock.json"
PATCH_PROVENANCE_LOCK="$REPO_ROOT/Config/ForgePlayRuntimePatchProvenance.lock.json"
PATCH_ROOT="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches"

fail() {
  printf 'error: ForgePlay Wine Runtime build failed: %s\n' "$*" >&2
  exit 1
}

validate_ordered_patch_contract() {
  /usr/bin/python3 - "$RUNTIME_MANIFEST" "$PATCH_PROVENANCE_LOCK" "$PATCH_ROOT" <<'PY'
import hashlib
import json
import re
import stat
import sys
from pathlib import Path, PurePosixPath

manifest_path, lock_path, patch_root = map(Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
lock = json.loads(lock_path.read_text(encoding="utf-8"))
order = manifest.get("patchApplicationOrder")
locked = lock.get("patches")
if not isinstance(order, list) or not isinstance(locked, list):
    raise SystemExit("runtime patch order or provenance inventory is malformed")
locked_order = [entry.get("path") for entry in locked if isinstance(entry, dict)]
if order != locked_order or len(order) != len(set(order)):
    raise SystemExit("runtime manifest must consume the complete provenance-locked patch order exactly")
for entry in locked:
    name = entry["path"]
    parsed = PurePosixPath(name)
    if parsed.is_absolute() or len(parsed.parts) != 1 or parsed.name != name:
        raise SystemExit(f"unsafe patch name: {name!r}")
    path = patch_root / name
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise SystemExit(f"patch must be a single-link regular file: {name}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
        raise SystemExit(f"patch hash mismatch: {name}")
for entry in lock.get("patchLicenseSidecars", []):
    if not isinstance(entry, dict):
        raise SystemExit("patch license sidecar entry must be an object")
    name = entry.get("path")
    patch_name = entry.get("patchPath")
    parsed = PurePosixPath(name) if isinstance(name, str) else None
    parsed_patch = PurePosixPath(patch_name) if isinstance(patch_name, str) else None
    if (
        parsed is None
        or parsed.is_absolute()
        or len(parsed.parts) != 1
        or parsed.name != name
        or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.patch\.license", name) is None
        or parsed_patch is None
        or parsed_patch.is_absolute()
        or len(parsed_patch.parts) != 1
        or parsed_patch.name != patch_name
        or not patch_name.endswith(".patch")
        or name != f"{patch_name}.license"
        or patch_name not in order
    ):
        raise SystemExit(f"unsafe or unbound patch license sidecar: {name!r}")
    path = patch_root / name
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise SystemExit(f"patch sidecar must be a single-link regular file: {name}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
        raise SystemExit(f"patch sidecar hash mismatch: {name}")
PY
}

reject_symlink_parent_components() {
  local candidate="$1"
  local label="$2"
  local current parent

  [[ "$candidate" = /* ]] || fail "$label must be an absolute path"
  current="$candidate"
  while [[ "$current" != "/" ]]; do
    [[ ! -L "$current" ]] || fail "$label must not contain symlink path components: $current"
    parent="$(/usr/bin/dirname "$current")"
    [[ "$parent" != "$current" ]] || break
    current="$parent"
  done
}

resolve_xcode_compiler_input() {
  local candidate="$1"
  local label="$2"
  local candidate_parent

  [[ "$candidate" = /* ]] || fail "$label must be an absolute path"
  candidate_parent="$(/usr/bin/dirname "$candidate")"
  reject_symlink_parent_components "$candidate_parent" "$label parent"
  /usr/bin/python3 - "$candidate" "$candidate_parent" "$label" <<'PY'
import os
import stat
import sys

candidate, candidate_parent, label = sys.argv[1:]
try:
    candidate_metadata = os.lstat(candidate)
except OSError as error:
    raise SystemExit(f"{label} could not be inspected: {error}")
if not (stat.S_ISREG(candidate_metadata.st_mode) or stat.S_ISLNK(candidate_metadata.st_mode)):
    raise SystemExit(f"{label} is neither a regular file nor a compiler-driver symlink")

resolved = os.path.realpath(candidate)
resolved_parent = os.path.realpath(candidate_parent)
if os.path.dirname(resolved) != resolved_parent:
    raise SystemExit(f"{label} resolves outside its Xcode tool directory")
try:
    resolved_metadata = os.lstat(resolved)
except OSError as error:
    raise SystemExit(f"{label} target could not be inspected: {error}")
if (
    not stat.S_ISREG(resolved_metadata.st_mode)
    or resolved_metadata.st_nlink != 1
    or not os.access(resolved, os.X_OK)
):
    raise SystemExit(f"{label} target is not a single-link executable regular file")
print(resolved)
PY
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

reject_symlink_descendant_components() {
  local trusted_root="$1"
  local candidate="$2"
  local label="$3"

  /usr/bin/python3 - "$trusted_root" "$candidate" "$label" <<'PY'
import os
import stat
import sys

root, candidate, label = sys.argv[1:]
root = os.path.normpath(root)
candidate = os.path.normpath(candidate)
if os.path.commonpath([root, candidate]) != root or candidate == root:
    raise SystemExit(f"{label} is outside its trusted root")
current = root
for component in os.path.relpath(candidate, root).split(os.sep):
    current = os.path.join(current, component)
    metadata = os.lstat(current)
    if stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(f"{label} contains a symlink descendant component: {current}")
PY
}

directory_identity() {
  /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null
}

thaw_owned_tool_snapshot_for_removal() {
  local tree_root="$1"
  local expected_tree_identity="$2"
  local build_root="$3"
  local expected_build_identity="$4"
  local build_parent="$5"
  local expected_parent_identity="$6"

  /usr/bin/python3 - \
    "$tree_root" \
    "$expected_tree_identity" \
    "$build_root" \
    "$expected_build_identity" \
    "$build_parent" \
    "$expected_parent_identity" <<'PY'
import os
import stat
import sys

tree_root, expected_tree, build_root, expected_build, build_parent, expected_parent = sys.argv[1:]


def parse_identity(value, label):
    fields = value.split(":")
    if len(fields) != 2 or any(not field.isdigit() for field in fields):
        raise SystemExit(f"{label} identity is invalid")
    return tuple(map(int, fields))


def identity(value):
    return value.st_dev, value.st_ino


tree_identity = parse_identity(expected_tree, "tool snapshot root")
build_identity = parse_identity(expected_build, "build root")
parent_identity = parse_identity(expected_parent, "build parent")
if (
    not all(os.path.isabs(path) and os.path.normpath(path) == path for path in (tree_root, build_root, build_parent))
    or os.path.dirname(tree_root) != build_root
    or os.path.dirname(build_root) != build_parent
):
    raise SystemExit("owned tool snapshot cleanup paths do not form the exact bound hierarchy")

directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
parent_fd = os.open(build_parent, directory_flags)
try:
    if identity(os.fstat(parent_fd)) != parent_identity:
        raise SystemExit("build parent identity changed before tool snapshot cleanup")
    build_fd = os.open(os.path.basename(build_root), directory_flags, dir_fd=parent_fd)
    try:
        if identity(os.fstat(build_fd)) != build_identity:
            raise SystemExit("build root identity changed before tool snapshot cleanup")
        tree_fd = os.open(os.path.basename(tree_root), directory_flags, dir_fd=build_fd)
        try:
            tree_metadata = os.fstat(tree_fd)
            if identity(tree_metadata) != tree_identity or tree_metadata.st_uid != os.geteuid():
                raise SystemExit("tool snapshot root identity changed before cleanup")
            for _, directory_names, _, directory_fd in os.fwalk(
                ".",
                topdown=False,
                follow_symlinks=False,
                dir_fd=tree_fd,
            ):
                current_metadata = os.fstat(directory_fd)
                if not stat.S_ISDIR(current_metadata.st_mode) or current_metadata.st_uid != os.geteuid():
                    raise SystemExit("tool snapshot cleanup encountered an unowned directory")
                for directory_name in directory_names:
                    metadata = os.stat(
                        directory_name,
                        dir_fd=directory_fd,
                        follow_symlinks=False,
                    )
                    if stat.S_ISLNK(metadata.st_mode):
                        continue
                    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
                        raise SystemExit("tool snapshot cleanup encountered an unsafe directory entry")
                os.fchmod(directory_fd, 0o700)
            if identity(os.fstat(tree_fd)) != tree_identity:
                raise SystemExit("tool snapshot root identity changed while being thawed")
            rebound = os.stat(
                os.path.basename(tree_root),
                dir_fd=build_fd,
                follow_symlinks=False,
            )
            if not stat.S_ISDIR(rebound.st_mode) or identity(rebound) != tree_identity:
                raise SystemExit("tool snapshot path changed while being thawed")
        finally:
            os.close(tree_fd)
        if identity(os.fstat(build_fd)) != build_identity:
            raise SystemExit("build root identity changed while tool snapshot was thawed")
    finally:
        os.close(build_fd)
    if identity(os.fstat(parent_fd)) != parent_identity:
        raise SystemExit("build parent identity changed while tool snapshot was thawed")
finally:
    os.close(parent_fd)
PY
}

regular_file_identity() {
  /usr/bin/python3 - "$1" <<'PY'
import os
import stat
import sys

metadata = os.lstat(sys.argv[1])
if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink < 1:
    raise SystemExit(1)
print(
    f"{metadata.st_dev}:{metadata.st_ino}:{metadata.st_nlink}:"
    f"{metadata.st_size}:{int(metadata.st_mtime)}:{int(metadata.st_ctime)}"
)
PY
}

gstreamer_file_manifest() {
  local mode="$1"
  local root="$2"
  local manifest="$3"
  /usr/bin/python3 - "$mode" "$root" "$manifest" <<'PY'
import hashlib
import json
import os
import stat
import sys

mode, root, manifest = sys.argv[1:]
root = os.path.realpath(root)

def identity(value):
    return [
        value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
        value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    ]

def digest_regular(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise SystemExit(f"GStreamer SDK input is not a single-link regular file: {path}")
        value = hashlib.sha256()
        total = 0
        while total < before.st_size:
            chunk = os.pread(descriptor, min(1024 * 1024, before.st_size - total), total)
            if not chunk:
                raise SystemExit(f"GStreamer SDK input became incomplete: {path}")
            value.update(chunk)
            total += len(chunk)
        after = os.fstat(descriptor)
        if identity(before) != identity(after) or total != before.st_size:
            raise SystemExit(f"GStreamer SDK input changed while hashing: {path}")
        return identity(before), value.hexdigest()
    finally:
        os.close(descriptor)

def capture():
    root_metadata = os.lstat(root)
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        raise SystemExit("GStreamer SDK root is not a bound directory")
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
                    raise SystemExit(f"GStreamer SDK directory symlink escapes its root: {path}")
                rows.append({
                    "path": relative,
                    "kind": "directory-symlink",
                    "identity": identity(metadata),
                    "target": target,
                    "targetIdentity": identity(os.lstat(resolved)),
                })
            elif not stat.S_ISDIR(metadata.st_mode):
                raise SystemExit(f"GStreamer SDK directory entry is unsafe: {path}")
            else:
                rows.append({"path": relative, "kind": "directory", "identity": identity(metadata)})
        for name in file_names:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root)
            metadata = os.lstat(path)
            if stat.S_ISLNK(metadata.st_mode):
                target = os.readlink(path)
                resolved = os.path.realpath(path)
                if os.path.commonpath([root, resolved]) != root:
                    raise SystemExit(f"GStreamer SDK symlink escapes its root: {path}")
                target_identity, sha256 = digest_regular(resolved)
                rows.append({"path": relative, "kind": "symlink", "identity": identity(metadata), "target": target, "targetIdentity": target_identity, "sha256": sha256})
            elif stat.S_ISREG(metadata.st_mode):
                file_identity, sha256 = digest_regular(path)
                rows.append({"path": relative, "kind": "file", "identity": file_identity, "sha256": sha256})
                total_bytes += metadata.st_size
            else:
                raise SystemExit(f"GStreamer SDK contains an unsupported entry: {path}")
            if len(rows) > 100000 or total_bytes > 16 * 1024 * 1024 * 1024:
                raise SystemExit("GStreamer SDK file manifest exceeds its bound")
    return {"schemaVersion": 1, "rootIdentity": identity(root_metadata), "entries": rows}

actual = capture()
if mode == "capture":
    descriptor = os.open(manifest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, 0o400)
    try:
        payload = (json.dumps(actual, sort_keys=True, separators=(",", ":")) + "\n").encode()
        os.write(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
elif mode == "verify":
    descriptor = os.open(manifest, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 64 * 1024 * 1024:
            raise SystemExit("GStreamer SDK file manifest is unsafe")
        expected = json.loads(os.read(descriptor, metadata.st_size).decode())
    finally:
        os.close(descriptor)
    if actual != expected:
        raise SystemExit("GStreamer SDK file identities or content hashes changed")
else:
    raise SystemExit("unsupported GStreamer SDK file manifest mode")
PY
}

compiler_capsule_manifest() {
  local mode="$1"
  local capsule_root="$2"
  local manifest="$3"
  /usr/bin/python3 - "$mode" "$capsule_root" "$manifest" <<'PY'
import hashlib
import json
import os
import stat
import sys

mode, root, manifest = sys.argv[1:]
root = os.path.realpath(root)
MAXIMUM_ENTRIES = 200000
MAXIMUM_BYTES = 16 * 1024 * 1024 * 1024
MAXIMUM_MANIFEST_BYTES = 64 * 1024 * 1024
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()


def digest_regular(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise SystemExit(f"compiler capsule object is not a single-link regular file: {path}")
        digest = hashlib.sha256()
        total = 0
        while total < before.st_size:
            chunk = os.pread(descriptor, min(1024 * 1024, before.st_size - total), total)
            if not chunk:
                raise SystemExit(f"compiler capsule object became incomplete: {path}")
            digest.update(chunk)
            total += len(chunk)
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
        if identity(before) != identity(after) or total != before.st_size:
            raise SystemExit(f"compiler capsule object changed while hashing: {path}")
        return before, digest.hexdigest()
    finally:
        os.close(descriptor)


def digest_symlink(path):
    before = os.lstat(path)
    if not stat.S_ISLNK(before.st_mode) or before.st_nlink != 1:
        raise SystemExit(f"compiler capsule link is not a private symlink: {path}")
    target = os.readlink(path)
    if os.path.isabs(target):
        raise SystemExit(f"compiler capsule contains an absolute symlink: {path}")
    resolved = os.path.realpath(path)
    try:
        contained = os.path.commonpath([root, resolved]) == root
    except ValueError:
        contained = False
    if not contained or not os.path.exists(resolved):
        raise SystemExit(f"compiler capsule symlink escapes its root or is dangling: {path}")
    after = os.lstat(path)
    if (
        before.st_dev,
        before.st_ino,
        before.st_mode,
        before.st_nlink,
        before.st_size,
        before.st_mtime_ns,
        before.st_ctime_ns,
        target,
    ) != (
        after.st_dev,
        after.st_ino,
        after.st_mode,
        after.st_nlink,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
        os.readlink(path),
    ):
        raise SystemExit(f"compiler capsule symlink changed while being inspected: {path}")
    return before, target, hashlib.sha256(os.fsencode(target)).hexdigest()


def scan():
    root_metadata = os.lstat(root)
    if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
        raise SystemExit("compiler capsule root must be a non-symlink directory")
    rows = [{
        "path": ".",
        "type": "directory",
        "mode": stat.S_IMODE(root_metadata.st_mode),
        "length": 0,
        "sha256": EMPTY_SHA256,
    }]
    total_bytes = 0
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_names.sort()
        file_names.sort()
        for name in directory_names:
            path = os.path.join(directory, name)
            metadata = os.lstat(path)
            if stat.S_ISLNK(metadata.st_mode):
                metadata, target, sha256 = digest_symlink(path)
                rows.append({
                    "path": os.path.relpath(path, root),
                    "type": "symlink",
                    "mode": stat.S_IMODE(metadata.st_mode),
                    "length": len(os.fsencode(target)),
                    "sha256": sha256,
                })
                total_bytes += len(os.fsencode(target))
            elif stat.S_ISDIR(metadata.st_mode):
                rows.append({
                    "path": os.path.relpath(path, root),
                    "type": "directory",
                    "mode": stat.S_IMODE(metadata.st_mode),
                    "length": 0,
                    "sha256": EMPTY_SHA256,
                })
            else:
                raise SystemExit(f"compiler capsule contains an unsafe directory: {path}")
        for name in file_names:
            path = os.path.join(directory, name)
            relative = os.path.relpath(path, root)
            if relative.startswith("../") or relative == ".." or os.path.isabs(relative):
                raise SystemExit(f"compiler capsule object escaped its root: {path}")
            metadata = os.lstat(path)
            if stat.S_ISLNK(metadata.st_mode):
                metadata, target, sha256 = digest_symlink(path)
                rows.append({
                    "path": relative,
                    "type": "symlink",
                    "mode": stat.S_IMODE(metadata.st_mode),
                    "length": len(os.fsencode(target)),
                    "sha256": sha256,
                })
                total_bytes += len(os.fsencode(target))
            else:
                metadata, sha256 = digest_regular(path)
                rows.append({
                    "path": relative,
                    "type": "file",
                    "mode": stat.S_IMODE(metadata.st_mode),
                    "length": metadata.st_size,
                    "sha256": sha256,
                })
                total_bytes += metadata.st_size
        if len(rows) > MAXIMUM_ENTRIES or total_bytes > MAXIMUM_BYTES:
            raise SystemExit("compiler capsule exceeds its deterministic entry or byte bound")
    rows.sort(key=lambda row: row["path"])
    platform_contracts = []
    contract_path = os.path.join(root, "platform-contracts.json")
    if os.path.exists(contract_path):
        with open(contract_path, "rb") as handle:
            requested_contracts = json.load(handle)
        if not isinstance(requested_contracts, list) or len(requested_contracts) > 4096:
            raise SystemExit("compiler capsule platform-contract list is invalid")
        for requested in requested_contracts:
            if not isinstance(requested, str) or not os.path.isabs(requested):
                raise SystemExit("compiler capsule platform contract must be an absolute path")
            if not requested.startswith(("/usr/lib/", "/System/Library/", "/System/Cryptexes/")):
                raise SystemExit(f"compiler capsule platform contract is outside immutable OS roots: {requested}")
            if os.path.exists(requested):
                metadata, sha256 = digest_regular(requested)
                platform_contracts.append({
                    "path": requested,
                    "type": "immutable-os-file",
                    "mode": stat.S_IMODE(metadata.st_mode),
                    "length": metadata.st_size,
                    "sha256": sha256,
                })
            else:
                platform_contracts.append({
                    "path": requested,
                    "type": "dyld-shared-cache-contract",
                    "mode": 0,
                    "length": 0,
                    "sha256": EMPTY_SHA256,
                })
        platform_contracts.sort(key=lambda row: row["path"])
    return {
        "schemaVersion": 1,
        "maximumEntries": MAXIMUM_ENTRIES,
        "maximumBytes": MAXIMUM_BYTES,
        "entries": rows,
        "platformContracts": platform_contracts,
    }


actual = scan()
if mode == "capture":
    descriptor = os.open(
        manifest,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o400,
    )
    try:
        payload = (json.dumps(actual, sort_keys=True, separators=(",", ":")) + "\n").encode()
        if len(payload) > MAXIMUM_MANIFEST_BYTES:
            raise SystemExit("compiler capsule manifest exceeds its byte bound")
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise SystemExit("compiler capsule manifest write made no progress")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
elif mode == "verify":
    descriptor = os.open(manifest, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            raise SystemExit("compiler capsule manifest must be a single-link regular file")
        if metadata.st_size < 1 or metadata.st_size > MAXIMUM_MANIFEST_BYTES:
            raise SystemExit("compiler capsule manifest violates its byte bound")
        payload = bytearray()
        while len(payload) < metadata.st_size:
            chunk = os.read(descriptor, metadata.st_size - len(payload))
            if not chunk:
                raise SystemExit("compiler capsule manifest became incomplete")
            payload.extend(chunk)
        expected = json.loads(payload.decode("utf-8"))
    finally:
        os.close(descriptor)
    if actual != expected:
        raise SystemExit("compiler capsule has a missing, extra, replaced, or mutated object")
else:
    raise SystemExit("unsupported compiler capsule manifest mode")
PY
}

validate_vulkan_configure_result() {
  local configure_root="$1"
  local config_header="$configure_root/include/config.h"
  local config_log="$configure_root/config.log"

  [[ "$configure_root" = /* && -d "$configure_root" && ! -L "$configure_root" ]] ||
    fail "Wine configure result root must be an absolute non-symlink directory: $configure_root"
  reject_symlink_parent_components "$configure_root" "Wine configure result root"
  for configure_output in "$config_header" "$config_log"; do
    [[ -f "$configure_output" && ! -L "$configure_output" ]] ||
      fail "Wine configure result is missing a non-symlink file: $configure_output"
    [[ "$(/usr/bin/stat -f '%l' "$configure_output" 2>/dev/null)" == "1" ]] ||
      fail "Wine configure result must not be hardlinked: $configure_output"
  done
  LC_ALL=C /usr/bin/grep -Fqx '#define SONAME_LIBVULKAN "libvulkan.1.dylib"' "$config_header" ||
    fail "Wine configure did not bind the required x86_64 Vulkan host loader"
  if LC_ALL=C /usr/bin/grep -Fq \
      'libvulkan and libMoltenVK 64-bit development files not found' "$config_log"; then
    fail "Wine configure disabled the required Vulkan host backend"
  fi
}

validate_vulkan_capsule_dependency_lock() {
  local capsule_root="$1"
  local capsule_manifest="$2"
  local dependency_lock="$3"
  local locked_input

  [[ "$capsule_root" = /* && -d "$capsule_root" && ! -L "$capsule_root" ]] ||
    fail "Vulkan development capsule root must be an absolute non-symlink directory"
  for locked_input in "$capsule_manifest" "$dependency_lock"; do
    [[ "$locked_input" = /* && -f "$locked_input" && ! -L "$locked_input" ]] ||
      fail "Vulkan capsule dependency-lock input must be an absolute non-symlink file: $locked_input"
  done
  reject_symlink_parent_components "$capsule_root" "Vulkan development capsule root"
  reject_symlink_parent_components "$capsule_manifest" "Vulkan development capsule manifest"
  reject_symlink_parent_components "$dependency_lock" "runtime dependency lock"
  compiler_capsule_manifest verify "$capsule_root" "$capsule_manifest" ||
    fail "Vulkan development capsule changed before dependency-lock validation"
  /usr/bin/python3 - \
    "$capsule_root" \
    "$capsule_manifest" \
    "$dependency_lock" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys

capsule_root, manifest_path, lock_path = sys.argv[1:]
MAXIMUM_JSON_BYTES = 64 * 1024 * 1024
MAXIMUM_LOADER_BYTES = 256 * 1024 * 1024
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
VULKAN_LOADER_SOURCE_PATTERN = re.compile(r"libvulkan\.[0-9][0-9.]*\.dylib")


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


def read_stable(path, maximum, label):
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size < 1
            or before.st_size > maximum
        ):
            raise SystemExit(f"{label} is not a bounded single-link regular file")
        payload = bytearray()
        while len(payload) < before.st_size:
            chunk = os.read(descriptor, min(1024 * 1024, before.st_size - len(payload)))
            if not chunk:
                raise SystemExit(f"{label} became incomplete")
            payload.extend(chunk)
        after = os.fstat(descriptor)
        if len(payload) != before.st_size or identity(before) != identity(after):
            raise SystemExit(f"{label} changed during descriptor-bound validation")
        return bytes(payload)
    finally:
        os.close(descriptor)


if not all(os.path.isabs(path) for path in (capsule_root, manifest_path, lock_path)):
    raise SystemExit("Vulkan capsule dependency-lock inputs must use absolute paths")
root_metadata = os.lstat(capsule_root)
if not stat.S_ISDIR(root_metadata.st_mode) or stat.S_ISLNK(root_metadata.st_mode):
    raise SystemExit("Vulkan development capsule root is not a canonical directory")

contract_path = os.path.join(capsule_root, "metadata", "contract.json")
loader_path = os.path.join(capsule_root, "lib", "libvulkan.1.dylib")
contract = json.loads(read_stable(contract_path, MAXIMUM_JSON_BYTES, "Vulkan capsule contract"))
manifest = json.loads(read_stable(manifest_path, MAXIMUM_JSON_BYTES, "Vulkan capsule manifest"))
dependency_lock = json.loads(read_stable(lock_path, MAXIMUM_JSON_BYTES, "runtime dependency lock"))
loader_payload = read_stable(loader_path, MAXIMUM_LOADER_BYTES, "Vulkan capsule loader")
loader_sha256 = hashlib.sha256(loader_payload).hexdigest()

if (
    contract.get("schemaVersion") != 1
    or contract.get("module") != "vulkan"
    or contract.get("loaderInstallName") != "libvulkan.1.dylib"
    or SHA256_PATTERN.fullmatch(str(contract.get("loaderSHA256", ""))) is None
):
    raise SystemExit("Vulkan development capsule contract is malformed")
if contract["loaderSHA256"] != loader_sha256:
    raise SystemExit("Vulkan development capsule loader digest does not match its contract")

entries = manifest.get("entries")
if manifest.get("schemaVersion") != 1 or not isinstance(entries, list):
    raise SystemExit("Vulkan development capsule manifest is malformed")
loader_entries = [
    entry
    for entry in entries
    if isinstance(entry, dict) and entry.get("path") == "lib/libvulkan.1.dylib"
]
if (
    len(loader_entries) != 1
    or loader_entries[0].get("type") != "file"
    or loader_entries[0].get("sha256") != loader_sha256
    or loader_entries[0].get("length") != len(loader_payload)
):
    raise SystemExit("Vulkan development capsule manifest does not bind the loader payload exactly")

artifacts = dependency_lock.get("artifacts")
if dependency_lock.get("schemaVersion") != 1 or not isinstance(artifacts, list):
    raise SystemExit("runtime dependency lock is malformed")
loader_artifacts = [
    artifact
    for artifact in artifacts
    if isinstance(artifact, dict)
    and artifact.get("targetPath") == "wine/lib/libvulkan.1.dylib"
]
if len(loader_artifacts) != 1:
    raise SystemExit("runtime dependency lock must declare one exact packaged Vulkan loader entry")
loader_artifact = loader_artifacts[0]
locked_sha256 = loader_artifact.get("sourceSHA256")
locked_source_path = loader_artifact.get("sourcePath")
if (
    loader_artifact.get("formula") != "vulkan-loader"
    or not isinstance(loader_artifact.get("formulaVersion"), str)
    or not loader_artifact["formulaVersion"]
    or not isinstance(locked_source_path, str)
    or os.path.isabs(locked_source_path)
    or os.path.normpath(locked_source_path) != locked_source_path
    or os.path.dirname(locked_source_path) != "lib"
    or VULKAN_LOADER_SOURCE_PATTERN.fullmatch(os.path.basename(locked_source_path)) is None
    or SHA256_PATTERN.fullmatch(str(locked_sha256 or "")) is None
):
    raise SystemExit("runtime dependency lock Vulkan loader entry is malformed")
if locked_sha256 != loader_sha256:
    raise SystemExit(
        "Vulkan development loader digest differs from the packaged dependency lock: "
        f"development={loader_sha256} packaged={locked_sha256}"
    )
PY
}

if [[ "${1:-}" == "--capture-compiler-capsule" ||
      "${1:-}" == "--verify-compiler-capsule" ]]; then
  [[ "$#" -eq 3 ]] ||
    fail "usage: build-forgeplay-wine-runtime.sh ${1:-<compiler-capsule-mode>} <capsule-root> <manifest>"
  compiler_capsule_mode="${1#--}"
  compiler_capsule_mode="${compiler_capsule_mode%-compiler-capsule}"
  compiler_capsule_manifest "$compiler_capsule_mode" "$2" "$3" ||
    fail "compiler capsule ${compiler_capsule_mode} failed"
  exit 0
fi

if [[ "${1:-}" == "--validate-vulkan-configure-result" ]]; then
  [[ "$#" -eq 2 ]] ||
    fail "usage: build-forgeplay-wine-runtime.sh --validate-vulkan-configure-result <Wine build root>"
  validate_vulkan_configure_result "$2"
  printf 'Validated Vulkan-enabled Wine configure result: %s\n' "$2"
  exit 0
fi

if [[ "${1:-}" == "--validate-vulkan-capsule-dependency-lock" ]]; then
  [[ "$#" -eq 4 ]] ||
    fail "usage: build-forgeplay-wine-runtime.sh --validate-vulkan-capsule-dependency-lock <capsule-root> <capsule-manifest> <runtime-dependency-lock>"
  validate_vulkan_capsule_dependency_lock "$2" "$3" "$4"
  printf 'Validated Vulkan development capsule against packaged dependency lock: %s\n' "$4"
  exit 0
fi

materialize_compiler_capsule() {
  local capsule_root="$1"
  local manifest="$2"
  local clang_source="$3"
  local clangxx_source="$4"
  local mingw64_source="$5"
  local mingw32_source="$6"
  local bison_source="$7"
  local msgfmt_source="${8:--}"
  /usr/bin/python3 - \
    "$capsule_root" \
    "$manifest" \
    "$clang_source" \
    "$clangxx_source" \
    "$mingw64_source" \
    "$mingw32_source" \
    "$bison_source" \
    "$msgfmt_source" <<'PY'
import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys

(
    root,
    manifest,
    clang_source,
    clangxx_source,
    mingw64_source,
    mingw32_source,
    bison_source,
    msgfmt_source,
) = sys.argv[1:]
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
MAXIMUM_TREE_ENTRIES = 200000
MAXIMUM_TREE_BYTES = 16 * 1024 * 1024 * 1024
MAXIMUM_FILE_BYTES = 2 * 1024 * 1024 * 1024
SAFE_TOKEN = re.compile(r"^[A-Za-z0-9_.+-]+$")
COMPILER_STAGE_NAMES = ("cc1", "cc1plus", "collect2", "lto-wrapper", "lto1", "as", "ld")
COMPILER_SUPPORT_PROGRAM_NAMES = ("liblto_plugin.so",)
TARGET_HELPER_NAMES = (
    "nm",
    "ar",
    "ranlib",
    "strip",
    "objcopy",
    "objdump",
    "dlltool",
    "windres",
    "as",
    "ld",
)
entry_count = 0
byte_count = 0
executable_sources = []
hardlink_source_bindings = {}
discovery_driver_bindings = {}
query_discovered_source_bindings = {}


def fail(message):
    raise SystemExit(message)


def source_identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def digest_source_descriptor(descriptor, size, source, label):
    digest = hashlib.sha256()
    total = 0
    while total < size:
        chunk = os.pread(descriptor, min(1024 * 1024, size - total), total)
        if not chunk:
            fail(f"{label} became incomplete: {source}")
        digest.update(chunk)
        total += len(chunk)
    return total, digest.hexdigest()


def capture_source_binding(source, label):
    source = os.path.realpath(source)
    path_before = os.lstat(source)
    source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(source_fd)
        if source_identity(path_before) != source_identity(before):
            fail(f"{label} path changed before descriptor binding: {source}")
        if not stat.S_ISREG(before.st_mode) or before.st_nlink < 1:
            fail(f"{label} is not a regular file: {source}")
        if before.st_size < 0 or before.st_size > MAXIMUM_FILE_BYTES:
            fail(f"{label} exceeds its per-file bound: {source}")
        total, sha256 = digest_source_descriptor(source_fd, before.st_size, source, label)
        after = os.fstat(source_fd)
        path_after = os.lstat(source)
        expected_identity = source_identity(before)
        if (
            source_identity(after) != expected_identity
            or source_identity(path_after) != expected_identity
            or total != before.st_size
        ):
            fail(f"{label} changed while its binding was captured: {source}")
        return {
            "path": source,
            "identity": expected_identity,
            "sha256": sha256,
        }
    finally:
        os.close(source_fd)


def revalidate_source_binding(binding, label, verify_digest):
    source = binding["path"]
    path_before = os.lstat(source)
    source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(source_fd)
        expected_identity = binding["identity"]
        if (
            source_identity(path_before) != expected_identity
            or source_identity(before) != expected_identity
            or not stat.S_ISREG(before.st_mode)
            or before.st_nlink < 1
        ):
            fail(f"{label} identity changed: {source}")
        sha256 = binding["sha256"]
        total = before.st_size
        if verify_digest:
            total, sha256 = digest_source_descriptor(source_fd, before.st_size, source, label)
        after = os.fstat(source_fd)
        path_after = os.lstat(source)
        if (
            source_identity(after) != expected_identity
            or source_identity(path_after) != expected_identity
            or total != before.st_size
            or sha256 != binding["sha256"]
        ):
            fail(f"{label} content or path binding changed: {source}")
    finally:
        os.close(source_fd)


def bind_discovery_driver(source):
    binding = capture_source_binding(source, "compiler discovery driver")
    previous = discovery_driver_bindings.get(binding["path"])
    if previous is not None and previous != binding:
        fail(f"compiler discovery driver binding changed: {binding['path']}")
    discovery_driver_bindings[binding["path"]] = binding
    return binding


def bind_query_discovered_source(source, label):
    source = os.path.realpath(source)
    previous = query_discovered_source_bindings.get(source)
    if previous is not None:
        revalidate_source_binding(previous, label, verify_digest=False)
        return source
    binding = capture_source_binding(source, label)
    query_discovered_source_bindings[source] = binding
    return source


def query(executable, arguments, driver_binding=None):
    if driver_binding is not None:
        if os.path.realpath(executable) != driver_binding["path"]:
            fail("compiler discovery query did not use its bound driver path")
        executable = driver_binding["path"]
        revalidate_source_binding(
            driver_binding,
            "compiler discovery driver binding before query",
            verify_digest=False,
        )
    environment = {
        "PATH": SYSTEM_PATH,
        "LC_ALL": "C",
        "LANG": "C",
        "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    }
    try:
        result = subprocess.run(
            [executable, *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=30,
            check=False,
        )
    finally:
        if driver_binding is not None:
            revalidate_source_binding(
                driver_binding,
                "compiler discovery driver binding after query",
                verify_digest=False,
            )
    if result.returncode != 0 or len(result.stdout) > 1024 * 1024 or len(result.stderr) > 1024 * 1024:
        fail(f"compiler capsule discovery command failed closed: {executable} {' '.join(arguments)}")
    try:
        value = result.stdout.decode("utf-8").strip()
    except UnicodeDecodeError as error:
        fail(f"compiler capsule discovery output is not UTF-8: {error}")
    if not value or "\n" in value or "\r" in value:
        fail(f"compiler capsule discovery returned an invalid scalar: {executable} {' '.join(arguments)}")
    return value


def ensure_construction_directory(path):
    root_path = os.path.abspath(root)
    requested_path = os.path.abspath(path)
    try:
        contained = os.path.commonpath([root_path, requested_path]) == root_path
    except ValueError:
        contained = False
    if not contained:
        fail(f"compiler capsule construction directory escaped its root: {path}")

    relative = os.path.relpath(requested_path, root_path)
    components = [] if relative == "." else relative.split(os.sep)
    current = root_path
    for component in components:
        if component in {"", ".", ".."}:
            fail(f"compiler capsule construction directory is unsafe: {path}")
        current = os.path.join(current, component)
        try:
            os.mkdir(current, 0o700)
        except FileExistsError:
            pass
        descriptor = os.open(
            current,
            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISDIR(metadata.st_mode):
                fail(f"compiler capsule construction path is not a directory: {current}")
            os.fchmod(descriptor, 0o700)
        finally:
            os.close(descriptor)
    if not components:
        descriptor = os.open(
            current,
            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
        try:
            os.fchmod(descriptor, 0o700)
        finally:
            os.close(descriptor)


def freeze_capsule_directories():
    for directory, directory_names, _ in os.walk(root, topdown=False, followlinks=False):
        for directory_name in directory_names:
            child = os.path.join(directory, directory_name)
            metadata = os.lstat(child)
            if stat.S_ISLNK(metadata.st_mode):
                target = os.readlink(child)
                resolved = os.path.realpath(child)
                if (
                    os.path.isabs(target)
                    or os.path.commonpath([root, resolved]) != root
                    or not os.path.exists(resolved)
                ):
                    fail(f"compiler capsule contains an unsafe symlink before freeze: {child}")
                continue
            if not stat.S_ISDIR(metadata.st_mode):
                fail(f"compiler capsule contains an unsafe directory before freeze: {child}")
        descriptor = os.open(
            directory,
            os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISDIR(metadata.st_mode):
                fail(f"compiler capsule freeze target is not a directory: {directory}")
            os.fchmod(descriptor, 0o500)
        finally:
            os.close(descriptor)


def stable_copy(
    source,
    destination,
    executable=False,
    required_binding=None,
    track_loader_dependencies=True,
):
    global entry_count, byte_count
    source = os.path.realpath(source)
    discovered_binding = query_discovered_source_bindings.get(source)
    if required_binding is not None and discovered_binding is not None and required_binding != discovered_binding:
        fail(f"compiler capsule source has conflicting discovery bindings: {source}")
    if required_binding is None:
        required_binding = discovered_binding
    if required_binding is not None and source != required_binding["path"]:
        fail(f"compiler capsule copy did not use its bound source path: {source}")
    path_before = os.lstat(source)
    source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(source_fd)
        if source_identity(path_before) != source_identity(before):
            fail(f"compiler capsule input path changed before descriptor binding: {source}")
        if not stat.S_ISREG(before.st_mode) or before.st_nlink < 1:
            fail(f"compiler capsule input is not a regular file: {source}")
        if before.st_size < 0 or before.st_size > MAXIMUM_FILE_BYTES:
            fail(f"compiler capsule input exceeds its per-file bound: {source}")
        if required_binding is not None and source_identity(before) != required_binding["identity"]:
            fail(f"compiler discovery driver binding changed before copy: {source}")
        magic = os.pread(source_fd, 4, 0)
        ensure_construction_directory(os.path.dirname(destination))
        destination_fd = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o500 if executable else 0o400,
        )
        try:
            total = 0
            digest = hashlib.sha256()
            while True:
                chunk = os.read(source_fd, min(1024 * 1024, MAXIMUM_FILE_BYTES - total + 1))
                if not chunk:
                    break
                total += len(chunk)
                if total > MAXIMUM_FILE_BYTES:
                    fail(f"compiler capsule input exceeded its per-file bound: {source}")
                digest.update(chunk)
                view = memoryview(chunk)
                while view:
                    written = os.write(destination_fd, view)
                    if written <= 0:
                        fail("compiler capsule copy made no progress")
                    view = view[written:]
            after = os.fstat(source_fd)
            path_after = os.lstat(source)
            expected_identity = source_identity(before)
            sha256 = digest.hexdigest()
            if (
                source_identity(after) != expected_identity
                or source_identity(path_after) != expected_identity
                or total != before.st_size
            ):
                fail(f"compiler capsule input changed while being copied: {source}")
            if required_binding is not None and (
                expected_identity != required_binding["identity"]
                or sha256 != required_binding["sha256"]
            ):
                fail(f"compiler discovery driver binding changed during copy: {source}")
            os.fsync(destination_fd)
            os.fchmod(destination_fd, 0o500 if executable else 0o400)
            destination_metadata = os.fstat(destination_fd)
            if (
                not stat.S_ISREG(destination_metadata.st_mode)
                or destination_metadata.st_nlink != 1
                or destination_metadata.st_size != total
                or stat.S_IMODE(destination_metadata.st_mode) != (0o500 if executable else 0o400)
            ):
                fail(f"compiler capsule output is not a private single-link copy: {destination}")
        finally:
            os.close(destination_fd)
    finally:
        os.close(source_fd)
    if before.st_nlink > 1:
        binding = {
            "path": source,
            "identity": source_identity(before),
            "sha256": sha256,
        }
        previous = hardlink_source_bindings.get(source)
        if previous is not None and previous != binding:
            fail(f"compiler capsule hardlink source binding changed between copies: {source}")
        hardlink_source_bindings[source] = binding
    entry_count += 1
    byte_count += before.st_size
    if entry_count > MAXIMUM_TREE_ENTRIES or byte_count > MAXIMUM_TREE_BYTES:
        fail("compiler capsule exceeded its deterministic entry or byte bound")
    if executable and track_loader_dependencies and magic in {
        b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
        b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
        b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
        b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
    }:
        executable_sources.append(source)
    return destination


def bounded_copy_tree(source, destination, label):
    global entry_count, byte_count
    source = os.path.realpath(source)
    metadata = os.lstat(source)
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} is not a canonical directory")
    ensure_construction_directory(os.path.dirname(destination))

    def copy_symlink(source_path, target_path):
        global entry_count, byte_count
        before = os.lstat(source_path)
        if not stat.S_ISLNK(before.st_mode) or before.st_nlink != 1:
            fail(f"{label} link is not a single-link symlink: {source_path}")
        target = os.readlink(source_path)
        if os.path.isabs(target):
            fail(f"{label} contains an absolute symlink: {source_path}")
        resolved = os.path.realpath(source_path)
        try:
            contained = os.path.commonpath([source, resolved]) == source
        except ValueError:
            contained = False
        if not contained or not os.path.exists(resolved):
            fail(f"{label} symlink escaped its bounded source root or is dangling: {source_path}")
        os.symlink(target, target_path)
        after = os.lstat(source_path)
        target_metadata = os.lstat(target_path)
        if (
            source_identity(before) != source_identity(after)
            or os.readlink(source_path) != target
            or not stat.S_ISLNK(target_metadata.st_mode)
            or target_metadata.st_nlink != 1
            or os.readlink(target_path) != target
        ):
            fail(f"{label} symlink changed or was not reproduced exactly: {source_path}")
        entry_count += 1
        byte_count += len(os.fsencode(target))
        if entry_count > MAXIMUM_TREE_ENTRIES or byte_count > MAXIMUM_TREE_BYTES:
            fail("compiler capsule exceeded its deterministic entry or byte bound")

    def copy_directory(source_directory, target_directory, ancestry):
        global entry_count
        canonical = os.path.realpath(source_directory)
        if os.path.commonpath([source, canonical]) != source:
            fail(f"{label} symlink escaped its bounded source root: {source_directory}")
        if canonical in ancestry:
            fail(f"{label} contains a directory cycle: {source_directory}")
        before = os.lstat(canonical)
        if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
            fail(f"{label} traversal object is not a canonical directory: {source_directory}")
        names = sorted(os.listdir(canonical))
        os.mkdir(target_directory, 0o700)
        entry_count += 1
        if entry_count > MAXIMUM_TREE_ENTRIES:
            fail("compiler capsule exceeded its deterministic entry bound")
        next_ancestry = ancestry | {canonical}
        for name in names:
            if name in {"", ".", ".."} or "/" in name:
                fail(f"{label} contains an unsafe entry name")
            source_path = os.path.join(canonical, name)
            target_path = os.path.join(target_directory, name)
            source_metadata = os.lstat(source_path)
            if stat.S_ISLNK(source_metadata.st_mode):
                copy_symlink(source_path, target_path)
            elif stat.S_ISDIR(source_metadata.st_mode):
                copy_directory(source_path, target_path, next_ancestry)
            elif stat.S_ISREG(source_metadata.st_mode):
                stable_copy(
                    source_path,
                    target_path,
                    executable=bool(source_metadata.st_mode & 0o111),
                    track_loader_dependencies=False,
                )
            else:
                fail(f"{label} contains an unsupported object: {source_path}")
        after = os.lstat(canonical)
        after_names = sorted(os.listdir(canonical))
        identity = lambda value: (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )
        if identity(before) != identity(after) or names != after_names:
            fail(f"{label} changed while being materialized: {canonical}")

    copy_directory(source, destination, set())


def require_specific_root(path, required_parts, label):
    canonical = os.path.realpath(path)
    parts = canonical.split(os.sep)
    joined = "/".join(parts)
    if not os.path.isdir(canonical) or required_parts not in joined:
        fail(f"{label} is not the expected bounded compiler-owned root: {canonical}")
    return canonical


def program_path(driver, program, driver_binding):
    value = query(driver, [f"-print-prog-name={program}"], driver_binding)
    if not os.path.isabs(value):
        candidate = os.path.join(os.path.dirname(os.path.realpath(driver)), value)
        if os.path.isfile(candidate):
            value = candidate
    if not os.path.isabs(value) or not os.path.isfile(value):
        fail(f"compiler did not resolve required helper {program} to an absolute file")
    return bind_query_discovered_source(value, f"compiler support program {program}")


def file_path(driver, name, driver_binding):
    value = query(driver, [f"-print-file-name={name}"], driver_binding)
    if value == name or not os.path.isabs(value) or not os.path.exists(value):
        fail(f"compiler did not resolve required resource {name}")
    return bind_query_discovered_source(value, f"compiler support file {name}")


def shell_wrapper(path, driver, common_environment, forced_arguments):
    environment_lines = "\n".join(
        f"export {name}={shlex.quote(value)}" for name, value in sorted(common_environment.items())
    )
    forced = " ".join(shlex.quote(value) for value in forced_arguments)
    payload = f"""#!/bin/bash
set -euo pipefail
{environment_lines}
exec {shlex.quote(driver)} {forced} "$@"
""".encode("utf-8")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, 0o500)
    try:
        os.write(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


if os.path.exists(root):
    fail("compiler capsule root must be fresh")
os.mkdir(root, 0o700)
ensure_construction_directory(root)
runtime_library_root = os.path.join(root, "runtime-libs")
ensure_construction_directory(runtime_library_root)
wrapper_root = os.path.join(root, "bin")
ensure_construction_directory(wrapper_root)

if clang_source != "-" or clangxx_source != "-":
    if clang_source == "-" or clangxx_source == "-":
        fail("Apple Clang capsule requires both clang and clang++")
    clang_binding = bind_discovery_driver(clang_source)
    clangxx_binding = bind_discovery_driver(clangxx_source)
    clang_source = clang_binding["path"]
    clangxx_source = clangxx_binding["path"]
    clang_resource_roots = {
        os.path.realpath(query(clang_source, ["-print-resource-dir"], clang_binding)),
        os.path.realpath(query(clangxx_source, ["-print-resource-dir"], clangxx_binding)),
    }
    if len(clang_resource_roots) != 1:
        fail("clang and clang++ do not share one exact compiler resource directory")
    clang_resource_source = require_specific_root(
        clang_resource_roots.pop(), "/lib/clang/", "Apple Clang resource directory"
    )
    clang_resource = os.path.join(root, "apple-clang", "resource")
    bounded_copy_tree(clang_resource_source, clang_resource, "Apple Clang resource directory")
    clang_sdk_source = query("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"])
    clang_sdk_source = require_specific_root(
        clang_sdk_source, "/SDKs/", "Apple Clang macOS SDK"
    )
    if not os.path.basename(clang_sdk_source).endswith(".sdk"):
        fail("Apple Clang macOS SDK does not identify one exact SDK root")
    clang_sdk = os.path.join(root, "apple-clang", "sdk")
    bounded_copy_tree(clang_sdk_source, clang_sdk, "Apple Clang macOS SDK")
    apple_driver_root = os.path.join(root, "apple-clang", "drivers")
    ensure_construction_directory(apple_driver_root)
    clang_driver = stable_copy(
        clang_source,
        os.path.join(apple_driver_root, "clang"),
        executable=True,
        required_binding=clang_binding,
    )
    clangxx_driver = stable_copy(
        clangxx_source,
        os.path.join(apple_driver_root, "clang++"),
        executable=True,
        required_binding=clangxx_binding,
    )
    apple_helper_root = os.path.join(root, "apple-clang", "helpers")
    ensure_construction_directory(apple_helper_root)
    for helper_name in ("ld", "as"):
        helper = query("/usr/bin/xcrun", ["--find", helper_name])
        if not os.path.isabs(helper) or not os.path.isfile(helper):
            fail(f"xcrun did not resolve required Apple compiler helper: {helper_name}")
        stable_copy(helper, os.path.join(apple_helper_root, helper_name), executable=True)

    common_environment = {
        "PATH": f"{apple_helper_root}:{SYSTEM_PATH}",
        "COMPILER_PATH": apple_helper_root,
        "DYLD_LIBRARY_PATH": runtime_library_root,
        "DYLD_FALLBACK_LIBRARY_PATH": runtime_library_root,
        "SDKROOT": clang_sdk,
        "LC_ALL": "C",
    }
    shell_wrapper(
        os.path.join(wrapper_root, "clang"),
        clang_driver,
        common_environment,
        [f"-resource-dir={clang_resource}", "-isysroot", clang_sdk, f"-B{apple_helper_root}/"],
    )
    shell_wrapper(
        os.path.join(wrapper_root, "clang++"),
        clangxx_driver,
        common_environment,
        [f"-resource-dir={clang_resource}", "-isysroot", clang_sdk, f"-B{apple_helper_root}/"],
    )

if bison_source != "-":
    bison_binding = bind_discovery_driver(bison_source)
    bison_source = bison_binding["path"]
    bison_data_source = require_specific_root(
        query(bison_source, ["--print-datadir"], bison_binding),
        "/share/bison",
        "Bison data directory",
    )
    bison_root = os.path.join(root, "bison")
    bison_data = os.path.join(bison_root, "data")
    bounded_copy_tree(bison_data_source, bison_data, "Bison data directory")
    bison_driver = stable_copy(
        bison_source,
        os.path.join(bison_root, "bison.real"),
        executable=True,
        required_binding=bison_binding,
    )
    shell_wrapper(
        os.path.join(wrapper_root, "bison"),
        bison_driver,
        {"BISON_PKGDATADIR": bison_data, "LC_ALL": "C"},
        [],
    )

if msgfmt_source != "-":
    msgfmt_binding = bind_discovery_driver(msgfmt_source)
    msgfmt_source = msgfmt_binding["path"]
    msgfmt_root = os.path.join(root, "gettext")
    ensure_construction_directory(msgfmt_root)
    msgfmt_driver = stable_copy(
        msgfmt_source,
        os.path.join(msgfmt_root, "msgfmt.real"),
        executable=True,
        required_binding=msgfmt_binding,
    )
    shell_wrapper(
        os.path.join(wrapper_root, "msgfmt"),
        msgfmt_driver,
        {
            "DYLD_LIBRARY_PATH": runtime_library_root,
            "DYLD_FALLBACK_LIBRARY_PATH": runtime_library_root,
            "LC_ALL": "C",
        },
        [],
    )

for source_driver in (value for value in (mingw64_source, mingw32_source) if value != "-"):
    driver_binding = bind_discovery_driver(source_driver)
    source_driver = driver_binding["path"]
    target = query(source_driver, ["-dumpmachine"], driver_binding)
    version = query(source_driver, ["-dumpfullversion", "-dumpversion"], driver_binding)
    if SAFE_TOKEN.fullmatch(target) is None or SAFE_TOKEN.fullmatch(version) is None:
        fail("MinGW compiler returned an unsafe target or version token")
    target_root = os.path.join(root, "mingw", target)
    ensure_construction_directory(os.path.join(target_root, "bin"))
    driver = stable_copy(
        source_driver,
        os.path.join(target_root, "bin", f"{target}-gcc.real"),
        executable=True,
        required_binding=driver_binding,
    )
    helper_root = os.path.join(target_root, "helpers")
    ensure_construction_directory(helper_root)
    compiler_stage_sources = {}
    for helper_name in COMPILER_STAGE_NAMES:
        helper = program_path(source_driver, helper_name, driver_binding)
        compiler_stage_sources[helper_name] = helper
        stable_copy(helper, os.path.join(helper_root, helper_name), executable=True)
    target_helper_drivers = {}
    for helper_name in TARGET_HELPER_NAMES:
        helper = program_path(source_driver, helper_name, driver_binding)
        if helper_name not in compiler_stage_sources:
            stable_copy(helper, os.path.join(helper_root, helper_name), executable=True)
        target_helper_path = os.path.join(helper_root, f"{target}-{helper_name}")
        stable_copy(helper, target_helper_path, executable=True)
        target_helper_drivers[helper_name] = target_helper_path

    compiler_support_root = os.path.join(target_root, "support")
    ensure_construction_directory(compiler_support_root)
    for support_name in COMPILER_SUPPORT_PROGRAM_NAMES:
        support_source = program_path(source_driver, support_name, driver_binding)
        stable_copy(
            support_source,
            os.path.join(compiler_support_root, support_name),
            executable=True,
        )

    libgcc_file = file_path(source_driver, "libgcc.a", driver_binding)
    libgcc_source = require_specific_root(
        os.path.dirname(libgcc_file), f"/lib/gcc/{target}/", "MinGW GCC resource directory"
    )
    libgcc_root = os.path.join(target_root, "lib", "gcc", target, version)
    ensure_construction_directory(os.path.dirname(libgcc_root))
    bounded_copy_tree(libgcc_source, libgcc_root, "MinGW GCC resource directory")

    target_library_file = file_path(source_driver, "libshell32.a", driver_binding)
    target_library_source = require_specific_root(
        os.path.dirname(target_library_file), f"/{target}/lib", "MinGW target library directory"
    )
    target_library_root = os.path.join(target_root, target, "lib")
    ensure_construction_directory(os.path.dirname(target_library_root))
    bounded_copy_tree(target_library_source, target_library_root, "MinGW target library directory")

    include_sources = []
    for include_name in ("include", "include-fixed"):
        value = query(source_driver, [f"-print-file-name={include_name}"], driver_binding)
        if value != include_name and os.path.isabs(value) and os.path.isdir(value):
            include_sources.append(os.path.realpath(value))
    target_include_source = os.path.realpath(os.path.join(target_library_source, "..", "include"))
    if os.path.isdir(target_include_source):
        include_sources.append(target_include_source)
    include_roots = []
    for index, include_source in enumerate(dict.fromkeys(include_sources)):
        include_root = os.path.join(target_root, "includes", f"{index:02d}")
        ensure_construction_directory(os.path.dirname(include_root))
        bounded_copy_tree(include_source, include_root, "MinGW compiler include directory")
        include_roots.append(include_root)
    if not include_roots:
        fail("MinGW compiler exposed no bounded include roots")

    wrapper_environment = {
        "PATH": helper_root,
        "COMPILER_PATH": helper_root,
        "GCC_EXEC_PREFIX": f"{target_root}/lib/gcc/",
        "LIBRARY_PATH": f"{compiler_support_root}:{libgcc_root}:{target_library_root}",
        "DYLD_LIBRARY_PATH": runtime_library_root,
        "DYLD_FALLBACK_LIBRARY_PATH": runtime_library_root,
        "LC_ALL": "C",
    }
    forced_arguments = [
        f"-B{helper_root}/",
        f"-B{compiler_support_root}/",
        f"-B{libgcc_root}/",
        f"-B{target_library_root}/",
        f"--sysroot={target_root}",
        "-nostdinc",
    ]
    for include_root in include_roots:
        forced_arguments.extend(["-isystem", include_root])
    shell_wrapper(
        os.path.join(wrapper_root, f"{target}-gcc"),
        driver,
        wrapper_environment,
        forced_arguments,
    )
    for helper_name, target_helper_driver in sorted(target_helper_drivers.items()):
        shell_wrapper(
            os.path.join(wrapper_root, f"{target}-{helper_name}"),
            target_helper_driver,
            wrapper_environment,
            [],
        )

def macho_filetype(path):
    result = subprocess.run(
        ["/usr/bin/otool", "-hv", path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": SYSTEM_PATH, "LC_ALL": "C"},
        timeout=30,
        check=False,
    )
    if result.returncode != 0 or len(result.stdout) > 1024 * 1024:
        fail(f"compiler capsule Mach-O type discovery failed: {path}")
    lines = result.stdout.decode("utf-8", errors="strict").splitlines()
    for line in lines:
        fields = line.split()
        if fields and fields[0].startswith(("MH_MAGIC", "FAT_")) and len(fields) >= 5:
            return fields[4]
    fail(f"compiler capsule could not parse the Mach-O type: {path}")


def macho_rpaths(path):
    result = subprocess.run(
        ["/usr/bin/otool", "-l", path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": SYSTEM_PATH, "LC_ALL": "C"},
        timeout=30,
        check=False,
    )
    if result.returncode != 0 or len(result.stdout) > 4 * 1024 * 1024:
        fail(f"compiler capsule rpath discovery failed: {path}")
    lines = result.stdout.decode("utf-8", errors="strict").splitlines()
    values = []
    awaiting_path = False
    for line in lines:
        stripped = line.strip()
        if stripped == "cmd LC_RPATH":
            awaiting_path = True
            continue
        if awaiting_path and stripped.startswith("path "):
            value = stripped[5:].split(" (offset ", 1)[0]
            if not value or "\x00" in value:
                fail(f"compiler capsule contains an invalid LC_RPATH: {path}")
            values.append(value)
            awaiting_path = False
    return values


def macho_install_name(path):
    if macho_filetype(path) != "DYLIB":
        return None
    result = subprocess.run(
        ["/usr/bin/otool", "-D", path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": SYSTEM_PATH, "LC_ALL": "C"},
        timeout=30,
        check=False,
    )
    if result.returncode != 0 or len(result.stdout) > 1024 * 1024:
        fail(f"compiler capsule install-name discovery failed: {path}")
    values = [line.strip() for line in result.stdout.decode("utf-8", errors="strict").splitlines()[1:] if line.strip()]
    if len(values) != 1:
        fail(f"compiler capsule dylib does not declare one exact install name: {path}")
    return values[0]


def safe_loader_suffix(value, prefix, path):
    marker = f"{prefix}/"
    if not value.startswith(marker):
        fail(f"compiler capsule contains an unsupported loader reference: {value}")
    suffix = value[len(marker):]
    normalized = os.path.normpath(suffix)
    if not suffix or os.path.isabs(suffix) or normalized in {"", ".", ".."} or normalized.startswith(f"..{os.sep}"):
        fail(f"compiler capsule contains an unsafe loader reference: {value} ({path})")
    return normalized


def loader_root_suffix(value, prefix, path):
    marker = f"{prefix}/"
    if not value.startswith(marker):
        fail(f"compiler capsule contains an unsupported loader root: {value}")
    suffix = value[len(marker):]
    normalized = os.path.normpath(suffix)
    if not suffix or os.path.isabs(suffix) or normalized in {"", "."} or "\x00" in suffix:
        fail(f"compiler capsule contains an unsafe loader root: {value} ({path})")
    return normalized


def expand_loader_root(value, path, filetype):
    if value.startswith("@loader_path/"):
        suffix = loader_root_suffix(value, "@loader_path", path)
        return os.path.realpath(os.path.join(os.path.dirname(path), suffix))
    if value.startswith("@executable_path/"):
        if filetype != "EXECUTE":
            fail(f"non-executable compiler object declares @executable_path: {path}")
        suffix = loader_root_suffix(value, "@executable_path", path)
        return os.path.realpath(os.path.join(os.path.dirname(path), suffix))
    if os.path.isabs(value):
        return os.path.realpath(value)
    fail(f"compiler capsule contains an unsupported LC_RPATH: {value} ({path})")


def resolve_loader_dependency(path, dependency):
    filetype = macho_filetype(path)
    if dependency.startswith("@loader_path/"):
        candidate = expand_loader_root(dependency, path, filetype)
        if not os.path.isfile(candidate):
            fail(f"compiler capsule loader dependency is unavailable: {dependency} ({path})")
        return candidate
    if dependency.startswith("@executable_path/"):
        candidate = expand_loader_root(dependency, path, filetype)
        if not os.path.isfile(candidate):
            fail(f"compiler capsule executable dependency is unavailable: {dependency} ({path})")
        return candidate
    if dependency.startswith("@rpath/"):
        suffix = safe_loader_suffix(dependency, "@rpath", path)
        candidates = set()
        for rpath in macho_rpaths(path):
            root = expand_loader_root(rpath, path, filetype)
            candidate = os.path.realpath(os.path.join(root, suffix))
            if os.path.isfile(candidate):
                candidates.add(candidate)
        if len(candidates) != 1:
            fail(f"compiler capsule could not resolve one exact loader dependency: {dependency} ({path})")
        return candidates.pop()
    fail(f"compiler capsule contains an unresolved mutable loader dependency: {dependency}")


platform_contracts = set()
pending = list(dict.fromkeys(executable_sources))
seen = set()
copied_library_names = {}
while pending:
    executable = pending.pop()
    if executable in seen:
        continue
    seen.add(executable)
    result = subprocess.run(
        ["/usr/bin/otool", "-L", executable],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": SYSTEM_PATH, "LC_ALL": "C"},
        timeout=30,
        check=False,
    )
    if result.returncode != 0 or len(result.stdout) > 4 * 1024 * 1024:
        fail(f"compiler capsule dependency discovery failed: {executable}")
    install_name = macho_install_name(executable)
    for line in result.stdout.decode("utf-8", errors="strict").splitlines()[1:]:
        dependency = line.strip().split(" ", 1)[0]
        if not dependency:
            continue
        if install_name is not None and dependency == install_name:
            continue
        if dependency.startswith(("/usr/lib/", "/System/Library/", "/System/Cryptexes/")):
            platform_contracts.add(dependency)
            continue
        if dependency.startswith("@"):
            dependency = resolve_loader_dependency(executable, dependency)
        if not os.path.isabs(dependency) or not os.path.isfile(dependency):
            fail(f"compiler capsule dependency is not an absolute file: {dependency}")
        canonical = os.path.realpath(dependency)
        basename = os.path.basename(canonical)
        previous = copied_library_names.get(basename)
        if previous is not None and previous != canonical:
            fail(f"compiler capsule mutable libraries collide by basename: {basename}")
        if previous is None:
            stable_copy(canonical, os.path.join(runtime_library_root, basename), executable=True)
            copied_library_names[basename] = canonical
            pending.append(canonical)

contract_path = os.path.join(root, "platform-contracts.json")
contract_payload = (json.dumps(sorted(platform_contracts), separators=(",", ":")) + "\n").encode()
contract_fd = os.open(contract_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, 0o400)
try:
    os.write(contract_fd, contract_payload)
    os.fsync(contract_fd)
finally:
    os.close(contract_fd)

# Rehash exactly the sources whose pathname can name a multiply linked inode,
# every compiler driver whose bytes produced discovery answers, and each file
# or program returned by a compiler query. Other single-link sources retain
# stable before/after copy checks without an unnecessary second full-tree read.
final_source_bindings = dict(hardlink_source_bindings)
for binding_kind, bindings in (
    ("compiler discovery driver", discovery_driver_bindings),
    ("compiler query-discovered source", query_discovered_source_bindings),
):
    for source, binding in bindings.items():
        previous = final_source_bindings.get(source)
        if previous is not None and previous != binding:
            fail(f"{binding_kind} and existing source bindings disagree: {source}")
        final_source_bindings[source] = binding
for source in sorted(final_source_bindings):
    revalidate_source_binding(
        final_source_bindings[source],
        "compiler capsule final source binding",
        verify_digest=True,
    )
freeze_capsule_directories()
PY
  compiler_capsule_manifest capture "$capsule_root" "$manifest" ||
    fail "compiler capsule manifest could not be captured"
  compiler_capsule_manifest verify "$capsule_root" "$manifest" ||
    fail "compiler capsule failed its immediate post-capture verification"
}

materialize_vulkan_development_capsule() {
  local capsule_root="$1"
  local manifest="$2"
  local trusted_prefix="$3"
  local pkg_config="$4"

  /usr/bin/python3 - \
    "$capsule_root" \
    "$trusted_prefix" \
    "$pkg_config" <<'PY'
import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys

root, trusted_prefix, pkg_config = sys.argv[1:]
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
MAXIMUM_ENTRIES = 4096
MAXIMUM_BYTES = 256 * 1024 * 1024
MAXIMUM_FILE_BYTES = 64 * 1024 * 1024


def fail(message):
    raise SystemExit(message)


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


def require_contained(path, label, kind):
    if not os.path.isabs(path) or "\x00" in path:
        fail(f"{label} is not an absolute path")
    canonical = os.path.realpath(path)
    try:
        contained = os.path.commonpath([trusted_prefix, canonical]) == trusted_prefix
    except ValueError:
        contained = False
    if not contained or canonical == trusted_prefix:
        fail(f"{label} resolves outside its trusted installation prefix")
    metadata = os.lstat(canonical)
    if kind == "directory":
        valid = stat.S_ISDIR(metadata.st_mode)
    else:
        valid = stat.S_ISREG(metadata.st_mode) and metadata.st_nlink == 1
    if not valid:
        fail(f"{label} is not a trusted canonical {kind}")
    return canonical


def regular_binding(path, label):
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size < 0
            or before.st_size > MAXIMUM_FILE_BYTES
        ):
            fail(f"{label} is not a bounded single-link regular file")
        digest = hashlib.sha256()
        total = 0
        while total < before.st_size:
            chunk = os.read(descriptor, min(1024 * 1024, before.st_size - total))
            if not chunk:
                fail(f"{label} became incomplete while binding")
            digest.update(chunk)
            total += len(chunk)
        after = os.fstat(descriptor)
        if total != before.st_size or identity(before) != identity(after):
            fail(f"{label} changed while its identity was bound")
        return identity(before), digest.hexdigest()
    finally:
        os.close(descriptor)


def query(arguments, label):
    environment = {
        "PATH": SYSTEM_PATH,
        "LC_ALL": "C",
        "LANG": "C",
        "PKG_CONFIG_PATH": f"{trusted_prefix}/lib/pkgconfig:{trusted_prefix}/share/pkgconfig",
        "PKG_CONFIG_LIBDIR": f"{trusted_prefix}/lib/pkgconfig:{trusted_prefix}/share/pkgconfig",
    }
    result = subprocess.run(
        [pkg_config, *arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        timeout=30,
        check=False,
    )
    if result.returncode != 0 or len(result.stdout) > 1024 * 1024 or len(result.stderr) > 1024 * 1024:
        fail(f"trusted pkg-config could not resolve the Vulkan {label}")
    try:
        value = result.stdout.decode("utf-8").strip()
    except UnicodeDecodeError as error:
        fail(f"trusted pkg-config returned non-UTF-8 Vulkan {label}: {error}")
    if not value or "\n" in value or "\r" in value or "\x00" in value:
        fail(f"trusted pkg-config returned an invalid Vulkan {label}")
    return value


def write_exclusive(path, payload, mode=0o400):
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        mode,
    )
    try:
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                fail(f"Vulkan development capsule write made no progress: {path}")
            view = view[written:]
        os.fsync(descriptor)
        os.fchmod(descriptor, mode)
    finally:
        os.close(descriptor)


entry_count = 0
byte_count = 0
header_file_count = 0


def stable_copy(source, destination):
    global entry_count, byte_count
    source = os.path.realpath(source)
    path_before = os.lstat(source)
    source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        before = os.fstat(source_fd)
        if (
            identity(path_before) != identity(before)
            or not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size < 0
            or before.st_size > MAXIMUM_FILE_BYTES
        ):
            fail(f"Vulkan development input is not a bounded single-link regular file: {source}")
        destination_fd = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o400,
        )
        try:
            digest = hashlib.sha256()
            total = 0
            while total < before.st_size:
                chunk = os.read(source_fd, min(1024 * 1024, before.st_size - total))
                if not chunk:
                    fail(f"Vulkan development input became incomplete: {source}")
                digest.update(chunk)
                view = memoryview(chunk)
                while view:
                    written = os.write(destination_fd, view)
                    if written <= 0:
                        fail(f"Vulkan development capsule copy made no progress: {destination}")
                    view = view[written:]
                total += len(chunk)
            os.fsync(destination_fd)
            os.fchmod(destination_fd, 0o400)
            destination_metadata = os.fstat(destination_fd)
            if (
                not stat.S_ISREG(destination_metadata.st_mode)
                or destination_metadata.st_nlink != 1
                or destination_metadata.st_size != total
                or stat.S_IMODE(destination_metadata.st_mode) != 0o400
            ):
                fail(f"Vulkan development capsule copy is unsafe: {destination}")
        finally:
            os.close(destination_fd)
        after = os.fstat(source_fd)
        path_after = os.lstat(source)
        if identity(before) != identity(after) or identity(before) != identity(path_after):
            fail(f"Vulkan development input changed while being copied: {source}")
    finally:
        os.close(source_fd)
    entry_count += 1
    byte_count += before.st_size
    if entry_count > MAXIMUM_ENTRIES or byte_count > MAXIMUM_BYTES:
        fail("Vulkan development capsule exceeded its deterministic entry or byte bound")
    return digest.hexdigest()


if os.path.exists(root) or os.path.islink(root):
    fail("Vulkan development capsule root must be fresh")
if not os.path.isabs(root) or not os.path.isabs(trusted_prefix) or not os.path.isabs(pkg_config):
    fail("Vulkan development capsule inputs must use absolute paths")
capsule_parent = os.path.realpath(os.path.dirname(root))
if (
    os.path.dirname(os.path.realpath(pkg_config)) != capsule_parent
    or os.path.basename(root) in {"", ".", ".."}
):
    fail("Vulkan development pkg-config must be a sibling private snapshot of its capsule")
trusted_prefix = os.path.realpath(trusted_prefix)
prefix_metadata = os.lstat(trusted_prefix)
if not stat.S_ISDIR(prefix_metadata.st_mode):
    fail("Vulkan development trusted prefix is not a canonical directory")
pkg_config_metadata = os.lstat(pkg_config)
if (
    not stat.S_ISREG(pkg_config_metadata.st_mode)
    or pkg_config_metadata.st_nlink != 1
    or not os.access(pkg_config, os.X_OK)
):
    fail("Vulkan development pkg-config is not a private executable regular file")

version = query(["--modversion", "vulkan"], "module version")
if re.fullmatch(r"[0-9][0-9A-Za-z.+_-]*", version) is None:
    fail("trusted pkg-config returned an unsafe Vulkan module version")
include_query = query(["--variable=includedir", "vulkan"], "include directory")
library_query = query(["--variable=libdir", "vulkan"], "library directory")
pc_query = query(["--variable=pcfiledir", "vulkan"], "pkg-config directory")
include_root = require_contained(
    include_query,
    "Vulkan include directory",
    "directory",
)
library_root = require_contained(
    library_query,
    "Vulkan library directory",
    "directory",
)
pc_root = require_contained(
    pc_query,
    "Vulkan pkg-config directory",
    "directory",
)
pc_source = require_contained(
    os.path.join(pc_root, "vulkan.pc"),
    "Vulkan pkg-config metadata",
    "file",
)
loader_source = require_contained(
    os.path.join(library_root, "libvulkan.dylib"),
    "Vulkan loader development library",
    "file",
)
header_source = require_contained(
    os.path.join(include_root, "vulkan", "vulkan.h"),
    "Vulkan primary header",
    "file",
)

cflags_query = query(["--cflags", "vulkan"], "compiler flags")
libraries_query = query(["--libs", "vulkan"], "linker flags")
pc_binding = regular_binding(pc_source, "Vulkan pkg-config metadata")
query_contract = (
    version,
    include_query,
    library_query,
    pc_query,
    cflags_query,
    libraries_query,
)
revalidated_query_contract = (
    query(["--modversion", "vulkan"], "revalidated module version"),
    query(["--variable=includedir", "vulkan"], "revalidated include directory"),
    query(["--variable=libdir", "vulkan"], "revalidated library directory"),
    query(["--variable=pcfiledir", "vulkan"], "revalidated pkg-config directory"),
    query(["--cflags", "vulkan"], "revalidated compiler flags"),
    query(["--libs", "vulkan"], "revalidated linker flags"),
)
if query_contract != revalidated_query_contract:
    fail("trusted pkg-config Vulkan contract changed during capsule discovery")
if regular_binding(pc_source, "Vulkan pkg-config metadata") != pc_binding:
    fail("Vulkan pkg-config metadata changed during capsule discovery")
if identity(os.lstat(pkg_config)) != identity(pkg_config_metadata):
    fail("Vulkan development pkg-config changed during capsule discovery")

cflags = shlex.split(cflags_query)
libraries = shlex.split(libraries_query)
if (
    len(cflags) != 1
    or not cflags[0].startswith("-I")
    or os.path.realpath(cflags[0][2:]) != include_root
):
    fail("trusted pkg-config Vulkan compiler flags do not name the bound include directory exactly")
library_searches = [token[2:] for token in libraries if token.startswith("-L")]
library_names = [token for token in libraries if token.startswith("-l")]
if (
    len(libraries) != 2
    or len(library_searches) != 1
    or os.path.realpath(library_searches[0]) != library_root
    or library_names != ["-lvulkan"]
):
    fail("trusted pkg-config Vulkan linker flags do not name one exact loader contract")

for command, label in (
    (["/usr/bin/lipo", loader_source, "-verify_arch", "x86_64"], "x86_64 architecture"),
    (["/usr/bin/otool", "-D", loader_source], "Mach-O install name"),
):
    result = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={"PATH": SYSTEM_PATH, "LC_ALL": "C"},
        timeout=30,
        check=False,
    )
    if result.returncode != 0 or len(result.stdout) > 1024 * 1024:
        fail(f"Vulkan loader does not provide the required {label}")
    if command[1] == "-D":
        install_names = [line.strip() for line in result.stdout.decode("utf-8").splitlines()[1:] if line.strip()]
        if len(install_names) != 1 or os.path.basename(install_names[0]) != "libvulkan.1.dylib":
            fail("Vulkan loader does not expose the required libvulkan.1.dylib install name")

os.mkdir(root, 0o700)
capsule_include = os.path.join(root, "include")
capsule_library = os.path.join(root, "lib")
capsule_pkg_config = os.path.join(capsule_library, "pkgconfig")
capsule_metadata = os.path.join(root, "metadata")
for directory in (capsule_include, capsule_library, capsule_pkg_config, capsule_metadata):
    os.mkdir(directory, 0o700)

for directory, directory_names, file_names in os.walk(include_root, followlinks=False):
    directory_names.sort()
    file_names.sort()
    relative_directory = os.path.relpath(directory, include_root)
    destination_directory = capsule_include if relative_directory == "." else os.path.join(capsule_include, relative_directory)
    source_directory_metadata = os.lstat(directory)
    if not stat.S_ISDIR(source_directory_metadata.st_mode):
        fail(f"Vulkan include traversal encountered a non-directory: {directory}")
    for name in directory_names:
        source_path = os.path.join(directory, name)
        if stat.S_ISLNK(os.lstat(source_path).st_mode):
            fail(f"Vulkan include tree contains a symlink directory: {source_path}")
        os.mkdir(os.path.join(destination_directory, name), 0o700)
        entry_count += 1
    for name in file_names:
        source_path = os.path.join(directory, name)
        if stat.S_ISLNK(os.lstat(source_path).st_mode):
            fail(f"Vulkan include tree contains a symlink file: {source_path}")
        stable_copy(source_path, os.path.join(destination_directory, name))
        header_file_count += 1

if not os.path.isfile(os.path.join(capsule_include, "vulkan", "vulkan.h")):
    fail(f"Vulkan include capsule omitted its primary header: {header_source}")
loader_sha256 = stable_copy(loader_source, os.path.join(capsule_library, "libvulkan.1.dylib"))
os.symlink("libvulkan.1.dylib", os.path.join(capsule_library, "libvulkan.dylib"))
pc_sha256 = stable_copy(pc_source, os.path.join(capsule_metadata, "upstream-vulkan.pc"))
if regular_binding(pc_source, "Vulkan pkg-config metadata") != pc_binding or pc_sha256 != pc_binding[1]:
    fail("Vulkan pkg-config metadata changed before its capsule copy was committed")

generated_pc = (
    f"prefix={root}\n"
    "exec_prefix=${prefix}\n"
    "libdir=${prefix}/lib\n"
    "includedir=${prefix}/include\n\n"
    "Name: Vulkan-Loader\n"
    "Description: ForgePlay build-bound Vulkan loader development capsule\n"
    f"Version: {version}\n"
    "Libs: -L${libdir} -lvulkan\n"
    "Cflags: -I${includedir}\n"
).encode("utf-8")
write_exclusive(os.path.join(capsule_pkg_config, "vulkan.pc"), generated_pc)
contract = {
    "schemaVersion": 1,
    "module": "vulkan",
    "version": version,
    "loaderInstallName": "libvulkan.1.dylib",
    "loaderSHA256": loader_sha256,
    "upstreamPkgConfigSHA256": pc_sha256,
    "headerFileCount": header_file_count,
}
write_exclusive(
    os.path.join(capsule_metadata, "contract.json"),
    (json.dumps(contract, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"),
)

for directory, _, _ in os.walk(root, topdown=False, followlinks=False):
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        os.fchmod(descriptor, 0o500)
    finally:
        os.close(descriptor)
PY
  compiler_capsule_manifest capture "$capsule_root" "$manifest" ||
    fail "Vulkan development capsule manifest could not be captured"
  compiler_capsule_manifest verify "$capsule_root" "$manifest" ||
    fail "Vulkan development capsule failed its immediate post-capture verification"
}

if [[ "${1:-}" == "--materialize-compiler-capsule" ]]; then
  [[ "$#" -eq 8 || "$#" -eq 9 ]] ||
    fail "usage: build-forgeplay-wine-runtime.sh --materialize-compiler-capsule <capsule-root> <manifest> <clang-or-dash> <clang++-or-dash> <mingw64-or-dash> <mingw32-or-dash> <bison-or-dash> [msgfmt-or-dash]"
  materialize_compiler_capsule "$2" "$3" "$4" "$5" "$6" "$7" "$8" "${9:--}"
  exit 0
fi

if [[ "${1:-}" == "--materialize-vulkan-development-capsule" ]]; then
  [[ "$#" -eq 5 ]] ||
    fail "usage: build-forgeplay-wine-runtime.sh --materialize-vulkan-development-capsule <capsule-root> <manifest> <trusted-prefix> <pkg-config>"
  materialize_vulkan_development_capsule "$2" "$3" "$4" "$5"
  exit 0
fi

snapshot_regular_input() {
  local source="$1"
  local destination="$2"
  local label="$3"
  local maximum_bytes="$4"
  local expected_identity
  expected_identity="$(regular_file_identity "$source")" ||
    fail "$label identity could not be bound"
  /usr/bin/python3 - \
    "$source" "$destination" "$label" "$maximum_bytes" "$expected_identity" <<'PY'
import os
import stat
import sys

source, destination, label, maximum_text, expected_identity = sys.argv[1:]
maximum = int(maximum_text)
source_fd = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    before = os.fstat(source_fd)
    observed = (
        f"{before.st_dev}:{before.st_ino}:{before.st_nlink}:"
        f"{before.st_size}:{int(before.st_mtime)}:{int(before.st_ctime)}"
    )
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink < 1
        or before.st_size < 0
        or before.st_size > maximum
        or observed != expected_identity
    ):
        raise SystemExit(f"{label} violates its bound input identity")
    destination_fd = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o500,
    )
    try:
        total = 0
        while True:
            chunk = os.read(source_fd, min(1024 * 1024, maximum - total + 1))
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                raise SystemExit(f"{label} exceeded its snapshot bound")
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                if written <= 0:
                    raise SystemExit(f"{label} snapshot write made no progress")
                view = view[written:]
        after = os.fstat(source_fd)
        after_observed = (
            f"{after.st_dev}:{after.st_ino}:{after.st_nlink}:"
            f"{after.st_size}:{int(after.st_mtime)}:{int(after.st_ctime)}"
        )
        if total != before.st_size or after_observed != observed:
            raise SystemExit(f"{label} changed while being snapshotted")
        os.fsync(destination_fd)
        os.fchmod(destination_fd, 0o500)
        destination_metadata = os.fstat(destination_fd)
        if (
            not stat.S_ISREG(destination_metadata.st_mode)
            or destination_metadata.st_nlink != 1
            or destination_metadata.st_size != total
            or stat.S_IMODE(destination_metadata.st_mode) != 0o500
        ):
            raise SystemExit(f"{label} snapshot is not a private executable copy")
    finally:
        os.close(destination_fd)
finally:
    os.close(source_fd)
PY
}

atomic_publish_directory_no_replace() {
  local staged_root="$1"
  local destination_root="$2"
  local expected_stage_identity="$3"
  /usr/bin/python3 - "$staged_root" "$destination_root" "$expected_stage_identity" <<'PY'
import ctypes
import errno
import os
import stat
import sys

source, destination, expected_identity = sys.argv[1:]
source_parent, source_name = os.path.split(source)
destination_parent, destination_name = os.path.split(destination)
if not source_name or not destination_name:
    raise SystemExit("publication basenames must be non-empty")

flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY
source_parent_fd = os.open(source_parent, flags)
destination_parent_fd = os.open(destination_parent, flags)
try:
    source_fd = os.open(source_name, flags, dir_fd=source_parent_fd)
    source_metadata = os.fstat(source_fd)
    source_identity = f"{source_metadata.st_dev}:{source_metadata.st_ino}"
    if not stat.S_ISDIR(source_metadata.st_mode) or source_identity != expected_identity:
        raise SystemExit("publication source identity changed before rename")

    try:
        library = ctypes.CDLL(None, use_errno=True)
        source_bytes = os.fsencode(source_name)
        destination_bytes = os.fsencode(destination_name)
        if sys.platform == "darwin":
            operation = library.renameatx_np
            operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
            operation.restype = ctypes.c_int
            result = operation(
                source_parent_fd,
                source_bytes,
                destination_parent_fd,
                destination_bytes,
                0x00000004,
            )
        elif hasattr(library, "renameat2"):
            operation = library.renameat2
            operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
            operation.restype = ctypes.c_int
            result = operation(
                source_parent_fd,
                source_bytes,
                destination_parent_fd,
                destination_bytes,
                0x00000001,
            )
        else:
            raise SystemExit("platform lacks an approved atomic no-replace rename primitive")
        if result != 0:
            error_number = ctypes.get_errno()
            if error_number == errno.EEXIST:
                raise SystemExit("install root appeared concurrently")
            raise SystemExit(f"atomic no-replace publication failed with errno {error_number}")
        destination_metadata = os.stat(
            destination_name,
            dir_fd=destination_parent_fd,
            follow_symlinks=False,
        )
        descriptor_metadata = os.fstat(source_fd)
        destination_identity = f"{destination_metadata.st_dev}:{destination_metadata.st_ino}"
        descriptor_identity = f"{descriptor_metadata.st_dev}:{descriptor_metadata.st_ino}"
        if destination_identity != expected_identity or descriptor_identity != expected_identity:
            raise SystemExit("published install identity does not match the bound staging directory")
    finally:
        os.close(source_fd)
finally:
    os.close(destination_parent_fd)
    os.close(source_parent_fd)
PY
}

[[ "$#" -eq 3 ]] ||
  fail "usage: build-forgeplay-wine-runtime.sh <patched Wine source root> <new build root> <new install root>"
[[ "$JOBS" =~ ^[1-9][0-9]*$ && "$JOBS" -le 16 ]] ||
  fail "FORGEPLAY_WINE_BUILD_JOBS must be an integer from 1 through 16"
[[ -n "$GSTREAMER_SDK_ROOT" ]] ||
  fail "FORGEPLAY_GSTREAMER_SDK_ROOT must point to the extracted GStreamer 1.0 SDK root"
[[ "$GSTREAMER_SDK_ROOT" = /* ]] ||
  fail "FORGEPLAY_GSTREAMER_SDK_ROOT must be an absolute path"
[[ -d "$GSTREAMER_SDK_ROOT" && ! -L "$GSTREAMER_SDK_ROOT" ]] ||
  fail "GStreamer SDK root must be a non-symlink directory: $GSTREAMER_SDK_ROOT"
reject_symlink_parent_components "$GSTREAMER_SDK_ROOT" "GStreamer SDK root"
GSTREAMER_SDK_ROOT="$(cd "$GSTREAMER_SDK_ROOT" && /bin/pwd -P)"
reject_symlink_parent_components "$GSTREAMER_SDK_ROOT" "GStreamer SDK root"
case "$GSTREAMER_SDK_ROOT" in
  *[[:space:]]*) fail "GStreamer SDK root must not contain whitespace" ;;
esac
GSTREAMER_SDK_BOUND_DIRECTORIES=(
  "$GSTREAMER_SDK_ROOT"
  "$GSTREAMER_SDK_ROOT/bin"
  "$GSTREAMER_SDK_ROOT/include"
  "$GSTREAMER_SDK_ROOT/include/gstreamer-1.0"
  "$GSTREAMER_SDK_ROOT/lib"
  "$GSTREAMER_SDK_ROOT/lib/pkgconfig"
)
GSTREAMER_SDK_BOUND_IDENTITIES=()
for gstreamer_sdk_directory in "${GSTREAMER_SDK_BOUND_DIRECTORIES[@]}"; do
  [[ -d "$gstreamer_sdk_directory" && ! -L "$gstreamer_sdk_directory" ]] ||
    fail "GStreamer SDK intermediate must be a non-symlink directory: $gstreamer_sdk_directory"
  GSTREAMER_SDK_BOUND_IDENTITIES+=("$(directory_identity "$gstreamer_sdk_directory")")
done
for gstreamer_sdk_file in \
  "$GSTREAMER_SDK_ROOT/bin/pkg-config" \
  "$GSTREAMER_SDK_ROOT/include/gstreamer-1.0/gst/gst.h" \
  "$GSTREAMER_SDK_ROOT/lib/libgstreamer-1.0.0.dylib" \
  "$GSTREAMER_SDK_ROOT/lib/pkgconfig/gstreamer-1.0.pc"; do
  reject_symlink_descendant_components \
    "$GSTREAMER_SDK_ROOT" \
    "$gstreamer_sdk_file" \
    "required GStreamer SDK file"
  [[ -f "$gstreamer_sdk_file" && ! -L "$gstreamer_sdk_file" ]] ||
    fail "required GStreamer SDK file is unavailable: $gstreamer_sdk_file"
done
/usr/bin/lipo "$GSTREAMER_SDK_ROOT/lib/libgstreamer-1.0.0.dylib" -verify_arch x86_64 ||
  fail "GStreamer SDK does not provide the required x86_64 runtime architecture"
GSTREAMER_PKG_CONFIG_PATH="$GSTREAMER_SDK_ROOT/lib/pkgconfig"

for required_tool in "$SOURCE_VALIDATOR" "$BUILD_PATH_VERIFIER"; do
  [[ -f "$required_tool" && ! -L "$required_tool" ]] ||
    fail "required build tool must be a non-symlink file: $required_tool"
done
[[ "$HOMEBREW_X86_PREFIX" = /* ]] ||
  fail "FORGEPLAY_HOMEBREW_X86_PREFIX must be an absolute path"
reject_symlink_parent_components "$HOMEBREW_X86_PREFIX" "Homebrew x86 prefix"
for cross_compiler in \
  "$HOMEBREW_X86_PREFIX/bin/x86_64-w64-mingw32-gcc" \
  "$HOMEBREW_X86_PREFIX/bin/i686-w64-mingw32-gcc"; do
  [[ -x "$cross_compiler" ]] || fail "required MinGW cross-compiler is unavailable: $cross_compiler"
done
MINGW64_INPUT="$(resolve_trusted_tool_input \
  "$HOMEBREW_X86_PREFIX/bin/x86_64-w64-mingw32-gcc" \
  "$HOMEBREW_X86_PREFIX" \
  "MinGW x86_64 compiler")" || fail "unable to bind the MinGW x86_64 compiler"
MINGW32_INPUT="$(resolve_trusted_tool_input \
  "$HOMEBREW_X86_PREFIX/bin/i686-w64-mingw32-gcc" \
  "$HOMEBREW_X86_PREFIX" \
  "MinGW i686 compiler")" || fail "unable to bind the MinGW i686 compiler"
HOMEBREW_PKG_CONFIG="$(resolve_trusted_tool_input \
  "$HOMEBREW_X86_PREFIX/bin/pkg-config" \
  "$HOMEBREW_X86_PREFIX" \
  "x86_64 Homebrew pkg-config")" || fail "unable to bind x86_64 Homebrew pkg-config"
[[ "$MSGFMT_INPUT" = /* ]] ||
  fail "FORGEPLAY_MSGFMT must be an absolute path"
MSGFMT_INPUT="$(resolve_trusted_tool_input \
  "$MSGFMT_INPUT" \
  "$HOMEBREW_X86_PREFIX" \
  "Wine translation msgfmt")" || fail "unable to bind Wine translation msgfmt"
HOMEBREW_PKG_CONFIG_PATH="$HOMEBREW_X86_PREFIX/lib/pkgconfig:$HOMEBREW_X86_PREFIX/share/pkgconfig"

[[ -d "$SOURCE_INPUT" && ! -L "$SOURCE_INPUT" ]] ||
  fail "patched Wine source root must be a non-symlink directory: $SOURCE_INPUT"
[[ "$SOURCE_INPUT" = /* && "$BUILD_INPUT" = /* && "$INSTALL_INPUT" = /* ]] ||
  fail "source, build, and install roots must be absolute paths"
reject_symlink_parent_components "$SOURCE_INPUT" "patched Wine source root"
reject_symlink_parent_components "$BUILD_INPUT" "build root"
reject_symlink_parent_components "$INSTALL_INPUT" "install root"
SOURCE_ROOT="$(cd "$SOURCE_INPUT" && /bin/pwd -P)"
BUILD_PARENT="$(cd "$(/usr/bin/dirname "$BUILD_INPUT")" && /bin/pwd -P)"
BUILD_BASENAME="$(/usr/bin/basename "$BUILD_INPUT")"
INSTALL_PARENT="$(cd "$(/usr/bin/dirname "$INSTALL_INPUT")" && /bin/pwd -P)"
INSTALL_BASENAME="$(/usr/bin/basename "$INSTALL_INPUT")"
[[ -n "$BUILD_BASENAME" && "$BUILD_BASENAME" != "." && "$BUILD_BASENAME" != ".." ]] ||
  fail "build root basename is unsafe"
[[ -n "$INSTALL_BASENAME" && "$INSTALL_BASENAME" != "." && "$INSTALL_BASENAME" != ".." ]] ||
  fail "install root basename is unsafe"
BUILD_ROOT="$BUILD_PARENT/$BUILD_BASENAME"
INSTALL_ROOT="$INSTALL_PARENT/$INSTALL_BASENAME"
reject_symlink_parent_components "$SOURCE_ROOT" "patched Wine source root"
reject_symlink_parent_components "$BUILD_ROOT" "build root"
reject_symlink_parent_components "$INSTALL_ROOT" "install root"
case "$SOURCE_ROOT$BUILD_ROOT$INSTALL_ROOT" in
  *[[:space:]]*) fail "source, build, and install roots must not contain whitespace" ;;
esac
[[ ! -e "$BUILD_ROOT" && ! -L "$BUILD_ROOT" ]] || fail "build root already exists: $BUILD_ROOT"
[[ ! -e "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]] || fail "install root already exists: $INSTALL_ROOT"

/usr/bin/python3 - "$SOURCE_ROOT" "$BUILD_ROOT" "$INSTALL_ROOT" "$REPO_ROOT" <<'PY' ||
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

BUILD_PARENT_ID="$(directory_identity "$BUILD_PARENT")" ||
  fail "build parent identity is unavailable"
/bin/mkdir "$BUILD_ROOT"
BUILD_ROOT_ID="$(directory_identity "$BUILD_ROOT")" ||
  fail "build root identity is unavailable"
[[ "$(directory_identity "$BUILD_PARENT")" == "$BUILD_PARENT_ID" ]] ||
  fail "build parent changed while the build root was created"
TOOL_SNAPSHOT_ROOT="$BUILD_ROOT/.forgeplay-tool-snapshots"
/bin/mkdir -m 700 "$TOOL_SNAPSHOT_ROOT"
TOOL_SNAPSHOT_ROOT_ID="$(directory_identity "$TOOL_SNAPSHOT_ROOT")" ||
  fail "tool snapshot root identity is unavailable"
[[ "$(directory_identity "$BUILD_ROOT")" == "$BUILD_ROOT_ID" ]] ||
  fail "build root changed while the tool snapshot root was created"
SOURCE_VALIDATOR_SNAPSHOT="$TOOL_SNAPSHOT_ROOT/package-forgeplay-runtime.sh"
BUILD_PATH_VERIFIER_SNAPSHOT="$TOOL_SNAPSHOT_ROOT/verify-wine-runtime-build-paths.py"
RUNTIME_DEPENDENCY_LOCK_SNAPSHOT="$TOOL_SNAPSHOT_ROOT/runtime-dependencies.lock.json"
snapshot_regular_input \
  "$SOURCE_VALIDATOR" \
  "$SOURCE_VALIDATOR_SNAPSHOT" \
  "Wine source validator" \
  8388608
snapshot_regular_input \
  "$BUILD_PATH_VERIFIER" \
  "$BUILD_PATH_VERIFIER_SNAPSHOT" \
  "Wine build-path verifier" \
  8388608
snapshot_regular_input \
  "$RUNTIME_DEPENDENCY_LOCK" \
  "$RUNTIME_DEPENDENCY_LOCK_SNAPSHOT" \
  "runtime dependency lock" \
  4194304
GSTREAMER_SDK_FILE_MANIFEST="$BUILD_ROOT/.forgeplay-gstreamer-sdk-files.json"
gstreamer_file_manifest \
  capture \
  "$GSTREAMER_SDK_ROOT" \
  "$GSTREAMER_SDK_FILE_MANIFEST" ||
  fail "GStreamer SDK file identities could not be captured"

XCRUN_CLANG="$(PATH="$FORGEPLAY_SYSTEM_TOOL_PATH" /usr/bin/xcrun --find clang)" ||
  fail "unable to resolve the platform clang through xcrun"
XCRUN_CLANGXX="$(PATH="$FORGEPLAY_SYSTEM_TOOL_PATH" /usr/bin/xcrun --find clang++)" ||
  fail "unable to resolve the platform clang++ through xcrun"
ORIGINAL_CLANG="$(resolve_xcode_compiler_input "$XCRUN_CLANG" "platform clang")" ||
  fail "unable to bind the platform clang executable"
ORIGINAL_CLANGXX="$(resolve_xcode_compiler_input "$XCRUN_CLANGXX" "platform clang++")" ||
  fail "unable to bind the platform clang++ executable"
[[ "$BISON_INPUT" = /* ]] ||
  fail "FORGEPLAY_BISON must be an absolute path"
ORIGINAL_BISON="$(
  cd "$(/usr/bin/dirname "$BISON_INPUT")" &&
    printf '%s/%s\n' "$(/bin/pwd -P)" "$(/usr/bin/basename "$BISON_INPUT")"
)" || fail "unable to resolve the canonical Bison executable"
ORIGINAL_MSGFMT="$MSGFMT_INPUT"
for tool in \
  "$ORIGINAL_CLANG" \
  "$ORIGINAL_CLANGXX" \
  "$ORIGINAL_BISON" \
  "$ORIGINAL_MSGFMT" \
  /usr/bin/make \
  "$MINGW64_INPUT" \
  "$MINGW32_INPUT" \
  "$HOMEBREW_PKG_CONFIG" \
  "$GSTREAMER_SDK_ROOT/bin/pkg-config"; do
  [[ "$tool" = /* && -x "$tool" && -f "$tool" && ! -L "$tool" ]] ||
    fail "build tool capsule input is unsafe: $tool"
  reject_symlink_parent_components "$tool" "build tool capsule input"
done

COMPILER_CAPSULE_ROOT="$TOOL_SNAPSHOT_ROOT/compiler-capsule"
COMPILER_CAPSULE_MANIFEST="$BUILD_ROOT/.forgeplay-compiler-capsule.json"
materialize_compiler_capsule \
  "$COMPILER_CAPSULE_ROOT" \
  "$COMPILER_CAPSULE_MANIFEST" \
  "$ORIGINAL_CLANG" \
  "$ORIGINAL_CLANGXX" \
  "$MINGW64_INPUT" \
  "$MINGW32_INPUT" \
  "$ORIGINAL_BISON" \
  "$ORIGINAL_MSGFMT"
CLANG="$COMPILER_CAPSULE_ROOT/bin/clang"
CLANGXX="$COMPILER_CAPSULE_ROOT/bin/clang++"
PINNED_BISON="$COMPILER_CAPSULE_ROOT/bin/bison"
PINNED_MSGFMT="$COMPILER_CAPSULE_ROOT/bin/msgfmt"
PINNED_MAKE=/usr/bin/make
PINNED_MINGW64="$COMPILER_CAPSULE_ROOT/bin/x86_64-w64-mingw32-gcc"
PINNED_MINGW32="$COMPILER_CAPSULE_ROOT/bin/i686-w64-mingw32-gcc"
PINNED_HOMEBREW_PKG_CONFIG="$TOOL_SNAPSHOT_ROOT/homebrew-pkg-config"
PINNED_GSTREAMER_PKG_CONFIG="$TOOL_SNAPSHOT_ROOT/gstreamer-pkg-config"
snapshot_regular_input "$HOMEBREW_PKG_CONFIG" "$PINNED_HOMEBREW_PKG_CONFIG" "Homebrew pkg-config" 268435456
snapshot_regular_input "$GSTREAMER_SDK_ROOT/bin/pkg-config" "$PINNED_GSTREAMER_PKG_CONFIG" "GStreamer pkg-config" 268435456
VULKAN_DEVELOPMENT_CAPSULE_ROOT="$TOOL_SNAPSHOT_ROOT/vulkan-development"
VULKAN_DEVELOPMENT_CAPSULE_MANIFEST="$BUILD_ROOT/.forgeplay-vulkan-development-capsule.json"
materialize_vulkan_development_capsule \
  "$VULKAN_DEVELOPMENT_CAPSULE_ROOT" \
  "$VULKAN_DEVELOPMENT_CAPSULE_MANIFEST" \
  "$HOMEBREW_X86_PREFIX" \
  "$PINNED_HOMEBREW_PKG_CONFIG"
validate_vulkan_capsule_dependency_lock \
  "$VULKAN_DEVELOPMENT_CAPSULE_ROOT" \
  "$VULKAN_DEVELOPMENT_CAPSULE_MANIFEST" \
  "$RUNTIME_DEPENDENCY_LOCK_SNAPSHOT" ||
  fail "Vulkan development capsule does not match the packaged dependency lock"
VULKAN_PKG_CONFIG_PATH="$VULKAN_DEVELOPMENT_CAPSULE_ROOT/lib/pkgconfig"
WINE_CONFIGURE_PKG_CONFIG_PATH="$GSTREAMER_PKG_CONFIG_PATH:$VULKAN_PKG_CONFIG_PATH:$HOMEBREW_PKG_CONFIG_PATH"
TOOL_CAPSULE_MANIFEST="$BUILD_ROOT/.forgeplay-build-tool-capsule.json"
gstreamer_file_manifest \
  capture \
  "$TOOL_SNAPSHOT_ROOT" \
  "$TOOL_CAPSULE_MANIFEST" ||
  fail "build tool capsule identities could not be captured"

for gstreamer_package in \
  gstreamer-1.0 \
  gstreamer-video-1.0 \
  gstreamer-audio-1.0 \
  gstreamer-tag-1.0; do
  PKG_CONFIG_PATH="$GSTREAMER_PKG_CONFIG_PATH" \
    "$PINNED_GSTREAMER_PKG_CONFIG" --exists "$gstreamer_package" ||
    fail "GStreamer SDK is missing required pkg-config package: $gstreamer_package"
done
PKG_CONFIG_PATH="$WINE_CONFIGURE_PKG_CONFIG_PATH" \
  PKG_CONFIG_LIBDIR="$WINE_CONFIGURE_PKG_CONFIG_PATH" \
  "$PINNED_GSTREAMER_PKG_CONFIG" --exists gnutls ||
  fail "x86_64 GnuTLS is unavailable to the Wine configure boundary"
FREETYPE_CFLAGS="$(
  PKG_CONFIG_PATH="$HOMEBREW_PKG_CONFIG_PATH" \
    "$PINNED_HOMEBREW_PKG_CONFIG" --cflags freetype2
)" || fail "unable to resolve the x86_64 Homebrew FreeType build flags"
FREETYPE_LIBS="$(
  PKG_CONFIG_PATH="$HOMEBREW_PKG_CONFIG_PATH" \
    "$PINNED_HOMEBREW_PKG_CONFIG" --libs freetype2
)" || fail "unable to resolve the x86_64 Homebrew FreeType linker flags"
VULKAN_CFLAGS="-I$VULKAN_DEVELOPMENT_CAPSULE_ROOT/include"
VULKAN_LDFLAGS="-L$VULKAN_DEVELOPMENT_CAPSULE_ROOT/lib"
[[ "$(
    PKG_CONFIG_PATH="$VULKAN_PKG_CONFIG_PATH" \
      PKG_CONFIG_LIBDIR="$VULKAN_PKG_CONFIG_PATH" \
      "$PINNED_HOMEBREW_PKG_CONFIG" --cflags vulkan
  )" == "$VULKAN_CFLAGS" ]] ||
  fail "Vulkan development capsule compiler contract is not exact"
[[ "$(
    PKG_CONFIG_PATH="$VULKAN_PKG_CONFIG_PATH" \
      PKG_CONFIG_LIBDIR="$VULKAN_PKG_CONFIG_PATH" \
      "$PINNED_HOMEBREW_PKG_CONFIG" --libs vulkan
  )" == "$VULKAN_LDFLAGS -lvulkan" ]] ||
  fail "Vulkan development capsule linker contract is not exact"
gstreamer_file_manifest \
  verify \
  "$TOOL_SNAPSHOT_ROOT" \
  "$TOOL_CAPSULE_MANIFEST" ||
  fail "build tool capsule changed during configuration discovery"

validate_ordered_patch_contract || fail "ordered runtime patch contract is invalid"
PATH="$FORGEPLAY_SYSTEM_TOOL_PATH" \
  FORGEPLAY_WINE_SOURCE="$SOURCE_ROOT" \
  FORGEPLAY_VALIDATION_SCRIPT_DIR="$SCRIPT_DIR" \
  /bin/bash "$SOURCE_VALIDATOR_SNAPSHOT" --validate-wine-source

INSTALL_PARENT_ID="$(directory_identity "$INSTALL_PARENT")" ||
  fail "install parent identity is unavailable"
INSTALL_STAGE="$(/usr/bin/mktemp -d "$INSTALL_PARENT/.${INSTALL_BASENAME}.forgeplay-install.XXXXXXXX")" ||
  fail "unable to create a private install staging root"
/bin/chmod 700 "$INSTALL_STAGE" || fail "unable to protect the install staging root"
INSTALL_STAGE_ID="$(directory_identity "$INSTALL_STAGE")" ||
  fail "install staging identity is unavailable"
[[ "$(directory_identity "$INSTALL_PARENT")" == "$INSTALL_PARENT_ID" ]] ||
  fail "install parent changed while staging was created"

cleanup() {
  [[ -n "${INSTALL_STAGE:-}" && -n "${INSTALL_STAGE_ID:-}" ]] || return 0
  [[ -d "$INSTALL_STAGE" && ! -L "$INSTALL_STAGE" ]] || return 0
  if [[ "$(directory_identity "$INSTALL_STAGE" || true)" != "$INSTALL_STAGE_ID" ]]; then
    printf 'warning: refusing to clean a substituted install staging root: %s\n' \
      "$INSTALL_STAGE" >&2
    return 0
  fi
  if [[ "$(directory_identity "$INSTALL_PARENT" || true)" != "$INSTALL_PARENT_ID" ]]; then
    printf 'warning: refusing to clean through a substituted install parent: %s\n' \
      "$INSTALL_PARENT" >&2
    return 0
  fi
  /bin/rm -rf -- "$INSTALL_STAGE"
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
    /usr/bin/find \
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
  if ! /usr/bin/otool -l "$winegstreamer" 2>/dev/null |
      /usr/bin/awk '/cmd LC_RPATH/{seen=1; next} seen && /path /{print $2; seen=0}' |
      /usr/bin/grep -Fxq '@loader_path/../../../gstreamer/lib'; then
    /usr/bin/install_name_tool \
      -add_rpath '@loader_path/../../../gstreamer/lib' \
      "$winegstreamer" ||
      fail "unable to add the isolated GStreamer runtime search path"
  fi
}

# A full Wine install intentionally contains compiler/development front-ends.
# ForgePlay's distributed Runtime does not. Remove only the same explicit
# denylist enforced by the canonical packager before scanning the install tree
# for embedded developer-machine paths. Keeping this list local to the clean
# builder makes the published install root itself package-ready while the
# packager's exact runtime-bin allowlist remains the final authority.
prune_development_only_wine_bin_entries() {
  local install_root="$1"
  local bin_root="$install_root/bin"
  local name path
  local development_only_entries=(
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

  [[ -d "$bin_root" && ! -L "$bin_root" ]] ||
    fail "installed Wine bin root is missing or unsafe: $bin_root"
  for name in "${development_only_entries[@]}"; do
    path="$bin_root/$name"
    if [[ -e "$path" || -L "$path" ]]; then
      [[ -f "$path" || -L "$path" ]] ||
        fail "development-only Wine entry is not a removable file: $path"
      /bin/rm -f -- "$path"
    fi
    [[ ! -e "$path" && ! -L "$path" ]] ||
      fail "development-only Wine entry remained after clean install normalization: $path"
  done
}

BUILD_TOOL_PATH="$COMPILER_CAPSULE_ROOT/bin:$TOOL_SNAPSHOT_ROOT:$FORGEPLAY_SYSTEM_TOOL_PATH"
PATH_MAP_FLAGS="-g -O2 -ffile-prefix-map=$SOURCE_ROOT=wine-11.12/source -ffile-prefix-map=$BUILD_ROOT=wine-11.12/build"
CLANG_ID="$(/usr/bin/stat -f '%d:%i:%z:%m:%c' "$CLANG")" ||
  fail "unable to bind the platform clang identity"
CLANGXX_ID="$(/usr/bin/stat -f '%d:%i:%z:%m:%c' "$CLANGXX")" ||
  fail "unable to bind the platform clang++ identity"
PLATFORM_MAKE_ID="$(regular_file_identity "$PINNED_MAKE")" ||
  fail "unable to bind the platform Make identity"

(
  cd "$BUILD_ROOT"
  for ((gstreamer_index = 0; gstreamer_index < ${#GSTREAMER_SDK_BOUND_DIRECTORIES[@]}; gstreamer_index++)); do
    [[ "$(directory_identity "${GSTREAMER_SDK_BOUND_DIRECTORIES[$gstreamer_index]}")" == "${GSTREAMER_SDK_BOUND_IDENTITIES[$gstreamer_index]}" ]] ||
      fail "GStreamer SDK intermediate changed before configure"
  done
  [[ "$(/usr/bin/stat -f '%d:%i:%z:%m:%c' "$CLANG")" == "$CLANG_ID" &&
     "$(/usr/bin/stat -f '%d:%i:%z:%m:%c' "$CLANGXX")" == "$CLANGXX_ID" ]] ||
    fail "platform compiler identity changed before configure"
  [[ "$(regular_file_identity "$PINNED_MAKE")" == "$PLATFORM_MAKE_ID" ]] ||
    fail "platform Make identity changed before configure"
  gstreamer_file_manifest \
    verify \
    "$GSTREAMER_SDK_ROOT" \
    "$GSTREAMER_SDK_FILE_MANIFEST" ||
    fail "GStreamer SDK files changed before configure"
  gstreamer_file_manifest \
    verify \
    "$TOOL_SNAPSHOT_ROOT" \
    "$TOOL_CAPSULE_MANIFEST" ||
    fail "build tool capsule changed before configure"
  compiler_capsule_manifest \
    verify \
    "$COMPILER_CAPSULE_ROOT" \
    "$COMPILER_CAPSULE_MANIFEST" ||
    fail "compiler helper/resource capsule changed before configure"
  compiler_capsule_manifest \
    verify \
    "$VULKAN_DEVELOPMENT_CAPSULE_ROOT" \
    "$VULKAN_DEVELOPMENT_CAPSULE_MANIFEST" ||
    fail "Vulkan development capsule changed before configure"
  validate_vulkan_capsule_dependency_lock \
    "$VULKAN_DEVELOPMENT_CAPSULE_ROOT" \
    "$VULKAN_DEVELOPMENT_CAPSULE_MANIFEST" \
    "$RUNTIME_DEPENDENCY_LOCK_SNAPSHOT" ||
    fail "Vulkan development capsule diverged from the packaged dependency lock before configure"
  PATH="$BUILD_TOOL_PATH" \
  CC="$CLANG -arch x86_64" \
  CXX="$CLANGXX -arch x86_64" \
  CFLAGS="$PATH_MAP_FLAGS" \
  CXXFLAGS="$PATH_MAP_FLAGS" \
  OBJCFLAGS="$PATH_MAP_FLAGS" \
  CROSSCFLAGS="$PATH_MAP_FLAGS" \
  CPPFLAGS="$VULKAN_CFLAGS" \
  LDFLAGS="$VULKAN_LDFLAGS" \
  FREETYPE_CFLAGS="$FREETYPE_CFLAGS" \
  FREETYPE_LIBS="$FREETYPE_LIBS" \
  MSGFMT="$PINNED_MSGFMT" \
  PKG_CONFIG="$PINNED_GSTREAMER_PKG_CONFIG" \
  PKG_CONFIG_PATH="$WINE_CONFIGURE_PKG_CONFIG_PATH" \
  PKG_CONFIG_LIBDIR="$WINE_CONFIGURE_PKG_CONFIG_PATH" \
    "$SOURCE_ROOT/configure" \
      --prefix="$LOGICAL_PREFIX" \
      --host=x86_64-apple-darwin \
      --enable-win64 \
      --enable-archs=i386,x86_64 \
      --disable-tests \
      --with-vulkan \
      --without-x --without-alsa --without-capi --without-cups --without-dbus \
      --without-ffmpeg --without-gphoto --without-gssapi \
      --without-inotify --without-krb5 --without-netapi --without-opencl \
      --without-oss --without-pcap --without-pcsclite --without-pulse \
      --without-sane --without-sdl --without-udev --without-usb --without-v4l2 \
      --without-wayland
  validate_vulkan_configure_result "$BUILD_ROOT"
  PATH="$BUILD_TOOL_PATH" \
    "$PINNED_MAKE" -j"$JOBS"
  PATH="$BUILD_TOOL_PATH" \
    "$PINNED_MAKE" -j"$JOBS" DESTDIR="$INSTALL_STAGE" install
)

STAGED_INSTALL_ROOT="$INSTALL_STAGE$LOGICAL_PREFIX"
[[ -x "$STAGED_INSTALL_ROOT/bin/wine" && -x "$STAGED_INSTALL_ROOT/bin/wineserver" ]] ||
  fail "clean Wine install did not produce the required launchers: $STAGED_INSTALL_ROOT"
PATH="$FORGEPLAY_SYSTEM_TOOL_PATH" \
  FORGEPLAY_VALIDATION_SCRIPT_DIR="$SCRIPT_DIR" \
  /bin/bash "$SOURCE_VALIDATOR_SNAPSHOT" \
    --validate-wine-runtime-payload \
    "$STAGED_INSTALL_ROOT" ||
  fail "clean Wine install is missing a runtime-required component or canonical language resource"
for ((gstreamer_index = 0; gstreamer_index < ${#GSTREAMER_SDK_BOUND_DIRECTORIES[@]}; gstreamer_index++)); do
  [[ "$(directory_identity "${GSTREAMER_SDK_BOUND_DIRECTORIES[$gstreamer_index]}")" == "${GSTREAMER_SDK_BOUND_IDENTITIES[$gstreamer_index]}" ]] ||
    fail "GStreamer SDK intermediate changed during the build"
done
gstreamer_file_manifest \
  verify \
  "$GSTREAMER_SDK_ROOT" \
  "$GSTREAMER_SDK_FILE_MANIFEST" ||
  fail "GStreamer SDK files changed during the build"
gstreamer_file_manifest \
  verify \
  "$TOOL_SNAPSHOT_ROOT" \
  "$TOOL_CAPSULE_MANIFEST" ||
  fail "build tool capsule changed during the build"
compiler_capsule_manifest \
  verify \
  "$COMPILER_CAPSULE_ROOT" \
  "$COMPILER_CAPSULE_MANIFEST" ||
  fail "compiler helper/resource capsule changed during the build"
compiler_capsule_manifest \
  verify \
  "$VULKAN_DEVELOPMENT_CAPSULE_ROOT" \
  "$VULKAN_DEVELOPMENT_CAPSULE_MANIFEST" ||
  fail "Vulkan development capsule changed during the build"
validate_vulkan_capsule_dependency_lock \
  "$VULKAN_DEVELOPMENT_CAPSULE_ROOT" \
  "$VULKAN_DEVELOPMENT_CAPSULE_MANIFEST" \
  "$RUNTIME_DEPENDENCY_LOCK_SNAPSHOT" ||
  fail "Vulkan development capsule diverged from the packaged dependency lock during the build"
[[ "$(regular_file_identity "$PINNED_MAKE")" == "$PLATFORM_MAKE_ID" ]] ||
  fail "platform Make identity changed during the build"
STAGED_INSTALL_ROOT_ID="$(directory_identity "$STAGED_INSTALL_ROOT")" ||
  fail "installed runtime staging identity is unavailable"
strip_installed_macho_debug_symbols "$STAGED_INSTALL_ROOT"
normalize_installed_winegstreamer_search_path "$STAGED_INSTALL_ROOT"
prune_development_only_wine_bin_entries "$STAGED_INSTALL_ROOT"
PATH="$FORGEPLAY_SYSTEM_TOOL_PATH" /usr/bin/python3 "$BUILD_PATH_VERIFIER_SNAPSHOT" \
  "$STAGED_INSTALL_ROOT/bin" \
  "$STAGED_INSTALL_ROOT/lib/wine"
[[ "$(directory_identity "$BUILD_PARENT")" == "$BUILD_PARENT_ID" &&
   "$(directory_identity "$BUILD_ROOT")" == "$BUILD_ROOT_ID" &&
   "$(directory_identity "$TOOL_SNAPSHOT_ROOT")" == "$TOOL_SNAPSHOT_ROOT_ID" ]] ||
  fail "owned tool snapshot cleanup identity changed before thaw"
thaw_owned_tool_snapshot_for_removal \
  "$TOOL_SNAPSHOT_ROOT" \
  "$TOOL_SNAPSHOT_ROOT_ID" \
  "$BUILD_ROOT" \
  "$BUILD_ROOT_ID" \
  "$BUILD_PARENT" \
  "$BUILD_PARENT_ID" ||
  fail "owned tool snapshot directories could not be thawed for cleanup"
[[ "$(directory_identity "$BUILD_PARENT")" == "$BUILD_PARENT_ID" &&
   "$(directory_identity "$BUILD_ROOT")" == "$BUILD_ROOT_ID" &&
   "$(directory_identity "$TOOL_SNAPSHOT_ROOT")" == "$TOOL_SNAPSHOT_ROOT_ID" ]] ||
  fail "owned tool snapshot cleanup identity changed after thaw"
/bin/rm -rf -- "$TOOL_SNAPSHOT_ROOT"
[[ ! -e "$TOOL_SNAPSHOT_ROOT" && ! -L "$TOOL_SNAPSHOT_ROOT" ]] ||
  fail "owned tool snapshot root remained after cleanup"
[[ "$(directory_identity "$INSTALL_PARENT")" == "$INSTALL_PARENT_ID" ]] ||
  fail "install parent changed before publication"
[[ ! -e "$INSTALL_ROOT" && ! -L "$INSTALL_ROOT" ]] ||
  fail "install root appeared before publication"
[[ "$(directory_identity "$STAGED_INSTALL_ROOT")" == "$STAGED_INSTALL_ROOT_ID" ]] ||
  fail "installed runtime staging identity changed before publication"
atomic_publish_directory_no_replace \
  "$STAGED_INSTALL_ROOT" \
  "$INSTALL_ROOT" \
  "$STAGED_INSTALL_ROOT_ID" ||
  fail "atomic no-replace install publication failed"
trap - EXIT
cleanup

printf 'Built clean ForgePlay Wine Runtime install root: %s\n' "$INSTALL_ROOT"
