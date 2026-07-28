#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Facta-Leopard
# SPDX-License-Identifier: GPL-3.0-only
#
# ForgePlay Game Mode
# Original source: https://github.com/Facta-Leopard/ForgePlay

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCH_FILE="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-process-host-routing.patch"
SCOPE_PATCH_FILE="$REPO_ROOT/Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-direct-target-scope.patch"
HOST_CONFIG="$REPO_ROOT/Config/ForgePlayGameModeProcessHost.xcconfig"
HOST_SOURCE="$REPO_ROOT/Native/GameModeProcessHost/GameModeProcessHost.m"
HOST_IDENTITY_SOURCE="$REPO_ROOT/Native/GameModeProcessHost/GameModeRuntimeIdentity.m"
HOST_EXECUTION_SOURCE="$REPO_ROOT/Native/GameModeProcessHost/GameModeInheritedExecution.m"

python3 - \
    "$PATCH_FILE" \
    "$SCOPE_PATCH_FILE" \
    "$HOST_CONFIG" \
    "$HOST_SOURCE" \
    "$HOST_IDENTITY_SOURCE" \
    "$HOST_EXECUTION_SOURCE" <<'PY'
import sys
from pathlib import Path


(
    patch_path,
    scope_patch_path,
    host_config_path,
    host_source_path,
    host_identity_source_path,
    host_execution_source_path,
) = map(Path, sys.argv[1:])


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"error: {message}")


require(patch_path.is_file() and not patch_path.is_symlink(),
        f"Game Mode loader patch is missing or unsafe: {patch_path}")
require(scope_patch_path.is_file() and not scope_patch_path.is_symlink(),
        f"Game Mode target-scope patch is missing or unsafe: {scope_patch_path}")
require(host_config_path.is_file() and not host_config_path.is_symlink(),
        f"Game Mode host build configuration is missing or unsafe: {host_config_path}")
require(host_source_path.is_file() and not host_source_path.is_symlink(),
        f"Game Mode host source is missing or unsafe: {host_source_path}")
require(host_identity_source_path.is_file() and not host_identity_source_path.is_symlink(),
        f"Game Mode host Runtime identity source is missing or unsafe: {host_identity_source_path}")
require(host_execution_source_path.is_file() and not host_execution_source_path.is_symlink(),
        f"Game Mode host execution source is missing or unsafe: {host_execution_source_path}")
patch = patch_path.read_text(encoding="utf-8")
scope_patch = scope_patch_path.read_text(encoding="utf-8")
host_config = host_config_path.read_text(encoding="utf-8")
host_source = host_source_path.read_text(encoding="utf-8")
host_identity_source = host_identity_source_path.read_text(encoding="utf-8")
host_execution_source = host_execution_source_path.read_text(encoding="utf-8")
added_source = "\n".join(
    line[1:]
    for line in patch.splitlines()
    if line.startswith("+") and not line.startswith("+++")
)
scope_added_source = "\n".join(
    line[1:]
    for line in scope_patch.splitlines()
    if line.startswith("+") and not line.startswith("+++")
)


def function_body(source: str, name: str) -> str:
    start = source.find(name)
    require(start >= 0, f"missing function: {name}")
    opening = source.find("{", start)
    require(opening >= 0, f"missing function body: {name}")
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    raise SystemExit(f"error: unterminated function body: {name}")


for changed_path in (
    "dlls/kernelbase/process.c",
    "dlls/ntdll/unix/process.c",
    "dlls/ntdll/unix/loader.c",
):
    require(f"diff --git a/{changed_path} b/{changed_path}" in patch,
            f"missing integration boundary: {changed_path}")

require(patch.count('L"FORGEPLAY_STEAM_GAME_PROCESS"') >= 3,
        "Steam game identity is not installed and scrubbed in every child environment")
require("apply_forgeplay_steam_game_process_unix_environment" in patch and
        '+        "FORGEPLAY_STEAM_GAME_PROCESS",' in patch,
        "Steam game identity is not synchronized into the Unix child")
for changed_path in (
    "dlls/ntdll/unix/process.c",
    "dlls/ntdll/unix/loader.c",
    "dlls/winemac.drv/window.c",
):
    require(f"diff --git a/{changed_path} b/{changed_path}" in scope_patch,
            f"missing direct-target integration boundary: {changed_path}")

host_body = function_body(added_source, "forgeplay_exec_required_game_mode_host")
require('forgeplay_environment_flag_enabled( "FORGEPLAY_STEAM_GAME_PROCESS" )' in host_body,
        "fixed host routing is not gated by the independent Steam game identity")
require('forgeplay_environment_flag_enabled( "FORGEPLAY_GAME_RENDERER_ACTIVE" )' not in host_body,
        "Game Mode routing must not depend on renderer activation")
