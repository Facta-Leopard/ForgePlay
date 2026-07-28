#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PAGES=(
  index.html
  why.html
  license.html
  privacy.html
  support.html
  compatibility.html
  updates.html
  site.css
  locale-bootstrap.js
  site.js
  compatibility.js
  announcements.js
  developer-apps.js
  site-data/compatibility-games.json
  site-data/compatibility.schema.json
  site-data/announcements.json
  site-data/announcements.schema.json
  site-data/developer-apps.json
  site-data/developer-apps.schema.json
  site-data/README.md
  site-assets/forgeplay-favicon.png
  site-assets/forgeplay-hero.jpg
  site-assets/forgeplay-hero-3200.jpg
  site-assets/forgeplay-icon.png
  site-assets/forgeplay-manifesto.jpg
  site-assets/forgeplay-manifesto-3200.jpg
  site-assets/forgeplay-social.png
  site-assets/developer-apps/hopdisk.png
  site-assets/developer-apps/bunmixer.png
  site-assets/developer-apps/latchcast.png
  site-assets/developer-apps/lorabit.png
  site-assets/developer-apps/kanindex.png
  site-assets/developer-apps/bunniki.jpg
  site-assets/developer-apps/openbooklm.jpg
  site-assets/developer-apps/seolapin.jpg
  site-assets/developer-apps/brambletread.jpg
  site-assets/developer-apps/moonwhisk-vale.jpg
  LICENSE.md
  LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md
  LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE_KO.md
  LICENSES/ForgePlayGameMode/GAME_MODE_NOTICE
  LICENSES/ForgePlayGameMode/README.md
  LICENSES/ForgePlayGameMode/DECISION_KO.md
  LICENSES/ForgePlayGameMode/GPL_COMPARISON_KO.md
  LICENSES/GPL-3.0-only.txt
  LICENSES/LGPL-2.1-or-later.txt
)
LANGS=(ko en de es fr ja zh-Hans zh-Hant)

fail() {
  printf 'error: invalid static site: %s\n' "$*" >&2
  exit 1
}

require_regular_file() {
  local path="$1"
  local link_count
  [[ -f "$path" && ! -L "$path" ]] || fail "$path must be a non-symlink regular file"
  if link_count="$(stat -f '%l' "$path" 2>/dev/null)"; then
    :
  elif link_count="$(stat -c '%h' "$path" 2>/dev/null)"; then
    :
  else
    fail "could not inspect link count for $path"
  fi
  [[ "$link_count" == "1" ]] || fail "$path must not be hardlinked"
}

require_snippet() {
  local path="$1"
  local snippet="$2"
  grep -Fq -- "$snippet" "$path" || fail "$(basename "$path") missing required text: $snippet"
}

for page in "${PAGES[@]}"; do
  require_regular_file "$ROOT_DIR/$page"
done

python3 - "$ROOT_DIR" \
  "$ROOT_DIR/index.html" \
  "$ROOT_DIR/why.html" \
  "$ROOT_DIR/license.html" \
  "$ROOT_DIR/privacy.html" \
  "$ROOT_DIR/support.html" \
  "$ROOT_DIR/compatibility.html" \
  "$ROOT_DIR/updates.html" <<'PY'
import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit

root = Path(sys.argv[1])
root_resolved = root.resolve()
paths = [Path(value) for value in sys.argv[2:]]
parsed_pages = {}

class Parser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.references = []
        self.ids = []
        self.i18n_keys = []

    def handle_starttag(self, tag, attrs):
        for key, value in attrs:
            if key == "id" and value:
                self.ids.append(value)
            if key in {"href", "src"} and value:
                self.references.append(value)
            if key in {
                "data-i18n",
                "data-i18n-aria-label",
                "data-i18n-alt",
                "data-i18n-placeholder",
            } and value:
                self.i18n_keys.append(value)

def parse_page(path):
    resolved = path.resolve()
    if resolved in parsed_pages:
        return parsed_pages[resolved]
    parser = Parser()
    try:
        with open(path, "r", encoding="utf-8") as handle:
            parser.feed(handle.read())
        parser.close()
    except Exception as exc:
        raise SystemExit(f"{path}: HTML parse failed: {exc}")
    ids = set()
    for html_id in parser.ids:
        if html_id in ids:
            raise SystemExit(f"{path}: duplicate id: {html_id}")
        ids.add(html_id)
    parsed_pages[resolved] = (parser.references, ids, parser.i18n_keys)
    return parsed_pages[resolved]

for path in paths:
    parse_page(path)

