# ForgePlay Frame Generation GPL-3.0-only scope

Copyright (C) 2026 Facta-Leopard

## 1. Assignment and exact source identity

The ForgePlay-authored Frame Generation implementation identified by
`FRAME_GENERATION_FILE_LICENSES.json` and
`FRAME_GENERATION_SYMBOL_MANIFEST.md` is licensed under the GNU General
Public License, version 3 only (`GPL-3.0-only`). The unmodified license text
is at `LICENSES/GPL-3.0-only.txt`.

This assignment is bound to `1.2_Release`, base commit
`72a2598c99f0b649d1384ed0763a00037f5d1d2e`. The file manifest records the
exact SHA-256 of each dedicated covered file. The symbol manifest identifies
the covered declarations and Frame Generation-specific statements in mixed
files at that commit. Unrelated declarations are not newly licensed merely
because they share a file.

These external notices deliberately preserve the base source, native code,
Swift code, configurations, tests, and content-addressed Wine patch bytes.
They apply the following notices to the identified ForgePlay-authored code
without inserting headers into those files:

```text
SPDX-FileCopyrightText: 2026 Facta-Leopard
SPDX-License-Identifier: GPL-3.0-only
```

This is an offline, source-only license preparation. It does not assert that
a new binary was built, signed, published, or released. A later publication
must bind its source inventory to both this base identity and the exact
conveyed preparation tree.

## 2. Covered implementation

The dedicated assignment covers the five files in
`Native/D3DMetalFrameGenerationProxy/`,
`Sources/ForgePlay/FrameGeneration/FrameGenerationDomain.swift`, the proxy
xcconfig, and the three dedicated test/contract files listed path-exactly in
the file manifest.

The native implementation includes the `FPD3DMetalFrameGenerationProxyGetAPIV1`
interface, the session and public Metal observation integration, the
project-owned state machine, current-frame replay, the 50:50 midpoint shader,
output scheduling, resource ownership, telemetry, and Frame Check overlay.
The Swift assignment includes configuration and validation, launch/persistence
plumbing, UI controls, and observation parsing/diagnostics only as delimited
by the symbol manifest. That manifest also identifies the related build and
verification sections. It does not assign an entire mixed file by implication.

The assignment concerns copyright held by Facta-Leopard. The repository's
architecture contract describes the implementation as ForgePlay-owned and
based on public platform APIs; it is not an independent authorship audit or
a complete clean-room provenance record. No license or ownership claim over
third-party material is created by this notice.

## 3. Wine-derived glue remains separately identified

The following exact patch copies are excluded from the Frame Generation GPL
assignment and retain their `LGPL-2.1-or-later` source boundary:

- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-forgeplay-metal-window-surface-contract.patch`
- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-steam-session-compatibility-controls.patch`

The first modifies Wine `winemac.drv` and adds `metal_surface_contract.c`
with an explicit LGPL-2.1-or-later notice. Its `forgeplay_framegen_*` ABI
types, `framegen_*` loader/session/view/error glue, and Metal-view adapters
are not the independently assigned native proxy implementation. The second
modifies Wine process/environment and other compatibility code; its Frame
Generation key mappings and Unix environment propagation remain Wine-derived
glue. Preserve their exact patch bytes, upstream notices, and source identity.

Wine is version 11.12. The source archive SHA-256 is
`d3bc091192d985846c9f20065cc81f21331f01e22b736b131e3449e1306671bc`;
the current final patched source tree SHA-256 is
`5f5d93000e059d4ab388bc4ecfcd7dbdd19ada0a5da1400d28ea58f46ba95038`.
The authoritative reconstruction records remain
`Config/ForgePlayRuntimeSourceIdentity.lock.json` and
`Config/ForgePlayRuntimePatchProvenance.lock.json`. Hashes establish identity,
not independent authorship. This notice does not change those records.

The existing Game Mode scope separately designates the GameModeProcessHost
and two Game Mode Wine patch copies for GPL conversion. That existing policy
is not extended to the two Frame Generation glue patch copies by this notice.

## 4. Apple and other third-party exclusions

D3DMetal, MetalFX, other Apple binaries, Apple SDK/framework implementations,
third-party renderer binaries and sources, Wine upstream material, artwork,
fonts, and trademarks are not assigned a new license by this scope. Using an
Apple public API does not make that API's implementation ForgePlay source.
Apple binaries are absent from the source-only export and retain their own
terms. No Apple or other third-party copyright is claimed or relicensed.

The direct-DMG contract separately requires the configured D3DMetal payload's
Apple license, acknowledgements, framework license, and original Apple code
signature. This notice does not replace or expand those terms and grants no
GPL compatibility or linking exception for D3DMetal or any other component.

## 5. Combined-work and Corresponding Source obligations

The application target compiles the covered Swift code into the main
ForgePlay executable. The proxy is a separate dylib embedded by the
application and loaded by Wine's macOS driver in the game process. A source
filename, target boundary, external notice, or dynamic-loading boundary does
not itself eliminate obligations for a conveyed combined work.

A distribution of a combined work containing covered code must provide the
rights and version-matched Corresponding Source required by GPLv3, including
the applicable source and build, packaging, installation-control, and
verification material. Preserve upstream notices and all applicable GPL and
LGPL source obligations. Separately licensed patch copies retain their
independent permissions; that fact does not narrow the existing combined
Wine obligations described in the Game Mode scope. This scope grants no
authority to withhold required rights or to distribute third-party binaries
without permission under their own terms.

## 6. GPL permissions

The GPL grants advance permission for compliant use, copying, modification,
commercial use, and conveyance. No separate permission from Facta-Leopard is
required when all GPLv3 conditions are satisfied. This grant does not
authorize proprietary distribution that omits GPL obligations. Separate
licensing can be offered only for rights the licensor actually owns.

## 7. Additional terms under GPLv3 section 7

These are the same categories of additional terms used for ForgePlay Game
Mode, with Frame Generation attribution. They apply only to material for
which Facta-Leopard holds the applicable copyright.

### Author attribution

Source distributions and legal notices accompanying non-source distributions
must preserve:

```text
ForgePlay Frame Generation
Copyright (C) 2026 Facta-Leopard
Original source: https://github.com/Facta-Leopard/ForgePlay
```

If an interactive distribution provides an About, Legal, Credits, or
equivalent Appropriate Legal Notices interface, the attribution must also be
preserved there.

### Modified versions and origin

Modified versions must be marked as modified in a reasonable manner. They
must not misrepresent themselves as an official ForgePlay release or imply
endorsement by Facta-Leopard.

### No trademark license

No trademark rights in the ForgePlay name or logo are granted. Truthful
references required to identify the origin of the covered code are not
prohibited.

## 8. Source notice delivery

Convey this scope, `FRAME_GENERATION_NOTICE`, both manifests, and the
unmodified GPLv3 text with the identified source and applicable binary legal
material. Keep this exact-base assignment distinguishable from later source
modifications. A materially changed covered file needs an updated identity
record; do not silently use a base-release hash for different bytes.

The official repository's no-external-code-contributions maintenance policy
is not a restriction on GPL rights to fork, modify, or redistribute covered
code. No UI or website modification is performed by this license preparation.
