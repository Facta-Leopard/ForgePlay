<!--
SPDX-FileCopyrightText: 2026 Facta-Leopard
SPDX-License-Identifier: GPL-3.0-only
ForgePlay Game Mode
Original source: https://github.com/Facta-Leopard/ForgePlay
-->

# ForgePlay GameModeProcessHost

This directory contains the source/build contract for one fixed, pre-signed
Game Mode process host. It does not claim that macOS Game Mode activates; that
requires user-observed device QA after the Runtime and app integration are
complete.

## Product boundary

- The outer ForgePlay app remains Apple Silicon `arm64` only.
- This host and the bundled Wine Unix runtime are `x86_64` internal components
  that run through Rosetta on Apple Silicon. They are not support for a
  different Mac product architecture.
- The bundle name and path are fixed:
  `ForgePlay.app/Contents/Helpers/GameModeProcessHost.app`.
- The Runtime path is fixed relative to that bundle:
  `ForgePlay.app/Contents/Resources/Runners/ForgePlayRuntime`.
- No game-specific app is generated, no external Runtime is discovered, and
  inherited values cannot select another host or Runtime.

## Implemented entry path

The implemented path is an opt-in beta Steam-child exec path. A standard Steam
launch does not select this host and continues through Wine's normal loader.
Renderer lineage can pass through Steam launchers, but ntdll captures the
Unix-only target identity for each child from Wine's resolved
`RTL_USER_PROCESS_PARAMETERS.ImagePathName`. A mutable command line or inherited
Windows variable cannot assert it. Every independently resolved executable
inside a separator-delimited `steamapps/common` game tree can enter the same
fixed host before PE mapping. This includes a real game executable started by a
launcher. `_CommonRedist`, targets outside the game tree, and standard sessions
continue through the normal Wine loader. This structural rule does not depend
on an account name, volume name, drive letter, library root, Steam App ID, or
game title.

The routed process keeps the fixed signed host identity and icon. Wine's normal
PE `RT_GROUP_ICON` application is suppressed only after the trusted loader has
selected this host; ForgePlay does not derive a process name or icon from the
game.
The host:

1. validates its fixed bundle and schema-3 Runtime identity;
2. validates that its signed or inherited App Group grants the compiled
   coordination container and fixed IPC/evidence paths;
3. validates the inherited host contract and exact bundled loader paths;
4. opens the coordinator's prefix lock without `FD_CLOEXEC`, verifies
   `FORGEPLAY_PREFIX_EXECUTION_LEASE_V1` prefix device/inode metadata, and holds
   a nonblocking shared `flock` for the rest of the process lifetime;
5. loads the exact bundled `x86_64-unix/ntdll.so` and calls `__wine_main` in the
   same PID with the original `argc` and `argv`.

Every host-side failure before `__wine_main` is entered records a bounded
failure event and exits nonzero. The host never execs a standard Wine loader,
and the patched Wine child loader also returns a failure status when this
required host cannot run. A Steam game child therefore cannot silently continue
outside Game Mode after a host validation or startup failure.

The outer app validates the complete bundled Runtime and host capability before
it enables routing. The host repeats the full schema-3 Runtime identity check.
There is no bootstrap or alternate Runtime identity.

On the same-process path, the host does not change the inherited current
directory, process environment, Wine socket descriptors, or game arguments.
Direct3D selection is an explicit per-Steam-session contract supplied by the
outer app: exactly one of D3DMetal, DXMT, D9VK, or DXVK is active. Renderer
selection and Game Mode eligibility remain independent. Selecting the beta
host is explicit per Steam session and does not change the selected renderer.

The following inherited keys are mandatory and validated:

- `FORGEPLAY_GAME_MODE_HOST_ENABLED=1`
- `FORGEPLAY_GAME_MODE_HOST_MODE=steam-child`
- `FORGEPLAY_STEAM_GAME_PROCESS=1`
- `FORGEPLAY_GAME_MODE_DIRECT_TARGET=1`
- `FORGEPLAY_GAME_MODE_HOST_ROUTED=1`
- `FORGEPLAY_GAME_MODE_HOST_EXECUTABLE`
- `FORGEPLAY_GAME_MODE_HOST_BUNDLE_IDENTIFIER`
- `FORGEPLAY_GAME_MODE_HOST_EXECUTABLE_SHA256`
- `FORGEPLAY_GAME_MODE_HOST_NTDLL`
- `FORGEPLAY_GAME_MODE_HOST_EVIDENCE_FILE`
- `FORGEPLAY_GAME_MODE_HOST_RUN_ID`
- `FORGEPLAY_PREFIX_EXECUTION_LOCK`
- `WINELOADERNOEXEC=1`
- `WINEPREFIX`
- `WINELOADER`
- `WINESERVER`
- `WINE_SERVER_ROOT`
- `WINE_MACH_SERVICE_NAME`

