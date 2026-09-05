# ForgePlay modifications to Wine 11.12

ForgePlay distributes a modified Wine 11.12 source and binary copy. This
notice records the license boundary and exact modification identity for that
copy; it does not replace Wine's upstream notices or the license texts shipped
with the Runtime.

## Exact modification snapshot

- Modification snapshot date: 2026-09-05
- Upstream release: Wine 11.12
- Upstream archive SHA-256:
  `d3bc091192d985846c9f20065cc81f21331f01e22b736b131e3449e1306671bc`
- Ordered patch count: 25
- Patch-set SHA-256:
  `b7939311ece8dcf37d6228e239932bec9c2f81ab2663b6f15017be51ec6f2493`
- Patched source-tree SHA-256:
  `5f5d93000e059d4ab388bc4ecfcd7dbdd19ada0a5da1400d28ea58f46ba95038`

The complete preferred form of the ForgePlay changes is the ordered patch set
shipped under `Patches/`. `SOURCE-AVAILABILITY.md` gives the reconstruction
procedure and exact order. Omitting or reordering a patch does not reconstruct
the distributed Wine copy.

## License boundary

Wine's unmodified material and ForgePlay modifications not expressly
converted below retain their applicable GNU Lesser General Public License,
version 2.1 or later (`LGPL-2.1-or-later`), notices, and copyrights. The
unmodified license text is shipped as `Legal/Wine/COPYING.LIB`.

The exact copies modified by these two Game Mode patches are designated for
conversion to GNU General Public License, version 3 only (`GPL-3.0-only`),
under LGPL 2.1 section 3:

- `Patches/wine-11.12-game-mode-process-host-routing.patch`
- `Patches/wine-11.12-game-mode-direct-target-scope.patch`

Those patches modify the distributed Wine copy directly. Their GPL effect is
not confined to the standalone patch files; a Wine copy containing those
changes must be conveyed consistently with GPLv3 as a combined derivative
work. Unmodified upstream Wine material retains its independent LGPL
permissions. The authoritative scope, file assignment, conversion basis, and
notices are shipped under `Legal/ForgePlayGameMode/`, including
`GAME_MODE_LICENSE_SCOPE.md`, `GAME_MODE_FILE_LICENSES.json`,
`GAME_MODE_NOTICE`, `GAME_MODE_SYMBOL_MANIFEST.md`, and the unmodified GPLv3
and LGPL 2.1 license texts.

All upstream Wine copyrights and attribution remain intact. This notice does
not relicense Apple D3DMetal, the bundled renderer payloads, GStreamer, fonts,
or any other separately identified third-party component; each retains its
own terms.
