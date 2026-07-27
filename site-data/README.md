# ForgePlay compatibility data

`compatibility-games.json` is the public compatibility database used by the
website. Games, test devices, and test reports are separate records so one game
can accumulate results from multiple Macs without changing the page structure.

## Excel / spreadsheet import contract

Excel, CSV, and other tabular sources can be normalized into this structure.
One spreadsheet row should represent one test report. The preferred columns are:

| Column | Required | Example |
| --- | --- | --- |
| `game_id` | yes | `stellar-blade` |
| `title_en` | yes for a new game | `Stellar Blade` |
| `title_ko` | optional | `스텔라 블레이드` |
| `status` | yes | `playable`, `testing`, `blocked`, or `unknown` |
| `device_id` | yes | `apple-silicon-m4-pro-24gb` |
| `platform` | yes for a new device | `Apple Silicon Mac` |
| `chip` | yes for a new device | `M4 Pro` |
| `unified_memory_gb` | yes for a new device | `24` |
| `macos_version` | optional | `26.0` |
| `tested_at` | optional | `2026-07-28` |
| `source` | yes | `project-test` or `community-report` |
| `blocker` | optional | `anti-cheat`, `launcher`, `graphics`, `runtime`, or `unknown` |
| `notes_en` | optional | Free-form public note |
| `notes_ko` | optional | 공개 비고 |

Imports must preserve existing identifiers, reject duplicate report IDs, and
validate references against `compatibility.schema.json` before publication.

## Project notices

`announcements.json` is the single source for the latest notice shown on the
homepage and the full project timeline on `updates.html`. Each notice carries a
stable ID, publication date, category, destination, and title/summary text for
all eight supported locales. Validate changes against
`announcements.schema.json` before publication.

## Developer app catalog

`developer-apps.json` mirrors the catalog shown inside ForgePlay. It keeps the
developer's Mac, iPad, and iPhone apps in a data file so the homepage can render
the catalog without hardcoding product cards. Every entry includes:

- a stable identifier and platform;
- the official App Store ID and URL;
- a local 512-by-512 App Store artwork file;
- a summary in all eight website locales; and
- Apple Silicon Mac compatibility where the App Store listing supports it.

Keep this catalog synchronized with
`Sources/ForgePlay/Models/DeveloperAppCatalog.swift` and validate structural
changes against `developer-apps.schema.json`.
