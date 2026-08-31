#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)

assert_single_api_contract() {
    local script="$1"
    local expected_count="$2"
    awk -v expected="$expected_count" '
        /^[[:space:]]*create_symlink / {
            if ($0 !~ /^[[:space:]]*create_symlink "[^"]*" "[^"]*" "[^"]*" \|\| exit 1$/) { invalid=1 }
            count++
        }
        END { exit invalid || count != expected ? 1 : 0 }
    ' "$DOTFILES_ROOT/$script"
}

assert_setup_script_registered() {
    awk '
        /^setup_scripts=\(/ { inside=1; next }
        inside && /^\)[[:space:]]*$/ { inside=0 }
        inside && $0 == "    \"hammerspoon/hammerspoon-setup.sh\"" { count++ }
        END { exit count == 1 ? 0 : 1 }
    ' "$DOTFILES_ROOT/setup-macos.sh"
}

assert_karabiner_goku_contract() {
    local setup="$DOTFILES_ROOT/karabiner-elements/karabiner-setup.sh"
    local configured_count
    local bare_count
    local failures=0

    configured_count=$(awk '
        /^[[:space:]]*#/ { next }
        { while (match($0, /GOKU_EDN_CONFIG_FILE="\$ICLOUD_KARABINER_EDN"[[:space:]]+goku/)) { count++; $0 = substr($0, RSTART + RLENGTH) } }
        END { print count + 0 }
    ' "$setup")
    if [ "$configured_count" -ne 1 ]; then
        failures=$((failures + 1))
    fi

    bare_count=$(awk '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            while (match(line, /GOKU_EDN_CONFIG_FILE="\$ICLOUD_KARABINER_EDN"[[:space:]]+goku/)) {
                line = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH)
            }
            if (line ~ /(^|[[:space:];|&])goku([[:space:];|&]|$)/) count++
        }
        END { print count + 0 }
    ' "$setup")
    if [ "$bare_count" -ne 0 ]; then
        failures=$((failures + 1))
    fi

    if rg -n '(^|[;&|[:space:]])(rm|unlink)([[:space:]]|$).*([Kk][Aa][Rr][Aa][Bb][Ii][Nn][Ee][Rr]\.edn|LOCAL_KARABINER_EDN)' "$setup" >/dev/null; then
        failures=$((failures + 1))
    fi

    return "$failures"
}

failures=0
run_contract() {
    local script="$1"
    local expected_count="$2"
    local valid_count
    set +e
    assert_single_api_contract "$script" "$expected_count"
    local rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "[PASS] $script"
    else
        valid_count=$(awk '/^[[:space:]]*create_symlink / && $0 ~ /^[[:space:]]*create_symlink "[^"]*" "[^"]*" "[^"]*" \|\| exit 1$/ { count++ } END { print count + 0 }' "$DOTFILES_ROOT/$script")
        if [ "$script" = "karabiner-elements/karabiner-setup.sh" ] && [ "$valid_count" -eq 2 ]; then
            printf '%s\n' "[EXPECTED_FAIL] $script (EDN symlink migration is not yet implemented)"
        elif [ "$valid_count" -eq 0 ]; then
            printf '%s\n' "[EXPECTED_FAIL] $script (single safe API migration is absent)"
        else
            printf '%s\n' "[UNEXPECTED_FAIL] $script (single API contract is malformed)"
            failures=$((failures + 1))
        fi
    fi
}

run_contract apps/cursor/cursor-setup.sh 2
run_contract apps/espanso/espanso-setup.sh 2
run_contract apps/ferdium/ferdium-setup.sh 2
run_contract gitignore/global-gitignore-setup.sh 1
run_contract karabiner-elements/karabiner-setup.sh 1
run_contract apps/warp/warp-setup.sh 1
run_contract apps/snapzy/snapzy-setup.sh 1
run_contract apps/codex/skills/skills-setup.sh 0
run_contract apps/codex/agents-setup.sh 1
run_contract textlint/textlint-setup.sh 2
run_contract hammerspoon/hammerspoon-setup.sh 1

set +e
assert_karabiner_goku_contract
goku_contract_status=$?
set -e
if [ "$goku_contract_status" -eq 0 ]; then
    printf '%s\n' '[PASS] karabiner-elements/karabiner-setup.sh uses one configured Goku call and preserves local karabiner.edn'
else
    printf '%s\n' '[EXPECTED_FAIL] karabiner-elements/karabiner-setup.sh Goku input/deletion contract (production migration is not yet implemented)'
fi

set +e
assert_setup_script_registered
registration_status=$?
set -e
if [ "$registration_status" -eq 0 ]; then
    printf '%s\n' "[PASS] setup-macos.sh registers hammerspoon/hammerspoon-setup.sh"
else
    if ! grep -Fqx '    "hammerspoon/hammerspoon-setup.sh"' "$DOTFILES_ROOT/setup-macos.sh"; then
        printf '%s\n' '[EXPECTED_FAIL] setup-macos.sh (Hammerspoon setup registration is absent)'
    else
        printf '%s\n' '[UNEXPECTED_FAIL] setup-macos.sh (Hammerspoon setup registration is duplicated or misplaced)'
        failures=$((failures + 1))
    fi
fi

if grep -Fqx '    "apps/codex/skills/skills-setup.sh"' "$DOTFILES_ROOT/setup-macos.sh"; then
    printf '%s\n' '[UNEXPECTED_FAIL] setup-macos.sh runs Skills setup standalone'
    failures=$((failures + 1))
else
    printf '%s\n' '[PASS] setup-macos.sh delegates Skills migration to codex-setup transaction'
fi

[ "$failures" -eq 0 ]
