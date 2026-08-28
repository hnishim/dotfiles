#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
SETUP="$DOTFILES_ROOT/skills/skills-setup.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/skills-setup-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

snapshot_state() {
    /usr/bin/python3 - "$@" <<'PY'
import hashlib
import os
import stat
import sys
from pathlib import Path

rows = []
def add(label, path, relative):
    info = path.lstat()
    mode = stat.S_IMODE(info.st_mode)
    if stat.S_ISLNK(info.st_mode):
        kind, value = "symlink", "link:" + os.readlink(path)
    elif stat.S_ISREG(info.st_mode):
        kind, value = "file", "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
    elif stat.S_ISDIR(info.st_mode):
        kind, value = "directory", ""
    else:
        raise SystemExit(f"unsupported state: {path}")
    rows.append(f"{label}/{relative}|{kind}|{mode:o}|{info.st_ino}|{value}")

for spec in sys.argv[1:]:
    label, raw = spec.split("=", 1)
    root = Path(raw)
    if not os.path.lexists(root):
        rows.append(f"{label}/.|missing")
        continue
    add(label, root, ".")
    if root.is_dir() and not root.is_symlink():
        for path in sorted(root.rglob("*")):
            add(label, path, path.relative_to(root).as_posix())
print("\n".join(rows))
PY
}

source_dir="$TMP_ROOT/source"
local_dir="$TMP_ROOT/local/skills"
system_dir="$TMP_ROOT/plugin-system"
mkdir -p "$source_dir/example" "$source_dir/notion-molcure" "$source_dir/notion-personal" \
    "$source_dir/draft-proposal" "$source_dir/draft-press-release-qa" \
    "$source_dir/writing-references" "$source_dir/.hidden" "$local_dir" "$system_dir"
printf '%s\n' example >"$source_dir/example/SKILL.md"
printf '%s\n' local >"$source_dir/notion-molcure/SKILL.md"
printf '%s\n' personal >"$source_dir/notion-personal/SKILL.md"
printf '%s\n' proposal >"$source_dir/draft-proposal/SKILL.md"
printf '%s\n' press >"$source_dir/draft-press-release-qa/SKILL.md"
printf '%s\n' reference >"$source_dir/writing-references/prose.md"
printf '%s\n' business >"$source_dir/writing-references/business-email.md"
printf '%s\n' hidden >"$source_dir/.hidden/SKILL.md"
printf '%s\n' plugin >"$system_dir/marker"
printf '%s\n' plugin >"$system_dir/.codex-system-skills.marker"
ln -s "$system_dir" "$local_dir/.system"

ICLOUD_SKILLS_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$local_dir" \
CODEX_SYSTEM_SKILLS_DIR_OVERRIDE="$system_dir" \
    /bin/bash "$SETUP" >"$TMP_ROOT/success.log"
[ -d "$local_dir" ]
[ -L "$local_dir/example" ]
[ -L "$local_dir/notion-molcure" ]
[ -L "$local_dir/notion-personal" ]
[ -L "$local_dir/draft-proposal" ]
[ -L "$local_dir/draft-press-release-qa" ]
[ -L "$local_dir/writing-references" ]
[ -f "$local_dir/notion-molcure/SKILL.md" ]
[ -f "$local_dir/notion-personal/SKILL.md" ]
[ -f "$local_dir/draft-proposal/SKILL.md" ]
[ -f "$local_dir/draft-press-release-qa/SKILL.md" ]
[ "$(readlink "$local_dir/notion-molcure")" = "$source_dir/notion-molcure" ]
[ "$(readlink "$local_dir/notion-personal")" = "$source_dir/notion-personal" ]
[ "$(readlink "$local_dir/draft-proposal")" = "$source_dir/draft-proposal" ]
[ "$(readlink "$local_dir/draft-press-release-qa")" = "$source_dir/draft-press-release-qa" ]
[ "$(readlink "$local_dir/writing-references")" = "$source_dir/writing-references" ]
[ "$(cat "$local_dir/writing-references/business-email.md")" = business ]
[ ! -e "$local_dir/.hidden" ]
[ "$(readlink "$local_dir/.system")" = "$system_dir" ]
[ "$(cat "$local_dir/.system/marker")" = plugin ]

system_inode=$(stat -f '%i' "$local_dir/.system")
example_inode=$(stat -f '%i' "$local_dir/example")
ICLOUD_SKILLS_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$local_dir" \
CODEX_SYSTEM_SKILLS_DIR_OVERRIDE="$system_dir" \
    /bin/bash "$SETUP" >"$TMP_ROOT/repeat.log"
[ "$(stat -f '%i' "$local_dir/.system")" = "$system_inode" ]
[ "$(stat -f '%i' "$local_dir/example")" = "$example_inode" ]

