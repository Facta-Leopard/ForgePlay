#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
RUNTIME_ROOT="${FORGEPLAY_RUNTIME_ROOT:-$REPO_ROOT/Resources/Runners/ForgePlayRuntime}"
WINE="$RUNTIME_ROOT/wine/bin/wine"
WINESERVER="$RUNTIME_ROOT/wine/bin/wineserver"
FIXTURE_SOURCE="$SCRIPT_DIR/Fixtures/WineSessionCompatibility/session_compatibility_probe.c"
TEMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
BUILD_ROOT="$(mktemp -d "$TEMP_ROOT/forgeplay-session-compatibility.XXXXXX")"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

windows_path() {
  local native_path="$1"
  printf 'Z:%s' "${native_path//\//\\}"
}

compiler() {
  local candidate
  candidate="$(command -v x86_64-w64-mingw32-gcc 2>/dev/null || true)"
  if [[ -z "$candidate" && -x /opt/homebrew/bin/x86_64-w64-mingw32-gcc ]]; then
    candidate=/opt/homebrew/bin/x86_64-w64-mingw32-gcc
  fi
  [[ -n "$candidate" && -x "$candidate" ]] ||
    fail "x86_64-w64-mingw32-gcc is required"
  printf '%s' "$candidate"
}

cleanup() {
  local profile prefix server_root
  if [[ -x "$WINESERVER" ]]; then
    for profile in standard wifi-identity ethernet-identity; do
      prefix="$BUILD_ROOT/$profile/prefix"
      server_root="$BUILD_ROOT/$profile/server"
      if [[ -d "$prefix" ]]; then
        WINEPREFIX="$prefix" WINE_SERVER_ROOT="$server_root" \
          "$WINESERVER" -k >/dev/null 2>&1 || true
      fi
    done
  fi
  if [[ "${FORGEPLAY_KEEP_TEST_ARTIFACTS:-0}" == "1" ]]; then
    printf 'test_artifacts=%s\n' "$BUILD_ROOT" >&2
  else
    rm -rf -- "$BUILD_ROOT"
  fi
}
trap cleanup EXIT

for required_file in "$WINE" "$WINESERVER" "$FIXTURE_SOURCE"; do
  [[ -f "$required_file" && ! -L "$required_file" ]] ||
    fail "required compatibility probe input is missing or unsafe: $required_file"
done
[[ -x "$WINE" && -x "$WINESERVER" ]] ||
  fail "Wine launchers must be executable"

X86_64_CC="$(compiler)"
PROBE="$BUILD_ROOT/session-compatibility-probe.exe"
"$X86_64_CC" -municode -O2 -Wall -Wextra \
  -o "$PROBE" "$FIXTURE_SOURCE" \
  -liphlpapi -lws2_32 -lole32 -luuid

run_profile() {
  local profile="$1"
  local audio_mode="$2"
  local profile_root="$BUILD_ROOT/$profile"
  local prefix="$profile_root/prefix"
  local server_root="$profile_root/server"
  local output="$profile_root/result.txt"
  local trace="$profile_root/wine-trace.log"

  mkdir -p "$prefix" "$server_root"
  chmod 700 "$prefix" "$server_root"
  if ! WINEPREFIX="$prefix" \
    WINE_SERVER_ROOT="$server_root" \
    WINEDEBUG="-all" \
    FORGEPLAY_NETWORK_PROFILE="$profile" \
    FORGEPLAY_AUDIO_INPUT_MODE="$audio_mode" \
      "$WINE" "$PROBE" "$(windows_path "$output")" 2>"$trace"; then
    [[ ! -f "$output" ]] || /bin/cat "$output" >&2
    /usr/bin/tail -100 "$trace" >&2 || true
    fail "compatibility probe failed for $profile/$audio_mode"
  fi
  [[ -f "$output" && ! -L "$output" ]] ||
    fail "compatibility probe output is missing: $output"
  grep -Fxq "network_profile=$profile" "$output" ||
    fail "network profile did not reach the probe: $profile"
  grep -Fxq "audio_input_mode=$audio_mode" "$output" ||
    fail "audio mode did not reach the probe: $audio_mode"
  grep -Fxq 'winsock_started=1' "$output" ||
    fail "Winsock did not initialize: $profile"
  grep -Fxq 'stream_socket_type=1' "$output" ||
    fail "TCP stream socket semantics changed: $profile"
  grep -Fxq 'datagram_socket_type=2' "$output" ||
    fail "UDP datagram socket semantics changed: $profile"
  grep -Fxq 'render_enum_hresult=0x00000000' "$output" ||
    fail "audio output endpoint enumeration failed: $profile/$audio_mode"

  if [[ "$audio_mode" == "disabled" ]]; then
    grep -Fxq 'capture_enum_hresult=0x00000000' "$output" ||
      fail "disabled audio input did not return a successful empty endpoint set"
    grep -Fxq 'capture_endpoint_count=0' "$output" ||
      fail "disabled audio input exposed a capture endpoint"
  else
    grep -Fxq 'capture_enum_hresult=0x00000000' "$output" ||
      fail "enabled audio input did not preserve the upstream capture path"
  fi

  if [[ "$profile" != "standard" ]]; then
    local active_count matching_count expected_type
    active_count="$(awk -F= '$1 == "active_adapter_count" {print $2}' "$output")"
    matching_count="$(awk -F= '$1 == "matching_adapter_count" {print $2}' "$output")"
    expected_type="$(awk -F= '$1 == "expected_adapter_type" {print $2}' "$output")"
    [[ "$active_count" =~ ^[1-9][0-9]*$ ]] ||
      fail "no active non-loopback adapter was available for $profile"
    [[ "$matching_count" == "$active_count" ]] ||
      fail "$profile did not normalize every active adapter"
    case "$profile:$expected_type" in
      wifi-identity:71|ethernet-identity:6) ;;
      *) fail "unexpected Windows adapter type for $profile: $expected_type" ;;
    esac
  fi
}

run_profile standard enabled
run_profile wifi-identity disabled
run_profile ethernet-identity disabled

printf 'steam_session_compatibility=PASS\n'
printf 'network_adapter_presentation=standard_wifi_ethernet\n'
printf 'socket_transport_semantics=tcp_and_udp_unchanged\n'
printf 'audio_input_disabled=capture_endpoints_hidden\n'
