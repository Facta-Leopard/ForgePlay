# ForgePlay Game Mode GPL-3.0-only Scope

This document applies the final `GPL-3.0-only` policy to the Game Mode
implementation identifiable in the current file structure and execution path.
It does not assume a source-file or target reorganization.

Copyright (C) 2026 Facta-Leopard

## 1. License

The public license is the GNU General Public License, version 3 only
(`GPL-3.0-only`).

The GPL itself grants advance permission to use, copy, modify, and convey the
covered code when all GPL conditions are satisfied. No separate permission
from Facta-Leopard is required for compliant use, including commercial use.
This grant does not authorize proprietary distribution that omits the GPL
requirements.

## 2. Covered ForgePlay Game Mode code

The covered scope consists of the following ForgePlay-authored Game Mode
implementation.

### Dedicated Swift source and tests

- `Sources/ForgePlay/Models/GameModeEvidence.swift`
- `Sources/ForgePlay/Services/GameModeHostCapability.swift`
- `Sources/ForgePlay/Services/GameModeLaunchRequestStore.swift`
- `Tests/ForgePlayTests/GameModeHostCapabilityTests.swift`
- `Tests/ForgePlayTests/GameModeLaunchRequestStoreTests.swift`

### Game Mode-specific code in mixed application files

- Game Mode Host selection, environment construction, launch registration,
  evidence parsing, process verification, and policy branches in
  `Sources/ForgePlay/Services/SafeProcessRunner.swift`
- the Game Mode toggle, state, launch-policy plumbing, and Game Mode notices in
  `Sources/ForgePlay/UI/SteamLaunchView.swift`
- Game Mode policy plumbing in `SteamManager.swift` and
  `SteamPrefixService.swift`
- Game Mode evidence collection in `SupportBundleService.swift`
- the Game Mode Host lease integration in `AppServices.swift` and
  `PrefixExecutionLease.swift`
- the `GameModeProcessHost` target, embedding configuration, and dedicated
  build steps in `project.yml`

Each binary release must accompany mixed files with a commit-specific symbol
manifest. The scope does not purport to relicense unrelated application
responsibilities merely because they share a file.

The mixed-file declarations are fixed in
`GAME_MODE_SYMBOL_MANIFEST.md`. The release tag and commit containing that
manifest bind it to the exact conveyed source tree.

### GameModeProcessHost

- the source, headers, property lists, entitlements, scripts, documentation,
  and provenance material in `Native/GameModeProcessHost/`
- the three `Config/ForgePlayGameModeProcessHost*.xcconfig` files
- `Scripts/prepare-game-mode-host-build-identity.sh`
- `Scripts/verify-game-mode-source-licenses.py`
- `Scripts/tests/test-wine-game-mode-process-host-routing.sh`

### Game Mode Wine patches

- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-process-host-routing.patch`
- `Resources/Runners/ForgePlayRuntime/Patches/wine-11.12-game-mode-direct-target-scope.patch`

ForgePlay-authored covered files should carry:

```text
SPDX-FileCopyrightText: 2026 Facta-Leopard
SPDX-License-Identifier: GPL-3.0-only
```

`GAME_MODE_FILE_LICENSES.json` is the machine-readable, path-exact license
assignment. The two content-addressed Wine patch inputs retain their
version-matched bytes; their whole-file `GPL-3.0-only` conversion notice is
therefore carried by that external manifest instead of being inserted into the
patch payload.

## 3. Wine-derived Game Mode material

Parts of `Native/GameModeProcessHost/GameModeProcessHost.m` are derived from
Wine 11.12 `loader/main.c`. The two Game Mode patches are modifications of
Wine source.

Section 3 of LGPL 2.1 permits applying a newer ordinary GNU GPL version to a
given copy. The selected policy converts the identified Game Mode Host and
Game Mode Wine patch copies to `GPL-3.0-only`.

All notices referring to the converted copies must be made consistent with
the GPL policy before a binary release. The conversion is irreversible for
those copies. It does not remove or transfer the existing Wine, Alexandre
Julliard, or other upstream copyrights. All provenance and source hashes
recorded in `Native/GameModeProcessHost/SOURCE-CONTRACT.md` must remain intact.

Because the two patches are applied directly to Wine `kernelbase` and `ntdll`
source, their GPL effect cannot be confined to standalone patch files. A Wine
copy containing those GPL changes must be conveyed consistently with GPLv3 as
a combined derivative work. Unmodified upstream material retains its
independent LGPL permissions.

## 4. Effect of the current application build

The current ForgePlay application target compiles all of
`Sources/ForgePlay`, including the covered Game Mode Swift code, into the main
ForgePlay executable.

Consequently, designating the Game Mode code as GPL-only does not confine the
copyleft effect to filenames when the current executable is conveyed. A
distribution of that combined executable must be able to provide GPLv3 rights
and Corresponding Source for the combined work as required by GPLv3.

This is a consequence of conveying one combined program. It does not change
the authorship of unrelated ForgePlay source files.

`GameModeProcessHost` is a separate Mach-O target, but at runtime it loads the
exact Wine `ntdll.so` and enters `__wine_main` in the same process. GPL code
and LGPL Wine can be combined, but the distribution must provide the complete
applicable source and retain all notices.

## 5. Separately licensed runtime material

The direct-DMG release contract intentionally includes D3DMetal as a
separately identified third-party runtime component under its own Apple
terms. D3DMetal is outside the ForgePlay Game Mode source-license scope and is
not relicensed under `GPL-3.0-only`.

This policy does not replace, extend, or grant permissions under Apple's
terms. A direct-DMG release must preserve the Apple software license,
acknowledgements, framework license, and original Apple code signature that
accompany the configured payload. The GPLv3 license, notices, and
version-matched Corresponding Source for ForgePlay Game Mode remain separate
release requirements.

## 6. Additional terms under GPLv3 section 7

The following additional terms apply to Game Mode material for which
Facta-Leopard holds the applicable copyright.

### Author attribution

Source distributions and legal notices accompanying non-source distributions
must preserve:

```text
ForgePlay Game Mode
Copyright (C) 2026 Facta-Leopard
Original source: https://github.com/Facta-Leopard/ForgePlay
```

If an interactive distribution provides an About, Legal, Credits, or
equivalent Appropriate Legal Notices interface, the attribution must also be
preserved there.

### Modified versions and origin

Modified versions must be marked as modified in a reasonable manner. They must
not misrepresent themselves as an official ForgePlay release or imply
endorsement by Facta-Leopard.

### No trademark license

No trademark rights in the ForgePlay name or logo are granted. Truthful
references required to identify the origin of the covered code are not
prohibited.

## 7. Separate permission

A person who fully complies with GPLv3 does not need separate permission,
including for commercial use.

This public license does not grant permission to distribute the covered code
in a proprietary product without complying with GPLv3. Facta-Leopard may
decide whether to offer a separate license for code solely owned by
Facta-Leopard, but cannot unilaterally grant proprietary rights to Wine-derived
or other third-party material.

## 8. GitHub Releases and Corresponding Source

Every GitHub Release conveying covered object code must publish
version-matched Corresponding Source at the same time. It must include:

- the covered Swift and mixed-file Game Mode source at the exact release commit
- complete GameModeProcessHost source and build material
- both GPL Game Mode Wine patches and the corresponding patched Wine source
  offer or source distribution permitted by GPLv3
- build, packaging, and installation-control scripts
- the unmodified GPLv3 text, this scope, `GAME_MODE_NOTICE`, and all upstream
  notices
- exact source, patch, and build fingerprints

The binary-first and source-later release pattern is not used.

## 9. No external code contributions

The official ForgePlay repository does not accept external code contributions.
This is a maintenance policy, not a restriction on GPL rights to fork, modify,
and redistribute the covered code.

## 10. Excluded source-license scope

This document does not directly designate unrelated ForgePlay code, artwork,
trademarks, the ExternalStorageAccessBridge, non-Game-Mode Wine patches, or
third-party components as Game Mode GPL source.

That source-scope exclusion does not override GPL obligations that arise when
covered code is conveyed as part of one combined program.

## 11. Public binary release requirements

This scope is the final ForgePlay Game Mode license policy. A public binary
release is permitted only after:

1. the exact file assignment and mixed-file symbol manifest are present in the
   release commit, and the public build is made from that clean commit;
2. all covered source notices are consistent with `GPL-3.0-only`;
3. the LGPL-to-GPL conversion notices and Wine provenance are recorded;
4. separately licensed third-party components remain identified under their
   own terms with all required licenses, acknowledgements, and signatures; and
5. these documents and version-matched Corresponding Source ship with the
   binary.

The current `bundled-direct-dmg` configuration intentionally includes
D3DMetal under item 4. The release verifier requires the configured payload,
its Apple legal documents, and its preserved original Apple code signature.
This record does not relicense D3DMetal or replace Apple's terms.