for path in paths:
    references, _, _ = parse_page(path)
    for reference in references:
        parsed = urlsplit(reference)
        if parsed.scheme or parsed.netloc:
            continue
        target = parsed.path
        if target.startswith("/"):
            raise SystemExit(f"{path}: root-relative local reference is not allowed: {reference}")
        target_path = path if not target else root / target
        local_path = target_path.resolve()
        try:
            local_path.relative_to(root_resolved)
        except ValueError:
            raise SystemExit(f"{path}: local reference escapes project root: {reference}")
        if not local_path.exists():
            raise SystemExit(f"{path}: missing local reference target: {reference}")
        if parsed.fragment:
            if local_path.suffix.lower() != ".html":
                raise SystemExit(f"{path}: fragment reference target is not an HTML page: {reference}")
            _, target_ids, _ = parse_page(local_path)
            if parsed.fragment not in target_ids:
                raise SystemExit(f"{path}: missing fragment target #{parsed.fragment}: {reference}")

site_js = (root / "site.js").read_text(encoding="utf-8")
locale_names = ["ko", "en", "de", "es", "fr", "ja", "zh-Hans", "zh-Hant"]
markers = []
for match in re.finditer(
    r'^\s{4}(?:"(zh-Hans|zh-Hant)"|(ko|en|de|es|fr|ja)):\s*\{$',
    site_js,
    flags=re.MULTILINE,
):
    markers.append((match.group(1) or match.group(2), match.start(), match.end()))

if sorted(locale for locale, _, _ in markers) != sorted(locale_names):
    raise SystemExit("site.js must define exactly the eight supported locale objects")

translation_keys = {}
translation_values = {}
for index, (locale, _, start) in enumerate(markers):
    end = markers[index + 1][1] if index + 1 < len(markers) else site_js.index(
        "const message",
        start,
    )
    entries = re.findall(
        r'^\s{6}"([^"]+)":\s*"((?:[^"\\]|\\.)*)",?$',
        site_js[start:end],
        flags=re.MULTILINE,
    )
    keys = [key for key, _ in entries]
    if len(keys) != len(set(keys)):
        raise SystemExit(f"site.js has duplicate translation keys for {locale}")
    translation_keys[locale] = set(keys)
    translation_values[locale] = dict(entries)

english_keys = translation_keys["en"]
if len(english_keys) < 175:
    raise SystemExit("site.js English locale is unexpectedly incomplete")
for locale in locale_names:
    missing = english_keys - translation_keys[locale]
    extra = translation_keys[locale] - english_keys
    if missing or extra:
        raise SystemExit(
            f"site.js locale {locale} differs from English; "
            f"missing={sorted(missing)} extra={sorted(extra)}"
        )

retired_keys = {
    "home.whyKo",
    "home.whyEn",
    "home.license1Title",
    "home.license1Body",
    "home.license2Tag",
    "home.license2Title",
    "home.license2Body",
    "home.license3Tag",
    "home.license3Title",
    "home.license3Body",
    "home.licenseManifest",
    "home.licenseScope",
    "home.licenseFootnote",
    "privacy.languages",
    "support.languages",
}
present_retired_keys = retired_keys & english_keys
if present_retired_keys:
    raise SystemExit(
        f"site.js still contains retired translation keys: "
        f"{sorted(present_retired_keys)}"
    )

required_localized_keys = {
    "home.worldFirstRouteGameMode",
    "home.sponsorMark",
    "license.mastheadLabel",
    "license.mastheadAria",
    "license.mastheadScope",
    "license.filesLabel",
    "compat.logLabel",
}
missing_localized_keys = required_localized_keys - english_keys
if missing_localized_keys:
    raise SystemExit(
        f"site.js is missing localized presentation keys: "
        f"{sorted(missing_localized_keys)}"
    )

expected_game_mode_navigation = {
    "ko": "게임 모드",
    "ja": "ゲームモード",
    "zh-Hans": "游戏模式",
    "zh-Hant": "遊戲模式",
    "de": "Spielmodus",
    "es": "Modo Juego",
    "fr": "Mode Jeu",
}
for locale, expected in expected_game_mode_navigation.items():
    actual = translation_values[locale].get("shared.navGameMode")
    if actual != expected:
        raise SystemExit(
            f"site.js locale {locale} must use the localized Apple Game Mode "
            f"term {expected!r}; found {actual!r}"
        )
    locale_start = next(start for name, start, _ in markers if name == locale)
    locale_index = next(
        index for index, (name, _, _) in enumerate(markers) if name == locale
    )
    locale_end = (
        markers[locale_index + 1][1]
        if locale_index + 1 < len(markers)
        else site_js.index("const message", locale_start)
    )
    locale_block = site_js[locale_start:locale_end]
    if re.search(r"Game Mode|GAME MODE|Game-Mode|GAME-MODE", locale_block):
        raise SystemExit(
            f"site.js locale {locale} contains an untranslated Game Mode term"
        )

