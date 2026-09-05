# ForgePlay Source

[한국어](README_KO.md) | [English](README_EN.md)

## ForgePlay 1.2 source preparation

Product baseline: `1.2_Release`, commit
`72a2598c99f0b649d1384ed0763a00037f5d1d2e`.
This preparation adds license declarations and completes source-export inputs;
the baseline application, native frame-generation implementation and Wine patch
bytes are preserved. `SOURCE-INVENTORY.json` identifies the local preparation
commit, which must not be confused with the product baseline or a published tag.

Frame Generation is licensed under `GPL-3.0-only`, with the same categories of
attribution, modified-origin and trademark terms as Game Mode. Its exact scope
is in [the Frame Generation license](LICENSES/ForgePlayFrameGeneration/FRAME_GENERATION_LICENSE_SCOPE.md).
The path-and-hash license manifest preserves release source bytes using external
notices. Wine-derived integration patches and Apple's D3DMetal binary remain
separately identified under their own terms.

This is preparation for user review; no DMG is included and no release is
published by exporting this directory. Final distribution must carry the
version-matched binary, source archives and notices together.

This is ForgePlay's allowlisted, source-only publication tree. The two
language editions explain the project's position, the Steam launch path, the
Game Mode architecture, and the exact boundary between independently authored
orchestration and attributed Wine-derived loader code.

ForgePlay was built to demonstrate in working source that CrossOver is not the
only possible architecture for running Windows games on macOS. CodeWeavers'
contributions to Wine deserve credit; those contributions do not make every
independent implementation a CrossOver derivative.

Start with:

- [한국어 설명 및 구현 공개](README_KO.md)
- [English position and implementation disclosure](README_EN.md)
- [license map](LICENSE.md)
- [source-license boundary guide](SOURCE-LICENSES.md)
- [runtime source and reconstruction record](Resources/Runners/ForgePlayRuntime/SOURCE-AVAILABILITY.md)

This export contains source, tests, license records, and reconstruction tools.
It intentionally excludes application bundles, DMGs, credentials, notarization
material, and bundled third-party runtime binaries.

ForgePlay Game Mode  
Copyright (C) 2026 Facta-Leopard  
Original source: https://github.com/Facta-Leopard/ForgePlay
