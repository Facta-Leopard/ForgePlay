ForgePlay Game Mode — Wine-derived source notice
Release: 1.3_Release
Release source commit: a2165f50afe3964b238cb0cb9ecdc96787db9c4c
Copyright (C) 2000 Alexandre Julliard
Copyright (C) 2026 Facta-Leopard
SPDX-License-Identifier: GPL-3.0-only
Original ForgePlay source: https://github.com/Facta-Leopard/ForgePlay
Upstream Wine source: https://gitlab.winehq.org/wine/wine

Native/GameModeProcessHost/GameModeProcessHost.m derives its address
reservations, wine_main_preload_info ABI, replacement PROT_NONE mappings,
ntdll.so loading, and same-process __wine_main entry from Wine 11.12
loader/main.c, Copyright 2000 Alexandre Julliard.

Exact upstream Wine 11.12 loader/main.c SHA-256:
ab7df8fbca3308fba27b7f3e081526ca772ec81b39733d1b16f4374ef720e857

Exact unpatched Wine 11.12 dlls/ntdll/unix/loader.c SHA-256:
bf32acd84b67bd32004fe5ab8c810ab5d47243425f223744b4ca7a49d2547333

The upstream loader material was available under LGPL-2.1-or-later. The
identified GameModeProcessHost copy was converted to GPL-3.0-only under
LGPL 2.1 section 3. That conversion does not remove or transfer upstream
copyrights; unchanged upstream Wine retains its independent LGPL permissions.

ForgePlay adds host/runtime identity validation, inherited-environment and
application-group checks, prefix execution leases, and evidence recording.
The host loads the exact selected Wine ntdll.so and enters __wine_main in
the same process; it is not an independent reimplementation of Wine's
private loader ABI. The modified Wine loader installs WINELOADERNOEXEC=1
for that transition. Host and runtime must be rebuilt with matching runtime,
source, patch, build, and core-payload identities.

The two Game Mode Wine patch copies identified in LICENSE.txt retain their
GPL-3.0-only conversion and their exact version-matched bytes. Preserve all
Wine copyrights, Wine LICENSE, Wine COPYING.LIB, GPL-3.0-only text, this
notice, and the applicable complete native/modified-Wine source and build
materials when distributing the covered work. These obligations are not
replaced by the separate permission for the author-owned Swift wrapper.