require('forgeplay_environment_flag_enabled( "FORGEPLAY_GAME_MODE_HOST_ENABLED" )' in host_body,
        "fixed host capability must remain an explicit opt-in")
require("execv( argv[1], argv + 1 )" in host_body,
        "host exec no longer preserves the Wine child argument vector")
require('"loader_contract_rejected"' in host_body and
        '"loader_exec_failed"' in host_body and
        'return STATUS_NOT_SUPPORTED;' in host_body and
        'return STATUS_INVALID_PARAMETER;' in host_body and
        'return STATUS_UNSUCCESSFUL;' in host_body,
        "an accepted beta Game Mode target must fail closed when its required host cannot run")

loader_start = patch.find("static NTSTATUS loader_exec")
require(loader_start >= 0, "loader_exec integration hunk is missing")
loader_end = patch.find("diff --git", loader_start)
loader_body = patch[loader_start:loader_end if loader_end >= 0 else len(patch)]
no_reexec_state = loader_body.find("putenv( noexec )")
host_attempt = loader_body.find("forgeplay_exec_required_game_mode_host( argv )")
standard_loader = loader_body.find("get_alternate_wineloader")
require(0 <= no_reexec_state < host_attempt < standard_loader,
        "Wine child-loader no-reexec state must exist before the fixed host attempt")
require("if ((status = forgeplay_exec_required_game_mode_host( argv ))) return status;" in
        loader_body,
        "an accepted beta Game Mode host failure must not fall through to the standard loader")

for fragment in (
    "/Contents/Helpers/GameModeProcessHost.app/Contents/MacOS/GameModeProcessHost",
    '"FORGEPLAY_GAME_MODE_HOST_MODE"',
    '"steam-child"',
    '"FORGEPLAY_GAME_MODE_HOST_EXECUTABLE_SHA256"',
    '"FORGEPLAY_GAME_MODE_HOST_NTDLL"',
    '"FORGEPLAY_PREFIX_EXECUTION_LOCK"',
    '\\"producer\\":\\"wine-loader\\"',
    '\\"event_code\\":\\"%s\\"',
    '\\"run_identifier\\":\\"%s\\"',
    '\\"darwin_pid\\":%ld',
):
    require(fragment in added_source, f"fixed host contract is missing: {fragment}")

require("ENABLE_DEBUG_DYLIB = NO" in host_config,
        "Xcode Debug Dylib would apply fixed-address loader flags to a dylib link")
require("STRIP_STYLE = non-global" in host_config,
        "Xcode install/archive must preserve the host dlsym preload export")
for fragment in (
    "sha256-macho-signature-independent-v1",
    "forgeplay-runtime-core-payload-v2",
    "FPSignatureIndependentSHA256ForFileRelativeToDirectory",
    "FPCanonicalCorePayloadPaths",
    "FPRequiredExecutionPayloadPaths",
    "[requiredExecutionPayloadSet isSubsetOfSet:corePayloadSet]",
    "for (NSString *relativePath in corePayloadPaths)",
):
    require(fragment in host_identity_source,
            f"Game Mode host Runtime identity lacks the signed-payload contract: {fragment}")
require("corePayloads.count != requiredPaths.count" not in host_identity_source,
        "Game Mode host still rejects signed Runtime payload extensions through a duplicated exact set")
reservation_body = function_body(host_source, "FPInitializeWineReservedAreas")
require("wine_main_preload_info" in reservation_body,
        "reservation initialization must use Wine's nearby exported preload table pointer")
require("fp_wine_reserve" not in reservation_body and
        "fp_wine_top_down" not in reservation_body,
        "reservation initialization directly references a segment outside x86_64 RIP range")

require("FPExecValidatedWineLoaderFallback" not in host_source,
        "Game Mode host still contains a standard Wine loader fallback")
require("fixedLoaderFallbackIdentityWithError" not in host_identity_source,
        "Runtime identity still exposes the removed standard-loader fallback")
for fragment in (
    "wine_loader_fallback_selected",
    "wine_loader_fallback_exec_failed",
    "runtime_fallback_executable_open_failed",
    "runtime_fallback_executable_policy_failed",
):
    require(fragment not in host_source and fragment not in host_identity_source,
            f"removed Game Mode fallback marker remains: {fragment}")
require("execv(" not in host_source and "execve(" not in host_source,
        "Game Mode host must not re-exec a non-Game-Mode Wine loader")

failure_start = host_source.find("if (!group)")
wine_main_entry = host_source.find("wineMain(argc, argv)")
require(0 <= failure_start < wine_main_entry,
        "host fail-closed coverage boundary is unavailable")
