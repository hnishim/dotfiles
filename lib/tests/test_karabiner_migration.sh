#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
COMMON="$DOTFILES_ROOT/lib/common.sh"
SETUP="$DOTFILES_ROOT/karabiner-elements/karabiner-setup.sh"
CONFIG_JSON="$DOTFILES_ROOT/karabiner-elements/config/karabiner.json"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/karabiner-migration-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

source "$COMMON"

assert_file_absent_from_setup() {
    local pattern="$1"
    if rg -n -i --fixed-strings "$pattern" "$SETUP"; then
        printf '%s\n' "[FAIL] setup contains forbidden legacy placement: $pattern" >&2
        return 1
    fi
}

scenario_manual_directory_migration_and_restore() {
    local home="$TMP_ROOT/home"
    local local_config="$home/.config/karabiner"
    local source_dir="$TMP_ROOT/repository/config"
    local backup_dir="$home/.config/karabiner_backup_20260831T120000"
    mkdir -p "$local_config" "$source_dir"
    printf '%s\n' preserve-this-setting >"$local_config/unknown-settings.txt"
    printf '%s\n' '{"profiles":[]}' >"$source_dir/karabiner.json"

    [ "$(find -P "$local_config" -type f -print)" = "$local_config/unknown-settings.txt" ]
    mv -- "$local_config" "$backup_dir"
    [ -f "$backup_dir/unknown-settings.txt" ]
    [ "$(cat "$backup_dir/unknown-settings.txt")" = preserve-this-setting ]

    create_symlink "$source_dir" "$local_config" "Karabiner directory"
    [ "$(readlink "$local_config")" = "$source_dir" ]
    jq -e '.profiles | type == "array"' "$local_config/karabiner.json" >/dev/null
    [ "$(cat "$backup_dir/unknown-settings.txt")" = preserve-this-setting ]

    rm -f -- "$local_config"
    mv -- "$backup_dir" "$local_config"
    [ -d "$local_config" ]
    [ ! -L "$local_config" ]
    [ "$(cat "$local_config/unknown-settings.txt")" = preserve-this-setting ]
}

scenario_intentional_link_failure_restores_backup() {
    local home="$TMP_ROOT/failure-home"
    local local_config="$home/.config/karabiner"
    local source_dir="$TMP_ROOT/failure-repository/config"
    local backup_dir="$home/.config/karabiner_backup_failure"
    mkdir -p "$local_config" "$source_dir"
    printf '%s\n' restore-me >"$local_config/unknown-settings.txt"
    printf '%s\n' '{"profiles":[]}' >"$source_dir/karabiner.json"

    mv -- "$local_config" "$backup_dir"
    printf '%s\n' conflicting-file >"$local_config"
    if create_symlink "$source_dir" "$local_config" "Karabiner directory"; then
        return 1
    fi
    [ -f "$local_config" ]
    [ "$(cat "$local_config")" = conflicting-file ]
    [ "$(cat "$backup_dir/unknown-settings.txt")" = restore-me ]

    rm -f -- "$local_config"
    mv -- "$backup_dir" "$local_config"
    [ -d "$local_config" ]
    [ ! -L "$local_config" ]
    [ "$(cat "$local_config/unknown-settings.txt")" = restore-me ]
}

scenario_setup_syntax_and_call_contract() {
    bash -n "$SETUP"
    awk '
        /^[[:space:]]*create_symlink / {
            if ($0 !~ /^[[:space:]]*create_symlink "[^"]*" "[^"]*" "[^"]*" \|\| exit 1$/) exit 1
            count++
        }
        END { exit count == 2 ? 0 : 1 }
    ' "$SETUP"
}

scenario_json_is_valid() {
    jq -e '. | type == "object"' "$CONFIG_JSON" >/dev/null
    jq -e 'has("profiles") and (.profiles | type == "array")' "$CONFIG_JSON" >/dev/null
}

scenario_setup_has_current_directory_contract() {
    rg -n --fixed-strings 'LOCAL_KARABINER_DIR="$HOME/.config/karabiner"' "$SETUP" >/dev/null
    rg -n --fixed-strings 'ICLOUD_KARABINER_JSON="$SCRIPT_DIR/config/karabiner.json"' "$SETUP" >/dev/null
    rg -n --fixed-strings 'create_symlink "$SCRIPT_DIR/config" "$LOCAL_KARABINER_DIR"' "$SETUP" >/dev/null
    if rg -n --fixed-strings 'LOCAL_KARABINER_JSON=' "$SETUP"; then
        return 1
    fi
}

scenario_no_legacy_karabiner_placement() {
    assert_file_absent_from_setup '.local'
    assert_file_absent_from_setup 'Mimi'
    assert_file_absent_from_setup 'Title Case'
    assert_file_absent_from_setup 'Two-panes Finder'
    if rg -n -i --fixed-strings 'mimi-resize.sh' "$SETUP" "$CONFIG_JSON"; then
        return 1
    fi
}

scenario_manual_directory_migration_and_restore
scenario_intentional_link_failure_restores_backup
scenario_setup_syntax_and_call_contract
scenario_json_is_valid
scenario_setup_has_current_directory_contract
scenario_no_legacy_karabiner_placement

printf '%s\n' '[PASS] Karabiner migration and static contract tests'
