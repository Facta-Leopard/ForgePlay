# ForgePlay License Manifest

ForgePlay is a multi-license distribution. A source license applies only to
the files and code expressly identified by its scope document or per-file
notice.

This manifest records the ForgePlay Game Mode and Frame Generation license
policies. It is not a license grant for unrelated ForgePlay-authored material.

## ForgePlay Game Mode

The Game Mode code identified in
`LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md` is licensed under the
GNU General Public License, version 3 only
(`GPL-3.0-only`), including the additional terms recorded in that scope.

Unmodified GPLv3 text: `LICENSES/GPL-3.0-only.txt`

The source-scope boundary does not override GPL obligations for a combined
executable or modified Wine copy that contains covered Game Mode code.

## ForgePlay Frame Generation

The ForgePlay-authored Frame Generation code identified in
`LICENSES/ForgePlayFrameGeneration/FRAME_GENERATION_LICENSE_SCOPE.md` is
licensed under `GPL-3.0-only`, with the same categories of GPLv3 section 7
additional terms as Game Mode: preserved author attribution, identification
of modified versions and origin, and no trademark license.

The external file and symbol manifests bind this assignment to the
`1.2_Release` source at commit
`72a2598c99f0b649d1384ed0763a00037f5d1d2e`. They carry the notices without
changing the identified native, Swift, configuration, test, or Wine patch
bytes. This source-only license preparation is not a new binary build claim.

The Frame Generation assignment excludes Wine-derived loading and
environment glue and all Apple binaries. Those boundaries do not override
GPLv3 obligations for any conveyed combined work containing covered code.

## Other ForgePlay-authored material

This manifest does not directly designate unrelated ForgePlay-authored source
as Game Mode or Frame Generation GPL source. Those files retain the separate
license expressly stated for them.

This statement does not authorize conveying a combined work in a manner that
withholds rights required by GPLv3 for the covered Game Mode or Frame
Generation code.

## Wine and Wine-derived material

Unmodified Wine material and non-converted copies retain their applicable
LGPL permissions. The GameModeProcessHost and the two Game Mode Wine patch
copies identified in the Game Mode scope are designated for conversion to
`GPL-3.0-only` under LGPL 2.1 section 3. A public binary release must first
make the corresponding source notices consistent with that designation.

Unmodified LGPL 2.1 text: `LICENSES/LGPL-2.1-or-later.txt`

All upstream copyrights, license notices, source-availability materials, and
provenance records remain required.

The Frame Generation glue in
`wine-11.12-forgeplay-metal-window-surface-contract.patch` and
`wine-11.12-steam-session-compatibility-controls.patch` remains within its
separate `LGPL-2.1-or-later` source-copy boundary. The Frame Generation
assignment does not convert or relicense those patch copies.

## Third-party material

Third-party components, artwork, fonts, notices, and trademarks remain under
their respective terms. Nothing in this manifest replaces those terms or
grants a GPL compatibility exception on behalf of another copyright holder.

## Direct DMG third-party component contract

The ForgePlay direct DMG intentionally includes D3DMetal as a separately
identified third-party runtime component under its own Apple terms. D3DMetal
is not designated as ForgePlay Game Mode or Frame Generation source and is
not relicensed under `GPL-3.0-only`.

The `bundled-direct-dmg` release verifier requires the Apple software license,
acknowledgements, framework license, and preserved original Apple code
signature to accompany that payload. This distribution decision does not
replace or expand Apple's terms, and it does not reduce the GPLv3 source and
notice obligations that apply to ForgePlay Game Mode or Frame Generation.
