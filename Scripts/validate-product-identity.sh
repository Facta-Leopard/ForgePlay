#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

fail() {
  printf 'error: ForgePlay product identity is unsafe: %s\n' "$*" >&2
  exit 1
}

bundle_identifier="${PRODUCT_BUNDLE_IDENTIFIER:-}"
team_identifier="${DEVELOPMENT_TEAM:-}"
application_group="${FORGEPLAY_GAME_MODE_APPLICATION_GROUP:-}"
configuration="${CONFIGURATION:-}"
code_signing_allowed="${CODE_SIGNING_ALLOWED:-YES}"

[[ -n "$bundle_identifier" ]] || fail "PRODUCT_BUNDLE_IDENTIFIER is empty."
[[ "${#bundle_identifier}" -le 255 ]] ||
  fail "PRODUCT_BUNDLE_IDENTIFIER exceeds 255 bytes."
[[ "$bundle_identifier" != .* && "$bundle_identifier" != *. &&
   "$bundle_identifier" != *..* ]] ||
  fail "PRODUCT_BUNDLE_IDENTIFIER contains an empty component: $bundle_identifier"
[[ "$bundle_identifier" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] ||
  fail "PRODUCT_BUNDLE_IDENTIFIER contains an unsupported character or boundary: $bundle_identifier"
[[ "$bundle_identifier" == *.* ]] ||
  fail "PRODUCT_BUNDLE_IDENTIFIER must contain at least two components: $bundle_identifier"

IFS='.' read -r -a identifier_components <<< "$bundle_identifier"
for component in "${identifier_components[@]}"; do
  [[ -n "$component" && "$component" != -* && "$component" != *- ]] ||
    fail "PRODUCT_BUNDLE_IDENTIFIER contains an unsafe component: $bundle_identifier"
done

last_component="${identifier_components[${#identifier_components[@]} - 1]}"
[[ "$(printf '%s' "$last_component" | /usr/bin/tr '[:upper:]' '[:lower:]')" != "app" ]] ||
  fail "the final bundle-identifier component must not be 'app'; macOS can classify its container as an application bundle: $bundle_identifier"

if [[ -n "$team_identifier" ]]; then
  [[ "$team_identifier" =~ ^[A-Z0-9]{10}$ ]] ||
    fail "DEVELOPMENT_TEAM must be a 10-character Apple team identifier."
fi

case "$configuration" in
  Release)
    if [[ "$code_signing_allowed" == "NO" ]]; then
      # Source-only and compile-only Release checks do not emit a signed
      # product. The signed archive path below still requires the exact team
      # and App Group identity.
      :
    else
      [[ -n "$team_identifier" ]] || fail "$configuration requires DEVELOPMENT_TEAM."
      expected_application_group="$team_identifier.$bundle_identifier"
      [[ "$application_group" == "$expected_application_group" ]] ||
        fail "FORGEPLAY_GAME_MODE_APPLICATION_GROUP must be $expected_application_group, got ${application_group:-<empty>}."
    fi
    ;;
  Distribution|AppStore)
    [[ -n "$team_identifier" ]] || fail "$configuration requires DEVELOPMENT_TEAM."
    expected_application_group="$team_identifier.$bundle_identifier"
    [[ "$application_group" == "$expected_application_group" ]] ||
      fail "FORGEPLAY_GAME_MODE_APPLICATION_GROUP must be $expected_application_group, got ${application_group:-<empty>}."
    ;;
  *)
    # Debug and custom development configurations may be unsigned. If they do
    # opt into an App Group, it must still be the exact team/product identity.
    if [[ -n "$application_group" ]]; then
      [[ -n "$team_identifier" ]] ||
        fail "FORGEPLAY_GAME_MODE_APPLICATION_GROUP requires DEVELOPMENT_TEAM."
      expected_application_group="$team_identifier.$bundle_identifier"
      [[ "$application_group" == "$expected_application_group" ]] ||
        fail "FORGEPLAY_GAME_MODE_APPLICATION_GROUP must be $expected_application_group, got $application_group."
    fi
    ;;
esac

printf 'Validated ForgePlay product identity: %s\n' "$bundle_identifier"
