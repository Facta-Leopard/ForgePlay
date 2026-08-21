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
  site-assets/why-story.css
  locale-bootstrap.js
  site.js
  site-assets/current-release.js
  site-assets/why-story.js
  compatibility.js
  announcements.js
  developer-apps.js
  site-data/compatibility-games.json
  site-data/compatibility.schema.json
  site-data/current-release.json
  site-data/current-release.schema.json
  site-data/announcements.json
  site-data/announcements.schema.json
  site-data/developer-apps.json
  site-data/developer-apps.schema.json
  site-data/README.md
  site-data/why-story/ko.md
  site-data/why-story/en.md
  site-data/why-story/de.md
  site-data/why-story/es.md
  site-data/why-story/fr.md
  site-data/why-story/ja.md
  site-data/why-story/zh-Hans.md
  site-data/why-story/zh-Hant.md
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
  site-assets/developer-apps/majordex.png
  site-assets/developer-apps/forgekit.png
  site-assets/developer-apps/harewatch.png
  site-assets/developer-apps/warrennet.png
  site-assets/developer-apps/hazel-and-peanut.png
  site-assets/developer-apps/grayline.png
  site-assets/developer-apps/leporis-ascendant.png
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

python3 - "$ROOT_DIR" "${LANGS[@]}" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
locales = sys.argv[2:]
expected_reference_ids = {
    "crossover-95",
    "lgpl",
    "game-mode",
    "crossover-settings",
    "compatibility-database",
    "crossover-proprietary",
    "gptk-license",
    "crossover26",
}
required_terms = {
    "ForgePlay",
    "CrossOver",
    "CodeWeavers",
    "Wine",
    "Game Host",
    "GPTK",
    "D3DMetal",
    "LGPL",
}
structural_counts = None

for locale in locales:
    path = root / "site-data" / "why-story" / f"{locale}.md"
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()
    if not text.endswith("\n") or "\r" in text or "\ufffd" in text:
        raise SystemExit(f"{path}: invalid UTF-8 text normalization")
    if "[^^" in text:
        raise SystemExit(f"{path}: malformed footnote marker")
    if re.search(r"!\[[^\]]*\]\(", text):
        raise SystemExit(f"{path}: images are not supported by the note renderer")
    if re.search(r"</?[A-Za-z][^>]*>", text):
        raise SystemExit(f"{path}: raw HTML is not allowed")

    level_two = [line for line in lines if line.startswith("## ")]
    level_three = [line for line in lines if line.startswith("### ")]
    if len(level_two) != 1 or len(level_three) != 10:
        raise SystemExit(
            f"{path}: expected one title and ten full-text sections"
        )
    if len(level_three) != len(set(level_three)):
        raise SystemExit(f"{path}: duplicate section heading")

    missing_terms = sorted(term for term in required_terms if term not in text)
    if missing_terms:
        raise SystemExit(f"{path}: missing core terms: {missing_terms}")
    if not re.search(r"95\s*%", text):
        raise SystemExit(f"{path}: missing the 95 percent claim")

    definitions = re.findall(
        r"^\[\^([^\]]+)\]:\s*(\S.*)$",
        text,
        flags=re.MULTILINE,
    )
    definition_ids = [identifier for identifier, _ in definitions]
    if len(definition_ids) != len(set(definition_ids)):
        raise SystemExit(f"{path}: duplicate footnote definition")
    if set(definition_ids) != expected_reference_ids:
        raise SystemExit(
            f"{path}: footnote definitions differ from the source statement"
        )
    references = re.findall(r"\[\^([^\]]+)\](?!:)", text)
    if set(references) != expected_reference_ids:
        raise SystemExit(
            f"{path}: every source note must be cited in the full text"
        )

    links = re.findall(r"\[[^\]]+\]\(([^)]+)\)", text)
    if not links or any(not target.startswith("https://") for target in links):
        raise SystemExit(f"{path}: note links must use HTTPS")

    unsupported_blocks = [
        line
        for line in lines
        if re.match(r"^(?:# |####|\* |\+ |\d+\. |---+$)", line)
    ]
    if unsupported_blocks:
        raise SystemExit(f"{path}: unsupported Markdown block syntax")

    counts = {
        "paragraphs": sum(
            bool(line)
            and not line.startswith(("## ", "### ", "> ", "- ", "[^"))
            for line in lines
        ),
        "quotes": sum(line.startswith("> ") for line in lines),
        "listItems": sum(line.startswith("- ") for line in lines),
        "footnotes": len(definitions),
    }
    if structural_counts is None:
        structural_counts = counts
    elif counts != structural_counts:
        raise SystemExit(
            f"{path}: localized statement structure is not aligned; "
            f"expected={structural_counts} actual={counts}"
        )

english = (root / "site-data" / "why-story" / "en.md").read_text(encoding="utf-8")
for locale in locales:
    if locale == "en":
        continue
    localized = (
        root / "site-data" / "why-story" / f"{locale}.md"
    ).read_text(encoding="utf-8")
    if localized == english:
        raise SystemExit(f"why-story locale {locale} is an English fallback")
PY

python3 - "$ROOT_DIR" \
  "$ROOT_DIR/index.html" \
  "$ROOT_DIR/why.html" \
  "$ROOT_DIR/license.html" \
  "$ROOT_DIR/privacy.html" \
  "$ROOT_DIR/support.html" \
  "$ROOT_DIR/compatibility.html" \
  "$ROOT_DIR/updates.html" <<'PY'
import hashlib
import json
import re
import sys
from datetime import date, datetime
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit

root = Path(sys.argv[1])
root_resolved = root.resolve()
forgeplay_icon_path = root / "site-assets" / "forgeplay-icon.png"
forgeplay_icon_hash = hashlib.sha256(forgeplay_icon_path.read_bytes()).hexdigest()
if forgeplay_icon_hash != "65a8602880ce0d14f623f81ce9aa8a1dc6c87da2ea617654e54bdbd0740511b3":
    raise SystemExit("website ForgePlay icon differs from the in-app dark appearance")
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
            if parsed.scheme.lower() != "https":
                raise SystemExit(
                    f"{path}: external references must use HTTPS: {reference}"
                )
            if (
                parsed.netloc.lower() == "github.com"
                and parsed.path.lower().startswith("/facta-leopard/forgeplay/issues")
            ):
                allowed_issue_destinations = {
                    (
                        "support.html",
                        "/facta-leopard/forgeplay/issues/new/choose",
                        "",
                    ),
                    (
                        "compatibility.html",
                        "/facta-leopard/forgeplay/issues/new",
                        "template=compatibility-report.yml",
                    ),
                }
                issue_destination = (
                    path.name,
                    parsed.path.lower(),
                    parsed.query.lower(),
                )
                if issue_destination not in allowed_issue_destinations:
                    raise SystemExit(
                        f"{path}: unexpected GitHub Issues destination: {reference}"
                    )
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
    "home.gameModeCheck",
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
    "developerApps.count",
    "developerApps.countOne",
    "developerApps.projectCount",
    "developerApps.projectCountOne",
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

if database.get("schemaVersion") != 2:
    raise SystemExit("compatibility database schemaVersion must be 2")
if schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
    raise SystemExit("compatibility schema must use JSON Schema draft 2020-12")
if schema.get("properties", {}).get("schemaVersion", {}).get("const") != 2:
    raise SystemExit("compatibility schema must require schemaVersion 2")
report_properties = schema.get("$defs", {}).get("report", {}).get("properties", {})
for version_field in ("forgePlayVersion", "gameVersion"):
    version_types = report_properties.get(version_field, {}).get("type", [])
    if not (
        isinstance(version_types, list)
        and {"string", "null"}.issubset(version_types)
    ):
        raise SystemExit(
            f"compatibility report {version_field} must support a string or null"
        )
test_profile_reference_schema = (
    schema.get("$defs", {})
    .get("report", {})
    .get("properties", {})
    .get("testProfileId", {})
)
test_profile_reference_options = test_profile_reference_schema.get("anyOf", [])
if not (
    any(option.get("$ref") == "#/$defs/identifier" for option in test_profile_reference_options)
    and any(option.get("type") == "null" for option in test_profile_reference_options)
):
    raise SystemExit("compatibility reports must support an explicitly unreported device")
