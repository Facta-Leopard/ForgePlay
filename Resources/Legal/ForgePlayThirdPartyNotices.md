# ForgePlay Third-Party Notices

ForgePlay includes its Wine-based ForgePlay Runtime as the only execution engine. The current Developer ID DMG configuration includes an Apple GPTK/D3DMetal evaluation renderer payload as a separate third-party component; the matching Apple `License.rtf`, acknowledgements, framework license, and original Apple code signatures remain with that payload. The App Store candidate excludes that optional Apple payload. This paragraph records the configured package contents and does not make a licensing determination. No ForgePlay build bundles Steam, Microsoft Runtime installers, DirectX installers, .NET installers, NVIDIA PhysX installers, OpenAL installers, XNA installers, or Windows game files. Builds that include ForgePlay Runtime must keep the applicable Wine license notices and source-availability obligations.

## ForgePlay Frame Generation and License Boundaries

The ForgePlay-authored Frame Generation implementation identified in the bundled `LICENSES/ForgePlayFrameGeneration/FRAME_GENERATION_LICENSE_SCOPE.md` is licensed under GNU General Public License version 3 only (`GPL-3.0-only`). The accompanying notice and file and symbol manifests in that directory identify the exact scope, source identity, and additional terms. The unmodified GPL text is included as `LICENSES/GPL-3.0-only.txt`.

```text
ForgePlay Frame Generation
Copyright (C) 2026 Facta-Leopard
Original source: https://github.com/Facta-Leopard/ForgePlay
```

The Wine-derived metal-window-surface and Steam session compatibility patch copies, including Frame Generation loading and environment glue, remain separately identified under `LGPL-2.1-or-later`; this Frame Generation GPL assignment does not convert them. Existing ForgePlay Game Mode license assignments remain unchanged. These source-copy boundaries do not remove GPL obligations for a conveyed combined work. D3DMetal, MetalFX, and other Apple or third-party components retain their own terms, and this notice grants no compatibility or linking exception. The fonts listed below remain under the SIL Open Font License 1.1, not this GPL assignment.

## Apple Technologies

ForgePlay may use Apple platform frameworks, Apple Foundation Models, security-scoped bookmarks, SwiftData, and macOS app distribution technologies such as Developer ID signing, Hardened Runtime, notarization, and stapling.

Apple Game Porting Toolkit, Evaluation environment for Windows games, Apple Foundation Models, Apple Intelligence, macOS, and related marks belong to Apple Inc. ForgePlay does not claim ownership of Apple GPTK or D3DMetal and does not treat those files as ForgePlay-owned source code. The original notices included with the exact payload remain attached to that component.

## Steam

Steam and Steam game content belong to Valve Corporation and the relevant game publishers. ForgePlay does not store Steam account passwords or Steam Guard codes. Steam login happens in Steam's own UI.

## Microsoft Runtime Components

Microsoft Visual C++ Redistributable, DirectX End-User Runtime, .NET Framework, XNA Framework, Windows, and related marks belong to Microsoft. ForgePlay opens official pages or uses user-selected installers; it does not redistribute these installers in the app bundle.

## Other Runtime Components

NVIDIA PhysX belongs to NVIDIA. OpenAL and other runtime components belong to their respective owners. ForgePlay uses user-selected installers only when the user chooses to apply them to a local Prefix running through the bundled ForgePlay Runtime.

## Noto Fonts in the Native App

The ForgePlay macOS app bundles unmodified regular and bold files from Noto Sans and the Korean, Japanese, Simplified Chinese, and Traditional Chinese (Taiwan) regional families of Noto Sans CJK. Noto Sans provides the common Latin, Greek, and Cyrillic fallback, including the complete Russian and Ukrainian alphabets; the CJK families provide the region-specific fallback for the app’s eight supported UI localizations. Native macOS UI activation registers only the locale-selected fonts in the ForgePlay process. The explicit Windows font compatibility workflow may separately copy the exact unmodified Noto files into ForgePlay’s managed Wine prefix; it does not install them as host-wide macOS fonts. The fonts are distributed under the SIL Open Font License, Version 1.1, and the exact license texts are included as `NotoSans-OFL.txt` and `NotoSansCJK-OFL.txt` next to the app font resources. Cyrillic glyph coverage does not claim Russian or Ukrainian UI translation. ForgePlay does not claim ownership of the fonts and does not modify or rename them.

