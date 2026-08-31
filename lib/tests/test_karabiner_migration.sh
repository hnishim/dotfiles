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
    if ! awk '
        /^[[:space:]]*create_symlink / {
            if ($0 !~ /^[[:space:]]*create_symlink "[^"]*" "[^"]*" "[^"]*" \|\| exit 1$/) exit 1
            count++
        }
        END { exit count == 1 ? 0 : 1 }
    ' "$SETUP"; then
        printf '%s\n' '[EXPECTED_FAIL] setup still has the pre-migration create_symlink contract' >&2
        return 1
    fi
}

scenario_setup_uses_repository_edn_for_goku() {
    rg -n --fixed-strings 'check_path "$ICLOUD_KARABINER_EDN" "iCloud karabiner.edn" "file" || exit 1' "$SETUP" >/dev/null
    if ! rg -n --fixed-strings 'GOKU_EDN_CONFIG_FILE="$ICLOUD_KARABINER_EDN" goku' "$SETUP" >/dev/null; then
        printf '%s\n' '[EXPECTED_FAIL] setup does not pass the repository EDN through GOKU_EDN_CONFIG_FILE' >&2
        return 1
    fi
    [ "$(awk '
        /^[[:space:]]*#/ { next }
        { while (match($0, /GOKU_EDN_CONFIG_FILE="\$ICLOUD_KARABINER_EDN"[[:space:]]+goku/)) { count++; $0 = substr($0, RSTART + RLENGTH) } }
        END { print count + 0 }
    ' "$SETUP")" -eq 1 ]
    [ "$(awk '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            while (match(line, /GOKU_EDN_CONFIG_FILE="\$ICLOUD_KARABINER_EDN"[[:space:]]+goku/)) {
                line = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH)
            }
            if (line ~ /(^|[[:space:];|&])goku([[:space:];|&]|$)/) count++
        }
        END { print count + 0 }
    ' "$SETUP")" -eq 0 ]
    if rg -n --fixed-strings 'LOCAL_KARABINER_EDN=' "$SETUP"; then
        return 1
    fi
    if rg -n --fixed-strings 'create_symlink "$ICLOUD_KARABINER_EDN"' "$SETUP"; then
        return 1
    fi
    if rg -n --fixed-strings 'karabiner.edn:  $LOCAL_KARABINER_EDN' "$SETUP"; then
        return 1
    fi
}

scenario_setup_preserves_existing_edn() {
    if rg -n '(^|[;&|[:space:]])(rm|unlink)([[:space:]]|$).*([Kk][Aa][Rr][Aa][Bb][Ii][Nn][Ee][Rr]\.edn|LOCAL_KARABINER_EDN)' "$SETUP"; then
        printf '%s\n' '[FAIL] setup automatically removes the existing local karabiner.edn' >&2
        return 1
    fi
}

scenario_goku_runtime_uses_spaced_repository_path() {
    if ! command -v goku >/dev/null 2>&1; then
        printf '%s\n' '[SKIP] goku runtime contract (goku is not available on PATH)' >&2
        return 0
    fi

    local isolated_home="$TMP_ROOT/goku home"
    local spaced_repository="$TMP_ROOT/repository with spaces"
    local input_edn="$spaced_repository/karabiner.edn"
    local generated_json="$isolated_home/.config/karabiner/karabiner.json"
    local stdout_file="$TMP_ROOT/goku.stdout"
    local stderr_file="$TMP_ROOT/goku.stderr"
    local expected_normalized="$TMP_ROOT/expected-normalized.json"
    local actual_normalized="$TMP_ROOT/actual-normalized.json"
    local repository_json_hash_before
    local repository_json_hash_after

    mkdir -p "$isolated_home/.config/karabiner" "$spaced_repository"
    cp -- "$DOTFILES_ROOT/karabiner-elements/goku/karabiner.edn" "$input_edn"
    cp -- "$CONFIG_JSON" "$generated_json"
    repository_json_hash_before=$(shasum -a 256 "$CONFIG_JSON")

    if ! HOME="$isolated_home" GOKU_EDN_CONFIG_FILE="$input_edn" goku >"$stdout_file" 2>"$stderr_file"; then
        printf '%s\n' '[FAIL] goku runtime contract failed' >&2
        return 1
    fi
    [ ! -s "$stderr_file" ]
    jq -e '. | type == "object"' "$generated_json" >/dev/null
    jq -S . "$CONFIG_JSON" >"$expected_normalized"
    jq -S . "$generated_json" >"$actual_normalized"
    cmp -s "$expected_normalized" "$actual_normalized"
    repository_json_hash_after=$(shasum -a 256 "$CONFIG_JSON")
    [ "$repository_json_hash_before" = "$repository_json_hash_after" ]
    printf '%s\n' '[PASS] goku runtime contract (isolated HOME, spaced EDN path, normalized JSON, repository JSON unchanged)'
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
scenario_goku_runtime_uses_spaced_repository_path
scenario_setup_syntax_and_call_contract
scenario_setup_uses_repository_edn_for_goku
scenario_setup_preserves_existing_edn
scenario_json_is_valid
scenario_setup_has_current_directory_contract
scenario_no_legacy_karabiner_placement

printf '%s\n' '[PASS] Karabiner migration and static contract tests'
