# Lupain / 루팡

Copyright (C) 2026 Facta-Leopard.

The author-owned Lupain session/control code, view, build integration and new
masked Fopl illustration identified in `SCOPE.json` are licensed under
GNU General Public License, version 3 only (`GPL-3.0-only`). The user explicitly
selected this license on 2026-10-22. See `../GPL-3.0-only.txt` for the unmodified
license text. This is a project license declaration, not a government copyright
registration or a grant of another author's rights.

The integration adapts the author's LUPAIN 1.0.1 macOS application. It adds bounded
IPC, shared session ownership, proxy restoration/readback, signed engine packaging
and ForgePlay launch-window/keyring controls. The original project's files remain
unchanged. The original `updates` route identifier is retained only for existing
window restoration; it is no longer an updater.

## Third-party engine

SpoofDPI 1.5.5, source revision `0b49eafe80fca3636fdf58a338b405f663c9c37d`,
Copyright 2023 Kwanghoo Park and contributors, retains **Apache-2.0**.
It is an independently executed program controlled by documented CLI flags.
The upstream binary is preserved without code changes; distribution signing
changes its code signature and final-file hash. Its authorship is not reassigned
to Facta-Leopard and its original license is not replaced with GPL.

- [Official release](https://github.com/xvzc/spoofdpi/releases/tag/v1.5.5)
- Archive SHA256: `e9948c59e52f6b983846c960278bbd1b07d4f63204ff434a9e2ce08da5a1d707`
- Original executable SHA256: `cdb79b8d18fae266d2747bf264738e2f31f1e88f4871071199bd053668ba8c59`
- Upstream SPDX SBOM SHA256: `ce3e8072c90bd75f71679a93c74ee6092d552fc5b85255d406974f88b297bd3b`

`ThirdParty/` retains the original engine license, upstream SPDX SBOM and notices
for the 41 dependency entries in `dependency-register.json`. Their MIT, BSD and
Apache notices/patent terms remain applicable. The upstream register leaves Go's
stdlib at `NOASSERTION`; the retained `stdlib/LICENSE` is the Go Authors' BSD
three-clause text, accompanied by `stdlib/PATENTS`. This clarification does not
rewrite the upstream SBOM. Apple system libraries are dynamically linked and
are not redistributed here.

## Scope and source delivery

The GPL scope is the listed Lupain files and the explicitly identified Lupain
integration additions, not every file in ForgePlay or any third-party engine.
The old compiled-wrapper exception must not be inferred for these new files.
The public source packager includes their source, this notice, dependency notices
and the build recipe. Distribute matching covered source with a Lupain-enabled
ForgePlay binary. Do not treat an old public source archive as covering this work.

The newly generated `LauncherArtwork/Fopl/lupain.png` is included in this GPL
scope. Existing Fopl artwork, character branding and unrelated illustrations
retain their existing notices; no blanket artwork or trademark grant is made.
Imagegen was used to edit the author's existing Fopl reference: preserve brown
twintails, amber eyes, star pin, headset, cream/orange outfit and gold keyring;
add a black domino mask, use a friendly standing pose, remove the old download
props, and retain real transparency. No third-party character image was used.

## User data and distribution

This is a local HTTP proxy, not a remote VPN or a guarantee of game/UDP/QUIC
coverage. DNS queries go to Cloudflare DoH. The UI discloses this before enabling.
No browsing history, destinations or traffic logs are retained by the integration.
The private recovery record stores original proxy settings, not traffic content.

The current implementation targets directly distributed, non-sandboxed Mac builds.
Sandboxed Distribution/AppStore packaging disables the feature and omits its
executables. No Vision app changes or App Store approval are implied.
