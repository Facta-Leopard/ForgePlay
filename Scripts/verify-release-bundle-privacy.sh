#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=""
APP_PATH=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_PATH_VERIFIER="$SCRIPT_DIR/verify-wine-runtime-build-paths.py"
RUNTIME_CAPABILITY_VERIFIER="$SCRIPT_DIR/verify-bundled-runtime-capability.sh"
RUNTIME_ROOT_RELATIVE_PATH="Contents/Resources/Runners/ForgePlayRuntime"
REVIEWED_DXMT_RELATIVE_PATH="Contents/Resources/Runners/ForgePlayRuntime/Frameworks/renderer/dxmt/wine/x86_64-unix/winemetal.so"
REVIEWED_DXMT_ALLOW_FLAG="--allow-inventory-verified-dxmt-github-actions-paths"

fail() {
  printf 'error: release bundle privacy verification failed: %s\n' "$*" >&2
  exit 1
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --project-root)
      [[ "$#" -ge 2 ]] || fail "--project-root requires a path"
      PROJECT_ROOT="$2"
      shift 2
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      [[ -z "$APP_PATH" ]] ||
        fail "usage: verify-release-bundle-privacy.sh [--project-root <path>] <app bundle>"
      APP_PATH="$1"
      shift
      ;;
  esac
done

[[ -n "$APP_PATH" ]] ||
  fail "usage: verify-release-bundle-privacy.sh [--project-root <path>] <app bundle>"
[[ -d "$APP_PATH" && ! -L "$APP_PATH" ]] ||
  fail "app must be a non-symlink directory"

