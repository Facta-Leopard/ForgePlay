# ForgePlay License and Legal Notice

This is a localized guide to the legal material included with ForgePlay. It does not replace the canonical license texts, copyright notices, or component-specific terms shipped in the app.

## Release identity

An official ForgePlay build is identified by the `ForgePlay` display name, bundle identifier, version and build number in `Info.plist`, Developer ID signature, and the checksum and release manifest distributed with its DMG. Modified versions must identify their changes and must not claim to be an official ForgePlay release or imply endorsement by the maintainer.

## ForgePlay Game Mode

The ForgePlay Game Mode code identified by the scope document is licensed under GNU General Public License version 3 only (`GPL-3.0-only`). The exact scope and additional terms are recorded in `LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md`.

ForgePlay Game Mode  
Copyright (C) 2026 Facta-Leopard  
Original source: https://github.com/Facta-Leopard/ForgePlay

The unmodified license texts are included as `LICENSES/GPL-3.0-only.txt` and `LICENSES/LGPL-2.1-or-later.txt`. The repository-wide license boundaries are recorded in `LICENSE.md`.

## ForgePlay Frame Generation

The ForgePlay-authored Frame Generation code identified by the scope document is licensed under GNU General Public License version 3 only (`GPL-3.0-only`). The exact scope, source identity, and additional terms are recorded in the bundled `LICENSES/ForgePlayFrameGeneration/FRAME_GENERATION_LICENSE_SCOPE.md`; the accompanying notice and file and symbol manifests are in the same directory.

```text
ForgePlay Frame Generation
Copyright (C) 2026 Facta-Leopard
Original source: https://github.com/Facta-Leopard/ForgePlay
```

The Wine-derived Frame Generation loading and environment integration remains separately identified under `LGPL-2.1-or-later`; this Frame Generation GPL assignment does not convert that glue code. These source boundaries do not remove GPL obligations for a conveyed combined work. Apple components, including D3DMetal and MetalFX, and other third-party components retain their own terms; this notice grants no linking exception.

## Third-party components

Wine, fonts, renderers, Apple technologies, and other third-party components remain under their own licenses and terms. ForgePlay does not claim ownership of those components. A direct DMG may include D3DMetal as a separately identified Apple component; its Apple license, acknowledgements, and original signatures remain with that payload.

## Noto font fallback

ForgePlay bundles unmodified Noto Sans and Noto Sans CJK font files as a native UI fallback under the SIL Open Font License 1.1. The exact license texts are included as `NotoSans-OFL.txt` and `NotoSansCJK-OFL.txt`. The fonts remain the work of their respective copyright holders; ForgePlay does not claim ownership or use the app UI language as an implicit Windows-prefix font policy.

Noto Sans: Copyright 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic).

Noto Sans CJK: © 2014-2021 Adobe (http://www.adobe.com/).

Open the complete, unmodified license texts using the `Noto Sans OFL 1.1` and `Noto Sans CJK OFL 1.1` buttons in the app’s Legal section.

## Nanum Gothic runtime font fallback

ForgePlay Runtime includes unmodified Nanum Gothic Regular and Bold fonts as a Korean glyph fallback for Windows applications. Nanum Gothic: Copyright (c) 2010, NHN Corporation (http://www.nhncorp.com). These fonts are licensed under the SIL Open Font License 1.1, not the ForgePlay Frame Generation GPL assignment. Open the complete, unmodified license and Reserved Font Names using the `Nanum Gothic OFL 1.1` button in the same Legal section (`Runners/ForgePlayRuntime/Legal/NanumGothic/OFL.txt` in the app’s resources).

## Privacy and support

ForgePlay does not request or store Steam passwords or Steam Guard codes. Support bundles are created locally only at the user’s request and should be reviewed before sharing. Open the detailed Privacy Notice, Support Guide, and Third-Party Notices from the same Legal section.
