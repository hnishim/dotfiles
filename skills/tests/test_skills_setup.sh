#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/skills-setup-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

run_conflict_test() {
    source_dir="$TMP_ROOT/source"
    local_dir="$TMP_ROOT/local"
    mkdir -p "$source_dir/a-conflict" "$source_dir/b-later" "$local_dir"
    printf '%s\n' a >"$source_dir/a-conflict/SKILL.md"
    printf '%s\n' b >"$source_dir/b-later/SKILL.md"
    printf '%s\n' preserve >"$local_dir/a-conflict"
    conflict_inode=$(stat -f '%i' "$local_dir/a-conflict")

    set +e
    ICLOUD_SKILLS_DIR_OVERRIDE="$source_dir" \
    LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$local_dir" \
        /bin/bash "$DOTFILES_ROOT/skills/skills-setup.sh" >"$TMP_ROOT/output" 2>&1
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
        printf '%s\n' '[UNEXPECTED_FAIL] skills setup succeeded despite the conflict' >&2
        return 1
    fi
    if ! grep -Eq 'a-conflict|競合|同名|既存|変更しません|上書き|ERROR|error' "$TMP_ROOT/output"; then
        printf '%s\n' '[UNEXPECTED_FAIL] skills fixture did not reach the conflict' >&2
        return 1
    fi
    if [ ! -f "$local_dir/a-conflict" ] || [ "$(cat "$local_dir/a-conflict")" != preserve ] || [ "$(stat -f '%i' "$local_dir/a-conflict")" != "$conflict_inode" ]; then
        printf '%s\n' '[UNEXPECTED_FAIL] skills conflict state was not preserved' >&2
        return 1
    fi
    if [ -L "$local_dir/b-later" ] && [ "$(readlink "$local_dir/b-later")" = "$source_dir/b-later" ]; then
        printf '%s\n' '[EXPECTED_FAIL] skills old implementation continued after conflict and created the later link' >&2
        return 2
    fi
    if [ -e "$local_dir/b-later" ] || [ -L "$local_dir/b-later" ]; then
        printf '%s\n' '[UNEXPECTED_FAIL] skills later-link state is unexpected' >&2
        return 1
    fi
    printf '%s\n' '[PASS] skills conflict preserved and setup stopped before later link'
}

set +e
(set -e; run_conflict_test)
run_status=$?
set -e
if [ "$run_status" -eq 2 ]; then
    exit 1
fi
if [ "$run_status" -ne 0 ]; then
    printf '%s\n' "[UNEXPECTED_FAIL] skills conflict test failed (rc=$run_status)" >&2
    exit 1
fi
