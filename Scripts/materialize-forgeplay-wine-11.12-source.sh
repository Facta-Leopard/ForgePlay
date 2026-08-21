#!/bin/bash
set -euo pipefail

readonly FORGEPLAY_SYSTEM_TOOL_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PATH="$FORGEPLAY_SYSTEM_TOOL_PATH"
export PATH
unset CDPATH

SCRIPT_DIR="$(cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && /bin/pwd -P)"
MANIFEST="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/RuntimeManifest.json"
SOURCE_AVAILABILITY="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/SOURCE-AVAILABILITY.md"
PROVENANCE_LOCK="$REPO_ROOT/Config/ForgePlayRuntimePatchProvenance.lock.json"
SOURCE_IDENTITY_LOCK="$REPO_ROOT/Config/ForgePlayRuntimeSourceIdentity.lock.json"
PATCH_ROOT="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches"
PUBLIC_EXPORT_MARKER="$REPO_ROOT/.forgeplay-source-export"
OWNED_DIRECTORY_QUARANTINE_TOOL="$SCRIPT_DIR/quarantine-owned-directory.py"
EXPECTED_ARCHIVE_SHA256="d3bc091192d985846c9f20065cc81f21331f01e22b736b131e3449e1306671bc"
EXPECTED_ARCHIVE_ROOT="wine-11.12"
PUBLICATION_COMMITTED=0

fail() {
  printf 'error: Wine 11.12 source materialization failed: %s\n' "$*" >&2
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
    parent="$(/usr/bin/dirname "$current")"
    [[ "$parent" != "$current" ]] || break
    current="$parent"
  done
}

directory_identity() {
  /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null
}

# `/usr/bin/stat /dev/fd/N` reports the synthetic devfs device and descriptor
# access-mode bits on macOS, not the opened file's stable identity. Compare
# path and descriptor through lstat/fstat so external-volume source archives
# and patch snapshots do not fail closed solely because devfs projected them.
stable_file_identity() {
  /usr/bin/python3 - "$1" <<'PY'
import os
import sys

value = sys.argv[1]
metadata = os.fstat(int(value[3:])) if value.startswith("fd:") else os.lstat(value)
print(
    f"{metadata.st_dev}:{metadata.st_ino}:{metadata.st_mode}:"
    f"{metadata.st_nlink}:{metadata.st_size}:{metadata.st_mtime_ns}:"
    f"{metadata.st_ctime_ns}"
)
PY
}

cleanup_owned_workspace() {
  [[ -n "${WORKSPACE_ROOT:-}" && -n "${WORKSPACE_ID:-}" ]] || return 0
  [[ -d "$WORKSPACE_ROOT" && ! -L "$WORKSPACE_ROOT" ]] || return 0
  [[ "$(directory_identity "$WORKSPACE_ROOT" || true)" == "$WORKSPACE_ID" ]] || {
    printf 'warning: refusing to clean a substituted materialization workspace: %s\n' \
      "$WORKSPACE_ROOT" >&2
    return 1
  }
  [[ "$(directory_identity "$OUTPUT_PARENT" || true)" == "$OUTPUT_PARENT_ID" ]] || {
    printf 'warning: refusing to clean through a substituted output parent: %s\n' \
      "$OUTPUT_PARENT" >&2
    return 1
  }
  [[ -f "$OWNED_DIRECTORY_QUARANTINE_TOOL" &&
     ! -L "$OWNED_DIRECTORY_QUARANTINE_TOOL" ]] || {
    printf 'warning: materialization quarantine cleanup helper is unavailable: %s\n' \
      "$OWNED_DIRECTORY_QUARANTINE_TOOL" >&2
    return 1
  }
  if ! /usr/bin/python3 "$OWNED_DIRECTORY_QUARANTINE_TOOL" \
      --tree "$WORKSPACE_ROOT" \
      --tree-identity "$WORKSPACE_ID" \
      --parent "$OUTPUT_PARENT" \
      --parent-identity "$OUTPUT_PARENT_ID" \
      --label "Wine source materialization workspace"; then
    if [[ "$PUBLICATION_COMMITTED" == "1" ]]; then
      printf 'warning: source publication is committed; materialization workspace quarantine remains recoverable: %s\n' \
        "$WORKSPACE_ROOT" >&2
    else
      printf 'warning: pre-publication materialization workspace quarantine remains recoverable: %s\n' \
        "$WORKSPACE_ROOT" >&2
    fi
    return 1
  fi
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
    source_path_metadata = os.stat(
        source_name,
        dir_fd=source_parent_fd,
        follow_symlinks=False,
    )
    descriptor_metadata = os.fstat(source_fd)
    if (
        not stat.S_ISDIR(source_path_metadata.st_mode)
        or f"{source_path_metadata.st_dev}:{source_path_metadata.st_ino}" != expected_identity
        or f"{descriptor_metadata.st_dev}:{descriptor_metadata.st_ino}" != expected_identity
    ):
        raise SystemExit("publication source entry changed before atomic rename")

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
                raise SystemExit("publication destination appeared concurrently")
            raise SystemExit(f"atomic no-replace publication failed with errno {error_number}")
        # Successful atomic no-replace rename is the publication commit point.
        # Workspace cleanup is intentionally outside this transaction.
    finally:
        os.close(source_fd)
finally:
    os.close(destination_parent_fd)
    os.close(source_parent_fd)
PY
}

