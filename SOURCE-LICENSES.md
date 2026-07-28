# ForgePlay source license boundaries

This file is a guide to the license metadata in this source-only publication
tree. It does not create a license grant or replace `LICENSE.md`, the
component-specific scope documents, or third-party notices.

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

## Verification

Run both checks from this directory:

```sh
python3 Scripts/verify-game-mode-source-licenses.py "$PWD"
bash Scripts/tests/test-wine-game-mode-process-host-routing.sh
```

The export verifier runs the same license-boundary check and rejects missing
headers, missing patch sidecars, unclassified Game Mode Host files, changed
content-addressed patch bytes, and whole-file GPL spillover into declared
mixed files.
