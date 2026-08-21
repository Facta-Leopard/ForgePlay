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

EXPECTED_DOCUMENTS='LICENSE.md|98a715c6d8e51d4d67eb440381da947676ca3e5dfbca67f4c20a1e8b5d41be51
LICENSES/GPL-3.0-only.txt|3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986
LICENSES/LGPL-2.1-or-later.txt|e237fa56668030e928551ddd60f05df5fe957f75eab874bbd017e085ed722e7c
LICENSES/ForgePlayWine/FORGEPLAY-MODIFICATIONS.md|613ab79178fece6ea534589d64c1e9716b7a8a5c8730eebb4ea067fdd46ff081
LICENSES/ForgePlayGameMode/README.md|821358e7ecd15a3edd532fd42395e408870b271fa3d3da84325ff77ae0297432
LICENSES/ForgePlayGameMode/DECISION_KO.md|16a1667815c52400e3c5b731139b3d5186aa3796b3766e8843af76ff775b1eff
LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE.md|101053621d46dc820a0828d6fe427c2527d7bdb451fdf2603e3ca8ad2cc19505
LICENSES/ForgePlayGameMode/GAME_MODE_LICENSE_SCOPE_KO.md|2652189282124fb7bae9f7d12c990eadddc34765b59ced7f8cc5a05019d69906
LICENSES/ForgePlayGameMode/GAME_MODE_FILE_LICENSES.json|f79fe0987ed7cc4cd468a9c3e5d4da6ca9b20995a4b74c0293db1491fd70f12a
LICENSES/ForgePlayGameMode/GAME_MODE_SYMBOL_MANIFEST.md|f7edfaf2de8c6d436e3b6a21b7f91708f4802135b2235588a3504b946ab3a663
LICENSES/ForgePlayGameMode/GAME_MODE_NOTICE|3118c3c5754940d07309c44e7c4757a78869f720d3acf0c43a6efb8d2f5e0228
LICENSES/ForgePlayGameMode/GPL_COMPARISON_KO.md|4f84e1f1abc56c1c63079ad80cd8daec8c29640d83b5ab8fca019006c1791039'

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
grep -Fq 'https://github.com/Facta-Leopard/ForgePlay' \
  "$POLICY_ROOT/GAME_MODE_NOTICE" ||
  fail "Game Mode notice must identify the canonical repository"
grep -Fq 'direct-DMG release contract intentionally includes D3DMetal' \
  "$POLICY_ROOT/GAME_MODE_LICENSE_SCOPE.md" ||
  fail "Game Mode scope must retain the D3DMetal direct-DMG contract"
grep -Fq 'not relicensed under `GPL-3.0-only`' \
  "$POLICY_ROOT/GAME_MODE_LICENSE_SCOPE.md" ||
  fail "Game Mode scope must keep D3DMetal outside the GPL source scope"
grep -Fq '11af77aa6a1ce172505faa641c9ef5783ad10878ed552e0b55ab234a6dac1a07' \
  "$WINE_MODIFICATIONS_POLICY" ||
  fail "Wine modifications notice must identify the exact patch set"
grep -Fq '2d0c24a9f9ebdb84b7703204d1a72071b06ac48800e2314a9635f851200a1f66' \
  "$WINE_MODIFICATIONS_POLICY" ||
  fail "Wine modifications notice must identify the exact source tree"
for game_mode_patch in \
  wine-11.12-game-mode-process-host-routing.patch \
  wine-11.12-game-mode-direct-target-scope.patch; do
  grep -Fq "$game_mode_patch" "$WINE_MODIFICATIONS_POLICY" ||
    fail "Wine modifications notice must identify the GPL-converted Game Mode patches"
done

printf 'Bundled ForgePlay license documents verified: %s\n' "$DOCUMENT_ROOT"