used_keys = set()
for path in paths:
    _, _, keys = parse_page(path)
    used_keys.update(keys)
missing_used_keys = used_keys - english_keys
if missing_used_keys:
    raise SystemExit(f"HTML uses missing translation keys: {sorted(missing_used_keys)}")

database_path = root / "site-data" / "compatibility-games.json"
schema_path = root / "site-data" / "compatibility.schema.json"
try:
    database = json.loads(database_path.read_text(encoding="utf-8"))
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"compatibility JSON is invalid: {exc}")

if database.get("schemaVersion") != 1:
    raise SystemExit("compatibility database schemaVersion must be 1")
if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
    raise SystemExit("compatibility schema must use JSON Schema draft 2020-12")

profiles = database.get("testProfiles")
games = database.get("games")
reports = database.get("reports")
if not all(isinstance(collection, list) for collection in (profiles, games, reports)):
    raise SystemExit("compatibility database collections must be arrays")

def index_unique(items, collection_name):
    indexed = {}
    for item in items:
        identifier = item.get("id") if isinstance(item, dict) else None
        if not isinstance(identifier, str) or not identifier:
            raise SystemExit(f"{collection_name} contains an invalid id")
        if identifier in indexed:
            raise SystemExit(f"{collection_name} contains duplicate id: {identifier}")
        indexed[identifier] = item
    return indexed

profile_by_id = index_unique(profiles, "testProfiles")
game_by_id = index_unique(games, "games")
report_by_id = index_unique(reports, "reports")

allowed_statuses = {"playable", "testing", "blocked", "unknown"}
allowed_sources = {"project-test", "community-report"}
allowed_blockers = {"anti-cheat", "launcher", "graphics", "runtime", "unknown", None}
for game_id, game in game_by_id.items():
    titles = game.get("titles")
    if not isinstance(titles, dict) or not all(
        isinstance(titles.get(locale), str) and titles[locale].strip()
        for locale in ("en", "ko")
    ):
        raise SystemExit(f"game {game_id} must include non-empty English and Korean titles")

for report_id, report in report_by_id.items():
    if report.get("gameId") not in game_by_id:
        raise SystemExit(f"report {report_id} references an unknown game")
    if report.get("testProfileId") not in profile_by_id:
        raise SystemExit(f"report {report_id} references an unknown test profile")
    if report.get("status") not in allowed_statuses:
        raise SystemExit(f"report {report_id} has an invalid status")
    if report.get("source") not in allowed_sources:
        raise SystemExit(f"report {report_id} has an invalid source")
    if report.get("blocker") not in allowed_blockers:
        raise SystemExit(f"report {report_id} has an invalid blocker")

seed_game_ids = {
    "stellar-blade",
    "atomic-heart",
    "overwatch",
    "counter-strike-2",
    "half-life-2",
    "heroes-might-magic-olden-era",
    "kingdom-come-deliverance",
    "left-4-dead",
    "once-human",
    "pragmata",
    "the-walking-dead",
    "yu-gi-oh-master-duel",
}
missing_seed_games = seed_game_ids - game_by_id.keys()
if missing_seed_games:
    raise SystemExit(f"compatibility database is missing seed games: {sorted(missing_seed_games)}")

profile = profile_by_id.get("apple-silicon-m4-pro-24gb")
if not profile or profile.get("chip") != "M4 Pro" or profile.get("unifiedMemoryGB") != 24:
    raise SystemExit("compatibility database must include the M4 Pro 24GB test profile")

seed_reports = [
    report for report in reports
    if report.get("gameId") in seed_game_ids
    and report.get("testProfileId") == "apple-silicon-m4-pro-24gb"
    and report.get("status") == "playable"
]
if {report["gameId"] for report in seed_reports} != seed_game_ids:
    raise SystemExit("every seed game must have a playable M4 Pro 24GB report")

announcements_path = root / "site-data" / "announcements.json"
announcements_schema_path = root / "site-data" / "announcements.schema.json"
try:
    announcement_database = json.loads(announcements_path.read_text(encoding="utf-8"))
    announcement_schema = json.loads(announcements_schema_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"announcements JSON is invalid: {exc}")

if announcement_database.get("schemaVersion") != 1:
    raise SystemExit("announcements database schemaVersion must be 1")
