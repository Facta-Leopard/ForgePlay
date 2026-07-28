# ForgePlay Runtime Source Availability

This package contains Wine 11.12 under the GNU Lesser General Public License 2.1 or later.
The corresponding source is available without relying on a developer machine path:

- Upstream Wine 11.12 source archive: https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz
- Upstream detached signature: https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz.sign
- Upstream source archive SHA-256: `d3bc091192d985846c9f20065cc81f21331f01e22b736b131e3449e1306671bc`
- Wine release-key fingerprint: `DA23579A74D4AD9AF9D3F945CEFAC8EAAF17519D`
- ForgePlay modifications: the complete patch set shipped in this package under `Patches/`
- Independent renderer behavior contract: `Patches/wine-11.12-forgeplay-d3dmetal-bridge-contract.md`
- Validated corresponding source tree SHA-256: `01f174c44664cbc3a4f931b536080facef0a70d6bfa2c5603182abdba18ddc73`
- Packaged ForgePlay patch-set SHA-256: `1c5d85142f26f7d588133852f4710594c34ea7360bbe616cefccb1d33ff1d1c3`

The upstream archive and the complete packaged patch set are the machine-readable materials used to
reconstruct the modified Wine source for this runtime. The local `FORGEPLAY_WINE_SOURCE` build input
is validated during packaging, but its filesystem path is never written into the app bundle.
Wine's `LICENSE`, `COPYING.LIB`, and `AUTHORS` files are validated from that source tree and
copied into `Legal/Wine`.

To reconstruct the modified source from the public upstream archive and the patch files in this
package, download and verify the archive, extract it, and apply these patches in order:

```sh
curl -fLO "https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz"
curl -fLO "https://dl.winehq.org/wine/source/11.x/wine-11.12.tar.xz.sign"
printf '%s  %s\n' 'd3bc091192d985846c9f20065cc81f21331f01e22b736b131e3449e1306671bc' wine-11.12.tar.xz | shasum -a 256 -c -
gpg --status-fd 1 --verify wine-11.12.tar.xz.sign wine-11.12.tar.xz 2>/dev/null | \
  grep -F 'VALIDSIG DA23579A74D4AD9AF9D3F945CEFAC8EAAF17519D'
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
  Patches/wine-11.12-executable-scoped-process-arguments.patch \
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
  Patches/wine-11.12-steam-game-cef-browser-process-policy.patch; do
  patch -d wine-11.12 -p1 < "$patch_file"
done
```

Signature verification requires the WineHQ release-signing key and a local OpenPGP verifier. The
SHA-256 values above identify the exact validated source tree and packaged patch set; they are not
local paths and do not expose the packaging workstation. The source-tree fingerprint excludes VCS
metadata, Finder metadata, patch backup/reject files, and the generated `configure` file; it includes
`configure.ac`, which is the authoritative build-system source modified by the ForgePlay patch set.

ForgePlay's project-owned Windows Steam launcher source is copied into
`Sources/forgeplay_steam_launcher.c` and built into
`wine/lib/wine/x86_64-windows/forgeplay-steam-launcher.exe` during packaging. It directly invokes
Win32 `CreateProcessW` through the complete ForgePlay-owned
`--detach -- <Windows command...>` contract implemented in that source file.

ForgePlay's executable-scoped process argument patch keeps Valve's
`steamwebhelper.exe` in place and applies the Steam CEF compatibility arguments from Wine's
32-bit or 64-bit process-creation path. Steam updates can therefore replace their own executable
without deleting ForgePlay's launch policy. After successful target creation, Wine records only the
Windows PID and final target command line in the host-created per-launch observation file; it does
not serialize the process environment.

ForgePlay's Steam game CEF browser policy is activated by the host with
`FORGEPLAY_STEAM_GAME_CEF_BROWSER_POLICY_ENABLED=1` for a Steam session, then applies only to a
root executable in a separator-delimited `steamapps/common` tree that contains the generic
`libcef.dll` runtime marker. It appends one `--in-process-gpu` argument so the CEF browser process
does not depend on Wine's incompatible out-of-process GPU startup path. CEF `--type=` subprocesses,
non-CEF executables, Steam infrastructure roles, and command lines that already contain the argument
remain unchanged. The executable itself is never replaced or modified.

ForgePlay's Steam game renderer process patch leaves Steam and Steam WebHelper on the base Wine
renderer environment. Before every Steam launch the user must select exactly one of D3DMetal, DXMT,
D9VK, or DXVK. That single renderer is applied to Steam game children for the whole session.
Automatic Direct3D import classification, loader-stage profiles, and mixed renderer compositions
are not used. A missing or invalid manual selection is rejected instead of falling back to another
renderer. The Unix loader places only the selected renderer root ahead of Wine's compiled DLL
directory, while the Windows loader prepends only its matching i386 or x86_64 directories. Route V2
records use `manual-session-d3dmetal`, `manual-session-dxmt`, `manual-session-d9vk`, or
  `manual-session-dxvk` as the exact selection reason and describe the selected plan. A Load V3
  record proves an actual renderer load only when its
  resolved path exactly matches the active architecture-specific allowlist and reports
  `path-owner=verified`. Renderer state remains process-scoped and is scrubbed from Steam
  infrastructure children. The host-owned manual selection, architecture component, and matching DLL
  path controls remain available when Steam reexecutes itself, so the relaunched client can construct
  the same selected renderer for later game children. Separator-delimited `_CommonRedist` descendants
  are infrastructure and never enter the game-renderer route.