`NotoSans-OFL.txt` applies to the bundled Noto Sans files: Copyright 2022 The Noto Project Authors (https://github.com/notofonts/latin-greek-cyrillic)

`NotoSansCJK-OFL.txt` applies to the bundled Noto Sans CJK files: © 2014-2021 Adobe (http://www.adobe.com/).

Open the complete, unmodified license texts using the `Noto Sans OFL 1.1` and `Noto Sans CJK OFL 1.1` buttons in the app’s Legal section.

## Wine and Runtime Components

Wine and the renderer/runtime components bundled with ForgePlay are separate open-source projects or vendor technologies with their own licenses and terms. ForgePlay does not claim ownership of those upstream components.

Bundled ForgePlay Runtime candidates include Wine 11.12 built from a validated corresponding-source tree and FreeType 2.14.3 built from the official FreeType source archive. The runtime package includes Wine's `LICENSE`, `COPYING.LIB`, and `AUTHORS` files under `Contents/Resources/Runners/ForgePlayRuntime/Legal/Wine/`, FreeType license files under `Contents/Resources/Runners/ForgePlayRuntime/Legal/FreeType/`, and source-availability notes under `Contents/Resources/Runners/ForgePlayRuntime/SOURCE-AVAILABILITY.md`. That notice identifies the official WineHQ source archive and signature, the included ForgePlay patch set, source fingerprints, and reconstruction steps without exposing a packaging workstation path.

ForgePlay's Wine modifications are implemented as project-owned patches against the authenticated Wine 11.12 source. The runtime uses Wine's standard wineserver synchronization path. Its D3DMetal bridge is implemented from the documented public non-native-code-region interface, and its DXMT window-surface bridge exposes Wine's existing macOS driver ownership and Metal-view operations through a compile-time-checked ABI table. The complete modified Wine patch source and reconstruction contract are included with the runtime under the same Wine licensing obligations.

Bundled ForgePlay Runtime candidates may also include libsdl-org sdl2-compat 2.32.70 for Windows Steam client compatibility. ForgePlay uses this zlib-licensed SDL3-backed compatibility pair to satisfy the 32-bit `Steam/bin/gldriverquery.exe` `SDL2.dll` ABI import. The included `SDL2.dll` file name is an ABI compatibility requirement and is not a renamed Steam `SDL3.dll`.

Bundled ForgePlay Runtime candidates include the regular and bold faces of Nanum Gothic as a Korean glyph fallback for Windows applications running through Wine. Nanum Gothic is copyright (c) 2010, NHN Corporation and is distributed under the SIL Open Font License, Version 1.1. The bundled files are unmodified bytes from the Google Fonts repository at commit `16680f8688ffcd467d2eb2146a9ce0343404581d`: Regular SHA-256 `76f45ef4a6bcff344c837c95a7dcc26e017e38b5846d5ae0cdcb5b86be2e2d31`, Bold SHA-256 `21f9d3a7f1ca82ca1dc9a288e30138b4f1feb6e71fc89b5a9181fed174b6bbe2`, and OFL SHA-256 `eeacf16032901d0ed0456876ec77b8f0fda6b3fecec7d972f8543eb602e6c30f`. The machine-readable source identity, copyright notice, Reserved Font Names, and complete license text are included under `Contents/Resources/Runners/ForgePlayRuntime/Legal/NanumGothic/`.

Open the complete, unmodified Nanum Gothic license, including its copyright notice and Reserved Font Names, using the `Nanum Gothic OFL 1.1` button in the app’s Legal section.

The ForgePlay macOS app targets Apple Silicon (`arm64`) hosts only. Inside that arm64 app, the current bundled Wine compatibility-runtime candidates use `x86_64` Wine Unix binaries and therefore require Rosetta. Those internal binaries exist only to run Windows game workloads. They must be treated as transitional until an arm64 Wine Unix runtime or other review-safe long-term architecture is available.
