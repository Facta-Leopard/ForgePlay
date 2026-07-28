# ForgePlay Support Guide

ForgePlay support starts with local diagnostics. The app analyzes launch logs with the built-in Rule Engine first, then optionally uses Apple Foundation Models on this Mac when the user has enabled AI diagnostics.

## What to Include

When asking for support, reproduce the problem once with the current app and runtime when it is safe to do so. Include the game name, Steam App ID if available, what was visible in the Steam or game window, and the approximate time of the failure. If the app offers a support bundle, create it from the Diagnostics screen and review the archive before sharing it. ForgePlay saves the archive locally and does not upload it automatically.

## Support Bundle Contents

Support Bundle v2 is a local ZIP diagnostic artifact. Depending on which records and settings are available when it is created, it can contain:

- `README.md`, a human-readable starting point with the app build, Mac/GPU/display/volume summary, exact runtime identity state, selected Steam reference, launch timeline, Steam late-evidence status, and evidence-completeness counts.
- `metadata/bundle-manifest.json`, the authoritative schema-versioned index. It records the bundle ID and creation time, collection status, environment snapshot, available launch records, diagnostic-record summaries, included artifacts, skipped artifacts, collection issues, and collection limits.
- Redacted launch, install, runtime, and diagnostic text artifacts. When a run identifier is available, artifacts are grouped under that opaque identifier and labeled by role, such as standard output, standard error, process metadata, process observation, diagnostics, or final verdict. The manifest records the archived size, original size, encoding, modification time, truncation state, and SHA-256 digest of each included artifact.
- Process-metadata sidecars use schema 5 and can include the action and command, applied environment overrides, timing, outcome, actual operating-system process exit or signal state, a separate ForgePlay policy/verification status, timeout and PID, related log references, and a compact run-time host context such as the ForgePlay build, macOS build, model, architecture, processor count, and physical memory. The resolved Wine runtime mode is recorded as a bounded ForgePlay diagnostic field so support can distinguish the requested policy from what the Prefix actually launched with. Detached, preflight-failed, spawn-failed, and signaled commands are not assigned a fabricated process exit code.
- Retries, shutdown barriers, and other commands belonging to the same user operation are linked through bounded related-run references. The bundle follows safe in-root references to prioritize the related process metadata, stdout, stderr, and process-observation evidence; unsafe, cyclic, unreadable, or over-limit references are reported rather than followed silently.
- Redacted diagnostic results, system checks, limited `prefix.json` metadata, and an environment snapshot. The environment snapshot describes bundle-creation time and can include the ForgePlay version and build configuration, macOS and kernel information, Mac model and CPU, processor and memory information, the ForgePlay application process's translation state, power and thermal state, locale and time zone, Metal devices, displays, relevant volume capacity and access state, runtime file status, strict/derived identity and component fingerprint state, statically inspected graphics/Direct3D and Wine synchronization capabilities, selected renderer, synchronization, and video-memory policy, and selected Steam manifest status. This process-level translation field does not assert whether the bundled Wine child runtime is translated or whether Rosetta is available. Launch diagnostics also retain the run-time runtime identity and component fingerprints when available, so current settings are not silently applied to an older launch.
- A bounded set of known Steam logs that may be written after the launcher returns, including the game-process, content, shader, console, bootstrap, WebHelper, and Steam UI logs. The game-process log can contain the App ID and process start/exit evidence needed to distinguish the game that actually ran from the reference selected in ForgePlay. These logs are cumulative and must be correlated by their internal times and source modification times.
- An anonymous inventory for recent Steam dump files. Dump payloads and original filenames are not included; only an anonymous ID, filename digest, size, modification time, and sanitized extension are retained within fixed limits.

The bundle may be marked `partial`. A skipped, unreadable, truncated, or unavailable artifact is not the same as “no error found.” Review `skippedFiles` and `collectionIssues` in `metadata/bundle-manifest.json`; `metadata/skipped-files.json` is also written when files were skipped.

Text artifacts larger than 2 MiB retain a bounded head-and-tail snapshot and are marked as truncated. Included data is limited by file-count, scan-count, record-count, and a 64 MiB total budget, including reserved allowances for the mandatory manifest and README. Persisted launch-record artifacts and same-run renderer logs are checked before the general 5,000-item tree scan. Newer launch and log evidence is prioritized when a limit is reached, and the omission is recorded. Symlinks, hardlinks, non-regular files, unsupported binary files, screenshots, screen-OCR text, and binary crash dumps are excluded. These exclusions and limits protect privacy and keep the archive bounded, but they can also mean that additional evidence is needed.

ForgePlay redacts common secrets and Steam account identifiers. It also redacts selected local storage and game library paths, bundled Runtime diagnostic paths, and paths from an imported Apple supplemental renderer source. Archived entry names are anonymized instead of preserving original local names. Redaction is a protective measure, not a guarantee that every sensitive value can be recognized.

The selected game shown in the environment or a launch record is a launch-time reference, not proof that its executable started. For actual-game identification, inspect the Steam game-process evidence and correlate its App ID/start/exit times with the launch timeline. If that evidence is missing, unsafe, unreadable, truncated, or changed while being read, the bundle records the limitation instead of treating it as “no game-side failure.” Likewise, process-observation evidence distinguishes complete, recovered, and unavailable reads.

After creating the ZIP, ForgePlay verifies that the result is a regular non-symlink file, parses its end record and central directory, checks entry boundaries, and confirms that the README and bundle manifest are indexed. This structural archive check does not decompress and re-hash every payload and is not a promise that every diagnostic artifact was collected. If validation fails, ForgePlay removes the invalid archive when possible and reports the failure.

## Before Sharing

Open `README.md` first, then inspect `metadata/bundle-manifest.json` and the listed artifacts. Confirm that the bundle corresponds to the intended launch and check whether its collection status is `partial`. Search the extracted contents for names, paths, account details, tokens, and other information you do not want to disclose. Share the archive only with a support recipient you trust.

## What ForgePlay Does Not Need

Do not send Steam passwords, Steam Guard codes, payment details, Apple ID credentials, private keys, API tokens, or unrelated personal files. Screenshots, screen-OCR text, original dump filenames, and binary crash dumps are intentionally not included in Support Bundle v2. If support requests an excluded item separately, review it independently before sharing. ForgePlay does not need a separate execution engine from the user. An Apple Evaluation environment DMG/redist is relevant only when troubleshooting the optional D3DMetal supplemental-renderer import; Steam and Windows component installers are relevant only when troubleshooting the corresponding local installer selection.

## Installer Sources

ForgePlay does not host runtime installers on an app server. Use official vendor download pages or installers that the user already has, then select those files in ForgePlay.
