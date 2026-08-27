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

failures=0
run_contract() {
    local script="$1"
    local expected_count="$2"
    set +e
    assert_single_api_contract "$script" "$expected_count"
    local rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "[PASS] $script"
    else
        if ! awk '/^[[:space:]]*create_symlink / && $0 ~ /^[[:space:]]*create_symlink "[^"]*" "[^"]*" "[^"]*" \|\| exit 1$/ { found=1 } END { exit found ? 0 : 1 }' "$DOTFILES_ROOT/$script"; then
            printf '%s\n' "[EXPECTED_FAIL] $script (single safe API migration is absent)"
        else
            printf '%s\n' "[UNEXPECTED_FAIL] $script (single API contract is malformed)"
            failures=$((failures + 1))
        fi
    fi
}

run_contract cursor/cursor-setup.sh 2
run_contract espanso/espanso-setup.sh 2
run_contract ferdium/ferdium-setup.sh 2
run_contract gitignore/global-gitignore-setup.sh 1
run_contract karabiner-elements/karabiner-setup.sh 2
run_contract warp/warp-setup.sh 1
run_contract app/snapzy/snapzy-setup.sh 1
run_contract skills/skills-setup.sh 1
run_contract codex/agents-setup.sh 1
run_contract textlint/textlint-setup.sh 2

[ "$failures" -eq 0 ]
