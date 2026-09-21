#!/bin/bash

# Test the setup contract runner against isolated, representative regressions.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/setup-contract-fail-closed.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

fixture="$TMP_ROOT/dotfiles"
paths=(
    lib/tests/test_setup_call_contracts.sh
    setup-macos.sh
    apps/cursor/cursor-setup.sh
    apps/espanso/espanso-setup.sh
    apps/ferdium/ferdium-setup.sh
    gitignore/global-gitignore-setup.sh
    karabiner-elements/karabiner-setup.sh
    apps/warp/warp-setup.sh
    apps/snapzy/snapzy-setup.sh
    apps/codex/skills/skills-setup.sh
    apps/codex/agents/agents-setup.sh
    textlint/textlint-setup.sh
    hammerspoon/hammerspoon-setup.sh
)
for relative in "${paths[@]}"; do
    mkdir -p "$fixture/$(dirname -- "$relative")"
    cp -- "$DOTFILES_ROOT/$relative" "$fixture/$relative"
done

runner="$fixture/lib/tests/test_setup_call_contracts.sh"
log="$TMP_ROOT/contract.log"
if ! bash "$runner" >"$log" 2>&1; then
    cat "$log" >&2
    printf '%s\n' '[FAIL] current setup contract must pass' >&2
    exit 1
fi
if grep -Fq '[EXPECTED_FAIL]' "$log"; then
    cat "$log" >&2
    printf '%s\n' '[FAIL] migration exemptions remain in the contract runner' >&2
    exit 1
fi

expect_failure() {
    local name="$1"
    if bash "$runner" >"$log" 2>&1; then
        printf '[FAIL] %s was accepted as success\n' "$name" >&2
        cat "$log" >&2
        return 1
    fi
    printf '[PASS] contract runner rejects %s\n' "$name"
}

mutate_and_check() {
    local name="$1"
    local path="$2"
    local pattern="$3"
    local source="$fixture/$path"
    local backup="$TMP_ROOT/original"
    cp -- "$source" "$backup"
    sed "$pattern" "$backup" >"$source"
    if cmp -s "$backup" "$source"; then
        printf '%s\n' "[FAIL] $name mutation did not change its fixture" >&2
        return 1
    fi
    expect_failure "$name"
    cp -- "$backup" "$source"
}

mutate_and_check 'missing Cursor symlink calls' \
    apps/cursor/cursor-setup.sh '/^[[:space:]]*create_symlink /d'
mutate_and_check 'missing Hammerspoon loader link' \
    hammerspoon/hammerspoon-setup.sh '/^[[:space:]]*create_symlink /d'
mutate_and_check 'unconfigured Goku input' \
    karabiner-elements/karabiner-setup.sh 's/GOKU_EDN_CONFIG_FILE="$ICLOUD_KARABINER_EDN" goku/goku/'
mutate_and_check 'missing Hammerspoon entrypoint' \
    setup-macos.sh '/"hammerspoon\/hammerspoon-setup.sh"/d'

printf '%s\n' '[PASS] setup contract runner fails closed'