unified_memory_schema = (
    schema.get("$defs", {})
    .get("testProfile", {})
    .get("properties", {})
    .get("unifiedMemoryGB", {})
)
unified_memory_types = unified_memory_schema.get("type", [])
if not (
    isinstance(unified_memory_types, list)
    and {"integer", "null"}.issubset(unified_memory_types)
):
    raise SystemExit("compatibility profiles must support unreported unified memory")

game_titles_schema = schema.get("$defs", {}).get("gameTitles", {})
if not {"en", "ko"}.issubset(set(game_titles_schema.get("required", []))):
    raise SystemExit("compatibility game titles must require English and Korean")
if (
    game_titles_schema.get("properties", {})
    .get("ko", {})
    .get("pattern")
    != "[가-힣]"
):
    raise SystemExit("compatibility Korean game titles must require Hangul")

identifier_pattern = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
allowed_statuses = {"playable", "testing", "blocked", "unknown"}
allowed_sources = {"project-test", "github-issue", "community-report"}
allowed_blockers = {
    "anti-cheat",
    "launcher",
    "graphics",
    "runtime",
    "security-module",
    "unknown",
    None,
}

def require_object_shape(item, required, allowed, label):
    if not isinstance(item, dict):
        raise SystemExit(f"{label} must be an object")
    missing = required - item.keys()
    extra = item.keys() - allowed
    if missing or extra:
        raise SystemExit(
            f"{label} has invalid fields; missing={sorted(missing)} "
            f"extra={sorted(extra)}"
        )

def parse_iso_date(value, label):
    if not isinstance(value, str):
        raise SystemExit(f"{label} must be an ISO date")
    try:
        parsed = date.fromisoformat(value)
    except ValueError as exc:
        raise SystemExit(f"{label} must be an ISO date: {exc}")
    if parsed.isoformat() != value:
        raise SystemExit(f"{label} must use YYYY-MM-DD format")
    return parsed

def index_unique(items, collection_name):
    indexed = {}
    for item in items:
        identifier = item.get("id") if isinstance(item, dict) else None
        if (
            not isinstance(identifier, str)
            or not identifier_pattern.fullmatch(identifier)
        ):
            raise SystemExit(f"{collection_name} contains an invalid id")
        if identifier in indexed:
            raise SystemExit(f"{collection_name} contains duplicate id: {identifier}")
        indexed[identifier] = item
    return indexed

def validate_compatibility_database(candidate):
    require_object_shape(
        candidate,
        {"schemaVersion", "updatedAt", "testProfiles", "games", "reports"},
        {"$schema", "schemaVersion", "updatedAt", "testProfiles", "games", "reports"},
        "compatibility database",
    )
    if candidate.get("schemaVersion") != 2:
        raise SystemExit("compatibility database schemaVersion must be 2")

    updated_at = parse_iso_date(
        candidate.get("updatedAt"),
        "compatibility database updatedAt",
    )
    profiles = candidate.get("testProfiles")
    games = candidate.get("games")
    reports = candidate.get("reports")
    if not all(
        isinstance(collection, list)
        for collection in (profiles, games, reports)
    ):
        raise SystemExit("compatibility database collections must be arrays")
    if not games or not reports:
        raise SystemExit("compatibility database must include games and reports")

    profile_by_id = index_unique(profiles, "testProfiles")
    game_by_id = index_unique(games, "games")
    report_by_id = index_unique(reports, "reports")

    for profile_id, profile in profile_by_id.items():
        require_object_shape(
            profile,
            {"id", "platform", "chip", "unifiedMemoryGB", "macOSVersion"},
            {"id", "platform", "chip", "unifiedMemoryGB", "macOSVersion"},
            f"profile {profile_id}",
        )
        if not all(
            isinstance(profile.get(field), str) and profile[field].strip()
            for field in ("platform", "chip")
        ):
            raise SystemExit(f"profile {profile_id} has invalid platform or chip")
        memory = profile.get("unifiedMemoryGB")
        if memory is not None and (
            isinstance(memory, bool)
            or not isinstance(memory, int)
            or memory < 1
        ):
            raise SystemExit(f"profile {profile_id} has invalid unified memory")
        macos_version = profile.get("macOSVersion")
        if macos_version is not None and (
            not isinstance(macos_version, str) or not macos_version.strip()
        ):
            raise SystemExit(f"profile {profile_id} has invalid macOS version")

    for game_id, game in game_by_id.items():
        require_object_shape(
            game,
            {"id", "titles"},
            {"id", "titles"},
            f"game {game_id}",
        )
        titles = game.get("titles")
        if not isinstance(titles, dict) or not all(
            isinstance(titles.get(locale), str) and titles[locale].strip()
            for locale in ("en", "ko")
        ):
            raise SystemExit(
                f"game {game_id} must include non-empty English and Korean titles"
            )
        if not all(
            isinstance(value, str) and value.strip()
            for value in titles.values()
        ):
            raise SystemExit(f"game {game_id} contains an invalid localized title")
        if not re.search(r"[가-힣]", titles["ko"]):
            raise SystemExit(
                f"game {game_id} Korean title must contain Hangul"
            )

    reported_game_ids = set()
    for report_id, report in report_by_id.items():
        require_object_shape(
            report,
            {
                "id",
                "gameId",
                "testProfileId",
                "status",
                "source",
                "testedAt",
                "notes",
                "blocker",
            },
            {
                "id",
                "gameId",
                "testProfileId",
                "status",
                "source",
                "reporter",
                "forgePlayVersion",
                "gameVersion",
                "testedAt",
                "notes",
                "blocker",
            },
            f"report {report_id}",
        )
        game_id = report.get("gameId")
        if game_id not in game_by_id:
            raise SystemExit(f"report {report_id} references an unknown game")
        reported_game_ids.add(game_id)

        test_profile_id = report.get("testProfileId")
        if test_profile_id is not None and test_profile_id not in profile_by_id:
            raise SystemExit(
                f"report {report_id} references an unknown test profile"
            )
        status = report.get("status")
        if status not in allowed_statuses:
            raise SystemExit(f"report {report_id} has an invalid status")
        source = report.get("source")
        if source not in allowed_sources:
            raise SystemExit(f"report {report_id} has an invalid source")
        reporter = report.get("reporter")
        if reporter is not None and (
            not isinstance(reporter, str) or not reporter.strip()
        ):
            raise SystemExit(f"report {report_id} has an invalid reporter")
        if source != "project-test" and not reporter:
            raise SystemExit(
                f"report {report_id} must attribute a non-project source"
            )

        for version_field in ("forgePlayVersion", "gameVersion"):
            version = report.get(version_field)
            if version is not None and (
                not isinstance(version, str) or not version.strip()
            ):
                raise SystemExit(
                    f"report {report_id} has an invalid {version_field}"
                )

        blocker = report.get("blocker")
        if blocker not in allowed_blockers:
            raise SystemExit(f"report {report_id} has an invalid blocker")
        if status == "playable" and blocker is not None:
            raise SystemExit(f"playable report {report_id} cannot have a blocker")
        if status == "blocked" and blocker is None:
            raise SystemExit(f"blocked report {report_id} must include a blocker")

        tested_at = report.get("testedAt")
        if tested_at is not None:
            tested_date = parse_iso_date(
                tested_at,
                f"report {report_id} testedAt",
            )
            if tested_date > updated_at:
                raise SystemExit(
                    f"report {report_id} is newer than database updatedAt"
                )

        notes = report.get("notes")
        if notes is not None and (
            not isinstance(notes, dict)
            or not all(
                isinstance(notes.get(locale), str) and notes[locale].strip()
                for locale in locale_names
            )
        ):
            raise SystemExit(
                f"report {report_id} notes must cover all eight site locales"
            )

    unreported_games = game_by_id.keys() - reported_game_ids
    if unreported_games:
        raise SystemExit(
            f"compatibility database contains games without reports: "
            f"{sorted(unreported_games)}"
        )

validate_compatibility_database(database)

