#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/skills-setup-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

run_missing_target_test() {
    source_dir="$TMP_ROOT/source"
    local_parent="$TMP_ROOT/local"
    local_dir="$local_parent/skills"
    mkdir -p "$source_dir/example" "$local_parent"
    printf '%s\n' example >"$source_dir/example/SKILL.md"

    ICLOUD_SKILLS_DIR_OVERRIDE="$source_dir" \
    LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$local_dir" \
        /bin/bash "$DOTFILES_ROOT/skills/skills-setup.sh" >"$TMP_ROOT/missing-output" 2>&1

    if [ ! -L "$local_dir" ] || [ "$(readlink "$local_dir")" != "$source_dir" ]; then
        printf '%s\n' '[UNEXPECTED_FAIL] skills directory was not linked through create_symlink' >&2
        return 1
    fi
    printf '%s\n' '[PASS] missing skills directory linked'
}

run_conflict_test() {
    source_dir="$TMP_ROOT/conflict-source"
    local_parent="$TMP_ROOT/conflict-local"
    local_dir="$local_parent/skills"
    mkdir -p "$source_dir/example" "$local_dir/local-only"
    printf '%s\n' source >"$source_dir/example/SKILL.md"
    printf '%s\n' local >"$local_dir/local-only/SKILL.md"
    conflict_inode=$(stat -f '%i' "$local_dir")

    set +e
    ICLOUD_SKILLS_DIR_OVERRIDE="$source_dir" \
    LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$local_dir" \
        /bin/bash "$DOTFILES_ROOT/skills/skills-setup.sh" >"$TMP_ROOT/conflict-output" 2>&1
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        printf '%s\n' '[UNEXPECTED_FAIL] setup succeeded despite an existing directory conflict' >&2
        return 1
    fi
    if ! grep -Eq '競合|変更しません|ERROR|error' "$TMP_ROOT/conflict-output"; then
        printf '%s\n' '[UNEXPECTED_FAIL] conflict was not reported by create_symlink' >&2
        return 1
    fi
    if [ ! -d "$local_dir" ] || [ -L "$local_dir" ] || [ ! -d "$local_dir/local-only" ]; then
        printf '%s\n' '[UNEXPECTED_FAIL] existing directory conflict was changed' >&2
        return 1
    fi
    if [ "$(stat -f '%i' "$local_dir")" != "$conflict_inode" ]; then
        printf '%s\n' '[UNEXPECTED_FAIL] existing directory conflict was replaced' >&2
        return 1
    fi
    printf '%s\n' '[PASS] existing directory conflict preserved'
}

run_correct_link_test() {
    source_dir="$TMP_ROOT/correct-source"
    local_parent="$TMP_ROOT/correct-local"
    local_dir="$local_parent/skills"
    mkdir -p "$source_dir/example" "$local_parent"
    printf '%s\n' source >"$source_dir/example/SKILL.md"
    ln -s "$source_dir" "$local_dir"
    link_inode=$(stat -f '%i' "$local_dir")

    ICLOUD_SKILLS_DIR_OVERRIDE="$source_dir" \
    LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$local_dir" \
        /bin/bash "$DOTFILES_ROOT/skills/skills-setup.sh" >"$TMP_ROOT/correct-output" 2>&1

    if [ "$(readlink "$local_dir")" != "$source_dir" ] || [ "$(stat -f '%i' "$local_dir")" != "$link_inode" ]; then
        printf '%s\n' '[UNEXPECTED_FAIL] correct existing link was changed' >&2
        return 1
    fi
    printf '%s\n' '[PASS] correct existing link preserved'
}

run_missing_target_test
run_conflict_test
run_correct_link_test
