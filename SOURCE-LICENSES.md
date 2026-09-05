# ForgePlay source license boundaries

This file is a guide to the license metadata in this source-only publication
tree. It does not create a license grant or replace `LICENSE.md`, the
component-specific scope documents, or third-party notices.

## Release and inventory binding

`SOURCE-INVENTORY.json` binds every exported file by path, type/mode, byte
length, SHA-256, Git blob object identity, and origin classification to the
exact release commit recorded in that manifest. Generated Xcode project files
also bind the exact generator blob, `project.yml` blob, and XcodeGen version;
injected notices and patch-license sidecars bind their exact template blobs.
Public ForgePlay Runtime object code must be built from that verified export
through `package-forgeplay-runtime.sh --public-source-package`; the generated
Runtime records the release commit, inventory digest, exact final Runtime
manifest hash, and core/host/build output fingerprints in
`PublicRuntimeBuildClaim.json`. This JSON and its nested receipt are an
**unsigned build claim awaiting release attestation**. They let a recipient
reproduce and compare a candidate, but do not establish that Facta-Leopard
authorized or released it. The conveyed application archive must then be built through the
exported `Scripts/build-public-distribution-archive.sh` command. Its bundled
`PublicDistributionBuildClaim.json` is likewise unsigned candidate evidence;
it binds the same release/inventory and
the exact Distribution project, configuration, entitlement, build,
packaging, installation, and verification graph. Only the official commercial
release flow can promote those claims: after strict Developer ID verification
it derives `PublicRuntimeReleaseAttestation.json` from the signature-sealed
embedded bytes and binds that attestation into the release manifest. Recipients
of this source export do not receive the Developer ID private key and cannot
mint an official ForgePlay release attestation. An internal clean-room build
is not a substitute for either public command graph when conveying the
combined GPL-covered application.

That public command graph names its non-source redistributable inputs
explicitly: the authenticated Wine source-archive argument, the trusted Git
repository argument, `FORGEPLAY_GSTREAMER_SDK_ROOT`,
`FORGEPLAY_RENDERER_SOURCE`, and `FORGEPLAY_RUNTIME_POLICY_SOURCE`. The fresh
Wine install root is created inside the same public build transaction rather
than accepted as a release input. The policy input supplies the separately distributed
Apple legal material, reviewed font payload, and SDL compatibility payload;
public mode rejects the checked-in/private Runtime output as an implicit
fallback. Their fixed license or payload hashes and the generated Runtime SBOM
remain enforced by the packager.

This is the Corresponding Source closure for the conveyed ForgePlay
executable, not only a patch archive. It includes all of `Sources/ForgePlay`,
the whole-file and mixed-file assignments in
`GAME_MODE_FILE_LICENSES.json` and `GAME_MODE_SYMBOL_MANIFEST.md`, the complete
`GameModeProcessHost` source and target configuration, the applied Wine source
and patch material, and the build, packaging, verification, and installation
control scripts selected by the exported project and release command graph.

## Current Wine source identity

`Config/ForgePlayRuntimeSourceIdentity.lock.json` records one release source
identity. `currentFinalPatchedSourceTree.sha256` is the canonical tree hash after the
  complete current patch order has been applied. The source materializer,
  Runtime packager, Runtime manifest, unsigned build claim, export verifier,
  signed release attestation, and release gate must all enforce this one
  current identity.

## Whole-file ForgePlay Game Mode code

Files listed in
`LICENSES/ForgePlayGameMode/GAME_MODE_FILE_LICENSES.json` under
`wholeFileSPDX` are licensed as complete files under `GPL-3.0-only`. Each such
file carries these markers in its header:

```text
SPDX-FileCopyrightText: 2026 Facta-Leopard
SPDX-License-Identifier: GPL-3.0-only
```

The Wine-derived `GameModeProcessHost.m` and its source contract retain the
additional upstream copyright and conversion provenance required by the
Game Mode scope.

## Mixed application and build files

Files listed under `mixedSymbolScope` contain both Game Mode responsibilities
and unrelated ForgePlay responsibilities. Their headers point to
`LICENSES/ForgePlayGameMode/GAME_MODE_SYMBOL_MANIFEST.md`, which identifies
the declarations and integration statements covered by `GPL-3.0-only`.

A whole-file GPL SPDX identifier is intentionally not placed on those mixed
files because the approved policy does not designate their unrelated contents
as whole-file Game Mode source.