if announcement_schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
    raise SystemExit("announcements schema must use JSON Schema draft 2020-12")

announcements = announcement_database.get("announcements")
if not isinstance(announcements, list) or not announcements:
    raise SystemExit("announcements database must contain at least one announcement")

announcement_ids = set()
for announcement in announcements:
    identifier = announcement.get("id") if isinstance(announcement, dict) else None
    if not isinstance(identifier, str) or not identifier or identifier in announcement_ids:
        raise SystemExit(f"announcements database contains an invalid or duplicate id: {identifier}")
    announcement_ids.add(identifier)
    if announcement.get("type") not in {"compatibility", "project", "release"}:
        raise SystemExit(f"announcement {identifier} has an invalid type")
    for field in ("titles", "summaries"):
        values = announcement.get(field)
        if not isinstance(values, dict) or set(values) != set(locale_names):
            raise SystemExit(f"announcement {identifier} {field} must contain all eight locales")
        if not all(isinstance(value, str) and value.strip() for value in values.values()):
            raise SystemExit(f"announcement {identifier} {field} contains an empty translation")

if not any(announcement.get("featured") is True for announcement in announcements):
    raise SystemExit("announcements database must contain a featured homepage notice")

developer_apps_path = root / "site-data" / "developer-apps.json"
developer_apps_schema_path = root / "site-data" / "developer-apps.schema.json"
try:
    developer_apps_database = json.loads(developer_apps_path.read_text(encoding="utf-8"))
    developer_apps_schema = json.loads(developer_apps_schema_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"developer app catalog JSON is invalid: {exc}")

if developer_apps_database.get("schemaVersion") != 1:
    raise SystemExit("developer app catalog schemaVersion must be 1")
if developer_apps_schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
    raise SystemExit("developer app schema must use JSON Schema draft 2020-12")

developer_apps = developer_apps_database.get("apps")
if not isinstance(developer_apps, list):
    raise SystemExit("developer app catalog apps must be an array")

expected_developer_app_ids = {
    "hopdisk",
    "bunmixer",
    "latchcast",
    "lorabit",
    "kanindex",
    "bunniki",
    "openbooklm",
    "seolapin",
    "brambletread",
    "moonwhisk-vale",
}
developer_app_ids = set()
platform_counts = {"mac": 0, "ipad": 0, "iphone": 0}
for app in developer_apps:
    identifier = app.get("id") if isinstance(app, dict) else None
    if not isinstance(identifier, str) or not identifier or identifier in developer_app_ids:
        raise SystemExit(f"developer app catalog contains an invalid or duplicate id: {identifier}")
    developer_app_ids.add(identifier)
    platform = app.get("platform")
    if platform not in platform_counts:
        raise SystemExit(f"developer app {identifier} has an invalid platform")
    platform_counts[platform] += 1
    summaries = app.get("summaries")
    if not isinstance(summaries, dict) or set(summaries) != set(locale_names):
        raise SystemExit(f"developer app {identifier} summaries must contain all eight locales")
    if not all(isinstance(value, str) and value.strip() for value in summaries.values()):
        raise SystemExit(f"developer app {identifier} contains an empty summary translation")
    app_store_id = app.get("appStoreID")
    href = app.get("href")
    if not isinstance(app_store_id, str) or not app_store_id.isdigit():
        raise SystemExit(f"developer app {identifier} has an invalid App Store ID")
    if not isinstance(href, str) or not re.fullmatch(
        rf"https://apps\.apple\.com/us/app/[a-z0-9-]+/id{re.escape(app_store_id)}",
        href,
    ):
        raise SystemExit(f"developer app {identifier} has an invalid App Store URL")
    artwork = app.get("artwork")
    if not isinstance(artwork, str) or not artwork.startswith("site-assets/developer-apps/"):
        raise SystemExit(f"developer app {identifier} has an invalid artwork path")
    artwork_path = (root / artwork).resolve()
    try:
        artwork_path.relative_to(root_resolved)
    except ValueError:
        raise SystemExit(f"developer app {identifier} artwork escapes the project root")
    if not artwork_path.is_file() or artwork_path.is_symlink():
        raise SystemExit(f"developer app {identifier} artwork is missing or unsafe")

if developer_app_ids != expected_developer_app_ids:
    raise SystemExit("developer app catalog does not match the in-app catalog")
if platform_counts != {"mac": 5, "ipad": 3, "iphone": 2}:
    raise SystemExit(f"developer app platform counts are invalid: {platform_counts}")