# A minimal future database must pass without changing this verifier. This
# guards the compatibility pipeline against content-specific hardcoding.
validate_compatibility_database({
    "$schema": "./compatibility.schema.json",
    "schemaVersion": 2,
    "updatedAt": "2099-01-02",
    "testProfiles": [
        {
            "id": "apple-silicon-future-chip",
            "platform": "Apple Silicon Mac",
            "chip": "Future Chip",
            "unifiedMemoryGB": None,
            "macOSVersion": None,
        }
    ],
    "games": [
        {
            "id": "future-test-game",
            "titles": {
                "en": "Future Test Game",
                "ko": "미래 테스트 게임",
            },
        }
    ],
    "reports": [
        {
            "id": "future-test-game-community-report",
            "gameId": "future-test-game",
            "testProfileId": "apple-silicon-future-chip",
            "status": "playable",
            "source": "community-report",
            "reporter": "future-reporter",
            "forgePlayVersion": "vFuture",
            "gameVersion": None,
            "testedAt": "2099-01-02",
            "notes": None,
            "blocker": None,
        }
    ],
})

current_release_path = root / "site-data" / "current-release.json"
current_release_schema_path = root / "site-data" / "current-release.schema.json"
try:
    current_release = json.loads(current_release_path.read_text(encoding="utf-8"))
    current_release_schema = json.loads(
        current_release_schema_path.read_text(encoding="utf-8")
    )
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"current release JSON is invalid: {exc}")

current_release_fields = {
    "$schema",
    "schemaVersion",
    "product",
    "channel",
    "marketingVersion",
    "buildNumber",
    "releaseTag",
    "publishedAt",
    "minimumMacOSVersion",
    "releaseURL",
    "download",
}
if current_release_schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
    raise SystemExit("current release schema must use JSON Schema draft 2020-12")
if current_release_schema.get("additionalProperties") is not False:
    raise SystemExit("current release schema must reject unknown top-level fields")
if set(current_release_schema.get("required", [])) != current_release_fields:
    raise SystemExit("current release schema must require the complete field contract")
if set(current_release_schema.get("properties", {})) != current_release_fields:
    raise SystemExit("current release schema fields differ from the consumer contract")
current_release_properties = current_release_schema["properties"]
if current_release_properties.get("schemaVersion", {}).get("const") != 1:
    raise SystemExit("current release schema must require schemaVersion 1")
if current_release_properties.get("product", {}).get("const") != "ForgePlay":
    raise SystemExit("current release schema must bind the ForgePlay product")
if current_release_properties.get("channel", {}).get("const") != "stable":
    raise SystemExit("current release schema must bind the stable channel")
if current_release_properties.get("download", {}).get("$ref") != "#/$defs/download":
    raise SystemExit("current release schema must use the shared download definition")
current_release_download_schema = current_release_schema.get("$defs", {}).get("download", {})
current_release_download_fields = {"assetName", "url", "sha256", "byteSize"}
if current_release_download_schema.get("additionalProperties") is not False:
    raise SystemExit("current release download schema must reject unknown fields")
if set(current_release_download_schema.get("required", [])) != current_release_download_fields:
    raise SystemExit("current release download schema must require every field")
if set(current_release_download_schema.get("properties", {})) != current_release_download_fields:
    raise SystemExit("current release download schema fields differ from the contract")

release_version_pattern = re.compile(r"^[0-9]+(?:\.[0-9]+){1,2}$")
release_tag_pattern = re.compile(
    r"^v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$"
)
release_asset_pattern = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
release_sha256_pattern = re.compile(r"^[0-9a-f]{64}$")
release_utc_pattern = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$"
)

def require_exact_github_release_url(value, expected_path, label):
    if not isinstance(value, str):
        raise SystemExit(f"{label} must be an HTTPS GitHub URL")
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or parsed.hostname != "github.com"
        or parsed.port is not None
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path != expected_path
    ):
        raise SystemExit(f"{label} is outside the trusted ForgePlay release path")

def normalized_release_version(value):
    components = [int(component) for component in value.split(".")]
    return tuple((components + [0, 0, 0])[:3])

def validate_current_release(candidate):
    require_object_shape(
        candidate,
        current_release_fields,
        current_release_fields,
        "current release manifest",
    )
    if candidate.get("$schema") != "./current-release.schema.json":
        raise SystemExit("current release manifest references the wrong schema")
    if candidate.get("schemaVersion") != 1:
        raise SystemExit("current release manifest schemaVersion must be 1")
    if candidate.get("product") != "ForgePlay":
        raise SystemExit("current release manifest product must be ForgePlay")
    if candidate.get("channel") != "stable":
        raise SystemExit("current release manifest channel must be stable")

    marketing_version = candidate.get("marketingVersion")
    if not isinstance(marketing_version, str) or not release_version_pattern.fullmatch(
        marketing_version
    ):
        raise SystemExit("current release marketingVersion is invalid")
    build_number = candidate.get("buildNumber")
    if isinstance(build_number, bool) or not isinstance(build_number, int) or build_number < 1:
        raise SystemExit("current release buildNumber must be a positive integer")
    release_tag = candidate.get("releaseTag")
    if not isinstance(release_tag, str) or not release_tag_pattern.fullmatch(release_tag):
        raise SystemExit("current release releaseTag is invalid")
    tag_version = re.split(r"[-+]", release_tag[1:], maxsplit=1)[0]
    if normalized_release_version(marketing_version) != normalized_release_version(tag_version):
        raise SystemExit("current release marketingVersion and releaseTag disagree")

    published_at = candidate.get("publishedAt")
    if not isinstance(published_at, str) or not release_utc_pattern.fullmatch(published_at):
        raise SystemExit("current release publishedAt must be an ISO 8601 UTC timestamp")
    try:
        parsed_published_at = datetime.fromisoformat(
            published_at.removesuffix("Z") + "+00:00"
        )
    except ValueError as exc:
        raise SystemExit(f"current release publishedAt is invalid: {exc}")
    if parsed_published_at.utcoffset() is None:
        raise SystemExit("current release publishedAt must include a UTC offset")

    minimum_macos = candidate.get("minimumMacOSVersion")
    if not isinstance(minimum_macos, str) or not release_version_pattern.fullmatch(
        minimum_macos
    ):
        raise SystemExit("current release minimumMacOSVersion is invalid")

    download = candidate.get("download")
    require_object_shape(
        download,
        current_release_download_fields,
        current_release_download_fields,
        "current release download",
    )
    asset_name = download.get("assetName")
    if not isinstance(asset_name, str) or not release_asset_pattern.fullmatch(asset_name):
        raise SystemExit("current release download assetName is invalid")
    require_exact_github_release_url(
        candidate.get("releaseURL"),
        f"/Facta-Leopard/ForgePlay/releases/tag/{release_tag}",
        "current release releaseURL",
    )
    require_exact_github_release_url(
        download.get("url"),
        f"/Facta-Leopard/ForgePlay/releases/download/{release_tag}/{asset_name}",
        "current release download URL",
    )
    sha256 = download.get("sha256")
    if not isinstance(sha256, str) or not release_sha256_pattern.fullmatch(sha256):
        raise SystemExit("current release download sha256 is invalid")
    byte_size = download.get("byteSize")
    if isinstance(byte_size, bool) or not isinstance(byte_size, int) or byte_size < 1:
        raise SystemExit("current release download byteSize must be a positive integer")

validate_current_release(current_release)

# A future release must validate without teaching the verifier a specific app
# version. This prevents the update source from becoming another hardcoded UI.
validate_current_release({
    "$schema": "./current-release.schema.json",
    "schemaVersion": 1,
    "product": "ForgePlay",
    "channel": "stable",
    "marketingVersion": "9.7",
    "buildNumber": 42,
    "releaseTag": "v9.7.0",
    "publishedAt": "2099-01-02T03:04:05Z",
    "minimumMacOSVersion": "26.1",
    "releaseURL": "https://github.com/Facta-Leopard/ForgePlay/releases/tag/v9.7.0",
    "download": {
        "assetName": "ForgePlay-9.7-42.dmg",
        "url": "https://github.com/Facta-Leopard/ForgePlay/releases/download/v9.7.0/ForgePlay-9.7-42.dmg",
        "sha256": "0" * 64,
        "byteSize": 123456,
    },
})

announcements_path = root / "site-data" / "announcements.json"
announcements_schema_path = root / "site-data" / "announcements.schema.json"
try:
    announcement_database = json.loads(announcements_path.read_text(encoding="utf-8"))
    announcement_schema = json.loads(announcements_schema_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"announcements JSON is invalid: {exc}")

if announcement_database.get("schemaVersion") != 2:
    raise SystemExit("announcements database schemaVersion must be 2")