## Content-addressed Wine Game Mode patches

The following patch bytes are version-matched Runtime fingerprint inputs and
must not be changed merely to insert a comment header:

- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-process-host-routing.patch`
- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-direct-target-scope.patch`

Their adjacent `.license` sidecars carry the `GPL-3.0-only` SPDX assignment
without changing the patch hashes. The authoritative conversion basis and
provenance remain in `GAME_MODE_FILE_LICENSES.json`,
`GAME_MODE_LICENSE_SCOPE.md`, and the Runtime patch provenance lock.

The current direct-target-scope patch revision evaluates every eligible
executable resolved inside a separator-delimited Steam
`steamapps/common` game tree, including a launcher's long-lived child, while
excluding `_CommonRedist`. The historical patch filename does not narrow the
license assignment to a root launcher.

## Other ForgePlay-authored material

### ForgePlay Frame Generation (1.2)

The independent frame-generation implementation is expressly designated
`GPL-3.0-only` in
`LICENSES/ForgePlayFrameGeneration/FRAME_GENERATION_LICENSE_SCOPE.md`.
The adjacent path-and-hash file manifest assigns dedicated implementation,
configuration and test files; the symbol manifest identifies frame-generation
responsibilities in mixed Swift and build files. These external notices
preserve the implementation bytes of `1.2_Release`.

The Wine-derived `wine-11.12-metal-window-surface-contract.patch` and
`wine-11.12-steam-session-compatibility-controls.patch` are separately retained
LGPL integration inputs. Running the ForgePlay proxy in a Wine process does
not assign Wine's source license to the independently authored proxy. This
source-scope distinction does not waive obligations for a combined program.

Apple's D3DMetal and platform frameworks are not covered by this GPL grant.

### Other source responsibilities

Publishing a file in this source tree does not by itself apply the Game Mode
GPL designation to the entire file or repository. Other ForgePlay-authored
material follows only the license expressly assigned to it by `LICENSE.md`, a
scope document, or a per-file notice. Do not add a blanket SPDX identifier
that would silently change that policy.

## Third-party and upstream material

Wine-derived source, unmodified upstream material, renderers, fonts, artwork,
and other third-party material retain their applicable copyrights, licenses,
and terms. A ForgePlay notice does not replace upstream attribution or
relicense a third-party component unless the authoritative scope explicitly
records a permitted conversion.

In particular,
`wine-11.12-steam-session-compatibility-controls.patch` modifies Wine-derived
renderer-environment, NSI, and CoreAudio source and remains within Wine's
LGPL-2.1-or-later source boundary. It is not part of the separately assigned
ForgePlay Game Mode GPL scope.

The non-Game-Mode
`wine-11.12-helldivers2-process-policy.patch` and
`wine-11.12-heap-zero-memory.patch` copies likewise retain their
`LGPL-2.1-or-later` approved-derivative boundary. Their adjacent `.license`
sidecars, exact patch bytes, Wine notices, and reconstructable corresponding
Wine source remain part of the export. The GPL assignment of the two Game
Mode patches does not relicense those separate LGPL patch copies.

## D3DMetal boundary

D3DMetal is a separately licensed Apple binary payload under its own Apple
terms. It is intentionally absent from this source-only export and is not
relicensed under GPL or LGPL. The public source tree contains only ForgePlay's
independent bridge source and public behavior contract. A direct-DMG release
must separately preserve the configured D3DMetal payload's Apple license,
acknowledgements, framework license, and original Apple code signature; those
requirements do not reduce or replace the GPL combined-source or LGPL Wine
source obligations above.

## Verification

Run both checks from this directory:

```sh
python3 Scripts/verify-game-mode-source-licenses.py "$PWD"
python3 Scripts/verify-forgeplay-runtime-patch-provenance.py \
  --lock "$PWD/Config/ForgePlayRuntimePatchProvenance.lock.json" \
  --source-identity-lock "$PWD/Config/ForgePlayRuntimeSourceIdentity.lock.json" \
  --patch-root "$PWD/Resources/Runners/ForgePlayRuntime/Patches" \
  --export-license-inventory
bash Scripts/tests/test-wine-game-mode-process-host-routing.sh
```

The export verifier runs the same license-boundary check and rejects missing
headers, missing patch sidecars, unclassified Game Mode Host files, changed
content-addressed patch bytes, and whole-file GPL spillover into declared
mixed files.