developer_app_source_path = (
    root / "Sources" / "ForgePlay" / "Models" / "DeveloperAppCatalog.swift"
)
if developer_app_source_path.is_file() and not developer_app_source_path.is_symlink():
    source = developer_app_source_path.read_text(encoding="utf-8")
    source_blocks = re.findall(
        r"DeveloperAppListing\((.*?)\n        \)(?:,|\n    \])",
        source,
        flags=re.DOTALL,
    )
    if len(source_blocks) != len(developer_apps):
        raise SystemExit(
            "website developer app catalog count differs from DeveloperAppCatalog.swift"
        )

    platform_mapping = {"mac": "mac", "iPad": "ipad", "iPhone": "iphone"}
    source_apps = {}
    for block in source_blocks:
        def source_value(pattern):
            match = re.search(pattern, block)
            if not match:
                raise SystemExit(
                    f"could not parse DeveloperAppCatalog.swift field: {pattern}"
                )
            return match.group(1)

        app_store_id = source_value(r'appStoreID: "([0-9]+)"')
        source_apps[app_store_id] = {
            "name": source_value(r'name: "([^"]+)"'),
            "slug": source_value(r'appStoreSlug: "([^"]+)"'),
            "platform": platform_mapping[
                source_value(r"platform: \.([A-Za-z]+)")
            ],
            "kind": source_value(r"kind: \.([A-Za-z]+)"),
            "appleSiliconMacCompatible": ".appleSiliconMac" in block,
        }

    website_apps = {app["appStoreID"]: app for app in developer_apps}
    if set(website_apps) != set(source_apps):
        raise SystemExit(
            "website developer app IDs differ from DeveloperAppCatalog.swift"
        )
    for app_store_id, source_app in source_apps.items():
        website_app = website_apps[app_store_id]
        website_slug = urlsplit(website_app["href"]).path.split("/app/", 1)[1]
        website_slug = website_slug.rsplit("/id", 1)[0]
        website_projection = {
            "name": website_app["name"],
            "slug": website_slug,
            "platform": website_app["platform"],
            "kind": website_app["kind"],
            "appleSiliconMacCompatible": website_app[
                "appleSiliconMacCompatible"
            ],
        }
        if website_projection != source_app:
            raise SystemExit(
                f"website developer app {app_store_id} differs from "
                "DeveloperAppCatalog.swift"
            )
PY

for html in index.html why.html license.html privacy.html support.html compatibility.html updates.html; do
  require_snippet "$ROOT_DIR/$html" '<html lang="en">'
  require_snippet "$ROOT_DIR/$html" 'src="locale-bootstrap.js?v=20260728-7"'
  require_snippet "$ROOT_DIR/$html" 'href="site.css?v=20260728-7"'
  require_snippet "$ROOT_DIR/$html" 'src="site.js?v=20260728-7"'
  require_snippet "$ROOT_DIR/$html" 'data-language-select'
  require_snippet "$ROOT_DIR/$html" 'site-assets/forgeplay-icon.png'
done

require_snippet "$ROOT_DIR/index.html" 'id="game-mode"'
require_snippet "$ROOT_DIR/index.html" 'id="difference"'
require_snippet "$ROOT_DIR/index.html" 'id="release"'
require_snippet "$ROOT_DIR/index.html" 'CPU + GPU'
require_snippet "$ROOT_DIR/index.html" 'Bluetooth sampling rate'
require_snippet "$ROOT_DIR/index.html" 'href="https://support.apple.com/105118"'
require_snippet "$ROOT_DIR/index.html" 'The Game Mode path is an opt-in beta'
require_snippet "$ROOT_DIR/index.html" 'Confirm activation on your Mac'
require_snippet "$ROOT_DIR/index.html" 'macOS 26+ · Rosetta required'
require_snippet "$ROOT_DIR/index.html" 'Implementation details will be published with the open-source release'
require_snippet "$ROOT_DIR/index.html" 'href="#release" data-i18n="home.sourceLink"'
require_snippet "$ROOT_DIR/index.html" 'href="why.html"'
require_snippet "$ROOT_DIR/index.html" 'href="license.html"'
require_snippet "$ROOT_DIR/index.html" 'PLANNED WITHIN DAYS — NO PUBLIC DOWNLOAD YET'
require_snippet "$ROOT_DIR/index.html" 'site-assets/forgeplay-social.png'
require_snippet "$ROOT_DIR/index.html" 'site-assets/forgeplay-manifesto.jpg'
require_snippet "$ROOT_DIR/index.html" 'site-assets/forgeplay-hero-3200.jpg 3200w'
require_snippet "$ROOT_DIR/index.html" 'site-assets/forgeplay-manifesto-3200.jpg 3200w'
require_snippet "$ROOT_DIR/index.html" 'data-compatibility-count'
require_snippet "$ROOT_DIR/index.html" 'href="compatibility.html"'
require_snippet "$ROOT_DIR/index.html" 'PLAYABLE IN GAME MODE'
require_snippet "$ROOT_DIR/index.html" 'href="https://github.com/sponsors/facta-leopard"'
require_snippet "$ROOT_DIR/index.html" 'src="compatibility.js?v=20260728-7"'
require_snippet "$ROOT_DIR/index.html" 'src="announcements.js?v=20260728-7"'
require_snippet "$ROOT_DIR/index.html" 'src="developer-apps.js?v=20260728-7"'
require_snippet "$ROOT_DIR/index.html" 'data-latest-announcement'
require_snippet "$ROOT_DIR/index.html" 'id="other-apps"'
require_snippet "$ROOT_DIR/index.html" 'data-developer-app-grid'
require_snippet "$ROOT_DIR/index.html" 'DIRECTX'
require_snippet "$ROOT_DIR/index.html" 'METAL'
require_snippet "$ROOT_DIR/index.html" 'macOS GAME MODE'
require_snippet "$ROOT_DIR/index.html" 'data-i18n="home.worldFirstRouteGameMode"'
require_snippet "$ROOT_DIR/index.html" 'data-i18n="home.sponsorMark"'
require_snippet "$ROOT_DIR/index.html" 'THE WORLD’S FIRST*'

