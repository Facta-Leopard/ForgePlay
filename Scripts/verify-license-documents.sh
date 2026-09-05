#!/usr/bin/env bash
set -euo pipefail

INPUT_PATH="${1:-}"

fail() {
  printf 'error: invalid bundled license documents: %s\n' "$*" >&2
  exit 1
}

[[ -n "$INPUT_PATH" ]] ||
  fail "usage: verify-license-documents.sh <project root | app bundle>"
[[ -d "$INPUT_PATH" && ! -L "$INPUT_PATH" ]] ||
  fail "input must be a non-symlink directory: $INPUT_PATH"

if [[ "$INPUT_PATH" == *.app ]]; then
  DOCUMENT_ROOT="$INPUT_PATH/Contents/Resources"
else
  DOCUMENT_ROOT="$INPUT_PATH"
fi

LICENSE_MANIFEST="$DOCUMENT_ROOT/LICENSE.md"
LICENSE_TREE="$DOCUMENT_ROOT/LICENSES"

[[ -d "$DOCUMENT_ROOT" && ! -L "$DOCUMENT_ROOT" ]] ||
  fail "document root must be a non-symlink directory: $DOCUMENT_ROOT"
[[ -d "$LICENSE_TREE" && ! -L "$LICENSE_TREE" ]] ||
  fail "LICENSES must be a non-symlink directory: $LICENSE_TREE"

EXPECTED_DOCUMENTS='LICENSE.md|42bd16191e065f37b84e60876368305485796566f9978fc52275fc74db68f246
LICENSES/GPL-3.0-only.txt|3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986
LICENSES/LGPL-2.1-or-later.txt|e237fa56668030e928551ddd60f05df5fe957f75eab874bbd017e085ed722e7c
LICENSES/ForgePlayWine/FORGEPLAY-MODIFICATIONS.md|7bc6195b962110ba65eba9a9e72aef96e195d2fe1d4fd1c7fce38d2f070faccd
LICENSES/ForgePlayGameMode/README.md|821358e7ecd15a3edd532fd42395e408870b271fa3d3da84325ff77ae0297432
LICENSES/ForgePlayGameMode/DECISION_KO.md|16a1667815c52400e3c5b731139b3d5186aa3796b3766e8843af76ff775b1eff
LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md|101053621d46dc820a0828d6fe427c2527d7bdb451fdf2603e3ca8ad2cc19505
LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE_KO.md|2652189282124fb7bae9f7d12c990eadddc34765b59ced7f8cc5a05019d69906
LICENSES/ForgePlayGameMode/GAME_MODE_FILE_LICENSES.json|f79fe0987ed7cc4cd468a9c3e5d4da6ca9b20995a4b74c0293db1491fd70f12a
LICENSES/ForgePlayGameMode/GAME_MODE_SYMBOL_MANIFEST.md|f7edfaf2de8c6d436e3b6a21b7f91708f4802135b2235588a3504b946ab3a663
LICENSES/ForgePlayGameMode/GAME_MODE_NOTICE|3118c3c5754940d07309c44e7c4757a78869f720d3acf0c43a6efb8d2f5e0228
LICENSES/ForgePlayGameMode/GPL_COMPARISON_KO.md|4f84e1f1abc56c1c63079ad80cd8daec8c29640d83b5ab8fca019006c1791039
LICENSES/ForgePlayFrameGeneration/FRAME_GENERATION_FILE_LICENSES.json|654929a141b6b8b452c0e31729f6a02c4db7a6d302de09659a04ee68d5a9629b
LICENSES/ForgePlayFrameGeneration/FRAME_GENERATION_LICENSE_SCOPE.md|df0adacd519960ccf475b057282e51a8c5174917039866e1d6b2cced31449154
LICENSES/ForgePlayFrameGeneration/FRAME_GENERATION_LICENSE_SCOPE_KO.md|b11887425d90e06c46be2f29755c905a1473d467e0e43545a7e0eff9524cf0bb
LICENSES/ForgePlayFrameGeneration/FRAME_GENERATION_NOTICE|0da2d22ac489b04cb07fb4990dd34dc626ebb34502575849f675b1756faa4a6e
LICENSES/ForgePlayFrameGeneration/FRAME_GENERATION_SYMBOL_MANIFEST.md|0acc98f637d550325bfb37466e9b10cdb1be1f46c492fdd6dfce240990ce789f
LICENSES/THIRD-PARTY-SOURCE-PROVENANCE.md|50c2ebb0a54972d219914a89d4e1f23a3dcf2a8348df9c394962ece628a38e9c'

