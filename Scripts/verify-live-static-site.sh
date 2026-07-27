#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATIC_SITE_VERIFIER="$ROOT_DIR/Scripts/verify-static-site.sh"
BASE_URL="${FORGEPLAY_PAGES_BASE_URL:-https://facta-leopard.github.io/ForgePlay}"
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
DOWNLOAD_ROOT=""

fail() {
  printf 'error: invalid live static site: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$DOWNLOAD_ROOT" && -d "$DOWNLOAD_ROOT" ]]; then
    rm -rf "$DOWNLOAD_ROOT"
  fi
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_command curl
[[ -f "$STATIC_SITE_VERIFIER" && ! -L "$STATIC_SITE_VERIFIER" ]] ||
  fail "static site verifier must be a non-symlink regular file: $STATIC_SITE_VERIFIER"

BASE_URL="$(python3 - "$BASE_URL" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit

raw = sys.argv[1].strip()
parsed = urlsplit(raw)
if parsed.scheme != "https":
    raise SystemExit("base URL must use https")
if not parsed.netloc:
    raise SystemExit("base URL must include a host")
if parsed.username or parsed.password:
    raise SystemExit("base URL must not include credentials")
if parsed.query or parsed.fragment:
    raise SystemExit("base URL must not include query or fragment")
path = parsed.path.rstrip("/")
print(urlunsplit((parsed.scheme, parsed.netloc, path, "", "")))
PY
)" || fail "FORGEPLAY_PAGES_BASE_URL is invalid"

DOWNLOAD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/forgeplay-live-site.XXXXXX")" ||
  fail "download directory could not be created"

curl_file() {
  local url="$1"
  local target="$2"
  curl --fail --silent --show-error --location \
    --connect-timeout 10 \
    --max-time 30 \
    --retry 2 \
    --retry-delay 1 \
    --output "$target" \
    "$url"
}

curl_file "$BASE_URL/" "$DOWNLOAD_ROOT/index.html"
for page in "${PAGES[@]}"; do
  [[ "$page" != "index.html" ]] || continue
  mkdir -p "$(dirname "$DOWNLOAD_ROOT/$page")"
  curl_file "$BASE_URL/$page" "$DOWNLOAD_ROOT/$page"
done

bash "$STATIC_SITE_VERIFIER" "$DOWNLOAD_ROOT" >/dev/null
printf 'Live static site verification passed: %s\n' "$BASE_URL"
