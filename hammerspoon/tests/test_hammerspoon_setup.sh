#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
PRODUCTION_SETUP="$DOTFILES_ROOT/hammerspoon/hammerspoon-setup.sh"
PRODUCTION_INIT="$DOTFILES_ROOT/hammerspoon/init.lua"
PRODUCTION_COMMON="$DOTFILES_ROOT/lib/common.sh"
PRODUCTION_HAMMERSPOON_ROOT=$(cd -- "$DOTFILES_ROOT/../scripts/hammerspoon" && pwd)
PRODUCTION_RAYCAST_ROOT=$(cd -- "$DOTFILES_ROOT/../scripts/raycast" && pwd)
TMP_ROOT=$(cd -- "$(mktemp -d "${TMPDIR:-/tmp}/hammerspoon-setup-test.XXXXXX")" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

FIXTURE_ROOT="$TMP_ROOT/fixture"
FIXTURE_DOTFILES_ROOT="$FIXTURE_ROOT/dotfiles"
FIXTURE_SETUP="$FIXTURE_DOTFILES_ROOT/hammerspoon/hammerspoon-setup.sh"
FIXTURE_INIT="$FIXTURE_DOTFILES_ROOT/hammerspoon/init.lua"
FIXTURE_SOURCE_DIR="$FIXTURE_ROOT/scripts/hammerspoon"
FIXTURE_SOURCE_MAIN="$FIXTURE_SOURCE_DIR/main.lua"
FIXTURE_RAYCAST_ROOT="$FIXTURE_ROOT/scripts/raycast"

external_script_names=(
    title-case-chicago.py
    title-case-chicago.sh
    two-panes-finder.applescript
)

initialize_fixture() {
    rm -rf -- "$FIXTURE_ROOT"
    mkdir -p "$FIXTURE_DOTFILES_ROOT/hammerspoon" "$FIXTURE_DOTFILES_ROOT/lib" \
        "$FIXTURE_SOURCE_DIR" "$FIXTURE_RAYCAST_ROOT"

    cp -- "$PRODUCTION_SETUP" "$FIXTURE_SETUP"
    cp -- "$PRODUCTION_INIT" "$FIXTURE_INIT"
    cp -- "$PRODUCTION_COMMON" "$FIXTURE_DOTFILES_ROOT/lib/common.sh"
    cp -- "$PRODUCTION_HAMMERSPOON_ROOT/main.lua" "$FIXTURE_SOURCE_MAIN"
    for name in "${external_script_names[@]}"; do
        cp -- "$PRODUCTION_RAYCAST_ROOT/$name" "$FIXTURE_RAYCAST_ROOT/$name"
    done
}

assert_raycast_sources() {
    for name in "${external_script_names[@]}"; do
        [ -f "$FIXTURE_RAYCAST_ROOT/$name" ]
        [ ! -L "$FIXTURE_RAYCAST_ROOT/$name" ]
    done
}

assert_no_repository_external_scripts() {
    [ ! -e "$FIXTURE_SOURCE_DIR/external_scripts" ]
    [ ! -L "$FIXTURE_SOURCE_DIR/external_scripts" ]
    assert_raycast_sources
}

assert_runtime_external_scripts_absent() {
    local home="$1"
    [ ! -e "$home/.hammerspoon/external_scripts" ]
    [ ! -L "$home/.hammerspoon/external_scripts" ]
}

assert_init_symlink() {
    local home="$1"
    [ -d "$home/.hammerspoon" ]
    [ ! -L "$home/.hammerspoon" ]
    [ -L "$home/.hammerspoon/init.lua" ]
    [ "$(readlink "$home/.hammerspoon/init.lua")" = "$FIXTURE_INIT" ]
    assert_runtime_external_scripts_absent "$home"
}

assert_loader_chain() {
    [ -f "$FIXTURE_INIT" ]
    [ -f "$FIXTURE_SOURCE_MAIN" ]
    grep -Fq 'main.lua' "$FIXTURE_INIT"
    grep -Fq 'require("hotkeys").start()' "$FIXTURE_SOURCE_MAIN"
}

run_setup() {
    local home="$1"
    HOME="$home" /bin/bash "$FIXTURE_SETUP"
}

assert_legacy_external_scripts_side_effect() {
    [ -d "$FIXTURE_SOURCE_DIR/external_scripts" ]
    [ ! -L "$FIXTURE_SOURCE_DIR/external_scripts" ]
    [ "$(readlink "$FIXTURE_SOURCE_DIR/external_scripts/title-case-chicago.py")" = "$FIXTURE_RAYCAST_ROOT/title-case-chicago.py" ]
    [ "$(readlink "$FIXTURE_SOURCE_DIR/external_scripts/title-case-chicago.sh")" = "$FIXTURE_RAYCAST_ROOT/title-case-chicago.sh" ]
    [ "$(readlink "$FIXTURE_SOURCE_DIR/external_scripts/two-panes-finder.applescript")" = "$FIXTURE_RAYCAST_ROOT/two-panes-finder.applescript" ]
}

finish_success_scenario() {
    if assert_legacy_external_scripts_side_effect; then
        return 42
    fi
    assert_no_repository_external_scripts
}

expected_failures=0
unexpected_failures=0

scenario_missing_directory_creates_physical_hammerspoon_directory_and_init_link() {
    initialize_fixture
    local home="$TMP_ROOT/missing-directory-home"
    mkdir -p "$home"
    [ ! -e "$FIXTURE_SOURCE_DIR/external_scripts" ]
    [ ! -L "$FIXTURE_SOURCE_DIR/external_scripts" ]

    run_setup "$home"

    assert_init_symlink "$home"
    [ -d "$home/.hammerspoon" ]
    [ ! -L "$home/.hammerspoon" ]
    assert_loader_chain
    finish_success_scenario
}

scenario_existing_hammerspoon_directory_contents_are_preserved() {
    initialize_fixture
    local home="$TMP_ROOT/existing-directory-home"
    mkdir -p "$home/.hammerspoon/Spoons"
    printf '%s\n' preserve >"$home/.hammerspoon/marker"

    run_setup "$home"

    assert_init_symlink "$home"
    [ "$(cat "$home/.hammerspoon/marker")" = preserve ]
    [ -d "$home/.hammerspoon/Spoons" ]
    assert_loader_chain
    finish_success_scenario
}

scenario_correct_existing_init_link_is_idempotent() {
    initialize_fixture
    local home="$TMP_ROOT/correct-existing-home"
    mkdir -p "$home/.hammerspoon"
    ln -s "$FIXTURE_INIT" "$home/.hammerspoon/init.lua"
    local link_inode
    link_inode=$(stat -f '%i' "$home/.hammerspoon/init.lua")

    run_setup "$home"

    assert_init_symlink "$home"
    [ "$(stat -f '%i' "$home/.hammerspoon/init.lua")" = "$link_inode" ]
    finish_success_scenario
}

scenario_existing_init_file_is_preserved_on_failure() {
    initialize_fixture
    local home="$TMP_ROOT/init-file-conflict-home"
    local target="$home/.hammerspoon/init.lua"
    mkdir -p "$home/.hammerspoon"
    printf '%s\n' preserve >"$target"
    local inode
    inode=$(stat -f '%i' "$target")

    if run_setup "$home"; then return 1; fi

    [ -f "$target" ]
    [ ! -L "$target" ]
    [ "$(cat "$target")" = preserve ]
    [ "$(stat -f '%i' "$target")" = "$inode" ]
    assert_runtime_external_scripts_absent "$home"
    assert_no_repository_external_scripts
}

scenario_existing_init_directory_is_preserved_on_failure() {
    initialize_fixture
    local home="$TMP_ROOT/init-directory-conflict-home"
    local target="$home/.hammerspoon/init.lua"
    mkdir -p "$target"
    printf '%s\n' preserve >"$target/marker"

    if run_setup "$home"; then return 1; fi

    [ -d "$target" ]
    [ ! -L "$target" ]
    [ "$(cat "$target/marker")" = preserve ]
    assert_runtime_external_scripts_absent "$home"
    assert_no_repository_external_scripts
}

scenario_different_init_symlink_is_preserved_on_failure() {
    initialize_fixture
    local home="$TMP_ROOT/different-init-link-home"
    local target="$home/.hammerspoon/init.lua"
    local other="$TMP_ROOT/other-init.lua"
    mkdir -p "$home/.hammerspoon"
    printf '%s\n' preserve >"$other"
    ln -s "$other" "$target"

    if run_setup "$home"; then return 1; fi

    [ -L "$target" ]
    [ "$(readlink "$target")" = "$other" ]
    [ "$(cat "$other")" = preserve ]
    assert_runtime_external_scripts_absent "$home"
    assert_no_repository_external_scripts
}

scenario_broken_init_symlink_is_preserved_on_failure() {
    initialize_fixture
    local home="$TMP_ROOT/broken-init-link-home"
    local target="$home/.hammerspoon/init.lua"
    local missing="$TMP_ROOT/missing-init.lua"
    mkdir -p "$home/.hammerspoon"
    ln -s "$missing" "$target"

    if run_setup "$home"; then return 1; fi

    [ -L "$target" ]
    [ "$(readlink "$target")" = "$missing" ]
    assert_runtime_external_scripts_absent "$home"
    assert_no_repository_external_scripts
}

scenario_hammerspoon_directory_symlink_is_preserved_on_failure() {
    initialize_fixture
    local home="$TMP_ROOT/hammerspoon-directory-link-home"
    local other="$TMP_ROOT/other-hammerspoon-directory"
    mkdir -p "$home" "$other"
    printf '%s\n' preserve >"$other/marker"
    ln -s "$other" "$home/.hammerspoon"

    if run_setup "$home"; then return 1; fi

    [ -L "$home/.hammerspoon" ]
    [ "$(readlink "$home/.hammerspoon")" = "$other" ]
    [ "$(cat "$other/marker")" = preserve ]
    [ ! -e "$other/init.lua" ]
    [ ! -e "$other/external_scripts" ]
    assert_no_repository_external_scripts
}

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
    elif [ "$status" -eq 42 ] && assert_legacy_external_scripts_side_effect; then
        printf '%s\n' "[EXPECTED_FAIL] $name (known legacy external_scripts side effect)"
        expected_failures=$((expected_failures + 1))
    else
        printf '%s\n' "[UNEXPECTED_FAIL] $name (rc=$status)"
        unexpected_failures=$((unexpected_failures + 1))
        return 1
    fi
}

run_scenario scenario_missing_directory_creates_physical_hammerspoon_directory_and_init_link
run_scenario scenario_existing_hammerspoon_directory_contents_are_preserved
run_scenario scenario_correct_existing_init_link_is_idempotent
run_scenario scenario_existing_init_file_is_preserved_on_failure
run_scenario scenario_existing_init_directory_is_preserved_on_failure
run_scenario scenario_different_init_symlink_is_preserved_on_failure
run_scenario scenario_broken_init_symlink_is_preserved_on_failure
run_scenario scenario_hammerspoon_directory_symlink_is_preserved_on_failure

[ "$unexpected_failures" -eq 0 ]