conflict="$TMP_ROOT/conflict"
mkdir -p "$conflict"
printf '%s\n' preserve >"$conflict/writing-references"
inode=$(stat -f '%i' "$conflict/writing-references")
set +e
ICLOUD_SKILLS_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$conflict" \
CODEX_SYSTEM_SKILLS_DIR_OVERRIDE="$system_dir" \
    /bin/bash "$SETUP" >"$TMP_ROOT/conflict.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ "$(cat "$conflict/writing-references")" = preserve ]
[ "$(stat -f '%i' "$conflict/writing-references")" = "$inode" ]
[ ! -e "$conflict/example" ]
[ ! -e "$conflict/notion-molcure" ]

legacy_parent="$TMP_ROOT/legacy-parent"
legacy="$legacy_parent/skills"
mkdir -p "$legacy_parent/backups"
ln -s "$source_dir" "$legacy"
ICLOUD_SKILLS_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$legacy" \
CODEX_SYSTEM_SKILLS_DIR_OVERRIDE="$system_dir" \
CODEX_SKILLS_BACKUP_DIR_OVERRIDE="$TMP_ROOT/legacy-parent/backups" \
    /bin/bash "$SETUP" >"$TMP_ROOT/legacy.log"
[ -d "$legacy" ]
[ -L "$legacy/example" ]
[ "$(readlink "$legacy/example")" = "$source_dir/example" ]
[ -L "$legacy/.system" ]
[ "$(readlink "$legacy/.system")" = "$system_dir" ]
[ "$(readlink "$legacy/notion-molcure")" = "$source_dir/notion-molcure" ]
[ "$(readlink "$legacy/notion-personal")" = "$source_dir/notion-personal" ]
[ "$(readlink "$legacy/draft-proposal")" = "$source_dir/draft-proposal" ]
[ "$(readlink "$legacy/draft-press-release-qa")" = "$source_dir/draft-press-release-qa" ]
[ "$(readlink "$legacy/writing-references")" = "$source_dir/writing-references" ]
[ "$(cat "$legacy/writing-references/business-email.md")" = business ]
[ -n "$(find "$TMP_ROOT/legacy-parent/backups" -mindepth 1 -maxdepth 1 -print -quit)" ]
[ -L "$(find "$TMP_ROOT/legacy-parent/backups" -mindepth 1 -maxdepth 1 -type l -print -quit)" ]
[ "$(readlink "$(find "$TMP_ROOT/legacy-parent/backups" -mindepth 1 -maxdepth 1 -type l -print -quit)")" = "$source_dir" ]

legacy_rollback="$TMP_ROOT/legacy-rollback"
mkdir -p "$TMP_ROOT/legacy-rollback-backups"
ln -s "$source_dir" "$legacy_rollback"
printf '%s\n' existing >"$TMP_ROOT/legacy-rollback-backups/existing"
legacy_backup_inode=$(stat -f '%i' "$TMP_ROOT/legacy-rollback-backups/existing")
legacy_root_inode=$(stat -f '%i' "$legacy_rollback")
snapshot_state \
    "root=$legacy_rollback" \
    "backups=$TMP_ROOT/legacy-rollback-backups" >"$TMP_ROOT/legacy-rollback.before"
set +e
SKILLS_SETUP_FAIL_AFTER=1 \
ICLOUD_SKILLS_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$legacy_rollback" \
CODEX_SYSTEM_SKILLS_DIR_OVERRIDE="$system_dir" \
CODEX_SKILLS_BACKUP_DIR_OVERRIDE="$TMP_ROOT/legacy-rollback-backups" \
    /bin/bash "$SETUP" >"$TMP_ROOT/legacy-rollback.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ -L "$legacy_rollback" ]
[ "$(readlink "$legacy_rollback")" = "$source_dir" ]
[ "$(stat -f '%i' "$legacy_rollback")" = "$legacy_root_inode" ]
[ "$(cat "$TMP_ROOT/legacy-rollback-backups/existing")" = existing ]
[ "$(stat -f '%i' "$TMP_ROOT/legacy-rollback-backups/existing")" = "$legacy_backup_inode" ]
[ "$(find "$TMP_ROOT/legacy-rollback-backups" -mindepth 1 -maxdepth 1 -type l -o -type d | wc -l | tr -d ' ')" = 0 ]
snapshot_state \
    "root=$legacy_rollback" \
    "backups=$TMP_ROOT/legacy-rollback-backups" >"$TMP_ROOT/legacy-rollback.after"
cmp -s "$TMP_ROOT/legacy-rollback.before" "$TMP_ROOT/legacy-rollback.after"

legacy_backup_failure="$TMP_ROOT/legacy-backup-failure"
mkdir -p "$TMP_ROOT/legacy-backup-failure-backups"
ln -s "$source_dir" "$legacy_backup_failure"
printf '%s\n' existing >"$TMP_ROOT/legacy-backup-failure-backups/existing"
backup_inode=$(stat -f '%i' "$TMP_ROOT/legacy-backup-failure-backups/existing")
snapshot_state \
    "root=$legacy_backup_failure" \
    "backups=$TMP_ROOT/legacy-backup-failure-backups" >"$TMP_ROOT/legacy-backup-failure.before"
