#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
SETUP="$DOTFILES_ROOT/hammerspoon/hammerspoon-setup.sh"
DOTFILES_INIT="$DOTFILES_ROOT/hammerspoon/init.lua"
SOURCE_DIR=$(cd -- "$DOTFILES_ROOT/../scripts/hammerspoon" && pwd)
SOURCE_MAIN="$SOURCE_DIR/main.lua"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hammerspoon-setup-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

assert_init_symlink() {
    local home="$1"
    [ -d "$home/.hammerspoon" ]
    [ ! -L "$home/.hammerspoon" ]
    [ -L "$home/.hammerspoon/init.lua" ]
    [ "$(readlink "$home/.hammerspoon/init.lua")" = "$DOTFILES_INIT" ]
}

assert_loader_chain() {
    [ -f "$DOTFILES_INIT" ]
    [ -f "$SOURCE_MAIN" ]
    grep -Fq 'main.lua' "$DOTFILES_INIT"
    grep -Fq 'require("ai_command").start()' "$SOURCE_MAIN"
    grep -Fq 'require("utility_command").start()' "$SOURCE_MAIN"
}

run_setup() {
    local home="$1"
    HOME="$home" /bin/bash "$SETUP"
}

scenario_missing_directory_creates_physical_directory_and_init_link() {
    local home="$TMP_ROOT/missing-directory-home"
    mkdir -p "$home"
    run_setup "$home"
    assert_init_symlink "$home"
    assert_loader_chain
}

scenario_existing_directory_contents_are_preserved() {
    local home="$TMP_ROOT/existing-directory-home"
    mkdir -p "$home/.hammerspoon/Spoons"
    printf '%s\n' preserve >"$home/.hammerspoon/marker"
    run_setup "$home"
    assert_init_symlink "$home"
    [ "$(cat "$home/.hammerspoon/marker")" = preserve ]
    [ -d "$home/.hammerspoon/Spoons" ]
    assert_loader_chain
}

scenario_correct_existing_init_link_is_idempotent() {
    local home="$TMP_ROOT/correct-existing-home"
    mkdir -p "$home/.hammerspoon"
    ln -s "$DOTFILES_INIT" "$home/.hammerspoon/init.lua"
    local link_inode
    link_inode=$(stat -f '%i' "$home/.hammerspoon/init.lua")

    run_setup "$home"

    assert_init_symlink "$home"
    [ "$(stat -f '%i' "$home/.hammerspoon/init.lua")" = "$link_inode" ]
}

scenario_existing_init_file_is_preserved_on_failure() {
    local home="$TMP_ROOT/file-conflict-home"
    local target="$home/.hammerspoon/init.lua"
    mkdir -p "$home/.hammerspoon"
    printf '%s\n' preserve >"$target"
    local inode
    inode=$(stat -f '%i' "$target")

    if run_setup "$home"; then
        return 1
    fi

    [ -f "$target" ]
    [ ! -L "$target" ]
    [ "$(cat "$target")" = preserve ]
    [ "$(stat -f '%i' "$target")" = "$inode" ]
}

scenario_different_init_symlink_is_preserved_on_failure() {
    local home="$TMP_ROOT/different-link-home"
    local target="$home/.hammerspoon/init.lua"
    local other="$TMP_ROOT/other-init.lua"
    mkdir -p "$home/.hammerspoon"
    ln -s "$other" "$target"

    if run_setup "$home"; then
        return 1
    fi

    [ -L "$target" ]
    [ "$(readlink "$target")" = "$other" ]
}

scenario_broken_init_symlink_is_preserved_on_failure() {
    local home="$TMP_ROOT/broken-link-home"
    local target="$home/.hammerspoon/init.lua"
    local missing="$TMP_ROOT/missing-init.lua"
    mkdir -p "$home/.hammerspoon"
    ln -s "$missing" "$target"

    if run_setup "$home"; then
        return 1
    fi

    [ -L "$target" ]
    [ "$(readlink "$target")" = "$missing" ]
}

scenario_symlinked_hammerspoon_directory_is_preserved_on_failure() {
    local home="$TMP_ROOT/directory-link-home"
    local other="$TMP_ROOT/other-hammerspoon"
    mkdir -p "$home" "$other"
    ln -s "$other" "$home/.hammerspoon"

    if run_setup "$home"; then
        return 1
    fi

    [ -L "$home/.hammerspoon" ]
    [ "$(readlink "$home/.hammerspoon")" = "$other" ]
    [ ! -e "$other/init.lua" ]
}

expected_failures=0
unexpected_failures=0
production_ready=1
if [ ! -f "$SETUP" ] || [ ! -f "$DOTFILES_INIT" ] || [ ! -f "$SOURCE_MAIN" ] \
    || ! grep -Fq '.hammerspoon/init.lua' "$SETUP"; then
    production_ready=0
fi

run_scenario() {
    local name="$1"
    set +e
    (
        set -e
        "$name"
    )
    local status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        printf '%s\n' "[PASS] $name"
    elif [ "$production_ready" -eq 0 ]; then
        printf '%s\n' "[EXPECTED_FAIL] $name (Hammerspoon production setup is absent)"
        expected_failures=$((expected_failures + 1))
    else
        printf '%s\n' "[UNEXPECTED_FAIL] $name (rc=$status)"
        unexpected_failures=$((unexpected_failures + 1))
    fi
}

run_scenario scenario_missing_directory_creates_physical_directory_and_init_link
run_scenario scenario_existing_directory_contents_are_preserved
run_scenario scenario_correct_existing_init_link_is_idempotent
run_scenario scenario_existing_init_file_is_preserved_on_failure
run_scenario scenario_different_init_symlink_is_preserved_on_failure
run_scenario scenario_broken_init_symlink_is_preserved_on_failure
run_scenario scenario_symlinked_hammerspoon_directory_is_preserved_on_failure

[ "$unexpected_failures" -eq 0 ]
[ "$expected_failures" -eq 0 ]