if announcement_schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
    raise SystemExit("announcements schema must use JSON Schema draft 2020-12")
if announcement_schema.get("properties", {}).get("schemaVersion", {}).get("const") != 2:
    raise SystemExit("announcements schema must require schemaVersion 2")
paragraph_list_schema = announcement_schema.get("$defs", {}).get("paragraphList", {})
if (
    paragraph_list_schema.get("type") != "array"
    or paragraph_list_schema.get("minItems") != 1
    or paragraph_list_schema.get("items", {}).get("type") != "string"
):
    raise SystemExit("announcements schema must define non-empty paragraph lists")
announcement_item_schema = announcement_schema.get("$defs", {}).get("announcement", {})
if set(
    announcement_item_schema.get("properties", {})
    .get("type", {})
    .get("enum", [])
) != {"project", "release"}:
    raise SystemExit("announcements schema must allow only project and release notices")
if (
    announcement_item_schema.get("properties", {})
    .get("paragraphs", {})
    .get("$ref")
    != "#/$defs/localizedParagraphs"
):
    raise SystemExit("announcements schema must bind localized notice paragraphs")

announcements = announcement_database.get("announcements")
if not isinstance(announcements, list) or not announcements:
    raise SystemExit("announcements database must contain at least one announcement")

announcement_updated_at = parse_iso_date(
    announcement_database.get("updatedAt"),
    "announcements database updatedAt",
)
announcement_ids = set()
for announcement in announcements:
    identifier = announcement.get("id") if isinstance(announcement, dict) else None
    if not isinstance(identifier, str) or not identifier or identifier in announcement_ids:
        raise SystemExit(f"announcements database contains an invalid or duplicate id: {identifier}")
    announcement_ids.add(identifier)
    require_object_shape(
        announcement,
        {"id", "type", "publishedAt", "featured", "titles", "summaries", "href"},
        {"id", "type", "publishedAt", "featured", "titles", "summaries", "paragraphs", "href"},
        f"announcement {identifier}",
    )
    if announcement.get("type") not in {"project", "release"}:
        raise SystemExit(f"announcement {identifier} has an invalid type")
    if not isinstance(announcement.get("featured"), bool):
        raise SystemExit(f"announcement {identifier} featured must be a boolean")
    published_at = parse_iso_date(
        announcement.get("publishedAt"),
        f"announcement {identifier} publishedAt",
    )
    if published_at > announcement_updated_at:
        raise SystemExit(f"announcement {identifier} is newer than database updatedAt")
    href = announcement.get("href")
    if not isinstance(href, str) or not href.strip():
        raise SystemExit(f"announcement {identifier} has an invalid destination")
    parsed_href = urlsplit(href)
    if parsed_href.scheme or parsed_href.netloc:
        if parsed_href.scheme != "https":
            raise SystemExit(
                f"announcement {identifier} external destination must use HTTPS"
            )
        if (
            parsed_href.netloc.lower() == "github.com"
            and parsed_href.path.lower().startswith("/facta-leopard/forgeplay/issues")
        ):
            raise SystemExit(
                f"announcement {identifier} must not use GitHub Issues as its detail link"
            )
    else:
        if parsed_href.path.startswith("/"):
            raise SystemExit(
                f"announcement {identifier} destination must be relative to the site"
            )
        announcement_target = (root / (parsed_href.path or "updates.html")).resolve()
        try:
            announcement_target.relative_to(root_resolved)
        except ValueError:
            raise SystemExit(
                f"announcement {identifier} destination escapes the project root"
            )
        if not announcement_target.is_file():
            raise SystemExit(
                f"announcement {identifier} destination does not exist: {href}"
            )
        expected_dynamic_fragment = f"update-{identifier}"
        if parsed_href.fragment == expected_dynamic_fragment:
            if announcement_target != (root / "updates.html").resolve():
                raise SystemExit(
                    f"announcement {identifier} detail anchor must target updates.html"
                )
        elif parsed_href.fragment:
            if announcement_target.suffix.lower() != ".html":
                raise SystemExit(
                    f"announcement {identifier} fragment target is not an HTML page"
                )
            _, announcement_target_ids, _ = parse_page(announcement_target)
            if parsed_href.fragment not in announcement_target_ids:
                raise SystemExit(
                    f"announcement {identifier} has a missing fragment target: {href}"
                )
    if href.split("?", 1)[0].split("#", 1)[0] == "compatibility.html":
        raise SystemExit(
            "routine compatibility database changes must not become project notices"
        )
    for field in ("titles", "summaries"):
        values = announcement.get(field)
        if not isinstance(values, dict) or set(values) != set(locale_names):
            raise SystemExit(f"announcement {identifier} {field} must contain all eight locales")
        if not all(isinstance(value, str) and value.strip() for value in values.values()):
            raise SystemExit(f"announcement {identifier} {field} contains an empty translation")

    paragraphs = announcement.get("paragraphs")
    if paragraphs is not None:
        expected_detail_href = f"updates.html#update-{identifier}"
        if href != expected_detail_href:
            raise SystemExit(
                f"announcement {identifier} with full text must link to "
                f"its internal detail card: {expected_detail_href}"
            )
        if not isinstance(paragraphs, dict) or set(paragraphs) != set(locale_names):
            raise SystemExit(
                f"announcement {identifier} paragraphs must contain all eight locales"
            )
        paragraph_counts = set()
        for localized_paragraphs in paragraphs.values():
            if (
                not isinstance(localized_paragraphs, list)
                or not localized_paragraphs
                or not all(
                    isinstance(paragraph, str) and paragraph.strip()
                    for paragraph in localized_paragraphs
                )
            ):
                raise SystemExit(
                    f"announcement {identifier} contains invalid localized paragraphs"
                )
            paragraph_counts.add(len(localized_paragraphs))
        if len(paragraph_counts) != 1:
            raise SystemExit(
                f"announcement {identifier} paragraph structure differs by locale"
            )

featured_announcements = [
    announcement for announcement in announcements
    if announcement.get("featured") is True
]
if len(featured_announcements) != 1:
    raise SystemExit("announcements database must contain exactly one featured homepage notice")

developer_apps_path = root / "site-data" / "developer-apps.json"
developer_apps_schema_path = root / "site-data" / "developer-apps.schema.json"
try:
    developer_apps_database = json.loads(developer_apps_path.read_text(encoding="utf-8"))
    developer_apps_schema = json.loads(developer_apps_schema_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"developer app catalog JSON is invalid: {exc}")

if developer_apps_database.get("schemaVersion") != 2:
    raise SystemExit("developer app catalog schemaVersion must be 2")
if developer_apps_schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
    raise SystemExit("developer app schema must use JSON Schema draft 2020-12")
if developer_apps_database.get("sourceRevision") != (
    "566e4f4530d489175c512e7e431a343192d510b1"
):
    raise SystemExit("developer app catalog must identify the in-app 1.1 preview source")

developer_apps = developer_apps_database.get("apps")
if not isinstance(developer_apps, list):
    raise SystemExit("developer app catalog apps must be an array")

