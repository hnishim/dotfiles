#!/bin/bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../../../" && pwd)
SETUP="$DOTFILES_ROOT/apps/codex/skills/skills-setup.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/skills-setup-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT
source_dir="$TMP_ROOT/source"
mkdir -p "$source_dir/example" "$source_dir/writing-references" "$source_dir/.system"
printf '%s\n' example >"$source_dir/example/SKILL.md"
printf '%s\n' reference >"$source_dir/writing-references/prose.md"
printf '%s\n' opaque >"$source_dir/.system/state"
mkdir -p "$source_dir/.system/nested"
printf '%s\n' metadata >"$source_dir/.system/nested/metadata"

snapshot_tree() {
    /usr/bin/python3 - "$1" <<'PY'
import hashlib
import os
import stat
import sys
from pathlib import Path

root = Path(sys.argv[1])
if not os.path.lexists(root):
    print("missing")
    raise SystemExit

def describe(path, relative):
    info = path.lstat()
    mode = stat.S_IMODE(info.st_mode)
    if stat.S_ISLNK(info.st_mode):
        return f"{relative}|symlink|{mode:o}|{os.readlink(path)}"
    if stat.S_ISREG(info.st_mode):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        return f"{relative}|file|{mode:o}|{digest}"
    if stat.S_ISDIR(info.st_mode):
        return f"{relative}|directory|{mode:o}|"
    raise SystemExit(f"unsupported state: {path}")

print(describe(root, "."))
if root.is_dir() and not root.is_symlink():
    for path in sorted(root.rglob("*")):
        print(describe(path, path.relative_to(root).as_posix()))
PY
}

run_setup() {
    ICLOUD_SKILLS_DIR_OVERRIDE="$source_dir" \
    LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$1" \
        /bin/bash "$SETUP"
}

fresh="$TMP_ROOT/fresh/skills"
source_system_before=$(snapshot_tree "$source_dir/.system")
run_setup "$fresh" >/dev/null
[ "$(readlink "$fresh")" = "$source_dir" ]
[ -f "$fresh/example/SKILL.md" ]
[ -e "$fresh/.system" ]
fresh_inode=$(stat -f '%i' "$fresh")
run_setup "$fresh" >/dev/null
[ "$(readlink "$fresh")" = "$source_dir" ]
[ "$(stat -f '%i' "$fresh")" = "$fresh_inode" ]
[ "$source_system_before" = "$(snapshot_tree "$source_dir/.system")" ]

physical="$TMP_ROOT/physical/skills"
mkdir -p "$physical/example" "$TMP_ROOT/archive-system"
printf '%s\n' keep >"$physical/example/local"
ln -s "$TMP_ROOT/archive-system" "$physical/.system"
ln -s "$source_dir/example" "$physical/legacy-child"
physical_before=$(snapshot_tree "$physical")
if run_setup "$physical" >"$TMP_ROOT/physical.log" 2>&1; then
    printf '%s\n' '[FAIL] physical Skills target unexpectedly succeeded' >&2
    exit 1
fi
[ "$physical_before" = "$(snapshot_tree "$physical")" ]
[ ! -e "$TMP_ROOT/physical/backups" ]

for kind in wrong dangling; do
    target="$TMP_ROOT/$kind/skills"
    mkdir -p "$(dirname "$target")"
    if [ "$kind" = wrong ]; then
        mkdir -p "$TMP_ROOT/wrong/other"
        original_target="$TMP_ROOT/wrong/other"
    else
        original_target="$TMP_ROOT/no-such"
    fi
    ln -s "$original_target" "$target"
    before=$(snapshot_tree "$target")
    if run_setup "$target" >"$TMP_ROOT/$kind.log" 2>&1; then
        printf '[FAIL] %s Skills target unexpectedly succeeded\n' "$kind" >&2
        exit 1
    fi
    [ "$before" = "$(snapshot_tree "$target")" ]
    [ ! -e "$TMP_ROOT/$kind/backups" ]
done

unknown="$TMP_ROOT/unknown/skills"
mkdir -p "$unknown"
printf '%s\n' preserve >"$unknown/unknown-data"
unknown_before=$(snapshot_tree "$unknown")
if run_setup "$unknown" >"$TMP_ROOT/unknown.log" 2>&1; then
    printf '%s\n' '[FAIL] unknown Skills target unexpectedly succeeded' >&2
    exit 1
fi
[ "$unknown_before" = "$(snapshot_tree "$unknown")" ]
[ ! -e "$TMP_ROOT/unknown/backups" ]

missing="$TMP_ROOT/missing/.codex/skills"
run_setup "$missing" >/dev/null
[ -L "$missing" ]
[ "$(readlink "$missing")" = "$source_dir" ]
[ ! -e "$TMP_ROOT/missing/.codex/backups" ]

default_home="$TMP_ROOT/default-home"
default_target="$default_home/.codex/skills"
default_source="$DOTFILES_ROOT/../harness/skills"
/usr/bin/env -u CODEX_HARNESS_ROOT_OVERRIDE -u ICLOUD_SKILLS_DIR_OVERRIDE \
    HOME="$default_home" LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$default_target" \
    /bin/bash "$SETUP" >/dev/null
[ "$(readlink "$default_target")" = "$default_source" ]

override_harness="$TMP_ROOT/override-harness"
mkdir -p "$override_harness/skills/example"
printf '%s\n' override >"$override_harness/skills/example/SKILL.md"
override_target="$TMP_ROOT/override-home/.codex/skills"
CODEX_HARNESS_ROOT_OVERRIDE="$override_harness" \
    LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$override_target" \
    /bin/bash "$SETUP" >/dev/null
[ "$(readlink "$override_target")" = "$override_harness/skills" ]

for forbidden in LEGACY_SOURCE_DIR SYSTEM_DIR SYSTEM_MARKER_FILE CODEX_SYSTEM_SKILLS_ CODEX_SKILLS_RUNTIME_DIR_OVERRIDE .skills-runtime; do
    ! rg -Fq "$forbidden" "$SETUP"
done
[ "$source_system_before" = "$(snapshot_tree "$source_dir/.system")" ]
printf '%s\n' '[PASS] skills setup scenarios'
