# ForgePlay Privacy Notice

ForgePlay is designed for local game setup, launch diagnostics, and support bundle generation on an Apple Silicon Mac. ForgePlay does not include advertising tracking, third-party analytics, crash reporting SDKs, or telemetry SDKs.

## Local Data

ForgePlay stores setup state, selected file paths, security-scoped bookmarks, game records, prefix metadata, runtime installation records, launch records, diagnostics, and compatibility records in the user's Application Support folder. This data is used to run the app, restore user-selected locations, show diagnostics, and help the user manage local game environments.

## Files Selected by the User

ForgePlay uses macOS document and folder selection to access user-selected game storage, the Windows Steam installer, Windows prerequisite installers, logs, imported game folders, and an optional Apple Evaluation environment DMG or redist folder. The optional Apple input supplies D3DMetal renderer files only. ForgePlay always executes the ForgePlay Runtime included in the app and does not register an executable from another app or a user-selected Wine installation as its engine. ForgePlay stores security-scoped bookmarks when needed so authorized selections can be restored on later launches. If access expires or bookmark restoration fails, ForgePlay asks the user to select the item again.

## AI Diagnostics

AI diagnostics are off by default. When the user enables them, ForgePlay first shows a redacted preview and then uses Apple Foundation Models on this Mac. The preview and on-device prompt redact common secrets, Steam account identifiers, home/user paths, and selected local storage, runtime, renderer, and game library paths where possible. ForgePlay does not send AI diagnostic logs to an external AI endpoint and does not use an API key for AI diagnostics.

## Compatibility Updates

Remote compatibility database updates are optional and require a trusted signing public key shipped with ForgePlay. ForgePlay accepts only HTTPS feeds and applies signed, checksum-verified compatibility records that pass ForgePlay's local recipe policy.

## Support Bundles

Support bundles are created only when the user requests them. ForgePlay redacts bearer tokens, API keys, passwords, provider keys, URL user info, URL query secrets, Steam IDs, Steam account names, Steam persona names, Steam Guard lines, home/user paths, and selected local storage, runtime, renderer, and game library paths where possible. Support bundles are saved locally first; the user decides whether to share them.

## Steam and External Services

ForgePlay does not ask for, store, or transmit Steam account passwords or Steam Guard codes. Steam authentication happens inside Steam's own Windows UI running through the bundled ForgePlay Runtime.