set +e
SKILLS_SETUP_FAIL_BACKUP=1 \
ICLOUD_SKILLS_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$legacy_backup_failure" \
CODEX_SYSTEM_SKILLS_DIR_OVERRIDE="$system_dir" \
CODEX_SKILLS_BACKUP_DIR_OVERRIDE="$TMP_ROOT/legacy-backup-failure-backups" \
    /bin/bash "$SETUP" >"$TMP_ROOT/legacy-backup-failure.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ -L "$legacy_backup_failure" ]
[ "$(readlink "$legacy_backup_failure")" = "$source_dir" ]
[ "$(cat "$TMP_ROOT/legacy-backup-failure-backups/existing")" = existing ]
[ "$(stat -f '%i' "$TMP_ROOT/legacy-backup-failure-backups/existing")" = "$backup_inode" ]
snapshot_state \
    "root=$legacy_backup_failure" \
    "backups=$TMP_ROOT/legacy-backup-failure-backups" >"$TMP_ROOT/legacy-backup-failure.after"
cmp -s "$TMP_ROOT/legacy-backup-failure.before" "$TMP_ROOT/legacy-backup-failure.after"

rollback="$TMP_ROOT/rollback"
mkdir -p "$rollback" "$rollback/.system"
printf '%s\n' preserve >"$rollback/.system/keep"
set +e
SKILLS_SETUP_FAIL_AFTER=1 \
ICLOUD_SKILLS_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$rollback" \
CODEX_SYSTEM_SKILLS_DIR_OVERRIDE="$system_dir" \
    /bin/bash "$SETUP" >"$TMP_ROOT/rollback.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ -f "$rollback/.system/keep" ]
[ ! -e "$rollback/example" ]
[ ! -e "$rollback/notion-molcure" ]

missing_system="$TMP_ROOT/missing-system"
mkdir -p "$missing_system/source" "$missing_system/local"
printf '%s\n' source >"$missing_system/source/example"
if ICLOUD_SKILLS_DIR_OVERRIDE="$missing_system/source" \
   LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$missing_system/local" \
   CODEX_SYSTEM_SKILLS_DIR_OVERRIDE="$missing_system/missing" \
   /bin/bash "$SETUP" >"$TMP_ROOT/missing-system.log" 2>&1; then
    printf '%s\n' '[FAIL] missing .system unexpectedly succeeded' >&2
    exit 1
fi
[ ! -e "$missing_system/local/example" ]

bad_system="$TMP_ROOT/bad-system"
mkdir -p "$bad_system/source/example" "$bad_system/local" "$bad_system/provider"
printf '%s\n' source >"$bad_system/source/example/SKILL.md"
printf '%s\n' wrong >"$bad_system/provider/marker"
printf '%s\n' wrong >"$bad_system/provider/.codex-system-skills.marker"
if CODEX_SYSTEM_SKILLS_EXPECTED_MARKER=plugin \
   ICLOUD_SKILLS_DIR_OVERRIDE="$bad_system/source" \
   LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$bad_system/local" \
   CODEX_SYSTEM_SKILLS_DIR_OVERRIDE="$bad_system/provider" \
   /bin/bash "$SETUP" >"$TMP_ROOT/bad-system.log" 2>&1; then
    printf '%s\n' '[FAIL] unrecognized .system provider unexpectedly succeeded' >&2
    exit 1
fi
[ ! -e "$bad_system/local/example" ]

archive_default="$TMP_ROOT/dev/Archives/git-reorg/2026-08-28/skills"
archive_default_system="$archive_default/.system"
archive_default_source="$TMP_ROOT/archive-default-source"
archive_default_local="$TMP_ROOT/archive-default-local"
mkdir -p "$TMP_ROOT/dev/harness" "$archive_default_system" "$archive_default_source/example"
printf '%s\n' archive >"$archive_default_source/example/SKILL.md"
printf '%s\n' archive >"$archive_default_system/marker"
printf '%s\n' archive >"$archive_default_system/.codex-system-skills.marker"
CODEX_HARNESS_ROOT_OVERRIDE="$TMP_ROOT/dev/harness" \
ICLOUD_SKILLS_DIR_OVERRIDE="$archive_default_source" \
LOCAL_CODEX_SKILLS_DIR_OVERRIDE="$archive_default_local" \
    /bin/bash "$SETUP" >"$TMP_ROOT/archive-default.log"
[ "$(readlink "$archive_default_local/.system")" = "$archive_default_system" ]
[ "$(readlink "$archive_default_local/example")" = "$archive_default_source/example" ]

printf '%s\n' '[PASS] skills setup scenarios'