EXPECTED_PATHS="$(printf '%s\n' "$EXPECTED_DOCUMENTS" | cut -d '|' -f 1)"

verify_document() {
  local document_relative_path="$1"
  local expected_sha256="$2"
  local document_path="$DOCUMENT_ROOT/$document_relative_path"
  local link_count actual_sha256

  [[ -f "$document_path" && ! -L "$document_path" ]] ||
    fail "$document_relative_path must be a non-symlink regular file"
  link_count="$(stat -f '%l' "$document_path" 2>/dev/null)" ||
    fail "$document_relative_path link count could not be inspected"
  [[ "$link_count" == "1" ]] ||
    fail "$document_relative_path must not be hardlinked"
  actual_sha256="$(shasum -a 256 "$document_path" | awk '{print $1}')" ||
    fail "$document_relative_path SHA-256 could not be computed"
  [[ "$actual_sha256" == "$expected_sha256" ]] ||
    fail "$document_relative_path differs from the approved license document"
}

while IFS='|' read -r document_relative_path expected_sha256; do
  verify_document "$document_relative_path" "$expected_sha256"
done <<EOF
$EXPECTED_DOCUMENTS
EOF

while IFS= read -r discovered_path; do
  discovered_relative_path="${discovered_path#"$DOCUMENT_ROOT/"}"
  printf '%s\n' "$EXPECTED_PATHS" | grep -Fqx "$discovered_relative_path" ||
    fail "unexpected file in LICENSES: $discovered_relative_path"
done < <(find "$LICENSE_TREE" \( -type f -o -type l \) -print | LC_ALL=C sort)

if find "$LICENSE_TREE" -type l -print -quit | grep -q .; then
  fail "LICENSES must not contain symlinks"
fi

POLICY_ROOT="$LICENSE_TREE/ForgePlayGameMode"
WINE_MODIFICATIONS_POLICY="$LICENSE_TREE/ForgePlayWine/FORGEPLAY-MODIFICATIONS.md"
if grep -Eiq 'REVIEW DRAFT|NOT YET AN OPERATIVE|CANONICAL_REPOSITORY_URL|검토용 초안' \
  "$LICENSE_MANIFEST" "$POLICY_ROOT"/* "$WINE_MODIFICATIONS_POLICY"; then
  fail "approved license documents must not contain draft markers or placeholders"
fi

grep -Fq 'GPL-3.0-only' "$LICENSE_MANIFEST" ||
  fail "license manifest must identify GPL-3.0-only"
grep -Fq 'ForgePlay Frame Generation' "$LICENSE_MANIFEST" ||
  fail "license manifest must identify the independent Frame Generation GPL scope"
grep -Fq 'LGPL-2.1-or-later' "$LICENSE_TREE/ForgePlayFrameGeneration/FRAME_GENERATION_LICENSE_SCOPE.md" ||
  fail "Frame Generation scope must identify separate Wine glue licensing"
grep -Fq 'https://github.com/Facta-Leopard/ForgePlay' \
  "$POLICY_ROOT/GAME_MODE_NOTICE" ||
  fail "Game Mode notice must identify the canonical repository"
grep -Fq 'direct-DMG release contract intentionally includes D3DMetal' \
  "$POLICY_ROOT/GAME_MODE_LICENSE_SCOPE.md" ||
  fail "Game Mode scope must retain the D3DMetal direct-DMG contract"
grep -Fq 'not relicensed under `GPL-3.0-only`' \
  "$POLICY_ROOT/GAME_MODE_LICENSE_SCOPE.md" ||
  fail "Game Mode scope must keep D3DMetal outside the GPL source scope"
grep -Fq 'b7939311ece8dcf37d6228e239932bec9c2f81ab2663b6f15017be51ec6f2493' \
  "$WINE_MODIFICATIONS_POLICY" ||
  fail "Wine modifications notice must identify the exact patch set"
grep -Fq '5f5d93000e059d4ab388bc4ecfcd7dbdd19ada0a5da1400d28ea58f46ba95038' \
  "$WINE_MODIFICATIONS_POLICY" ||
  fail "Wine modifications notice must identify the exact source tree"
for game_mode_patch in \
  wine-11.12-game-mode-process-host-routing.patch \
  wine-11.12-game-mode-direct-target-scope.patch; do
  grep -Fq "$game_mode_patch" "$WINE_MODIFICATIONS_POLICY" ||
    fail "Wine modifications notice must identify the GPL-converted Game Mode patches"
done

printf 'Bundled ForgePlay license documents verified: %s\n' "$DOCUMENT_ROOT"