require_snippet "$ROOT_DIR/compatibility.html" 'data-compatibility-list'
require_snippet "$ROOT_DIR/compatibility.html" 'data-i18n-placeholder="compat.searchPlaceholder"'
require_snippet "$ROOT_DIR/compatibility.html" 'M4 Pro · 24GB'
require_snippet "$ROOT_DIR/compatibility.html" 'Works in Game Mode or doesn’t—report what you see.'
require_snippet "$ROOT_DIR/compatibility.html" 'Playable in Game Mode'
require_snippet "$ROOT_DIR/compatibility.html" 'Logs shorten the distance to a fix.'
require_snippet "$ROOT_DIR/compatibility.html" 'data-i18n="compat.logLabel"'
require_snippet "$ROOT_DIR/compatibility.html" 'issues/new?template=compatibility-report.yml'
require_snippet "$ROOT_DIR/compatibility.html" 'src="compatibility.js?v=20260728-7"'
require_snippet "$ROOT_DIR/compatibility.js" 'site-data/compatibility-games.json'
require_snippet "$ROOT_DIR/compatibility.js" 'forgeplay:localechange'
require_snippet "$ROOT_DIR/site.js" '"compat.statusPlayable": "게임 모드로 플레이 가능"'
require_snippet "$ROOT_DIR/site-data/README.md" 'Excel / spreadsheet import contract'
require_snippet "$ROOT_DIR/site-data/README.md" 'Developer app catalog'
require_snippet "$ROOT_DIR/site-data/README.md" 'DeveloperAppCatalog.swift'

require_snippet "$ROOT_DIR/updates.html" 'data-announcement-list'
require_snippet "$ROOT_DIR/updates.html" 'data-nav-page="updates"'
require_snippet "$ROOT_DIR/updates.html" 'src="announcements.js?v=20260728-7"'
require_snippet "$ROOT_DIR/announcements.js" 'site-data/announcements.json'
require_snippet "$ROOT_DIR/announcements.js" 'forgeplay:localechange'
require_snippet "$ROOT_DIR/developer-apps.js" 'site-data/developer-apps.json'
require_snippet "$ROOT_DIR/developer-apps.js" 'data-developer-platform'
require_snippet "$ROOT_DIR/developer-apps.js" 'forgeplay:localechange'

require_snippet "$ROOT_DIR/why.html" 'Why I Built ForgePlay'
require_snippet "$ROOT_DIR/why.html" 'site-assets/forgeplay-manifesto-3200.jpg 3200w'
require_snippet "$ROOT_DIR/why.html" 'iron rice bowl'
require_snippet "$ROOT_DIR/why.html" 'CodeWeavers’ long contribution to Wine deserves recognition'
require_snippet "$ROOT_DIR/why.html" 'If progress stalled because no one could challenge it'
require_snippet "$ROOT_DIR/why.html" '경쟁이 없어서 멈췄다면, 경쟁자를 만들어 주겠다!'
require_snippet "$ROOT_DIR/why.html" 'game engines and graphics—including the DirectX and Metal stacks'
require_snippet "$ROOT_DIR/why.html" '게임 엔진과 그래픽스, DirectX와 Metal 기술 스택'
require_snippet "$ROOT_DIR/why.html" 'href="index.html#release"'