`WINELOADER`, `WINESERVER`, and the host ntdll key must resolve to this exact
bundled Runtime. The server root must be
`<app-group>/Library/Caches/ForgePlay/WineServer/<prefix-hash16>` and the Mach
service must be `<app-group>.wineserver.<prefix-hash16>`. The hash is the first
eight bytes of SHA-256 over the canonical `WINEPREFIX` path.

The prefix lock must be the coordinator-derived file under
`<app-group>/Library/Application Support/ForgePlay/OperationLocks`. Its name is
the full SHA-256 identity used by `PrefixExecutionLease`; a caller cannot point
the host at a different app-group file that happens to contain similar
metadata. Both that lock and the evidence file must remain owner-only `0600`
regular files.

Sandboxed Distribution, App Store, and Debug hosts use the same child contract
as their bundled Wine executables: `app-sandbox + inherit +
allow-unsigned-executable-memory + disable-library-validation`. They do not
independently declare App Group, file-selection, bookmark, or network sandbox
keys; those static rights come from the signed parent ForgePlay app.

The direct Developer ID Release host is not sandboxed and does not declare
`inherit`. Its exact entitlements are the one ForgePlay App Group plus
`allow-unsigned-executable-memory` and `disable-library-validation`. The direct
profile name describes where the outer app keeps product data: the user's
normal `~/Library/Application Support/ForgePlay`. The App Group remains a
narrow coordination boundary for Game Mode IPC, evidence, Wine-server state,
and prefix leases; prefixes and other product data are not moved into it.

## LaunchServices boundary

The fixed app declares `LSSupportsGameMode=true`, the games category,
`NSPrincipalClass=WineApplication`, the ForgePlay app icon, and deliberately
omits `LSUIElement`.

Sandboxed LaunchServices does not reliably deliver arguments or environment.
The fixed app-group request root is:

`Library/Application Support/ForgePlay/GameModeLaunchRequests`

The current Swift request schema records coordination identity and a Steam App
ID, but it does not carry a validated executable, working directory, arguments,
or security-scoped authorization. Consequently this native host does not claim
or execute those requests yet. A LaunchServices start fails with the redacted
reason `launchservices_stage0a_request_execution_unsupported`; it never guesses
an executable from an App ID or scans the filesystem for a candidate.

## Evidence

Host events are redacted reason records under:

`Library/Application Support/ForgePlay/GameModeProcessHostEvidence/GameModeProcessHost-v1.jsonl`

Records use the shared `producer`, `event_code`, `run_identifier`, and
`darwin_pid` keys, plus schema version, timestamp, and Runtime identity. Paths,
command arguments, account data, and environment values are not logged. Runtime
fields are named as host build bindings; only the later
`runtime_identity_verified` event proves that the on-disk Runtime matched them.

## Build contract

The Xcode target renders a concrete host plist during its build-identity phase
and passes it to the linker as `__TEXT,__info_plist`. Xcode's macOS application
product type forces its generic embedded-plist switch off, so relying on that
switch would produce a host that fails its own identity contract. The host
compares the embedded and bundle plist identities before loading Wine.

`build-game-mode-process-host.sh` produces the sandbox-inheriting profile and
requires:

- a clean schema-3 ForgePlay Wine 11.12 Runtime;
- the corresponding validated Wine source tree;
- a ForgePlay-owned bundle identifier and exact shared app group;
- a host-specific provisioning profile containing those identifiers;
- the main ForgePlay `.icns` resource;
- a concrete signing identity.

It stages a new bundle and refuses to overwrite an existing output. It verifies
the fixed Mach-O segment addresses, embedded plist, exported preload symbol,
architecture, entitlements, and code signature. It does not build an archive
and does not modify Xcode project metadata.

The Xcode target uses `STRIP_STYLE = non-global`. Application targets otherwise
use the `all` strip style during install/archive, which removes executable
exports that no linked dylib references. Wine resolves
`wine_main_preload_info` with `dlsym`, so retaining global symbols is part of
the host ABI rather than optional debug metadata.
