#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
COMMON="$DOTFILES_ROOT/lib/common.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/symlink-helper-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

source "$COMMON"

source_file="$TMP_ROOT/source.txt"
printf '%s\n' source >"$source_file"

assert_correct_link() {
    local path="$1"
    local target="$2"
    [ -L "$path" ]
    [ "$(readlink "$path")" = "$target" ]
}

scenario_missing_and_idempotent() {
    local path="$TMP_ROOT/missing"
    create_symlink "$source_file" "$path" "missing"
    assert_correct_link "$path" "$source_file"
    local link_inode
    link_inode=$(stat -f '%i' "$path")
    create_symlink "$source_file" "$path" "missing"
    assert_correct_link "$path" "$source_file"
    [ "$(stat -f '%i' "$path")" = "$link_inode" ]
}

scenario_correct_existing_is_invariant() {
    local existing="$TMP_ROOT/correct-existing"
    ln -s "$source_file" "$existing"
    local existing_inode source_inode tree_before
    existing_inode=$(stat -f '%i' "$existing")
    source_inode=$(stat -f '%i' "$source_file")
    tree_before=$(find "$TMP_ROOT" -print | sort)
    create_symlink "$source_file" "$existing" "correct-existing"
    assert_correct_link "$existing" "$source_file"
    [ "$(stat -f '%i' "$existing")" = "$existing_inode" ]
    [ "$(stat -f '%i' "$source_file")" = "$source_inode" ]
    [ "$(find "$TMP_ROOT" -print | sort)" = "$tree_before" ]
}

scenario_safe_different_link_is_preserved() {
    local path="$TMP_ROOT/different-link"
    ln -s "$TMP_ROOT/other" "$path"
    local tree_before
    tree_before=$(find "$TMP_ROOT" -print | sort)
    if create_symlink "$source_file" "$path" "different"; then
        return 1
    fi
    [ "$(readlink "$path")" = "$TMP_ROOT/other" ]
    [ "$(find "$TMP_ROOT" -print | sort)" = "$tree_before" ]
}

scenario_safe_broken_link_is_preserved() {
    local path="$TMP_ROOT/broken-link"
    ln -s "$TMP_ROOT/missing-target" "$path"
    local tree_before
    tree_before=$(find "$TMP_ROOT" -print | sort)
    if create_symlink "$source_file" "$path" "broken"; then
        return 1
    fi
    [ "$(readlink "$path")" = "$TMP_ROOT/missing-target" ]
    [ "$(find "$TMP_ROOT" -print | sort)" = "$tree_before" ]
}

scenario_safe_regular_file_is_preserved() {
    local path="$TMP_ROOT/ordinary-file"
    printf '%s\n' keep >"$path"
    local path_inode tree_before
    path_inode=$(stat -f '%i' "$path")
    tree_before=$(find "$TMP_ROOT" -print | sort)
    if create_symlink "$source_file" "$path" "ordinary-file"; then
        return 1
    fi
    [ "$(cat "$path")" = keep ]
    [ "$(stat -f '%i' "$path")" = "$path_inode" ]
    [ "$(find "$TMP_ROOT" -print | sort)" = "$tree_before" ]
}

scenario_safe_directory_tree_is_preserved() {
    local path="$TMP_ROOT/ordinary-directory"
    mkdir "$path"
    mkdir "$path/nested"
    printf '%s\n' keep >"$path/entry"
    printf '%s\n' nested >"$path/nested/entry"
    local directory_tree
    directory_tree=$(find "$path" -print | sort)
    if create_symlink "$source_file" "$path" "ordinary-directory"; then
        return 1
    fi
    [ -d "$path" ]
    [ "$(cat "$path/entry")" = keep ]
    [ "$(cat "$path/nested/entry")" = nested ]
    [ "$(find "$path" -print | sort)" = "$directory_tree" ]
    [ "$(find -P "$path" -type l | wc -l | tr -d ' ')" -eq 0 ]
}

scenario_creation_failure_preserves_parent() {
    local parent="$TMP_ROOT/not-a-directory"
    local creation_failure="$parent/target"
    printf '%s\n' preserve >"$parent"
    local parent_inode
    parent_inode=$(stat -f '%i' "$parent")
    if create_symlink "$source_file" "$creation_failure" "creation-failure"; then
        return 1
    fi
    [ ! -e "$creation_failure" ]
    [ ! -L "$creation_failure" ]
    [ -f "$parent" ]
    [ "$(cat "$parent")" = preserve ]
    [ "$(stat -f '%i' "$parent")" = "$parent_inode" ]
}

scenario_child_shell_set_e_probe() {
    source "$runner_fixture"
}

scenario_runner_does_not_mask_mid_scenario_failure() {
    runner_fixture="$TMP_ROOT/runner-fixture.sh"
    runner_probe_marker="$TMP_ROOT/later-assertion-ran"
    local runner_output="$TMP_ROOT/runner-output"

    cat >"$runner_fixture" <<EOF
#!/bin/bash
[ 1 -eq 0 ]
touch "$runner_probe_marker"
EOF
    chmod +x "$runner_fixture"

    local prior_expected_failures prior_unexpected_failures observed_failures
    prior_expected_failures="$expected_failures"
    prior_unexpected_failures="$unexpected_failures"
    run_scenario scenario_child_shell_set_e_probe >"$runner_output" 2>&1
    observed_failures=$((expected_failures - prior_expected_failures + unexpected_failures - prior_unexpected_failures))

    if [ ! -e "$runner_probe_marker" ] && [ "$observed_failures" -eq 1 ]; then
        expected_failures="$prior_expected_failures"
        unexpected_failures="$prior_unexpected_failures"
        return 0
    fi
    return 1
}

expected_failures=0
unexpected_failures=0
single_api_ready=0
api_probe_source="$TMP_ROOT/api-probe-source"
api_probe_target="$TMP_ROOT/api-probe-target"
printf '%s\n' probe >"$api_probe_source"
if (source "$COMMON"; create_symlink "$api_probe_source" "$api_probe_target" "api probe") >/dev/null 2>&1; then
    single_api_ready=1
fi
rm -f "$api_probe_target"

run_scenario() {
    local name="$1"
    set +e
    (
        set -e
        "$name"
    )
    local rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "[PASS] $name"
    else
        if [ "$single_api_ready" -eq 0 ] && [ "$name" != scenario_runner_does_not_mask_mid_scenario_failure ]; then
                printf '%s\n' "[EXPECTED_FAIL] $name (common API migration is absent)"
                expected_failures=$((expected_failures + 1))
        else
                printf '%s\n' "[UNEXPECTED_FAIL] $name (rc=$rc)"
                unexpected_failures=$((unexpected_failures + 1))
        fi
    fi
}

run_scenario scenario_missing_and_idempotent
run_scenario scenario_correct_existing_is_invariant
run_scenario scenario_safe_different_link_is_preserved
run_scenario scenario_safe_broken_link_is_preserved
run_scenario scenario_safe_regular_file_is_preserved
run_scenario scenario_safe_directory_tree_is_preserved
run_scenario scenario_creation_failure_preserves_parent
run_scenario scenario_runner_does_not_mask_mid_scenario_failure

[ "$unexpected_failures" -eq 0 ]
[ "$expected_failures" -eq 0 ]