require_snippet "$ROOT_DIR/license.html" 'ForgePlay does not have a single license.'
require_snippet "$ROOT_DIR/license.html" 'GPL-3.0-only'
require_snippet "$ROOT_DIR/license.html" 'Corresponding Source'
require_snippet "$ROOT_DIR/license.html" 'not accept external code contributions'
require_snippet "$ROOT_DIR/license.html" 'data-i18n="license.mastheadLabel"'
require_snippet "$ROOT_DIR/license.html" 'data-i18n-aria-label="license.mastheadAria"'
require_snippet "$ROOT_DIR/license.html" 'data-i18n="license.mastheadScope"'
require_snippet "$ROOT_DIR/license.html" 'data-i18n="license.filesLabel"'
require_snippet "$ROOT_DIR/license.html" '게임 모드 코드는 GPLv3로 공개합니다. 나머지 구성 요소는 각자의 조건을 따릅니다.'
require_snippet "$ROOT_DIR/license.html" 'Game Mode code is GPLv3. Every other component keeps its own terms.'
require_snippet "$ROOT_DIR/license.html" 'Der Spielmodus-Code steht unter GPLv3. Für alle anderen Komponenten gelten ihre eigenen Bedingungen.'
require_snippet "$ROOT_DIR/license.html" 'El código del modo Juego usa GPLv3. Los demás componentes conservan sus propias condiciones.'
require_snippet "$ROOT_DIR/license.html" 'Le code du mode Jeu est sous GPLv3. Les autres composants conservent leurs propres conditions.'
require_snippet "$ROOT_DIR/license.html" 'ゲームモードのコードは GPLv3。その他のコンポーネントには、それぞれの条件が適用されます。'
require_snippet "$ROOT_DIR/license.html" '游戏模式代码采用 GPLv3。其他组件各自遵循原有条款。'
require_snippet "$ROOT_DIR/license.html" '遊戲模式程式碼採用 GPLv3。其他元件各自遵循原有條款。'
require_snippet "$ROOT_DIR/license.html" 'href="LICENSE.md" download'
require_snippet "$ROOT_DIR/license.html" 'href="LICENSES/GPL-3.0-only.txt" download'

require_snippet "$ROOT_DIR/site-data/announcements.json" '"de": "ForgePlay stellt den macOS-Spielmodus in den Mittelpunkt."'
require_snippet "$ROOT_DIR/site-data/announcements.json" '"es": "ForgePlay sitúa el modo Juego de macOS en el centro."'
require_snippet "$ROOT_DIR/site-data/announcements.json" '"fr": "ForgePlay place le mode Jeu de macOS au centre."'
require_snippet "$ROOT_DIR/site-data/announcements.json" '"ja": "ForgePlayはmacOSのゲームモードを中核に据えました。"'

require_snippet "$ROOT_DIR/privacy.html" "does not include advertising tracking"
require_snippet "$ROOT_DIR/privacy.html" "Apple Foundation Models"
require_snippet "$ROOT_DIR/privacy.html" "without an external AI server or API key"
require_snippet "$ROOT_DIR/privacy.html" "does not ask for, store, or transmit Steam passwords"
require_snippet "$ROOT_DIR/support.html" "support bundle"
require_snippet "$ROOT_DIR/support.html" "Do not send Steam passwords"
require_snippet "$ROOT_DIR/support.html" "D3DMetal in the direct-distribution DMG"
require_snippet "$ROOT_DIR/support.html" "Steam, Microsoft Runtime, DirectX"

for lang in "${LANGS[@]}"; do
  require_snippet "$ROOT_DIR/privacy.html" "id=\"privacy-$lang\" class=\"language-section\" lang=\"$lang\""
  require_snippet "$ROOT_DIR/support.html" "id=\"support-$lang\" class=\"language-section\" lang=\"$lang\""
  require_snippet "$ROOT_DIR/why.html" "id=\"why-$lang\" class=\"language-section story-language\" lang=\"$lang\""
  require_snippet "$ROOT_DIR/license.html" "id=\"license-$lang\" class=\"language-section license-language\" lang=\"$lang\""
done

for localized_page in privacy.html support.html why.html license.html; do
  if grep -Fq 'data-set-locale=' "$ROOT_DIR/$localized_page"; then
    fail "$localized_page must use only the global language selector"
  fi
  if [[ "$(grep -c 'data-language-select' "$ROOT_DIR/$localized_page")" -ne 1 ]]; then
    fail "$localized_page must contain exactly one global language selector"
  fi
