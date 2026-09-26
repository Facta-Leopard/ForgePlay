# Launcher artwork in the interactive guide

These six JPEGs are web-optimized copies of ForgePlay 2.0.0 (build 6)'s
first-party `Contents/Resources/LauncherArtwork/*.png` assets. Converted using
macOS sips, JPEG quality 83, maximum dimension 1200 px. No screenshot is used.

The original artwork README records generation from the project-owned
`forgeplay-hero.jpg` (SHA-256 d1ae7a2e95e4695be62eacd2c86749d1a3a0f32139aed1c4dfab5b0ade303388)
and `forgeplay-manifesto.jpg` (SHA-256 a57f64af5d98ee24d5ea163550e5aa2620d3d7b287421b5264d26d7fe353ea6f)
with the built-in image generator on September 26, 2026. No third-party
stock art, icon pack, or font was introduced. UI text remains live HTML.

`mark.png` is a resized copy of the author's
`Resources/Assets.xcassets/LaunchMark.imageset/ForgePlayMark.png`.

The nine metallic launcher icons in `../../guide-v2-icons.js` are an SVG port
of the author's `Sources/ForgePlayLauncher/LauncherTileArtwork.swift` contours,
including the original tile colors. The separate 24px Mac-interface icons are
independently authored generic SVG controls matched to the semantic roles in
`AppNavigation.swift`. They are not exported SF Symbols, Apple font glyphs, or
an external icon package. The mockup does not distribute Apple symbol files.

Mac light/dark palette values and control spacing follow `UI/Theme.swift`;
launcher colors and layout follow `LauncherModel.swift` and
`LauncherDashboardView.swift`. These reference sources remain unchanged.