expected_developer_app_ids = {
    "forgeplay",
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
    if identifier == "forgeplay":
        if app_store_id is not None or href != "index.html":
            raise SystemExit("ForgePlay developer catalog entry must link to the homepage")
    else:
        if not isinstance(app_store_id, str) or not app_store_id.isdigit():
            raise SystemExit(f"developer app {identifier} has an invalid App Store ID")
        if not isinstance(href, str) or not re.fullmatch(
            rf"https://apps\.apple\.com/us/app/[a-z0-9-]+/id{re.escape(app_store_id)}",
            href,
        ):
            raise SystemExit(f"developer app {identifier} has an invalid App Store URL")
    artwork = app.get("artwork")
    if not isinstance(artwork, str) or not artwork.startswith("site-assets/"):
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
if platform_counts != {"mac": 6, "ipad": 3, "iphone": 2}:
    raise SystemExit(f"developer app platform counts are invalid: {platform_counts}")

development_projects = developer_apps_database.get("inDevelopment")
if not isinstance(development_projects, list):
    raise SystemExit("developer app catalog inDevelopment must be an array")

expected_development_projects = {
    "majordex": ("MajorDex", "mac", "app"),
    "forgekit": ("ForgeKit", "mac", "app"),
    "harewatch": ("HareWatch", "mac", "utility"),
    "warrennet": ("WarrenNet", "mac", "utility"),
    "leporis-ascendant": ("Leporis Ascendant", "ipad", "game"),
    "hazel-and-peanut": ("Hazel&Peanut", "iphone", "game"),
    "grayline": ("GrayLine", "iphone", "game"),
}
expected_development_artwork_hashes = {
    "majordex": "3455a1b4ff3afe34df01db3aa6ef187bed7edd57fb670a8629be381aad17bd52",
    "forgekit": "03e6dfc77bf72e442ed85e036997ca340ec00d8e22636d7c9f7117e6b35461c9",
    "harewatch": "6f73ec849436bdeb91398ed7b1b76cd67e2cec3d4782fbfc5de475d73afd5cd0",
    "warrennet": "11ee5bf49f59cd1578644432c167b6b693cef90c910677af908dde93bb5a79d8",
    "hazel-and-peanut": "328158bc8681ee6b2d5731e914f39fe8897b57408fc7bdd6b24d764cf1837063",
    "grayline": "e711d6fc39786b8650cdadd876c4a785425c18717bde78589400c5d38d3d6f88",
    "leporis-ascendant": "a17ebfcb31b77fc57e8a53f230d62c1d8d02cf7d4600d1a873fd7704aea27215",
}
development_ids = set()
development_projection = {}
development_platform_counts = {"mac": 0, "ipad": 0, "iphone": 0}
for project in development_projects:
    identifier = project.get("id") if isinstance(project, dict) else None
    if not isinstance(identifier, str) or not identifier or identifier in development_ids:
        raise SystemExit(
            f"developer project catalog contains an invalid or duplicate id: {identifier}"
        )
    development_ids.add(identifier)
    platform = project.get("platform")
    if platform not in development_platform_counts:
        raise SystemExit(f"developer project {identifier} has an invalid platform")
    development_platform_counts[platform] += 1
    kind = project.get("kind")
    if kind not in {"app", "utility", "game"}:
        raise SystemExit(f"developer project {identifier} has an invalid kind")
    development_projection[identifier] = (project.get("name"), platform, kind)
    summaries = project.get("summaries")
    if summaries is not None:
        if not isinstance(summaries, dict) or set(summaries) != set(locale_names):
            raise SystemExit(
                f"developer project {identifier} summaries must contain all eight locales"
            )
        if not all(isinstance(value, str) and value.strip() for value in summaries.values()):
            raise SystemExit(
                f"developer project {identifier} contains an empty summary translation"
            )
    artwork = project.get("artwork")
    if not isinstance(artwork, str) or not artwork.startswith(
        "site-assets/developer-apps/"
    ):
        raise SystemExit(f"developer project {identifier} has an invalid artwork path")
    artwork_path = (root / artwork).resolve()
    try:
        artwork_path.relative_to(root_resolved)
    except ValueError:
        raise SystemExit(f"developer project {identifier} artwork escapes the project root")
    if not artwork_path.is_file() or artwork_path.is_symlink():
        raise SystemExit(f"developer project {identifier} artwork is missing or unsafe")
    artwork_hash = hashlib.sha256(artwork_path.read_bytes()).hexdigest()
    if artwork_hash != expected_development_artwork_hashes.get(identifier):
        raise SystemExit(
            f"developer project {identifier} artwork differs from the in-app asset"
        )

if development_ids != set(expected_development_projects):
    raise SystemExit("developer projects do not match the in-app 1.1 preview catalog")
if development_projection != expected_development_projects:
    raise SystemExit("developer project names, platforms, or kinds differ from the app")
if development_platform_counts != {"mac": 4, "ipad": 1, "iphone": 2}:
    raise SystemExit(
        f"developer project platform counts are invalid: {development_platform_counts}"
    )

developer_app_source_path = (
    root / "Sources" / "ForgePlay" / "Models" / "DeveloperAppCatalog.swift"
)
if developer_app_source_path.is_file() and not developer_app_source_path.is_symlink():
    source = developer_app_source_path.read_text(encoding="utf-8")
    source_blocks = [
        block
        for block in re.findall(
            r"DeveloperAppListing\((.*?)\n        \)(?:,|\n    \])",
            source,
            flags=re.DOTALL,
        )
        if re.search(r'appStoreID: "[0-9]+"', block)
    ]
    app_store_apps = [app for app in developer_apps if app.get("appStoreID")]
    if len(source_blocks) != len(app_store_apps):
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

    website_apps = {app["appStoreID"]: app for app in app_store_apps}
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
  require_snippet "$ROOT_DIR/$html" 'src="locale-bootstrap.js?v=20260729-14"'
  if [[ "$html" == "compatibility.html" ]]; then
    require_snippet "$ROOT_DIR/$html" 'href="site.css?v=20260811-22"'
    require_snippet "$ROOT_DIR/$html" 'src="site.js?v=20260811-22"'
  elif [[ "$html" == "updates.html" ]]; then
    require_snippet "$ROOT_DIR/$html" 'href="site.css?v=20260821-1"'
    require_snippet "$ROOT_DIR/$html" 'src="site.js?v=20260801-17"'
  elif [[ "$html" == "index.html" ]]; then
    require_snippet "$ROOT_DIR/$html" 'href="site.css?v=20260821-2"'
    require_snippet "$ROOT_DIR/$html" 'src="site.js?v=20260821-3"'
  else
    require_snippet "$ROOT_DIR/$html" 'href="site.css?v=20260729-14"'
    require_snippet "$ROOT_DIR/$html" 'src="site.js?v=20260729-14"'
  fi
  require_snippet "$ROOT_DIR/$html" 'data-language-select'
  require_snippet "$ROOT_DIR/$html" 'site-assets/forgeplay-icon.png?v=20260821-dark-1'
  require_snippet "$ROOT_DIR/$html" 'target="_blank" rel="noopener noreferrer"'
  require_snippet "$ROOT_DIR/$html" 'href="https://github.com/Facta-Leopard/ForgePlay/releases/latest"'
  require_snippet "$ROOT_DIR/$html" 'href="https://github.com/Facta-Leopard/ForgePlay/tree/main"'
  require_snippet "$ROOT_DIR/$html" 'data-i18n="shared.navSource"'
  if grep -Fq 'gall.dcinside.com' "$ROOT_DIR/$html" || \
     grep -Fq 'data-i18n="shared.navCommunity"' "$ROOT_DIR/$html"; then
    fail "$html must not contain the retired DCInside navigation link"
  fi
done

require_snippet "$ROOT_DIR/index.html" 'id="game-mode"'
require_snippet "$ROOT_DIR/index.html" 'id="difference"'
require_snippet "$ROOT_DIR/index.html" 'id="release"'
require_snippet "$ROOT_DIR/index.html" 'CPU + GPU'
require_snippet "$ROOT_DIR/index.html" 'Bluetooth sampling rate'
require_snippet "$ROOT_DIR/index.html" 'href="https://support.apple.com/105118"'
require_snippet "$ROOT_DIR/index.html" 'macOS 26+ · Rosetta required'
require_snippet "$ROOT_DIR/index.html" 'The published source includes ForgePlay, the Game Mode host, Wine patches, build records, and license notices.'
require_snippet "$ROOT_DIR/index.html" 'data-i18n="home.sourceLink">Browse the published source ↗'
require_snippet "$ROOT_DIR/index.html" 'href="why.html"'
require_snippet "$ROOT_DIR/index.html" 'href="license.html"'
require_snippet "$ROOT_DIR/index.html" 'CURRENT STABLE RELEASE'
require_snippet "$ROOT_DIR/index.html" 'data-current-release-status-summary'
require_snippet "$ROOT_DIR/index.html" 'data-current-release-label'
require_snippet "$ROOT_DIR/index.html" 'data-current-release-status'
require_snippet "$ROOT_DIR/index.html" 'data-current-release-download'
require_snippet "$ROOT_DIR/index.html" 'data-current-release-download-label'
require_snippet "$ROOT_DIR/index.html" 'data-current-release-link'
require_snippet "$ROOT_DIR/index.html" 'src="site-assets/current-release.js?v=20260811-22"'
require_snippet "$ROOT_DIR/index.html" 'data-release-download'
require_snippet "$ROOT_DIR/index.html" 'data-i18n="home.releaseNotesButton"'
require_snippet "$ROOT_DIR/index.html" 'site-assets/forgeplay-social.png'
require_snippet "$ROOT_DIR/index.html" 'site-assets/forgeplay-manifesto.jpg'
require_snippet "$ROOT_DIR/index.html" 'site-assets/forgeplay-hero-3200.jpg 3200w'
require_snippet "$ROOT_DIR/index.html" 'site-assets/forgeplay-manifesto-3200.jpg 3200w'
require_snippet "$ROOT_DIR/index.html" 'data-compatibility-count'
require_snippet "$ROOT_DIR/index.html" 'href="compatibility.html"'
require_snippet "$ROOT_DIR/index.html" 'PLAYABLE IN GAME MODE'
require_snippet "$ROOT_DIR/index.html" '<strong data-compatibility-count aria-live="polite">—</strong>'
require_snippet "$ROOT_DIR/index.html" 'href="https://github.com/sponsors/facta-leopard"'
require_snippet "$ROOT_DIR/index.html" 'src="compatibility.js?v=20260802-21"'
require_snippet "$ROOT_DIR/index.html" 'src="announcements.js?v=20260821-1"'
require_snippet "$ROOT_DIR/index.html" 'src="developer-apps.js?v=20260821-3"'
require_snippet "$ROOT_DIR/index.html" 'data-latest-announcement'
require_snippet "$ROOT_DIR/index.html" 'id="other-apps"'
require_snippet "$ROOT_DIR/index.html" 'data-developer-app-grid'
require_snippet "$ROOT_DIR/index.html" 'data-developer-view="development"'
require_snippet "$ROOT_DIR/index.html" 'class="release-evidence-copy"'
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
require_snippet "$ROOT_DIR/compatibility.html" '<strong data-compatibility-count aria-live="polite">—</strong>'
require_snippet "$ROOT_DIR/compatibility.html" 'href="site.css?v=20260811-22"'
require_snippet "$ROOT_DIR/compatibility.html" 'src="site.js?v=20260811-22"'
require_snippet "$ROOT_DIR/compatibility.html" 'src="site-assets/current-release.js?v=20260811-22"'
require_snippet "$ROOT_DIR/compatibility.html" 'src="compatibility.js?v=20260802-21"'
require_snippet "$ROOT_DIR/compatibility.html" 'data-current-release-card'
require_snippet "$ROOT_DIR/compatibility.html" 'data-current-release-tag'
require_snippet "$ROOT_DIR/compatibility.html" 'data-current-release-meta'
require_snippet "$ROOT_DIR/compatibility.html" 'data-i18n="compat.currentReleaseLabel"'
require_snippet "$ROOT_DIR/compatibility.html" 'data-i18n="compat.currentReleaseLoading"'
require_snippet "$ROOT_DIR/compatibility.html" 'data-i18n="compat.currentReleaseLink"'
require_snippet "$ROOT_DIR/compatibility.html" 'data-i18n="compat.columnTestedForgePlayVersions"'
require_snippet "$ROOT_DIR/compatibility.html" 'data-i18n="compat.columnMacOSVersion"'
require_snippet "$ROOT_DIR/compatibility.html" 'data-i18n="compat.columnRecords"'
require_snippet "$ROOT_DIR/compatibility.js" 'site-data/compatibility-games.json'
require_snippet "$ROOT_DIR/compatibility.js" 'forgeplay:localechange'
require_snippet "$ROOT_DIR/compatibility.js" 'const cacheBustedDataURL = (path) =>'
require_snippet "$ROOT_DIR/compatibility.js" 'url.searchParams.set("refresh", Date.now().toString())'
require_snippet "$ROOT_DIR/compatibility.js" 'cache: "no-store"'
require_snippet "$ROOT_DIR/compatibility.js" 'const playableGameIds = new Set('
require_snippet "$ROOT_DIR/compatibility.js" 'element.textContent = String(playableGameIds.size)'
require_snippet "$ROOT_DIR/compatibility.js" '"github-issue": "compat.verificationGitHubIssue"'
require_snippet "$ROOT_DIR/compatibility.js" '"community-report": "compat.verificationCommunityReport"'
require_snippet "$ROOT_DIR/compatibility.js" '"security-module": "compat.blockerSecurityModule"'
require_snippet "$ROOT_DIR/compatibility.js" 'Number.isInteger(profile.unifiedMemoryGB)'
require_snippet "$ROOT_DIR/compatibility.js" 'const formatMacOSVersion = (profile) => ('
require_snippet "$ROOT_DIR/compatibility.js" 'profile.macOSVersion.trim()'
require_snippet "$ROOT_DIR/compatibility.js" 'report.reporter ? "@" + report.reporter : null'
require_snippet "$ROOT_DIR/compatibility.js" 'const localizedNote = localizedText(report.notes, selectedLocale)'
require_snippet "$ROOT_DIR/compatibility.js" 'const aggregateStatus = (records) => ('
require_snippet "$ROOT_DIR/compatibility.js" 'records.some(({ report }) => report.status === status)'
require_snippet "$ROOT_DIR/compatibility.js" 'report.status === "playable"'
require_snippet "$ROOT_DIR/compatibility.js" 'report.forgePlayVersion'
require_snippet "$ROOT_DIR/compatibility.js" 'development: "compat.versionDevelopment"'
require_snippet "$ROOT_DIR/compatibility.js" 'message(versionMessageKey, "Development build")'
require_snippet "$ROOT_DIR/compatibility.js" 'report.gameVersion'
require_snippet "$ROOT_DIR/compatibility.js" 'const appendVersionBadges = (cell, records, resolveVersion) => {'
require_snippet "$ROOT_DIR/compatibility.js" 'const headlineRecords = playableRecords.length'
require_snippet "$ROOT_DIR/compatibility.js" '({ profile }) => formatMacOSVersion(profile)'
require_snippet "$ROOT_DIR/compatibility.js" 'compatibility-blocked-button'
require_snippet "$ROOT_DIR/compatibility.js" 'updatePanelState("blocked")'
require_snippet "$ROOT_DIR/site-assets/current-release.js" 'site-data/current-release.json'
require_snippet "$ROOT_DIR/site-assets/current-release.js" 'const cacheBustedDataURL = (path) =>'
require_snippet "$ROOT_DIR/site-assets/current-release.js" 'url.searchParams.set("refresh", Date.now().toString())'
require_snippet "$ROOT_DIR/site-assets/current-release.js" 'cache: "no-store"'
require_snippet "$ROOT_DIR/site-assets/current-release.js" 'const validateManifest = (candidate) =>'
require_snippet "$ROOT_DIR/site-assets/current-release.js" 'candidate.buildNumber'
require_snippet "$ROOT_DIR/site-assets/current-release.js" 'const trustedHost = "github.com"'
require_snippet "$ROOT_DIR/site-assets/current-release.js" 'data-current-release-status-summary'
require_snippet "$ROOT_DIR/site-assets/current-release.js" 'data-current-release-download'
require_snippet "$ROOT_DIR/site-assets/current-release.js" 'forgeplay:localechange'
require_snippet "$ROOT_DIR/site-assets/current-release.js" 'element.textContent = value'
if grep -Eq 'innerHTML|outerHTML|insertAdjacentHTML|document\.write' \
  "$ROOT_DIR/site-assets/current-release.js"; then
  fail "current-release.js must render release data without unsafe HTML insertion"
fi
require_snippet "$ROOT_DIR/site.js" '"compat.statusPlayable": "게임 모드로 플레이 가능"'
require_snippet "$ROOT_DIR/site.js" '"compat.columnTestedForgePlayVersions": "확인한 ForgePlay 버전"'
require_snippet "$ROOT_DIR/site.js" '"compat.columnMacOSVersion": "macOS 버전"'
require_snippet "$ROOT_DIR/site.js" '"compat.columnForgePlayVersion": "ForgePlay 버전"'
require_snippet "$ROOT_DIR/site.js" '"compat.columnGameVersion": "게임 버전"'
require_snippet "$ROOT_DIR/site.js" '"compat.versionNotReported": "버전 미기재"'
require_snippet "$ROOT_DIR/site.js" '"compat.versionDevelopment": "개발 빌드"'
require_snippet "$ROOT_DIR/site.js" '"compat.blockedRecords": "플레이 불가 기록 {count}건"'
require_snippet "$ROOT_DIR/site.js" '"compat.verificationGitHubIssue": "GitHub 이슈 제보"'
require_snippet "$ROOT_DIR/site.js" '"compat.verificationCommunityReport": "커뮤니티 제보"'
require_snippet "$ROOT_DIR/site.js" '"compat.deviceNotReported": "기기 정보 없음"'
require_snippet "$ROOT_DIR/site.js" '"compat.blockerSecurityModule": "보안 모듈로 인해 실행이 제한됩니다."'
require_snippet "$ROOT_DIR/site.css" '.compatibility-macos-version-cell {'
require_snippet "$ROOT_DIR/site.css" 'grid-row: 1 / 7;'
require_snippet "$ROOT_DIR/site.css" '.compatibility-release-summary strong {'
require_snippet "$ROOT_DIR/site.css" '.compatibility-release-summary[data-release-state="error"] strong {'
require_snippet "$ROOT_DIR/site-data/README.md" 'Current stable release manifest'
require_snippet "$ROOT_DIR/site-data/README.md" '`current-release.json`'
require_snippet "$ROOT_DIR/site-data/README.md" 'monotonically increasing integer `buildNumber`'
require_snippet "$ROOT_DIR/site-data/README.md" '`docs/update-check-contract.md`'
require_snippet "$ROOT_DIR/site-data/README.md" 'Excel / spreadsheet import contract'
require_snippet "$ROOT_DIR/site-data/README.md" 'Compatibility-only update workflow'
require_snippet "$ROOT_DIR/site-data/README.md" 'Edit only `compatibility-games.json`'
require_snippet "$ROOT_DIR/site-data/README.md" '`reporter`'
require_snippet "$ROOT_DIR/site-data/README.md" '`forgeplay_version`'
require_snippet "$ROOT_DIR/site-data/README.md" 'use `development` for an unreleased development build'
require_snippet "$ROOT_DIR/site-data/README.md" '`game_version`'
require_snippet "$ROOT_DIR/site-data/README.md" 'Developer app catalog'
require_snippet "$ROOT_DIR/site-data/README.md" 'DeveloperAppCatalog.swift'
require_snippet "$ROOT_DIR/site-data/README.md" 'Why ForgePlay exists — full text'
require_snippet "$ROOT_DIR/site-data/README.md" 'raw Markdown is never inserted into the page'
require_snippet "$ROOT_DIR/site-data/README.md" 'Routine compatibility database additions and result changes must not create'
require_snippet "$ROOT_DIR/site-data/README.md" 'No raw HTML or Markdown is rendered.'
require_snippet "$ROOT_DIR/updates.html" 'data-announcement-list'
require_snippet "$ROOT_DIR/updates.html" 'data-nav-page="updates"'
require_snippet "$ROOT_DIR/updates.html" 'src="announcements.js?v=20260821-1"'
require_snippet "$ROOT_DIR/updates.html" 'Releases, project notices, and development updates in one place.'
require_snippet "$ROOT_DIR/announcements.js" 'site-data/announcements.json'
require_snippet "$ROOT_DIR/announcements.js" 'forgeplay:localechange'
require_snippet "$ROOT_DIR/announcements.js" 'applyLinkDestination'
require_snippet "$ROOT_DIR/announcements.js" 'const cacheBustedDataURL = (path) =>'
require_snippet "$ROOT_DIR/announcements.js" 'url.searchParams.set("refresh", Date.now().toString())'
require_snippet "$ROOT_DIR/announcements.js" 'const localizedParagraphs = (value, selectedLocale) =>'
require_snippet "$ROOT_DIR/announcements.js" 'const announcementAnchorId = (identifier) => `update-${identifier}`'
require_snippet "$ROOT_DIR/announcements.js" 'article.id = announcementAnchorId(announcement.id)'
require_snippet "$ROOT_DIR/announcements.js" 'announcement.href !== announcementDetailHref(announcement.id)'
require_snippet "$ROOT_DIR/announcements.js" 'requestedCard.scrollIntoView({ block: "center" })'
require_snippet "$ROOT_DIR/announcements.js" 'body.className = "update-card-body"'
require_snippet "$ROOT_DIR/announcements.js" 'const bulletLinePattern = /^(\s*)-\s+(.+)$/'
require_snippet "$ROOT_DIR/announcements.js" 'const appendStructuredParagraph = (parent, paragraph) =>'
require_snippet "$ROOT_DIR/announcements.js" 'cache: "no-store"'
require_snippet "$ROOT_DIR/site.css" '.update-card-body {'
require_snippet "$ROOT_DIR/site.css" 'gap: 20px;'
require_snippet "$ROOT_DIR/site.css" '.update-card-section-title {'
require_snippet "$ROOT_DIR/site.css" '.update-card-list {'
if grep -Eq 'innerHTML|outerHTML|insertAdjacentHTML|document\.write' \
  "$ROOT_DIR/announcements.js"; then
  fail "announcements.js must render notices without unsafe HTML insertion"
fi
require_snippet "$ROOT_DIR/developer-apps.js" 'site-data/developer-apps.json'
require_snippet "$ROOT_DIR/developer-apps.js" 'data-developer-platform'
require_snippet "$ROOT_DIR/developer-apps.js" 'data-developer-view'
require_snippet "$ROOT_DIR/developer-apps.js" 'database.inDevelopment'
require_snippet "$ROOT_DIR/developer-apps.js" 'cache: "no-store"'
require_snippet "$ROOT_DIR/developer-apps.js" 'forgeplay:localechange'
if grep -Eq 'innerHTML|outerHTML|insertAdjacentHTML|document\.write' \
  "$ROOT_DIR/developer-apps.js"; then
  fail "developer-apps.js must render the catalog without unsafe HTML insertion"
fi

require_snippet "$ROOT_DIR/why.html" 'Why I Built ForgePlay'
require_snippet "$ROOT_DIR/why.html" 'site-assets/forgeplay-manifesto-3200.jpg 3200w'
require_snippet "$ROOT_DIR/why.html" 'iron rice bowl'
require_snippet "$ROOT_DIR/why.html" 'CodeWeavers’ long contribution to Wine deserves recognition'
require_snippet "$ROOT_DIR/why.html" 'If progress stalled because no one could challenge it'
require_snippet "$ROOT_DIR/why.html" '경쟁이 없어서 멈췄다면, 경쟁자를 만들어 주겠다!'
require_snippet "$ROOT_DIR/why.html" 'game engines and graphics—including the DirectX and Metal stacks'
require_snippet "$ROOT_DIR/why.html" '게임 엔진과 그래픽스, DirectX와 Metal 기술 스택'
require_snippet "$ROOT_DIR/why.html" 'href="https://github.com/Facta-Leopard/ForgePlay/tree/main"'
require_snippet "$ROOT_DIR/why.html" '공개 소스 보기 ↗'
require_snippet "$ROOT_DIR/why.html" 'href="site-assets/why-story.css?v=20260730-2"'
require_snippet "$ROOT_DIR/why.html" 'src="site-assets/why-story.js?v=20260730-1"'
require_snippet "$ROOT_DIR/why.html" 'id="full-story"'
require_snippet "$ROOT_DIR/why.html" 'data-why-story'
require_snippet "$ROOT_DIR/why.html" 'data-why-story-toc'
require_snippet "$ROOT_DIR/why.html" 'data-why-story-content'
require_snippet "$ROOT_DIR/why.html" 'Why ForgePlay Exists — Full Text'
require_snippet "$ROOT_DIR/site-assets/why-story.js" 'const storyDataRoot = "site-data/why-story"'
require_snippet "$ROOT_DIR/site-assets/why-story.js" 'document.createTextNode'
require_snippet "$ROOT_DIR/site-assets/why-story.js" 'content.replaceChildren'
require_snippet "$ROOT_DIR/site-assets/why-story.js" 'cache: "no-store"'
require_snippet "$ROOT_DIR/site-assets/why-story.js" 'forgeplay:localechange'
require_snippet "$ROOT_DIR/site-assets/why-story.js" '"zh-Hans"'
require_snippet "$ROOT_DIR/site-assets/why-story.js" '"zh-Hant"'
if grep -Eq 'innerHTML|outerHTML|insertAdjacentHTML|document\\.write' "$ROOT_DIR/site-assets/why-story.js"; then
  fail "why-story.js must render the statement without unsafe HTML insertion"
fi

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
require_snippet "$ROOT_DIR/site-data/announcements.json" '"id": "next-forgeplay-update-underway"'
require_snippet "$ROOT_DIR/site-data/announcements.json" '"ko": "다음 ForgePlay 업데이트를 준비하고 있습니다."'
require_snippet "$ROOT_DIR/site-data/announcements.json" '"id": "forgeplay-1-1-released"'
require_snippet "$ROOT_DIR/site-data/announcements.json" '"ko": "ForgePlay 1.1 업데이트 출시!"'
require_snippet "$ROOT_DIR/site-data/announcements.json" 'DirectX12 적용이 되지 않던 문제 수정'
require_snippet "$ROOT_DIR/site-data/announcements.json" 'Wine 11.12'
require_snippet "$ROOT_DIR/site-data/announcements.json" 'Game Porting Toolkit(GPTK) 4.0 beta'
require_snippet "$ROOT_DIR/site-data/announcements.json" 'GitHub Sponsors'
require_snippet "$ROOT_DIR/site-data/announcements.json" '"id": "forgeplay-1-0-released"'
require_snippet "$ROOT_DIR/site-data/announcements.json" '"ko": "ForgePlay 1.0을 공개했습니다."'
require_snippet "$ROOT_DIR/site-data/announcements.json" '"href": "https://github.com/Facta-Leopard/ForgePlay/releases/tag/v1.0.0"'

if grep -Fq 'home.releaseTitle' "$ROOT_DIR/index.html" "$ROOT_DIR/site.js"; then
  fail "the removed homepage release title must not remain"
fi

if grep -Fq '"id": "compatibility-database-opens"' \
  "$ROOT_DIR/site-data/announcements.json"; then
  fail "routine compatibility database updates must not appear in project notices"
fi

if grep -Fq 'updates.typeCompatibility' \
  "$ROOT_DIR/site.js" "$ROOT_DIR/announcements.js"; then
  fail "the retired compatibility notice category must not remain in the site"
fi

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
require_snippet "$ROOT_DIR/site.css" ".developer-view-tabs"
require_snippet "$ROOT_DIR/site.css" ".developer-project-card"
require_snippet "$ROOT_DIR/site.css" ".release-evidence-copy"
require_snippet "$ROOT_DIR/site.css" ".release-actions"
require_snippet "$ROOT_DIR/site.css" ".release-status.live"
require_snippet "$ROOT_DIR/site-assets/why-story.css" ".founder-note-cover"
require_snippet "$ROOT_DIR/site-assets/why-story.css" ".founder-note-paper"
require_snippet "$ROOT_DIR/site-assets/why-story.css" ".founder-note-toc"
require_snippet "$ROOT_DIR/site-assets/why-story.css" "@media (max-width: 760px)"
require_snippet "$ROOT_DIR/site-assets/why-story.css" "@media (prefers-reduced-motion: reduce)"
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
require_snippet "$ROOT_DIR/site.js" '"shared.navSource": "소스 코드"'
require_snippet "$ROOT_DIR/site.js" '"home.releaseStatus": "지금 다운로드 가능"'
require_snippet "$ROOT_DIR/site.js" '"home.releaseStatusVersioned": "지금 다운로드 가능 · {tag}"'
require_snippet "$ROOT_DIR/site.js" '"home.releaseStatus": "AVAILABLE NOW"'
require_snippet "$ROOT_DIR/site.js" '"home.releaseStatusVersioned": "AVAILABLE NOW · {tag}"'
require_snippet "$ROOT_DIR/site.js" '"home.releaseButtonVersioned": "Download {product} {version}"'
require_snippet "$ROOT_DIR/site.js" '"compat.currentReleaseLabel": "현재 릴리스"'
require_snippet "$ROOT_DIR/site.js" '"compat.currentReleaseUnavailable": "릴리스 정보를 일시적으로 불러올 수 없습니다."'

if grep -Fq 'shared.navCommunity' "$ROOT_DIR/site.js"; then
  fail "site.js must not contain the retired DCInside navigation localization"
fi

if grep -Fq 'community-link' "$ROOT_DIR/site.css"; then
  fail "site.css must not contain retired DCInside navigation styles"
fi

if grep -Fq '"compat.verificationCommunity":' "$ROOT_DIR/site.js"; then
  fail "site.js must not use the retired ambiguous community verification key"
fi

if grep -Fq 'releases/download/v1.0.0' \
  "$ROOT_DIR/index.html" "$ROOT_DIR/compatibility.html" "$ROOT_DIR/site.js"; then
  fail "active release UI must obtain the versioned download from current-release.json"
fi

for script in \
  locale-bootstrap.js \
  site.js \
  site-assets/current-release.js \
  compatibility.js \
  announcements.js \
  developer-apps.js \
  site-assets/why-story.js; do
  node --check "$ROOT_DIR/$script" >/dev/null || fail "$script has invalid JavaScript syntax"
done

if [[ -e "$ROOT_DIR/.git" ]]; then
  require_regular_file "$ROOT_DIR/docs/update-check-contract.md"
  require_regular_file "$ROOT_DIR/docs/compatibility-catalog-consumer-contract.md"
  require_snippet "$ROOT_DIR/docs/update-check-contract.md" 'https://facta-leopard.github.io/ForgePlay/site-data/current-release.json'
  require_snippet "$ROOT_DIR/docs/update-check-contract.md" '`CFBundleVersion`'
  require_snippet "$ROOT_DIR/docs/update-check-contract.md" '`buildNumber`'
  require_snippet "$ROOT_DIR/docs/update-check-contract.md" '업데이트 확인 실패'
  require_snippet "$ROOT_DIR/docs/update-check-contract.md" 'Developer ID 서명, Apple 공증'
  require_snippet "$ROOT_DIR/docs/update-check-contract.md" '`releases/latest`'
  require_snippet "$ROOT_DIR/docs/update-check-contract.md" '`compatibility-games.json`'
  require_snippet "$ROOT_DIR/docs/compatibility-catalog-consumer-contract.md" 'https://facta-leopard.github.io/ForgePlay/site-data/compatibility-games.json'
  require_snippet "$ROOT_DIR/docs/compatibility-catalog-consumer-contract.md" '`site-data/current-release.json`'
  require_snippet "$ROOT_DIR/docs/compatibility-catalog-consumer-contract.md" '`updatedAt`과 검증된 JSON payload의 SHA-256'
  require_snippet "$ROOT_DIR/docs/compatibility-catalog-consumer-contract.md" '같은 `updatedAt`, 다른 payload'
  require_snippet "$ROOT_DIR/docs/compatibility-catalog-consumer-contract.md" '`catalogRevision`'
  require_snippet "$ROOT_DIR/docs/compatibility-catalog-consumer-contract.md" '기존 캐시 보존'
  require_regular_file "$ROOT_DIR/.github/ISSUE_TEMPLATE/compatibility-report.yml"
  require_regular_file "$ROOT_DIR/.github/FUNDING.yml"
  require_snippet "$ROOT_DIR/.github/ISSUE_TEMPLATE/compatibility-report.yml" 'name: Compatibility report'
  require_snippet "$ROOT_DIR/.github/ISSUE_TEMPLATE/compatibility-report.yml" 'label: Reviewed diagnostics'
  require_snippet "$ROOT_DIR/.github/ISSUE_TEMPLATE/compatibility-report.yml" 'id: forgeplay_version'
  require_snippet "$ROOT_DIR/.github/ISSUE_TEMPLATE/compatibility-report.yml" 'id: game_version'
  require_snippet "$ROOT_DIR/.github/ISSUE_TEMPLATE/compatibility-report.yml" 'This field is optional.'
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

for retired_release_phrase in \
  "within days" \
  "PLANNED WITHIN DAYS" \
  "NO PUBLIC DOWNLOAD YET" \
  "며칠 내" \
  "다운로드할 수 없습니다" \
  "数日以内" \
  "数日内" \
  "in wenigen Tagen" \
  "unos días" \
  "quelques jours"; do
  if grep -Fiq "$retired_release_phrase" \
    "$ROOT_DIR/index.html" "$ROOT_DIR/site.js" \
    "$ROOT_DIR/site-data/announcements.json"; then
    fail "public site contains retired pre-release wording: $retired_release_phrase"
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