pre_entry_body = host_source[failure_start:wine_main_entry]
require(pre_entry_body.count("return FPFail(") >= 13,
        "a post-identity host failure does not fail closed")
require("return FPExecValidatedWineLoaderFallback(" not in pre_entry_body,
        "a post-identity host failure can still re-exec standard Wine")
require('"WINELOADERNOEXEC", 8' in host_execution_source and
        '@"wine_loader_noexec_environment_invalid"' in host_execution_source,
        "host execution must validate Wine 11.12's no-reexec loader state")
require('"FORGEPLAY_STEAM_GAME_PROCESS", 8' in host_execution_source and
        '"FORGEPLAY_GAME_MODE_DIRECT_TARGET", 8' in host_execution_source and
        '"FORGEPLAY_GAME_MODE_HOST_ROUTED", 8' in host_execution_source and
        '@"game_mode_target_environment_invalid"' in host_execution_source,
        "native host must independently validate the routed game-target identity")
require('"FORGEPLAY_GAME_MODE_PROCESS_NAME"' not in host_execution_source and
        "processDisplayName" not in host_execution_source and
        "setprogname(" not in host_source,
        "fixed host identity must not be replaced with a per-game process name")

require("forgeplay_game_mode_image_path_is_eligible" in scope_patch and
        "&params->ImagePathName" in scope_patch,
        "fixed host routing is not derived from Wine's resolved executable identity")
require("eligible_game_target" in scope_patch and
        "parent_game_lineage" not in scope_patch and
        "direct_game_target = !parent_game_lineage" not in scope_patch,
        "launcher descendants must be evaluated independently as resolved game targets")
require('"FORGEPLAY_GAME_MODE_DIRECT_TARGET"' in scope_patch and
        'forgeplay_environment_flag_enabled( "FORGEPLAY_GAME_MODE_DIRECT_TARGET" )' in
        scope_patch,
        "resolved eligible-target identity does not gate the fixed host")
require('unsetenv( "FORGEPLAY_GAME_MODE_HOST_ROUTED" )' in scope_patch and
        'getenv( "FORGEPLAY_GAME_MODE_HOST_ROUTED" )' in scope_patch and
        '"preserving fixed Game Mode host application icon' in scope_patch,
        "each loader decision must clear inherited routing state and preserve the fixed host icon")
require('"FORGEPLAY_GAME_MODE_PROCESS_NAME"' not in scope_patch and
        "forgeplay_game_mode_process_name_utf8" not in scope_patch,
        "Game Mode routing must not export or apply a per-game process name")
require('"loader_route_skipped_game_mode_not_requested"' in scope_patch and
        'forgeplay_environment_flag_enabled( "FORGEPLAY_GAME_MODE_HOST_ENABLED" )' in
        scope_patch,
        "a standard Steam launch cannot bypass the optional Game Mode boundary cleanly")
require('"loader_route_skipped_non_game_target"' in scope_patch and
        'unsetenv( "FORGEPLAY_STEAM_GAME_PROCESS" )' in scope_patch and
        'unsetenv( "FORGEPLAY_GAME_MODE_DIRECT_TARGET" )' in scope_patch,
        "out-of-tree targets do not return to the standard loader cleanly")
target_scope_body = function_body(
    scope_added_source,
    "forgeplay_game_mode_image_path_is_eligible",
)
for fragment in (
    "image_path->Buffer",
    "image_path->Length",
    '"steamapps"',
    '"common"',
    '"_CommonRedist"',
):
    require(fragment in target_scope_body,
            f"Game Mode target scope lacks its structural boundary: {fragment}")
for forbidden in (
    "/Users/",
    "/Volumes/",
    "EnclosureDisk",
    "SteamLibrary",
    "E:\\\\",
):
    require(forbidden not in target_scope_body,
            f"Game Mode target scope hardcodes a machine-specific value: {forbidden}")
require("argv[2]" not in scope_patch,
        "Game Mode target scope trusts the mutable command line instead of the resolved image")

print("wine_game_mode_process_host_routing_static=PASS")
print("game_identity_renderer_independent=yes")
print("game_mode_target_scope=each-eligible-steam-game-tree-executable")
print("launcher_descendant_host_routing=enabled")
print("steam_redistributable_host_routing=excluded")
print("fixed_bundled_host_only=yes")
print("fixed_host_icon_preserved=yes")
print("same_process_exec_contract=present")
print("wine_loader_host_failure=fail_closed")
print("host_post_identity_failure=fail_closed")
print("wine_loader_noexec_semantics=preserved")
print("activity_monitor_process_label=fixed-host-identity")
print("fixed_address_host_debug_dylib=disabled")
print("distant_reservation_rip_reference=absent")
PY