[[ "$#" -eq 2 ]] ||
  fail "usage: materialize-forgeplay-wine-11.12-source.sh <official-wine-11.12.tar.xz> <new-output-source-root>"
ARCHIVE_INPUT="$1"
OUTPUT_INPUT="$2"
[[ "$ARCHIVE_INPUT" = /* ]] || fail "archive path must be absolute"
[[ "$OUTPUT_INPUT" = /* ]] || fail "output source root must be absolute"
[[ -f "$ARCHIVE_INPUT" && ! -L "$ARCHIVE_INPUT" ]] ||
  fail "archive must be a non-symlink regular file"
[[ ! -e "$OUTPUT_INPUT" && ! -L "$OUTPUT_INPUT" ]] || fail "output source root must be fresh"

ARCHIVE_PARENT="$(cd "$(/usr/bin/dirname "$ARCHIVE_INPUT")" && /bin/pwd -P)"
ARCHIVE="$ARCHIVE_PARENT/$(/usr/bin/basename "$ARCHIVE_INPUT")"
OUTPUT_PARENT="$(cd "$(/usr/bin/dirname "$OUTPUT_INPUT")" && /bin/pwd -P)"
OUTPUT_BASENAME="$(/usr/bin/basename "$OUTPUT_INPUT")"
[[ -n "$OUTPUT_BASENAME" && "$OUTPUT_BASENAME" != "." && "$OUTPUT_BASENAME" != ".." ]] ||
  fail "output basename is unsafe"
OUTPUT_ROOT="$OUTPUT_PARENT/$OUTPUT_BASENAME"
reject_symlink_parent_components "$ARCHIVE" "archive"
reject_symlink_parent_components "$OUTPUT_ROOT" "output source root"
OUTPUT_PARENT_ID="$(directory_identity "$OUTPUT_PARENT")" || fail "output parent identity is unavailable"

/usr/bin/python3 - "$ARCHIVE" "$OUTPUT_ROOT" "$REPO_ROOT" <<'PY' ||
import os
import pwd
import sys

archive, output, repository = map(os.path.realpath, sys.argv[1:])
home = os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)
protected = {os.path.sep, home, repository, archive}
if output in protected:
    raise SystemExit("output equals a protected path")
for path in (repository, archive):
    if os.path.commonpath([output, path]) in {output, path}:
        raise SystemExit("output must not contain or be contained by repository/archive inputs")
if os.path.commonpath([output, home]) == output:
    raise SystemExit("output must not contain the user home directory")
PY
  fail "archive/output relationship is unsafe"

WORKSPACE_ROOT="$(/usr/bin/mktemp -d "$OUTPUT_PARENT/.${OUTPUT_BASENAME}.forgeplay-materialize.XXXXXXXX")" ||
  fail "could not create private materialization workspace"
/bin/chmod 700 "$WORKSPACE_ROOT" || fail "could not protect materialization workspace"
WORKSPACE_ID="$(directory_identity "$WORKSPACE_ROOT")" || fail "workspace identity is unavailable"
[[ "$(directory_identity "$OUTPUT_PARENT")" == "$OUTPUT_PARENT_ID" ]] ||
  fail "output parent changed while staging was created"
trap cleanup_owned_workspace EXIT

PATCH_LICENSE_SIDECAR_MODE="repository"
if [[ -e "$PUBLIC_EXPORT_MARKER" || -L "$PUBLIC_EXPORT_MARKER" ]]; then
  PATCH_LICENSE_SIDECAR_MODE="public-export"
fi

SNAPSHOT_ROOT="$WORKSPACE_ROOT/inputs"
STAGED_OUTPUT="$WORKSPACE_ROOT/output"
ARCHIVE_SNAPSHOT="$SNAPSHOT_ROOT/wine-11.12.tar.xz"
PATCH_SNAPSHOT_ROOT="$SNAPSHOT_ROOT/patches"
ORDER_FILE="$SNAPSHOT_ROOT/patch-order.txt"
/bin/mkdir -m 700 "$SNAPSHOT_ROOT" "$PATCH_SNAPSHOT_ROOT" "$STAGED_OUTPUT"

/usr/bin/python3 - \
  "$ARCHIVE" \
  "$MANIFEST" \
  "$SOURCE_AVAILABILITY" \
  "$PROVENANCE_LOCK" \
  "$SOURCE_IDENTITY_LOCK" \
  "$PATCH_ROOT" \
  "$PATCH_LICENSE_SIDECAR_MODE" \
  "$PUBLIC_EXPORT_MARKER" \
  "$ARCHIVE_SNAPSHOT" \
  "$PATCH_SNAPSHOT_ROOT" \
  "$ORDER_FILE" \
  "$EXPECTED_ARCHIVE_SHA256" <<'PY' || fail "immutable source-input snapshot could not be created and revalidated"
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import PurePosixPath

(
    archive_path,
    manifest_path,
    source_availability_path,
    lock_path,
    source_identity_path,
    patch_root_path,
    patch_license_sidecar_mode,
    public_export_marker_path,
    archive_snapshot,
    patch_snapshot_root,
    order_path,
    expected_archive_digest,
) = sys.argv[1:]

SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
CHUNK = 1024 * 1024
EXPECTED_EXPORT_LICENSE_SIDECARS = (
    (
        "wine-11.12-game-mode-process-host-routing.patch.license",
        "wine-11.12-game-mode-process-host-routing.patch",
        "479efa2903cd8e63fcde50b441cbf2fba316cdd840c190a3df3d7c5e6311e8cf",
    ),
    (
        "wine-11.12-game-mode-direct-target-scope.patch.license",
        "wine-11.12-game-mode-direct-target-scope.patch",
        "479efa2903cd8e63fcde50b441cbf2fba316cdd840c190a3df3d7c5e6311e8cf",
    ),
)
PUBLIC_EXPORT_MARKER_SHA256 = (
    "b311ae9f7becd7629934c36983b242f7dff4a9fb520b73a09b5ffa3c12383559"
)

if patch_license_sidecar_mode not in {"repository", "public-export"}:
    raise SystemExit("patch license sidecar mode is invalid")


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


def safe_basename(value, label, suffix):
    if not isinstance(value, str) or SAFE_NAME.fullmatch(value) is None:
        raise SystemExit(f"{label} must be a safe ASCII basename")
    parsed = PurePosixPath(value)
    if parsed.is_absolute() or len(parsed.parts) != 1 or parsed.name != value or not value.endswith(suffix):
        raise SystemExit(f"{label} has an unsafe path or suffix: {value!r}")
    return value


def copy_snapshot(
    source,
    destination,
    label,
    maximum_bytes,
    expected_digest=None,
    directory_fd=None,
    expected_mode=None,
):
    try:
        source_fd = os.open(
            source,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=directory_fd,
        )
    except OSError as error:
        raise SystemExit(f"{label} could not be opened safely: {error}") from error
    try:
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise SystemExit(f"{label} must be a single-link regular file")
        if expected_mode is not None and stat.S_IMODE(before.st_mode) != expected_mode:
            raise SystemExit(f"{label} mode must be {expected_mode:04o}")
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
                    raise SystemExit(f"{label} exceeded its bounded snapshot size while copying")
                digest.update(payload)
                view = memoryview(payload)
                while view:
                    written = os.write(destination_fd, view)
                    if written <= 0:
                        raise SystemExit(f"{label} snapshot write made no progress")
                    view = view[written:]
            after = os.fstat(source_fd)
            if identity(before) != identity(after) or total != before.st_size:
                raise SystemExit(f"{label} changed while its snapshot was copied")
            os.fsync(destination_fd)
            os.fchmod(destination_fd, 0o444)
            snapshot_metadata = os.fstat(destination_fd)
            if (
                not stat.S_ISREG(snapshot_metadata.st_mode)
                or snapshot_metadata.st_nlink != 1
                or stat.S_IMODE(snapshot_metadata.st_mode) != 0o444
                or snapshot_metadata.st_size != total
            ):
                raise SystemExit(f"{label} snapshot metadata is invalid")
        finally:
            os.close(destination_fd)
    finally:
        os.close(source_fd)

    actual_digest = digest.hexdigest()
    if expected_digest is not None and actual_digest != expected_digest:
        raise SystemExit(
            f"{label} SHA-256 mismatch: expected {expected_digest}, found {actual_digest}"
        )
    verification_fd = os.open(destination, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        verification_metadata = os.fstat(verification_fd)
        if not stat.S_ISREG(verification_metadata.st_mode) or stat.S_IMODE(verification_metadata.st_mode) != 0o444:
            raise SystemExit(f"{label} snapshot revalidation metadata is invalid")
        verification_digest = hashlib.sha256()
        verification_total = 0
        while True:
            payload = os.read(verification_fd, CHUNK)
            if not payload:
                break
            verification_total += len(payload)
            if verification_total > maximum_bytes:
                raise SystemExit(f"{label} snapshot exceeds its revalidation bound")
            verification_digest.update(payload)
        if verification_total != total or verification_digest.hexdigest() != actual_digest:
            raise SystemExit(f"{label} snapshot revalidation digest mismatch")
    finally:
        os.close(verification_fd)
    return actual_digest


manifest_snapshot = os.path.join(os.path.dirname(archive_snapshot), "RuntimeManifest.json")
source_availability_snapshot = os.path.join(os.path.dirname(archive_snapshot), "SOURCE-AVAILABILITY.md")
lock_snapshot = os.path.join(os.path.dirname(archive_snapshot), "PatchProvenance.lock.json")
source_identity_snapshot = os.path.join(os.path.dirname(archive_snapshot), "SourceIdentity.lock.json")
public_export_marker_snapshot = os.path.join(
    os.path.dirname(archive_snapshot), ".forgeplay-source-export"
)
if patch_license_sidecar_mode == "public-export":
    copy_snapshot(
        public_export_marker_path,
        public_export_marker_snapshot,
        "public source export marker",
        4096,
        PUBLIC_EXPORT_MARKER_SHA256,
        expected_mode=0o644,
    )
else:
    try:
        os.lstat(public_export_marker_path)
    except FileNotFoundError:
        pass
    else:
        raise SystemExit("repository mode must not contain a public source export marker")
copy_snapshot(archive_path, archive_snapshot, "Wine source archive", 2 * 1024 * 1024 * 1024, expected_archive_digest)
copy_snapshot(manifest_path, manifest_snapshot, "runtime manifest", 4 * 1024 * 1024)
copy_snapshot(source_availability_path, source_availability_snapshot, "runtime source availability", 4 * 1024 * 1024)
copy_snapshot(lock_path, lock_snapshot, "patch provenance lock", 4 * 1024 * 1024)
copy_snapshot(source_identity_path, source_identity_snapshot, "runtime source identity lock", 4 * 1024 * 1024)

def load_json_snapshot(path, label):
    try:
        with open(path, "rb") as handle:
            value = json.load(handle)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"{label} snapshot is unreadable: {error}") from error
    if not isinstance(value, dict):
        raise SystemExit(f"{label} snapshot must contain one JSON object")
    return value


def load_text_snapshot(path, label):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()
    except (OSError, UnicodeDecodeError) as error:
        raise SystemExit(f"{label} snapshot is unreadable: {error}") from error


def require_digest(value, label):
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
        raise SystemExit(f"{label} must be one lowercase SHA-256 digest")
    return value


def single_document_digest(document, pattern, label):
    values = re.findall(pattern, document, re.MULTILINE)
    if len(values) != 1:
        raise SystemExit(f"{label} must occur exactly once")
    return require_digest(values[0], label)


def validate_reviewed_entry(entry, label, suffix, approved_input_classes):
    expected_keys = {
        "approvedInputs",
        "implementationOwnership",
        "path",
        "responsibility",
        "sha256",
    }
    if not isinstance(entry, dict) or set(entry) != expected_keys:
        raise SystemExit(f"{label} entry schema is invalid")
    name = safe_basename(entry["path"], label, suffix)
    require_digest(entry["sha256"], f"{label} {name} SHA-256")
    if entry["implementationOwnership"] != "ForgePlay project":
        raise SystemExit(f"{label} has unreviewed implementation ownership: {name}")
    responsibility = entry["responsibility"]
    if not isinstance(responsibility, str) or not responsibility.strip():
        raise SystemExit(f"{label} responsibility must be non-empty: {name}")
    inputs = entry["approvedInputs"]
    if (
        not isinstance(inputs, list)
        or not inputs
        or any(not isinstance(value, str) for value in inputs)
        or len(inputs) != len(set(inputs))
        or not set(inputs).issubset(approved_input_classes)
    ):
        raise SystemExit(f"{label} approved-input closure is invalid: {name}")
    return name


def patch_set_digest(entries, overrides=None):
    overrides = overrides or {}
    digest = hashlib.sha256()
    for name, reviewed_digest in sorted(entries, key=lambda value: value[0]):
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(overrides.get(name, reviewed_digest).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def parse_transition_boundary(document):
    headings = list(
        re.finditer(
            r"^## Development worktree boundary — \d{4}-\d{2}-\d{2}$",
            document,
            re.MULTILINE,
        )
    )
    if not headings:
        return None
    if len(headings) != 1:
        raise SystemExit("source availability contains duplicate development boundaries")
    start = headings[0].end()
    next_heading = re.search(r"^## ", document[start:], re.MULTILINE)
    end = start + next_heading.start() if next_heading else len(document)
    section = document[start:end]
    blocks = re.findall(r"```json\n(.*?)\n```", section, re.DOTALL)
    if len(blocks) != 1 or section.count("```") != 2:
        raise SystemExit("development boundary must contain exactly one JSON code block")
    try:
        boundary = json.loads(blocks[0])
    except json.JSONDecodeError as error:
        raise SystemExit(f"development boundary JSON is invalid: {error}") from error
    if not isinstance(boundary, dict) or set(boundary) != {
        "boundaryKind",
        "currentBinary",
        "pendingNextBuild",
        "schemaVersion",
    }:
        raise SystemExit("development boundary schema is invalid")
    if boundary["schemaVersion"] != 1 or boundary["boundaryKind"] != "forgeplay-runtime-pending-next-build":
        raise SystemExit("development boundary authority is invalid")
    current = boundary["currentBinary"]
    pending = boundary["pendingNextBuild"]
    if not isinstance(current, dict) or set(current) != {
        "changedPatchSHA256Overrides",
        "patchSetSHA256",
        "sourceTreeSHA256",
    }:
        raise SystemExit("development boundary current-binary schema is invalid")
    if not isinstance(pending, dict) or set(pending) != {
        "patchSetSHA256",
        "sourceTreeSHA256",
    }:
        raise SystemExit("development boundary pending-next-build schema is invalid")
    require_digest(current["patchSetSHA256"], "boundary current-binary patch set")
    require_digest(current["sourceTreeSHA256"], "boundary current-binary source tree")
    require_digest(pending["patchSetSHA256"], "boundary pending patch set")
    require_digest(pending["sourceTreeSHA256"], "boundary pending source tree")
    overrides = current["changedPatchSHA256Overrides"]
    if not isinstance(overrides, list) or not overrides:
        raise SystemExit("development boundary must declare changed-patch digest overrides")
    for entry in overrides:
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256"}:
            raise SystemExit("development boundary changed-patch override schema is invalid")
        safe_basename(entry["path"], "development boundary changed patch", ".patch")
        require_digest(entry["sha256"], "development boundary changed-patch override")
    return boundary


manifest = load_json_snapshot(manifest_snapshot, "runtime manifest")
lock = load_json_snapshot(lock_snapshot, "patch provenance lock")
source_identity = load_json_snapshot(source_identity_snapshot, "runtime source identity lock")
source_availability = load_text_snapshot(source_availability_snapshot, "runtime source availability")

if manifest.get("schemaVersion") != 3 or manifest.get("runtimeIdentifier") != "com.forgeplay.runtime.wine-11.12":
    raise SystemExit("runtime manifest authority is invalid")
manifest_patch_set = require_digest(manifest.get("patchSetSHA256"), "runtime manifest patch set")
manifest_source_tree = require_digest(manifest.get("sourceTreeSHA256"), "runtime manifest source tree")

expected_lock_keys = {
    "approvedInputClasses",
    "behaviorContracts",
    "developmentModel",
    "patches",
    "patchLicenseSidecars",
    "prohibitedInputPolicy",
    "reviewLimitation",
    "schemaVersion",
    "upstreamSource",
}
if set(lock) != expected_lock_keys or lock.get("schemaVersion") != 1:
    raise SystemExit("patch provenance lock schema is invalid")
if lock.get("developmentModel") != "forgeplay-project-owned-reviewed-provenance":
    raise SystemExit("patch provenance development model is invalid")
if not isinstance(lock.get("reviewLimitation"), str) or "does not independently prove" not in lock["reviewLimitation"]:
    raise SystemExit("patch provenance proof limitation is missing")
if not isinstance(lock.get("prohibitedInputPolicy"), str) or not lock["prohibitedInputPolicy"].strip():
    raise SystemExit("patch provenance prohibited-input policy is missing")
approved_input_classes = lock.get("approvedInputClasses")
expected_input_classes = {
    "official-upstream-source",
    "project-authored-behavior-contracts",
    "project-requirements",
    "public-platform-interface-contracts",
    "repository-observation",
}
if (
    not isinstance(approved_input_classes, list)
    or len(approved_input_classes) != len(expected_input_classes)
    or set(approved_input_classes) != expected_input_classes
):
    raise SystemExit("patch provenance approved-input classes are invalid")
upstream_source = lock.get("upstreamSource")
if not isinstance(upstream_source, dict) or set(upstream_source) != {
    "archiveSHA256",
    "archiveURL",
    "patchedSourceTreeSHA256",
    "project",
    "releaseKeyFingerprint",
    "version",
}:
    raise SystemExit("patch provenance upstream-source schema is invalid")
if upstream_source != {
    "archiveSHA256": expected_archive_digest,
    "archiveURL": "https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz",
    "patchedSourceTreeSHA256": upstream_source.get("patchedSourceTreeSHA256"),
    "project": "Wine",
    "releaseKeyFingerprint": "DA23579A74D4AD9AF9D3F945CEFAC8EAAF17519D",
    "version": "11.12",
}:
    raise SystemExit("patch provenance upstream authority changed")
pending_source_tree = require_digest(
    upstream_source["patchedSourceTreeSHA256"],
    "patch provenance pending source tree",
)

if not isinstance(source_identity, dict) or set(source_identity) != {
    "currentFinalPatchedSourceTree",
    "schemaVersion",
    "upstreamSource",
}:
    raise SystemExit("runtime source identity lock schema is invalid")
if source_identity.get("schemaVersion") != 2 or source_identity.get("upstreamSource") != {
    "archiveSHA256": expected_archive_digest,
    "project": "Wine",
    "version": "11.12",
}:
    raise SystemExit("runtime source identity upstream authority changed")
pending_identity = source_identity.get("currentFinalPatchedSourceTree")
if pending_identity != {
    "hashAlgorithm": "forgeplay-source-tree-sha256-v1",
    "sha256": pending_source_tree,
}:
    raise SystemExit("pending final source identity is not bound to the provenance lock")

order = manifest.get("patchApplicationOrder")
patches = lock.get("patches")
contracts = lock.get("behaviorContracts")
sidecars = lock.get("patchLicenseSidecars")
if not all(isinstance(value, list) for value in (order, patches, contracts, sidecars)):
    raise SystemExit("manifest/provenance patch closure is malformed")
patch_names = [
    validate_reviewed_entry(entry, "patch provenance", ".patch", expected_input_classes)
    for entry in patches
]
contract_names = [
    validate_reviewed_entry(entry, "behavior-contract provenance", "-contract.md", expected_input_classes)
    for entry in contracts
]
if order != patch_names:
    raise SystemExit("manifest order does not exactly match the provenance lock")
if not order or len(order) != len(set(order)) or not contract_names or len(contract_names) != len(set(contract_names)):
    raise SystemExit("patch order must be non-empty and unique")

export_license_sidecars = []
if patch_license_sidecar_mode == "public-export":
    for name, patch_name, expected_digest in EXPECTED_EXPORT_LICENSE_SIDECARS:
        name = safe_basename(name, "public export patch license sidecar", ".patch.license")
        patch_name = safe_basename(
            patch_name,
            "public export sidecar patch",
            ".patch",
        )
        if name != f"{patch_name}.license" or patch_name not in order:
            raise SystemExit(
                f"public export patch license sidecar is not bound to an ordered patch: {name}"
            )
        export_license_sidecars.append(
            (
                name,
                require_digest(
                    expected_digest,
                    f"public export patch license sidecar {name}",
                ),
            )
        )

current_available_patch_set = single_document_digest(
    source_availability,
    r"^- Packaged ForgePlay patch-set SHA-256: `([0-9a-f]{64})`$",
    "SOURCE-AVAILABILITY current-binary patch set",
)
current_available_source_tree = single_document_digest(
    source_availability,
    r"^- Validated corresponding source tree SHA-256: `([0-9a-f]{64})`$",
    "SOURCE-AVAILABILITY current-binary source tree",
)
if (
    current_available_patch_set != manifest_patch_set
    or current_available_source_tree != manifest_source_tree
):
    raise SystemExit(
        "current-binary source identity disagrees across manifest and source availability"
    )

patch_root_fd = os.open(
    patch_root_path,
    os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_DIRECTORY,
)
patch_root_identity = identity(os.fstat(patch_root_fd))
try:
    patch_digests = []
    canonical_digests = []
    for entry, name in zip(patches, patch_names):
        expected_digest = entry["sha256"]
        destination = os.path.join(patch_snapshot_root, name)
        digest = copy_snapshot(
            name,
            destination,
            f"patch {name}",
            64 * 1024 * 1024,
            expected_digest,
            directory_fd=patch_root_fd,
        )
        patch_digests.append((digest, name))
        canonical_digests.append((name, digest))

    for entry, name in zip(contracts, contract_names):
        expected_digest = entry["sha256"]
        digest = copy_snapshot(
            name,
            os.path.join(patch_snapshot_root, name),
            f"behavior contract {name}",
            4 * 1024 * 1024,
            expected_digest,
            directory_fd=patch_root_fd,
        )
        canonical_digests.append((name, digest))

    for entry in sidecars:
        if not isinstance(entry, dict) or set(entry) != {
            "classification",
            "license",
            "patchPath",
            "path",
            "sha256",
        }:
            raise SystemExit("patch license sidecar entry schema is invalid")
        patch_name = safe_basename(entry.get("patchPath"), "sidecar patch", ".patch")
        name = safe_basename(entry.get("path"), "patch license sidecar", ".patch.license")
        if name != f"{patch_name}.license" or patch_name not in order:
            raise SystemExit(f"patch license sidecar is not bound to an ordered patch: {name}")
        if not isinstance(entry["classification"], str) or not entry["classification"].strip():
            raise SystemExit(f"patch license sidecar classification is invalid: {name}")
        if not isinstance(entry["license"], str) or not entry["license"].strip():
            raise SystemExit(f"patch license sidecar license is invalid: {name}")
        expected_digest = require_digest(entry["sha256"], f"patch license sidecar {name}")
        copy_snapshot(
            name,
            os.path.join(patch_snapshot_root, name),
            f"patch license sidecar {name}",
            1024 * 1024,
            expected_digest,
            directory_fd=patch_root_fd,
        )

    reviewed_names = {
        *patch_names,
        *contract_names,
        *(entry["path"] for entry in sidecars),
        *(name for name, _ in export_license_sidecars),
    }
    actual_names = set(os.listdir(patch_root_fd))
    if actual_names != reviewed_names:
        raise SystemExit(
            "patch root does not exactly match the reviewed provenance and export-license inventory "
            f"for {patch_license_sidecar_mode} mode"
        )

    for name, expected_digest in export_license_sidecars:
        copy_snapshot(
            name,
            os.path.join(patch_snapshot_root, name),
            f"public export patch license sidecar {name}",
            1024 * 1024,
            expected_digest,
            directory_fd=patch_root_fd,
        )

    if (
        set(os.listdir(patch_root_fd)) != reviewed_names
        or identity(os.fstat(patch_root_fd)) != patch_root_identity
    ):
        raise SystemExit("patch root changed while its reviewed snapshot was created")
finally:
    os.close(patch_root_fd)

pending_patch_set = patch_set_digest(canonical_digests)
transition = parse_transition_boundary(source_availability)
transition_required = (
    manifest_patch_set != pending_patch_set or manifest_source_tree != pending_source_tree
)
if transition_required:
    if manifest_patch_set == pending_patch_set or manifest_source_tree == pending_source_tree:
        raise SystemExit("pending patch-set and source-tree identities must transition together")
    if transition is None:
        raise SystemExit("pending next-build inputs require an explicit development boundary")
    current = transition["currentBinary"]
    pending = transition["pendingNextBuild"]
    if current["patchSetSHA256"] != manifest_patch_set or current["sourceTreeSHA256"] != manifest_source_tree:
        raise SystemExit("development boundary current-binary identity does not match the runtime manifest")
    if pending["patchSetSHA256"] != pending_patch_set or pending["sourceTreeSHA256"] != pending_source_tree:
        raise SystemExit("development boundary pending identity does not match reviewed inputs")

    patch_index = {name: index for index, name in enumerate(patch_names)}
    pending_patch_digests = dict(canonical_digests)
    override_items = current["changedPatchSHA256Overrides"]
    override_names = [entry["path"] for entry in override_items]
    if len(override_names) != len(set(override_names)):
        raise SystemExit("development boundary changed-patch overrides are duplicated")
    if any(name not in patch_index for name in override_names):
        raise SystemExit("development boundary changed-patch override is not an ordered reviewed patch")
    override_indices = [patch_index[name] for name in override_names]
    if override_indices != sorted(override_indices):
        raise SystemExit("development boundary changed-patch overrides are out of application order")
    overrides = {entry["path"]: entry["sha256"] for entry in override_items}
    if any(overrides[name] == pending_patch_digests[name] for name in override_names):
        raise SystemExit("development boundary contains a redundant changed-patch override")
    if patch_set_digest(canonical_digests, overrides) != manifest_patch_set:
        raise SystemExit("development boundary cannot reconstruct the current-binary patch-set identity")
elif transition is not None:
    raise SystemExit("development boundary is present even though no source transition is pending")
elif manifest_patch_set != pending_patch_set or manifest_source_tree != pending_source_tree:
    raise SystemExit("current runtime source identity is inconsistent")

order_fd = os.open(
    order_path,
    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
    0o600,
)
try:
    payload = "".join(f"{digest} {name}\n" for digest, name in patch_digests).encode("ascii")
    view = memoryview(payload)
    while view:
        written = os.write(order_fd, view)
        if written <= 0:
            raise SystemExit("patch-order snapshot write made no progress")
        view = view[written:]
    os.fsync(order_fd)
    os.fchmod(order_fd, 0o444)
finally:
    os.close(order_fd)
PY

revalidate_snapshot_sha256() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')" ||
    fail "$label snapshot SHA-256 could not be revalidated"
  [[ "$actual" == "$expected" ]] || fail "$label snapshot changed before consumption"
}

reset_inherited_descriptor() {
  /usr/bin/python3 - "$1" <<'PY'
import os
import sys

os.lseek(int(sys.argv[1]), 0, os.SEEK_SET)
PY
}

[[ -f "$ARCHIVE_SNAPSHOT" && ! -L "$ARCHIVE_SNAPSHOT" ]] ||
  fail "Wine source archive snapshot identity is unavailable"
ARCHIVE_SNAPSHOT_ID="$(stable_file_identity "$ARCHIVE_SNAPSHOT")" ||
  fail "Wine source archive snapshot identity could not be bound"
exec 8<"$ARCHIVE_SNAPSHOT"
[[ "$(stable_file_identity fd:8)" == "$ARCHIVE_SNAPSHOT_ID" ]] ||
  fail "Wine source archive snapshot changed while opening its consumption descriptor"
ARCHIVE_CONSUMPTION_SHA256="$(/usr/bin/shasum -a 256 /dev/fd/8 | /usr/bin/awk '{print $1}')" ||
  fail "Wine source archive descriptor SHA-256 could not be revalidated"
[[ "$ARCHIVE_CONSUMPTION_SHA256" == "$EXPECTED_ARCHIVE_SHA256" ]] ||
  fail "Wine source archive descriptor SHA-256 mismatch"
reset_inherited_descriptor 8
/usr/bin/python3 - /dev/fd/8 "$EXPECTED_ARCHIVE_ROOT" <<'PY' ||
import sys
import tarfile
from pathlib import PurePosixPath

archive, expected_root = sys.argv[1:]
with tarfile.open(archive, mode="r:xz") as handle:
    members = handle.getmembers()
    if not members:
        raise SystemExit("archive is empty")
    for member in members:
        path = PurePosixPath(member.name)
        if path.is_absolute() or not path.parts or path.parts[0] != expected_root or ".." in path.parts:
            raise SystemExit(f"unsafe archive member: {member.name!r}")
        if not (member.isfile() or member.isdir()):
            raise SystemExit(f"unsupported archive member type: {member.name!r}")
PY
  fail "archive layout is unsafe or not the exact Wine 11.12 source root"

reset_inherited_descriptor 8
/usr/bin/tar -xf /dev/fd/8 -C "$STAGED_OUTPUT" --strip-components=1 ||
  fail "safe archive snapshot extraction failed"
exec 8<&-
[[ -f "$STAGED_OUTPUT/VERSION" && ! -L "$STAGED_OUTPUT/VERSION" ]] ||
  fail "extracted source is missing VERSION"
[[ "$(/usr/bin/tr -d '\r\n' < "$STAGED_OUTPUT/VERSION")" == "Wine version 11.12" ]] ||
  fail "extracted source VERSION is not Wine 11.12"

exec 7<"$ORDER_FILE"
while IFS=' ' read -r patch_digest patch_name extra; do
  [[ -n "$patch_digest" && -n "$patch_name" && -z "${extra:-}" ]] ||
    fail "immutable ordered patch list is malformed"
  [[ "$patch_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.patch$ ]] ||
    fail "immutable ordered patch name is unsafe: $patch_name"
  [[ -f "$PATCH_SNAPSHOT_ROOT/$patch_name" && ! -L "$PATCH_SNAPSHOT_ROOT/$patch_name" ]] ||
    fail "ordered patch snapshot identity is unavailable: $patch_name"
  PATCH_SNAPSHOT_ID="$(stable_file_identity "$PATCH_SNAPSHOT_ROOT/$patch_name")" ||
    fail "ordered patch snapshot identity could not be bound: $patch_name"
  exec 9<"$PATCH_SNAPSHOT_ROOT/$patch_name"
  [[ "$(stable_file_identity fd:9)" == "$PATCH_SNAPSHOT_ID" ]] ||
    fail "ordered patch snapshot changed while opening its descriptor: $patch_name"
  PATCH_CONSUMPTION_SHA256="$(/usr/bin/shasum -a 256 /dev/fd/9 | /usr/bin/awk '{print $1}')" ||
    fail "ordered patch descriptor SHA-256 could not be revalidated: $patch_name"
  [[ "$PATCH_CONSUMPTION_SHA256" == "$patch_digest" ]] ||
    fail "ordered patch descriptor SHA-256 mismatch: $patch_name"
  reset_inherited_descriptor 9
  /usr/bin/patch -d "$STAGED_OUTPUT" -p1 --batch --forward <&9 ||
    fail "ordered patch snapshot application failed: $patch_name"
  exec 9<&-
done <&7
exec 7<&-

/usr/bin/python3 - "$STAGED_OUTPUT" "$SNAPSHOT_ROOT/SourceIdentity.lock.json" <<'PY' ||
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
identity = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
expected = identity["currentFinalPatchedSourceTree"]["sha256"]
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
        raise SystemExit(f"materialized Wine source contains a symlink: {relative}")
    if path.is_file():
        files.append(path)
if not files:
    raise SystemExit("materialized Wine source contains no regular files")

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
actual = digest.hexdigest()
if actual != expected:
    raise SystemExit(
        f"materialized final source identity mismatch: expected {expected}, found {actual}"
    )
PY
  fail "materialized Wine source does not match the current final patched-tree identity"

[[ "$(directory_identity "$OUTPUT_PARENT")" == "$OUTPUT_PARENT_ID" ]] ||
  fail "output parent changed before publication"
[[ ! -e "$OUTPUT_ROOT" && ! -L "$OUTPUT_ROOT" ]] ||
  fail "output source root appeared before publication"
STAGED_OUTPUT_ID="$(directory_identity "$STAGED_OUTPUT")" ||
  fail "staged output identity is unavailable"
atomic_publish_directory_no_replace \
  "$STAGED_OUTPUT" \
  "$OUTPUT_ROOT" \
  "$STAGED_OUTPUT_ID" ||
  fail "atomic no-replace source publication failed"
PUBLICATION_COMMITTED=1

if ! cleanup_owned_workspace; then
  printf 'warning: source publication committed despite post-commit workspace cleanup failure\n' >&2
fi
trap - EXIT
printf 'Materialized exact Wine 11.12 plus ForgePlay ordered patch set: %s\n' "$OUTPUT_ROOT"