ForgePlay's Game Mode process-host routing is an explicit beta selection and remains off for a
standard Steam launch. It keeps Steam's game lineage separate from the selected Direct3D renderer.
The direct-target scope derives a Unix-only identity independently for each child from Wine's
resolved `RTL_USER_PROCESS_PARAMETERS.ImagePathName`, not a mutable command line or inherited
Windows variable. Every resolved executable in a separator-delimited `steamapps/common` game tree
can enter the same fixed host, including a long-lived game child started by a launcher, regardless
of account, volume, drive letter, library root, Steam App ID, or game title. `_CommonRedist` and
targets outside that tree clear the Game Mode target identity and continue through the standard
Wine loader. When the beta host is requested, each accepted target enters the fixed pre-signed
`Contents/Helpers/GameModeProcessHost.app` before PE mapping. Its argv, current directory,
inherited handles, Wine server context, and Darwin PID remain on the original Steam-created process
path. A host contract or exec failure for an accepted target remains fail-closed. The helper
retains its fixed executable, process identity, and icon; ForgePlay does not replace them with a
per-game display name or PE icon.

ForgePlay's external-storage grant activation patch runs explicitly at the start of both the Unix
`ntdll` loader and `wineserver`. If all four grant environment values are absent, Wine continues
normally. If any value is present, all four must be non-empty and the project-owned bridge must load
and accept the manifest for external storage to become accessible. A rejected or incomplete grant
emits a bounded, path-free failure reason and continues through Wine's normal sandbox-limited path;
this preserves launch for games that do not need the unavailable external root. Successful
activation emits only the bounded `FORGEPLAY_EXTERNAL_STORAGE_GRANT_V1` status record; it does not
log a storage path or bookmark payload.

ForgePlay's managed Darwin process journal patch appends a bounded record when the Unix Wine loader
or wineserver begins. Each record contains only the launch UUID, opaque prefix scope, runtime
fingerprint, Darwin PID, and kernel process-start time; the owner-private file path is created by the
host and is never serialized. The immutable Unix launch key
`FORGEPLAY_MANAGED_WINE_PROCESS_EVIDENCE_FILE` identifies that pre-created journal across every
Wine child, including children that replace their Windows environment. At shutdown ForgePlay
validates the exact bundled executable path and
the unchanged start identity before signaling that PID, then reads the journal again after
`SIGTERM`, `SIGKILL`, and the wineserver barrier. An absent or invalid journal cannot be
misreported as a clean launch session.

ForgePlay's D3DMetal bridge is implemented in the project-owned
`dlls/ntdll/unix/forgeplay_d3dmetal.c` source from the documented public behavior contract. The
bridge is disabled unless the selected game child carries ForgePlay's explicit activation and target
selectors. It resolves only the public non-native-code-region ABI from the bundled D3DMetal shared
library, registers loaded PE image ranges, and leaves Wine 11.12's upstream Unix-call table intact.
The manually selected exact D3DMetal route also enables ForgePlay's scoped native pthread context.
That context synchronizes the mutable Windows static-TLS pointer through Darwin's Win64-reserved
slot and uses reentrant Apple time conversion interfaces so libc cannot overwrite the adjacent
mirrored PEB slot. The original native slots are restored before thread exit. Other renderer and
deferred routes keep Wine's standard GS switching.

ForgePlay's Metal renderer window-surface contract patch independently exports the public
`macdrv_functions` data symbol from `winemac.so`. Its table exposes Wine's display-state
initialization, window-data ownership, main-thread dispatch, and Metal view/layer operations through
a renderer-neutral ABI with compile-time offset checks and balanced acquire/release behavior.

The runtime uses Wine 11.12's standard wineserver synchronization path. No separate out-of-tree
synchronization backend is applied by the ForgePlay patch set.

ForgePlay's versioned SDL compatibility payload is copied into `SteamCompat/sdl2-compat` with its
license material. Packaging fails when the payload is missing SDL2.dll, SDL3.dll, or a license file.

ForgePlay's Windows font compatibility payload includes the exact Nanum Gothic Regular and Bold
font files under `wine/share/wine/fonts`. Their SIL Open Font License text is included under
`Legal/NanumGothic/OFL.txt`; packaging fails if any of these three files is missing or differs from
the reviewed SHA-256 digest. The opt-in `HKCU\\Software\\Wine\\Fonts\\ForcedReplacements`
contract is implemented in both Wine GDI and DirectWrite so an installed or game-private Tahoma
family cannot bypass the managed Korean family selected by ForgePlay.

ForgePlay's runtime policy plist and legal resources are copied separately from host binaries.
The packager never copies the checked-in runtime's `Frameworks` directory and rejects a renderer
source rooted in that output tree. The complete renderer payload is an explicit build-time input,
verified against `Config/ForgePlayRendererPayload.lock.json`, and becomes part of the self-contained
app runtime rather than an external runtime dependency.

The package materializes the 15 exact x86_64 Wine host dependency artifacts declared in
`Config/ForgePlayRuntimeDependencies.lock.json` into `wine/lib` and `wine/etc/vulkan/icd.d`, and
validates every source SHA-256 before copying. It neither scans the host dynamically for extra dependencies nor exposes
arbitrary top-level `Frameworks` libraries through a loader fallback path. Formula license files
are copied from the same pinned Cellar versions into `Legal/`.

Wine Media Foundation support is backed by the exact GStreamer 1.28.5 artifacts declared in
`Config/ForgePlayGStreamerPayload.lock.json`. Packaging verifies each official macOS SDK source
file, thins it to x86_64, isolates the closure under `wine/gstreamer`, and copies the corresponding
license material into `Legal/GStreamer`. Runtime launchers disable system GStreamer plug-ins and
expose only this reviewed payload.

Locked game renderer payloads stay under `Frameworks/renderer` and are not copied into the active
Wine module directories. The App Store payload preparation step removes Apple GPTK and D3DMetal
redistributables; Windows Steam uses base Wine Vulkan/MoltenVK rather than a game renderer overlay.