done

require_snippet "$ROOT_DIR/site.css" ":focus-visible"
require_snippet "$ROOT_DIR/site.css" "@media (max-width: 760px)"
require_snippet "$ROOT_DIR/site.css" "@media (prefers-reduced-motion: reduce)"
require_snippet "$ROOT_DIR/site.css" "grid-template-columns: 1fr;"
require_snippet "$ROOT_DIR/site.css" "word-break: keep-all"
require_snippet "$ROOT_DIR/site.css" ".world-first-route"
require_snippet "$ROOT_DIR/site.css" ".updates-list"
require_snippet "$ROOT_DIR/site.css" '.nav-links a[aria-current="page"]'
require_snippet "$ROOT_DIR/site.css" ".developer-app-grid"
require_snippet "$ROOT_DIR/locale-bootstrap.js" "const supportedLocales = Object.freeze(["
require_snippet "$ROOT_DIR/locale-bootstrap.js" "navigator.languages"
require_snippet "$ROOT_DIR/locale-bootstrap.js" "document.documentElement.lang = resolvedLocale"
require_snippet "$ROOT_DIR/locale-bootstrap.js" 'classList.add("locale-pending")'
require_snippet "$ROOT_DIR/site.js" "window.ForgePlayLocaleBootstrap"
require_snippet "$ROOT_DIR/site.js" "window.localStorage.setItem"
require_snippet "$ROOT_DIR/site.js" 'classList.remove("locale-pending")'
require_snippet "$ROOT_DIR/site.js" "initializeSectionNavigation"
require_snippet "$ROOT_DIR/site.js" 'section.hidden = section.getAttribute("lang") !== locale'
require_snippet "$ROOT_DIR/site.js" 'new Set(["privacy", "support", "why", "license"])'
require_snippet "$ROOT_DIR/site.js" 'window.ForgePlaySite = Object.freeze'
require_snippet "$ROOT_DIR/site.js" 'document.dispatchEvent(new CustomEvent("forgeplay:localechange"'

if [[ -d "$ROOT_DIR/.git" ]]; then
  require_regular_file "$ROOT_DIR/.github/ISSUE_TEMPLATE/compatibility-report.yml"
  require_regular_file "$ROOT_DIR/.github/FUNDING.yml"
  require_snippet "$ROOT_DIR/.github/ISSUE_TEMPLATE/compatibility-report.yml" 'name: Compatibility report'
  require_snippet "$ROOT_DIR/.github/ISSUE_TEMPLATE/compatibility-report.yml" 'label: Reviewed diagnostics'
  require_snippet "$ROOT_DIR/.github/FUNDING.yml" 'github:'
  require_snippet "$ROOT_DIR/.github/FUNDING.yml" 'facta-leopard'
fi

for forbidden_phrase in \
  "Download now" \
  "Game Mode activates normally" \
  "ForgePlay is entirely GPL" \
  "Developer ID and Mac App Store availability as separate distribution channels" \
  "App Store Connect submission" \
  "sandbox runtime QA" \
  "Apple review" \
  "does not host Apple GPTK"; do
  if grep -Fq "$forbidden_phrase" \
    "$ROOT_DIR/index.html" "$ROOT_DIR/why.html" "$ROOT_DIR/license.html" \
    "$ROOT_DIR/privacy.html" "$ROOT_DIR/support.html" "$ROOT_DIR/compatibility.html" \
    "$ROOT_DIR/updates.html"; then
    fail "public site must not contain inaccurate or retired wording: $forbidden_phrase"
  fi
done

for retired_license_phrase in \
  "Open code stays open. Separate rights stay clear." \
  "열린 코드는 열려 있게. 다른 권리는 분명하게." \
  "Offener Code bleibt offen. Getrennte Rechte bleiben klar." \
  "El código abierto sigue abierto. Los demás derechos, bien delimitados." \
  "Le code ouvert reste ouvert. Les autres droits restent clairement séparés." \
  "オープンなコードは、オープンなまま。別の権利は明確に。" \
  "开放的代码，始终开放。其他权利，边界清晰。" \
  "開放的程式碼，持續開放。其他權利，界線清楚。"; do
  if grep -Fq "$retired_license_phrase" \
    "$ROOT_DIR/index.html" "$ROOT_DIR/license.html" "$ROOT_DIR/site.js"; then
    fail "public site contains retired license wording: $retired_license_phrase"
  fi
done

printf 'Static site verification passed.\n'
