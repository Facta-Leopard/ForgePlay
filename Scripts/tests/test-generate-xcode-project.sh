#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SCRIPT="$ROOT_DIR/Scripts/generate-xcode-project.sh"
DEFAULT_TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TEMP_ROOT="$(mktemp -d "$DEFAULT_TEMP_ROOT/forgeplay-xcode-project-generator.XXXXXX")"
FIXTURE_ROOT="$TEMP_ROOT/project"
FAKE_BIN="$TEMP_ROOT/bin"

cleanup() {
  rm -rf -- "$TEMP_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$FIXTURE_ROOT/Scripts" "$FIXTURE_ROOT/Config" "$FAKE_BIN"
cp "$SOURCE_SCRIPT" "$FIXTURE_ROOT/Scripts/generate-xcode-project.sh"
printf 'name: Fixture\n' >"$FIXTURE_ROOT/project.yml"
printf 'FORGEPLAY_DEVELOPMENT_TEAM = USEROWNED\n' >"$FIXTURE_ROOT/Config/ForgePlay.local.xcconfig"

cat >"$FAKE_BIN/xcodegen" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${SWIFT_DETERMINISTIC_HASHING:-}" == "1" ]] || {
  printf 'SWIFT_DETERMINISTIC_HASHING was not pinned\n' >&2
  exit 91
}
[[ "${SWIFT_HASH_SEED+x}" != "x" ]] || {
  printf 'ambient SWIFT_HASH_SEED reached XcodeGen\n' >&2
  exit 92
}
printf '%s\n' "$*" >"${FORGEPLAY_TEST_XCODEGEN_ARGS:?}"
SH
chmod +x "$FAKE_BIN/xcodegen" "$FIXTURE_ROOT/Scripts/generate-xcode-project.sh"

before_hash="$(shasum -a 256 "$FIXTURE_ROOT/Config/ForgePlay.local.xcconfig" | awk '{print $1}')"
PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
SWIFT_DETERMINISTIC_HASHING=0 \
SWIFT_HASH_SEED=untrusted-ambient-seed \
FORGEPLAY_TEST_XCODEGEN_ARGS="$TEMP_ROOT/xcodegen-args.txt" \
  "$FIXTURE_ROOT/Scripts/generate-xcode-project.sh"
after_hash="$(shasum -a 256 "$FIXTURE_ROOT/Config/ForgePlay.local.xcconfig" | awk '{print $1}')"

[[ "$before_hash" == "$after_hash" ]] || fail "generator modified the user-owned local xcconfig"
grep -Fxq "generate --spec $FIXTURE_ROOT/project.yml" "$TEMP_ROOT/xcodegen-args.txt" ||
  fail "generator did not invoke xcodegen with the fixture project specification"

rm -f "$FIXTURE_ROOT/Config/ForgePlay.local.xcconfig" "$TEMP_ROOT/xcodegen-args.txt"
PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
FORGEPLAY_TEST_XCODEGEN_ARGS="$TEMP_ROOT/xcodegen-args.txt" \
  "$FIXTURE_ROOT/Scripts/generate-xcode-project.sh"
[[ ! -e "$FIXTURE_ROOT/Config/ForgePlay.local.xcconfig" ]] ||
  fail "generator created a local xcconfig when the user did not have one"

rm -f "$TEMP_ROOT/xcodegen-args.txt"
PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
FORGEPLAY_XCODEGEN_PATH="$FAKE_BIN/xcodegen" \
FORGEPLAY_TEST_XCODEGEN_ARGS="$TEMP_ROOT/xcodegen-args.txt" \
  "$FIXTURE_ROOT/Scripts/generate-xcode-project.sh"
grep -Fxq "generate --spec $FIXTURE_ROOT/project.yml" "$TEMP_ROOT/xcodegen-args.txt" ||
  fail "generator did not use the explicit XcodeGen binary under the sanitized PATH"

ln -s "$FAKE_BIN/xcodegen" "$TEMP_ROOT/xcodegen-symlink"
if PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
   FORGEPLAY_XCODEGEN_PATH="$TEMP_ROOT/xcodegen-symlink" \
   FORGEPLAY_TEST_XCODEGEN_ARGS="$TEMP_ROOT/should-not-run-symlink-tool.txt" \
   "$FIXTURE_ROOT/Scripts/generate-xcode-project.sh" >/dev/null 2>&1; then
  fail "generator accepted a symlink FORGEPLAY_XCODEGEN_PATH"
fi
[[ ! -e "$TEMP_ROOT/should-not-run-symlink-tool.txt" ]] ||
  fail "symlink XcodeGen binary ran before it was rejected"

if PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
   FORGEPLAY_XCODEGEN_PATH="bin/xcodegen" \
   FORGEPLAY_TEST_XCODEGEN_ARGS="$TEMP_ROOT/should-not-run-relative-tool.txt" \
   "$FIXTURE_ROOT/Scripts/generate-xcode-project.sh" >/dev/null 2>&1; then
  fail "generator accepted a relative FORGEPLAY_XCODEGEN_PATH"
fi
[[ ! -e "$TEMP_ROOT/should-not-run-relative-tool.txt" ]] ||
  fail "relative XcodeGen binary ran before it was rejected"

printf 'outside\n' >"$TEMP_ROOT/outside.xcconfig"
ln -s "$TEMP_ROOT/outside.xcconfig" "$FIXTURE_ROOT/Config/ForgePlay.local.xcconfig"
if PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
   FORGEPLAY_TEST_XCODEGEN_ARGS="$TEMP_ROOT/should-not-run.txt" \
   "$FIXTURE_ROOT/Scripts/generate-xcode-project.sh" >/dev/null 2>&1; then
  fail "generator accepted a symlink local xcconfig"
fi
[[ ! -e "$TEMP_ROOT/should-not-run.txt" ]] || fail "xcodegen ran after an unsafe local config was detected"

rm -f "$FIXTURE_ROOT/Config/ForgePlay.local.xcconfig"
ln -s "$TEMP_ROOT/missing-local.xcconfig" "$FIXTURE_ROOT/Config/ForgePlay.local.xcconfig"
if PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
   FORGEPLAY_TEST_XCODEGEN_ARGS="$TEMP_ROOT/should-not-run-broken.txt" \
   "$FIXTURE_ROOT/Scripts/generate-xcode-project.sh" >/dev/null 2>&1; then
  fail "generator accepted a broken-symlink local xcconfig"
fi
[[ ! -e "$TEMP_ROOT/should-not-run-broken.txt" ]] ||
  fail "xcodegen ran after a broken-symlink local config was detected"

printf 'PASS: Xcode project generator preserves local config and pins deterministic explicit XcodeGen\n'
