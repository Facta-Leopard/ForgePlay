# Compatibility platform contract — schema 3

## Active data and legacy compatibility

The authoritative platform-aware catalog is:
`https://facta-leopard.github.io/ForgePlay/site-data/compatibility-games.json`

Its schema is `compatibility.schema.json`. The website-only supplement is
`website-compatibility-reports.json`, with
`website-compatibility-reports.schema.json`. Both active payloads use
`schemaVersion: 3`. Website-only records and developer note patches retain their
separate scope; they are not silently promoted into the launcher catalog.

The user explicitly chose to update the existing endpoints directly. Both
published payloads use schema 3; there is no separate public legacy feed,
version-suffixed URL, or platform-association file. The launcher model and strict
validator are coordinated to consume schema 3 at the existing URL. Old released
clients that reject schema 3 are not the compatibility target of this change.

## Report field

Every schema-3 report contains the required, non-null field:

```json
{
  "id": "existing-report-id",
  "gameId": "existing-game-id",
  "launchPlatform": "steam"
}
```

This is a partial example; all other existing report fields are still required
by their schema. Record IDs, game IDs and hardware IDs keep their meaning.

| Wire value | Display |
| --- | --- |
| `steam` | Steam |
| `battlenet` | Battle.net |
| `epic` | Epic Games |
| `stove` | STOVE |
| `exe` | Direct EXE / EXE 직접 실행 |
| `vr` | VR |
| `unknown` | Unknown platform / 플랫폼 미확인 |

The field identifies the reported execution path, not the purchase source,
graphics backend or hardware `testProfile.platform`. A Steam-installed game
launched directly as an EXE is an `exe` report when that is the reported path.

`vr` identifies a reported ForgePlay VR execution path. It is separate from a
desktop Steam result even when the game is installed through Steam. A game's
name or VR support alone does not make its existing reports `vr`; record the
actual tested path. VR is displayed with the same abbreviation in all eight
website languages.

Schema 3 rejects missing, null and unsupported values; unknown information is
explicitly `unknown`. When an updated reader opens older schema-1/2 bundles or
caches, the absent field means `unknown`, never inferred Steam. Do not infer it
from a title, Steam App ID, another report or the initial migration.

## Status, history, filtering and UI identity

Partition reports by **(gameId, launchPlatform) before** assessing the current
ForgePlay release, status, color or history. Apply existing version/history rules
inside each partition independently. Steam-playable and Battle.net-blocked reports
for the same game must remain separate cards, not one combined verdict.

- Filter independently by platform, search text and status. “All platforms”
  displays all game-platform groups; it does not merge their results.
- Give every card/report a platform label. Use a platform-qualified UI identity
  such as `gameId:launchPlatform` for expansion and focus state.
- Keep playable groups first; then testing, blocked and unknown. Keep stable
  game order and platform order from the table within a status.
- Counts labelled as games count unique game IDs, not game-platform cards.
- Preserve each report's version, date, attribution and notes. Add a separate
  report for a separately tested execution path; do not rewrite historical
  statuses to manufacture a different platform result.

## Refresh and launcher integration

Keep strict validation: schema 3 permits the new key and requires one of the seven
values, rather than accepting arbitrary unknown keys. Keep legacy 1/2 decoding
for existing bundles/caches, mapping only their missing platform to unknown.

The v3 snapshot has its own `website-v3-<updatedAt>` revision. An optional integer
`revision` (0...9007199254740991, omitted=0) distinguishes same-day publications;
positive values append `-rN`. Ordering is (schema generation, date, revision).
Explicit zero and omitted revision are equivalent, including canonical hashing.
Reject null, booleans, fractions, strings and values outside the safe-integer range.
Legacy schema 1/2 does not permit this field. Keep rejecting content conflicts
for the same date/revision pair and preserve rollback, failure, size and cache
safety rules. The initial schema-3 date is 2026-09-29. Do not silently fall back to a Steam assumption
when fetch/validation fails; retain an already validated snapshot or report the
failure according to the existing client policy.

Canonical sources are under `Website/CompatibilityDB/`; the public URLs are
assembled by `Website/publication.json`. The web model is
`Website/Public/site-assets/website-compatibility.js`.
The homepage, full compatibility page and interactive guide consume the same v3 model. Native
model/validator, URL selection, cache migration and UI changes are coordinated
with the “런처 관련” task; this website task does not edit native code or build apps.

## Initial migration

The user explicitly classified all 56 existing reports (55 base + 1 website
follow-up) as Steam. Removing only `launchPlatform` from the migrated reports
reproduces their previous records exactly. No result, ForgePlay version, hardware,
reporter, note or tested date was changed. No Battle.net / Overwatch anti-cheat
report was included in that migration. The later 2026-09-29 revision 1 adds the
separately supplied Battle.net report and labels its anti-cheat explanation as
a developer note, without changing the existing Steam evidence.

The subsequent VR category addition keeps schema 3 and the existing URLs. It
extends the allowed values only: no report payload, update date, status or
Steam classification changes, and no VR results are invented. The launcher
reader and filters accept `vr` through the coordinated source update.
