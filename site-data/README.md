# ForgePlay compatibility data

`compatibility-games.json` is the public compatibility database used by the
website. Games, test devices, and test reports are separate records so one game
can accumulate results from multiple Macs without changing the page structure.

## Current stable release manifest

`current-release.json` is the machine-readable source of truth for the current
stable ForgePlay release. The homepage and compatibility page render their
current version and download destinations from this file. The app's future
manual update check must fetch the same public JSON instead of parsing HTML or
inferring a release from compatibility reports.

The manifest keeps the user-facing `marketingVersion` separate from the
monotonically increasing integer `buildNumber`. App update availability is
decided by `buildNumber`; `marketingVersion` and `releaseTag` are display and
release-identification values. Validate every change against
`current-release.schema.json`.

The complete consumer contract, validation rules, failure behavior, security
boundary, and release workflow are documented in
[`docs/update-check-contract.md`](https://github.com/Facta-Leopard/ForgePlay/blob/main/docs/update-check-contract.md).

## Compatibility-only update workflow

Compatibility content has one source of truth:
`site-data/compatibility-games.json`.

For future compatibility updates:

1. Edit only `compatibility-games.json`, including its `updatedAt` value.
2. Commit and push that file to `main`.
3. The GitHub Pages workflow validates and deploys the data automatically.

Do not bump HTML or JavaScript cache versions for a data-only update. The
website requests the compatibility database independently of asset versions,
and both the homepage count and compatibility rows are derived from the JSON.
New data appears the next time the page is loaded or refreshed.

The ForgePlay app also consumes this public JSON through an explicit refresh.
Its cache, rollback, same-date conflict, failure-preservation, and coordinated
schema rules are documented in
[`docs/compatibility-catalog-consumer-contract.md`](https://github.com/Facta-Leopard/ForgePlay/blob/main/docs/compatibility-catalog-consumer-contract.md).
Under the current contract, a published `updatedAt` identifies one immutable
payload; batch reports into a single publication when they arrive on the same
date.

## Excel / spreadsheet import contract

Excel, CSV, and other tabular sources can be normalized into this structure.
One spreadsheet row should represent one test report. The preferred columns are:

| Column | Required | Example |
| --- | --- | --- |
| `game_id` | yes | `stellar-blade` |
| `title_en` | yes for a new game | `Stellar Blade` |
| `title_ko` | yes for a new game; include Hangul | `스텔라 블레이드` |
| `status` | yes | `playable`, `testing`, `blocked`, or `unknown` |
| `forgeplay_version` | optional | `1.1`; use `development` for an unreleased development build; leave blank when not reported |
| `game_version` | optional | Game version, patch, or build; leave blank when not reported |
| `device_id` | yes; leave blank if not reported | `apple-silicon-m4-pro-24gb` |
| `platform` | yes for a new device | `Apple Silicon Mac` |
| `chip` | yes for a new device | `M4 Pro` |
| `unified_memory_gb` | optional; leave blank if not reported | `24` |
| `macos_version` | optional | `26.0` |
| `tested_at` | optional | `2026-07-28` |
| `source` | yes | `project-test`, `github-issue`, or `community-report` |
| `reporter` | optional | Public handle or display name for an attributed report |
| `blocker` | optional | `anti-cheat`, `launcher`, `graphics`, `runtime`, `security-module`, or `unknown` |
| `notes_en` | optional | Free-form public note |
| `notes_ko` | optional | 공개 비고 |

Imports must preserve existing identifiers, reject duplicate report IDs, and
validate references against `compatibility.schema.json` before publication.
Every game must keep both its official English title and a non-empty Korean
title containing Hangul, including titles whose official branding is written
only in Latin characters.

## Project notices

`announcements.json` is the single source for the latest notice shown on the
homepage and the full project timeline on `updates.html`. Each notice carries a
stable ID, publication date, category, destination, and title/summary text for
all eight supported locales. An optional localized `paragraphs` collection
provides the full notice on the updates page while the homepage keeps the short
summary. Validate changes against `announcements.schema.json` before
publication.

Localized paragraph items remain plain text and are always inserted with
`textContent`. The updates renderer recognizes a deliberately small set of
line-oriented markers for structured notices: `## ` for a section heading,
`- ` for a list item, two leading spaces before `- ` for a nested list item,
and an exact `---` item for a divider. No raw HTML or Markdown is rendered.

Routine compatibility database additions and result changes must not create
project notices. They belong only in `compatibility-games.json` and appear on
the compatibility page and its live homepage count. This keeps the project
timeline focused on releases and substantive project updates.

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

## Why ForgePlay exists — full text

The complete founder's statement lives in `why-story/`, with one Markdown
source for each of the website's eight locales. `site-assets/why-story.js` loads the active
locale on demand and renders the supported Markdown into the expandable note
on `why.html`; raw Markdown is never inserted into the page.

Keep all eight locale files structurally aligned when the statement changes.
The renderer intentionally supports only headings, paragraphs, block quotes,
unordered lists, bold text, inline code, HTTPS links, and named footnotes.
