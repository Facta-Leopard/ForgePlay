# ForgePlay License Manifest

ForgePlay is a multi-license distribution. A source license applies only to
the files and code expressly identified by its scope document or per-file
notice.

This manifest records the final ForgePlay Game Mode license policy. It is not
a license grant for unrelated ForgePlay-authored material.

## ForgePlay Game Mode

The Game Mode code identified in
`LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md` is licensed under the
GNU General Public License, version 3 only
(`GPL-3.0-only`), including the additional terms recorded in that scope.

Unmodified GPLv3 text: `LICENSES/GPL-3.0-only.txt`

The source-scope boundary does not override GPL obligations for a combined
executable or modified Wine copy that contains covered Game Mode code.

## Other ForgePlay-authored material

This manifest does not directly designate unrelated ForgePlay-authored source
as Game Mode GPL source. Those files retain the separate license expressly
stated for them.

This statement does not authorize conveying a combined work in a manner that
withholds rights required by GPLv3 for the covered Game Mode code.

## Wine and Wine-derived material

Unmodified Wine material and non-converted copies retain their applicable
LGPL permissions. The GameModeProcessHost and the two Game Mode Wine patch
copies identified in the Game Mode scope are designated for conversion to
`GPL-3.0-only` under LGPL 2.1 section 3. A public binary release must first
make the corresponding source notices consistent with that designation.

Unmodified LGPL 2.1 text: `LICENSES/LGPL-2.1-or-later.txt`

All upstream copyrights, license notices, source-availability materials, and
provenance records remain required.

## Third-party material

Third-party components, artwork, fonts, notices, and trademarks remain under
their respective terms. Nothing in this manifest replaces those terms or
grants a GPL compatibility exception on behalf of another copyright holder.

## Direct DMG third-party component contract

The ForgePlay direct DMG intentionally includes D3DMetal as a separately
identified third-party runtime component under its own Apple terms. D3DMetal
is not designated as ForgePlay Game Mode source and is not relicensed under
`GPL-3.0-only`.

The `bundled-direct-dmg` release verifier requires the Apple software license,
acknowledgements, framework license, and preserved original Apple code
signature to accompany that payload. This distribution decision does not
replace or expand Apple's terms, and it does not reduce the GPLv3 source and
notice obligations that apply to ForgePlay Game Mode.
