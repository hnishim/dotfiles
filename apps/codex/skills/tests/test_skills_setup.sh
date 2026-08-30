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
    CODEX_SKILLS_BACKUP_DIR_OVERRIDE="${2:-$1-backups}" \
        /bin/bash "$SETUP"
}

fresh="$TMP_ROOT/fresh/skills"
source_system_before=$(snapshot_tree "$source_dir/.system")
run_setup "$fresh" >/dev/null
[ "$(readlink "$fresh")" = "$source_dir" ]
[ -f "$fresh/example/SKILL.md" ]
[ -e "$fresh/.system" ]
run_setup "$fresh" >/dev/null
[ "$(readlink "$fresh")" = "$source_dir" ]
[ "$source_system_before" = "$(snapshot_tree "$source_dir/.system")" ]

physical="$TMP_ROOT/physical/skills"
mkdir -p "$physical/example" "$TMP_ROOT/archive-system"
printf '%s\n' keep >"$physical/example/local"
ln -s "$TMP_ROOT/archive-system" "$physical/.system"
ln -s "$source_dir/example" "$physical/legacy-child"
run_setup "$physical" "$TMP_ROOT/physical/backups" >/dev/null
[ "$(readlink "$physical")" = "$source_dir" ]
backup=$(find "$TMP_ROOT/physical/backups" -mindepth 1 -maxdepth 1 -name 'skills.symlink-install.*' -print -quit)
[ -n "$backup" ] && [ -f "$backup/example/local" ] && [ "$(readlink "$backup/.system")" = "$TMP_ROOT/archive-system" ]
[ "$(readlink "$backup/legacy-child")" = "$source_dir/example" ]

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
    run_setup "$target" "$TMP_ROOT/$kind/backups" >/dev/null
    [ "$(readlink "$target")" = "$source_dir" ]
    original_backup=$(find "$TMP_ROOT/$kind/backups" -mindepth 1 -maxdepth 1 -name 'skills.symlink-install.*' -print -quit)
    [ -L "$original_backup" ]
    [ "$(readlink "$original_backup")" = "$original_target" ]
done

unknown="$TMP_ROOT/unknown/skills"
mkdir -p "$unknown" "$TMP_ROOT/unknown/backups"
printf '%s\n' preserve >"$unknown/unknown-data"
run_setup "$unknown" "$TMP_ROOT/unknown/backups" >/dev/null
[ "$(readlink "$unknown")" = "$source_dir" ]
unknown_backup=$(find "$TMP_ROOT/unknown/backups" -mindepth 1 -maxdepth 1 -name 'skills.symlink-install.*' -print -quit)
[ "$(cat "$unknown_backup/unknown-data")" = preserve ]

collision="$TMP_ROOT/collision/skills"
mkdir -p "$collision" "$TMP_ROOT/collision/backups"
printf '%s\n' old >"$collision/old"
printf '%s\n' existing >"$TMP_ROOT/collision/backups/skills.symlink-install.fixed.1"
SKILLS_SETUP_BACKUP_TIMESTAMP_OVERRIDE=fixed SKILLS_SETUP_BACKUP_PID_OVERRIDE=1 \
    run_setup "$collision" "$TMP_ROOT/collision/backups" >/dev/null
[ -f "$TMP_ROOT/collision/backups/skills.symlink-install.fixed.1" ]
[ -d "$TMP_ROOT/collision/backups/skills.symlink-install.fixed.1.1" ]

rollback="$TMP_ROOT/rollback/skills"
mkdir -p "$rollback" "$TMP_ROOT/rollback/backups"
printf '%s\n' preserve >"$rollback/data"
printf '%s\n' existing >"$TMP_ROOT/rollback/backups/existing"
set +e
SKILLS_SETUP_FAIL_AFTER=1 run_setup "$rollback" "$TMP_ROOT/rollback/backups" >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ -d "$rollback" ] && [ "$(cat "$rollback/data")" = preserve ]
[ ! -L "$rollback" ] && [ "$(cat "$TMP_ROOT/rollback/backups/existing")" = existing ]
[ -z "$(find "$TMP_ROOT/rollback/backups" -mindepth 1 -maxdepth 1 -name 'skills.symlink-install.*' -print -quit)" ]
[ "$(cat "$source_dir/.system/state")" = opaque ]

backup_failure="$TMP_ROOT/backup-failure/skills"
mkdir -p "$(dirname "$backup_failure")" "$TMP_ROOT/backup-failure/backups" "$TMP_ROOT/backup-failure-source"
ln -s "$TMP_ROOT/backup-failure-source" "$backup_failure"
backup_failure_target=$(readlink "$backup_failure")
printf '%s\n' existing >"$TMP_ROOT/backup-failure/backups/existing"
set +e
SKILLS_SETUP_FAIL_BACKUP=1 run_setup "$backup_failure" "$TMP_ROOT/backup-failure/backups" >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ -L "$backup_failure" ] && [ "$(readlink "$backup_failure")" = "$backup_failure_target" ]
[ "$(cat "$TMP_ROOT/backup-failure/backups/existing")" = existing ]
[ -z "$(find "$TMP_ROOT/backup-failure/backups" -mindepth 1 -maxdepth 1 -name 'skills.symlink-install.*' -print -quit)" ]

missing="$TMP_ROOT/missing/.codex/skills"
missing_parent=$(dirname "$missing")
set +e
SKILLS_SETUP_FAIL_AFTER=1 run_setup "$missing" "$TMP_ROOT/missing/.codex/backups" >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ ! -e "$missing" ] && [ ! -L "$missing" ]
[ ! -e "$missing_parent" ]
[ ! -e "$TMP_ROOT/missing/.codex/backups" ]
[ -z "$(find "$TMP_ROOT/missing" -name '.skills*' -print -quit 2>/dev/null)" ]

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
