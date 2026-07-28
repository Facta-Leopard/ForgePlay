<!--
SPDX-FileCopyrightText: 2000 Alexandre Julliard
SPDX-FileCopyrightText: 2026 Facta-Leopard
SPDX-License-Identifier: GPL-3.0-only
ForgePlay Game Mode
Original source: https://github.com/Facta-Leopard/ForgePlay
-->

# GameModeProcessHost source and license contract

`GameModeProcessHost` is a fixed ForgePlay-owned Mach-O that enters the exact
bundled Wine 11.12 `__wine_main` in the existing Darwin process. It is not an
independent reimplementation of Wine's private loader ABI.

## Wine-derived portion

The following implementation details in `GameModeProcessHost.m` are derived
from Wine 11.12 `loader/main.c`:

- the `WINE_RESERVE` zero-fill segment and its `0x1fffff000` size;
- the `WINE_TOP_DOWN` zero-fill segment and its `0x001ff0000` size;
- the exported `wine_main_preload_info` ABI;
- replacement of both zero-fill mappings with fixed `PROT_NONE` mappings;
- loading `ntdll.so`, resolving `__wine_main`, and entering it in the same PID.

The patched Wine 11.12 `dlls/ntdll/unix/loader.c` installs
`WINELOADERNOEXEC=1` before entering this fixed host, and `__wine_main` consumes
that state to avoid running loader selection twice before unsetting it. A host
validation or startup failure returns nonzero; neither the patched Wine loader
nor the host can re-exec a standard Wine loader. The reviewed unpatched Wine
11.12 file has SHA-256:

`bf32acd84b67bd32004fe5ab8c810ab5d47243425f223744b4ca7a49d2547333`

The reviewed upstream loader portion was available under GNU LGPL 2.1 or
later. Under LGPL 2.1 section 3, this identified `GameModeProcessHost` copy is
converted to and distributed under `GPL-3.0-only`. The conversion does not
remove or transfer upstream copyrights, and the unchanged upstream Wine source
retains its independent LGPL permissions. The reviewed loader input is Wine
11.12 `loader/main.c` with SHA-256:

`ab7df8fbca3308fba27b7f3e081526ca772ec81b39733d1b16f4374ef720e857`

The complete corresponding Wine source contract is carried by the enclosing
ForgePlay Runtime:

- `Resources/Runners/ForgePlayRuntime/SOURCE-AVAILABILITY.md`
- `Resources/Runners/ForgePlayRuntime/BUILD-METADATA.md`
- `Resources/Runners/ForgePlayRuntime/Patches/`
- `Resources/Runners/ForgePlayRuntime/Legal/Wine/`

The build helper requires Wine's `LICENSE`, `COPYING.LIB`, and exact 11.12
loader source. It copies the license and this source contract into the fixed
host bundle. Distribution must keep the enclosing Runtime's complete source
availability and patch materials with the host.

## ForgePlay-owned portion

The host identity checks, app-group boundary, inherited-environment checks,
prefix execution lease, and redacted evidence records are ForgePlay-specific
code. They do not import another product's source, generated forwarding layer,
bundle identity, naming, or runtime-discovery mechanism.

## Exact-build boundary

The host is compiled with one schema-3 `RuntimeManifest.json` identity. Its
Game Mode path rejects any other manifest, Runtime identifier, source
fingerprint, patch fingerprint, build fingerprint, core-payload fingerprint,
or core file hash. Symbol-name compatibility alone never qualifies another
Runtime. A failed identity check terminates the child and cannot select an
alternate Runtime or a non-Game-Mode loader path.

The checked-in Runtime is schema 3, and a host built against its current
manifest may enter Game Mode only for that exact binary identity. Every clean
Wine rebuild must regenerate the host build identity from the new source,
patch-set, build, and core-payload fingerprints; carrying an older normal-path
identity forward is prohibited.