if [[ -n "$PROJECT_ROOT" ]]; then
  [[ "$PROJECT_ROOT" = /* && -d "$PROJECT_ROOT" && ! -L "$PROJECT_ROOT" ]] ||
    fail "project root must be an absolute non-symlink directory"
  PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"
fi

PROHIBITED_FILES="$(
  find "$APP_PATH" \( \
    -name '.DS_Store' -o \
    -name '.git' -o \
    -name '.env' -o \
    -name 'xcuserdata' -o \
    -name '*.xcuserstate' -o \
    -name 'ForgePlay.local.xcconfig' -o \
    -iname 'AuthKey_*.p8' -o \
    -iname '*.p8' -o \
    -iname '*.p12' -o \
    -iname '*.mobileprovision' -o \
    -iname '*.provisionprofile' \
  \) -print
)"
if [[ -n "$PROHIBITED_FILES" ]]; then
  while IFS= read -r prohibited_file; do
    printf '%s\n' "${prohibited_file#"$APP_PATH/"}" >&2
  done <<< "$PROHIBITED_FILES"
  fail "app contains a local-development or credential-shaped file"
fi

[[ -f "$BUILD_PATH_VERIFIER" && ! -L "$BUILD_PATH_VERIFIER" ]] ||
  fail "release build-path verifier is unavailable"

ALLOW_REVIEWED_DXMT_PATHS=0
RUNTIME_VERIFICATION_TARGET=""
REVIEWED_DXMT_PATH="$APP_PATH/$REVIEWED_DXMT_RELATIVE_PATH"
if [[ -e "$REVIEWED_DXMT_PATH" || -L "$REVIEWED_DXMT_PATH" ]]; then
  RUNTIME_ROOT_PATH="$APP_PATH/$RUNTIME_ROOT_RELATIVE_PATH"
  [[ -d "$RUNTIME_ROOT_PATH" && ! -L "$RUNTIME_ROOT_PATH" ]] ||
    fail "reviewed DXMT payload lacks a non-symlink Runtime root"
  [[ -f "$REVIEWED_DXMT_PATH" && ! -L "$REVIEWED_DXMT_PATH" ]] ||
    fail "reviewed DXMT payload path is not a non-symlink regular file"
  [[ -f "$RUNTIME_CAPABILITY_VERIFIER" && ! -L "$RUNTIME_CAPABILITY_VERIFIER" ]] ||
    fail "release Runtime inventory verifier is unavailable"
  RUNTIME_VERIFICATION_TARGET="$(cd "$RUNTIME_ROOT_PATH" && pwd -P)" ||
    fail "reviewed DXMT Runtime root could not be resolved"
  /bin/bash "$RUNTIME_CAPABILITY_VERIFIER" \
    --release-runtime-inventory-only \
    "$RUNTIME_VERIFICATION_TARGET" >/dev/null ||
    fail "reviewed DXMT path exception lacks a verified Runtime inventory and renderer/SBOM locks"
  ALLOW_REVIEWED_DXMT_PATHS=1
fi

if [[ "$ALLOW_REVIEWED_DXMT_PATHS" == "1" ]]; then
  /usr/bin/python3 "$BUILD_PATH_VERIFIER" \
    "$REVIEWED_DXMT_ALLOW_FLAG" \
    "$APP_PATH" >/dev/null ||
    fail "app contains a personal user-home or mounted-volume path"
else
  /usr/bin/python3 "$BUILD_PATH_VERIFIER" "$APP_PATH" >/dev/null ||
    fail "app contains a personal user-home or mounted-volume path"
fi

if [[ "$ALLOW_REVIEWED_DXMT_PATHS" == "1" ]]; then
  # Bind the accepted bytes to the same exhaustive inventory after scanning as
  # well, closing the mutation window between authorization and inspection.
  [[ "$(cd "$APP_PATH/$RUNTIME_ROOT_RELATIVE_PATH" && pwd -P)" == \
      "$RUNTIME_VERIFICATION_TARGET" ]] ||
    fail "reviewed DXMT Runtime root changed during privacy inspection"
  /bin/bash "$RUNTIME_CAPABILITY_VERIFIER" \
    --release-runtime-inventory-only \
    "$RUNTIME_VERIFICATION_TARGET" >/dev/null ||
    fail "Runtime inventory or renderer/SBOM locks changed during privacy inspection"
fi

python3 - "$APP_PATH" "$PROJECT_ROOT" "${HOME:-}" "${USER:-}" "${FORGEPLAY_NOTARY_KEY_PATH:-}" <<'PY'
import os
import re
import sys
from pathlib import Path

app = Path(sys.argv[1])
project_root = sys.argv[2]
home = sys.argv[3]
user = sys.argv[4]
notary_key_path = sys.argv[5]

markers: list[tuple[str, bytes]] = [
    ("local Xcode configuration path", b"Config/ForgePlay.local.xcconfig"),
]

pem_patterns: list[tuple[str, re.Pattern[bytes]]] = []
for label, key_type in (
    ("private-key PEM block", b"PRIVATE KEY"),
    ("RSA private-key PEM block", b"RSA PRIVATE KEY"),
    ("EC private-key PEM block", b"EC PRIVATE KEY"),
    ("OpenSSH private-key PEM block", b"OPENSSH PRIVATE KEY"),
):
    escaped_key_type = re.escape(key_type)
    pem_patterns.append(
        (
            label,
            re.compile(
                rb"-----BEGIN "
                + escaped_key_type
                + rb"-----[ \t]*\r?\n"
                + rb"(?:[A-Za-z][A-Za-z0-9-]*:[^\r\n]*\r?\n)*"
                + rb"(?:\r?\n)?"
                + rb"(?:[A-Za-z0-9+/=]{16,128}[ \t]*\r?\n){1,}"
                + rb"-----END "
                + escaped_key_type
                + rb"-----"
            ),
        )
    )

def add_path_marker(label: str, value: str) -> None:
    if value and value.startswith("/") and value != "/":
        markers.append((label, os.fsencode(value.rstrip("/"))))

add_path_marker("project source path", project_root)
add_path_marker("user home path", home)
add_path_marker("notarization private-key path", notary_key_path)
if user and user not in {"root", "runner"}:
    markers.append(("local account name", os.fsencode(user)))

max_marker_length = max(len(marker) for _, marker in markers)
pem_overlap_length = 256 * 1024
violations: list[tuple[str, str]] = []

for root, directory_names, file_names in os.walk(app, followlinks=False):
    directory_names[:] = [
        name for name in directory_names
        if not os.path.islink(os.path.join(root, name))
    ]
    for file_name in file_names:
        path = Path(root, file_name)
        if path.is_symlink() or not path.is_file():
            continue
        try:
            with path.open("rb") as handle:
                tail = b""
                found_labels: set[str] = set()
                scan_for_pem = True
                first_chunk = True
                while True:
                    chunk = handle.read(1024 * 1024)
                    if not chunk:
                        break
                    if first_chunk:
                        # Compiled cryptography libraries can contain public,
                        # non-credential self-test vectors. PEM credentials are
                        # textual files, so only apply the PEM block parser to
                        # files whose leading bytes are text-compatible.
                        scan_for_pem = b"\0" not in chunk[:8192]
                        first_chunk = False
                    data = tail + chunk
                    for label, marker in markers:
                        if label not in found_labels and marker in data:
                            found_labels.add(label)
                    if scan_for_pem:
                        for label, pattern in pem_patterns:
                            if label not in found_labels and pattern.search(data):
                                found_labels.add(label)
                    if found_labels:
                        break
                    overlap_length = max(max_marker_length - 1, pem_overlap_length)
                    tail = data[-overlap_length:]
        except OSError as error:
            raise SystemExit(f"could not inspect {path.relative_to(app)}: {error}")
        for label in sorted(found_labels):
            violations.append((str(path.relative_to(app)), label))

if violations:
    for relative_path, label in violations:
        print(f"{relative_path}: {label}", file=sys.stderr)
    raise SystemExit("app contains a private-key file or local workstation identity marker")
PY

printf 'Release bundle privacy verification passed: %s\n' "$APP_PATH"
