#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
HARNESS_ROOT="${CODEX_HARNESS_ROOT_OVERRIDE:-$(cd "$DOTFILES_ROOT/.." && pwd)/harness}"
SETUP="$DOTFILES_ROOT/codex/agents-setup.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agents-setup-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

agent_names=(planner plan-reviewer implementer reviewer git-actions)

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

python3 - "$HARNESS_ROOT" <<'PY'
import hashlib
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
names = ("planner", "plan-reviewer", "implementer", "reviewer", "git-actions")
read_only = {"planner", "plan-reviewer", "reviewer"}
for name in names:
    path = root / "agents" / f"{name}.toml"
    assert path.is_file() and not path.is_symlink(), path
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    assert data["name"] == name
    assert data["description"]
    assert data["model"]
    assert data["model_reasoning_effort"]
    assert data["developer_instructions"]
    if name in read_only:
        assert data.get("sandbox_mode") == "read-only", name
PY

source_dir="$TMP_ROOT/source"
local_dir="$TMP_ROOT/local/agents"
mkdir -p "$source_dir" "$local_dir"
for name in "${agent_names[@]}"; do
    printf 'name = "%s"\ndescription = "test"\nmodel = "test"\nmodel_reasoning_effort = "low"\nsandbox_mode = "read-only"\ndeveloper_instructions = "test"\n' "$name" >"$source_dir/$name.toml"
done

CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$local_dir" \
    /bin/bash "$SETUP" >"$TMP_ROOT/success.log"
for name in "${agent_names[@]}"; do
    [ -L "$local_dir/$name.toml" ]
    [ "$(readlink "$local_dir/$name.toml")" = "$source_dir/$name.toml" ]
done
planner_inode=$(stat -f '%i' "$local_dir/planner.toml")
AGENTS_SETUP_FAIL_AFTER=0 \
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$local_dir" \
    /bin/bash "$SETUP" >"$TMP_ROOT/success-repeat.log"
[ "$(stat -f '%i' "$local_dir/planner.toml")" = "$planner_inode" ]

conflict_source="$TMP_ROOT/conflict-source"
conflict_local="$TMP_ROOT/conflict-local"
mkdir -p "$conflict_source" "$conflict_local"
for name in "${agent_names[@]}"; do
    printf 'name = "%s"\ndescription = "test"\nmodel = "test"\nmodel_reasoning_effort = "low"\nsandbox_mode = "read-only"\ndeveloper_instructions = "test"\n' "$name" >"$conflict_source/$name.toml"
done
printf '%s\n' preserve >"$conflict_local/reviewer.toml"
inode=$(stat -f '%i' "$conflict_local/reviewer.toml")
if CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$conflict_source" \
   LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$conflict_local" \
   /bin/bash "$SETUP" >"$TMP_ROOT/conflict.log" 2>&1; then
    printf '%s\n' '[FAIL] agents conflict unexpectedly succeeded' >&2
    exit 1
fi
[ "$(cat "$conflict_local/reviewer.toml")" = preserve ]
[ "$(stat -f '%i' "$conflict_local/reviewer.toml")" = "$inode" ]
[ ! -e "$conflict_local/planner.toml" ]

for kind in file directory differing broken; do
    case "$kind" in
        file) conflict_path="$TMP_ROOT/$kind/planner.toml"; mkdir -p "$(dirname "$conflict_path")"; printf '%s\n' preserve >"$conflict_path" ;;
        directory) conflict_path="$TMP_ROOT/$kind/planner.toml"; mkdir -p "$conflict_path" ;;
        differing) conflict_path="$TMP_ROOT/$kind/planner.toml"; mkdir -p "$(dirname "$conflict_path")"; ln -s "$TMP_ROOT/$kind/other.toml" "$conflict_path" ;;
        broken) conflict_path="$TMP_ROOT/$kind/planner.toml"; mkdir -p "$(dirname "$conflict_path")"; ln -s "$TMP_ROOT/$kind/missing.toml" "$conflict_path" ;;
    esac
    if CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
       LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$TMP_ROOT/$kind" \
       /bin/bash "$SETUP" >"$TMP_ROOT/$kind.log" 2>&1; then
        printf '[FAIL] agents %s conflict unexpectedly succeeded\n' "$kind" >&2
        exit 1
    fi
    [ -e "$conflict_path" ] || [ -L "$conflict_path" ]
done

missing_source="$TMP_ROOT/missing-source"
missing_local="$TMP_ROOT/missing-local"
mkdir -p "$missing_source" "$missing_local"
for name in planner plan-reviewer implementer reviewer; do
    printf 'name = "%s"\ndescription = "test"\nmodel = "test"\nmodel_reasoning_effort = "low"\nsandbox_mode = "read-only"\ndeveloper_instructions = "test"\n' "$name" >"$missing_source/$name.toml"
done
if CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$missing_source" \
   LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$missing_local" \
   /bin/bash "$SETUP" >"$TMP_ROOT/missing.log" 2>&1; then
    printf '%s\n' '[FAIL] missing source unexpectedly succeeded' >&2
    exit 1
fi
[ ! -e "$missing_local/planner.toml" ]

malformed_source="$TMP_ROOT/malformed-source"
malformed_local="$TMP_ROOT/malformed-local"
mkdir -p "$malformed_source" "$malformed_local"
for name in "${agent_names[@]}"; do
    printf 'name = "%s"\ndescription = "test"\nmodel = "test"\nmodel_reasoning_effort = "low"\nsandbox_mode = "read-only"\ndeveloper_instructions = "test"\n' "$name" >"$malformed_source/$name.toml"
done
printf 'name = "planner"\ndescription = [\n' >"$malformed_source/planner.toml"
if CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$malformed_source" \
   LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$malformed_local" \
   /bin/bash "$SETUP" >"$TMP_ROOT/malformed.log" 2>&1; then
    printf '%s\n' '[FAIL] malformed Agent TOML unexpectedly succeeded' >&2
    exit 1
fi
[ ! -e "$malformed_local/planner.toml" ]

missing_target_source="$TMP_ROOT/missing-target-source"
missing_target_parent="$TMP_ROOT/missing-target-parent"
mkdir -p "$missing_target_source" "$missing_target_parent"
for name in "${agent_names[@]}"; do
    printf 'name = "%s"\ndescription = "test"\nmodel = "test"\nmodel_reasoning_effort = "low"\nsandbox_mode = "read-only"\ndeveloper_instructions = "test"\n' "$name" >"$missing_target_source/$name.toml"
done
set +e
AGENTS_SETUP_FAIL_AFTER=1 \
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$missing_target_source" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$missing_target_parent/agents" \
    /bin/bash "$SETUP" >"$TMP_ROOT/missing-target.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ ! -e "$missing_target_parent/agents" ]

legacy_source="$TMP_ROOT/legacy-source"
legacy_local="$TMP_ROOT/legacy-local"
legacy_target="$TMP_ROOT/legacy-target"
mkdir -p "$legacy_source" "$legacy_local" "$legacy_target" "$TMP_ROOT/legacy-backups"
for name in "${agent_names[@]}"; do
    printf 'name = "%s"\ndescription = "test"\nmodel = "test"\nmodel_reasoning_effort = "low"\nsandbox_mode = "read-only"\ndeveloper_instructions = "test"\n' "$name" >"$legacy_source/$name.toml"
    printf '%s\n' legacy >"$legacy_target/$name.toml"
    ln -s "$legacy_target/$name.toml" "$legacy_local/$name.toml"
done
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$legacy_source" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$legacy_local" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_target" \
CODEX_AGENTS_BACKUP_DIR_OVERRIDE="$TMP_ROOT/legacy-backups" \
    /bin/bash "$SETUP" >"$TMP_ROOT/legacy.log"
for name in "${agent_names[@]}"; do
    [ "$(readlink "$legacy_local/$name.toml")" = "$legacy_source/$name.toml" ]
done
[ "$(find "$TMP_ROOT/legacy-backups" -mindepth 1 -maxdepth 1 -type l | wc -l | tr -d ' ')" = 5 ]
for name in "${agent_names[@]}"; do
    backup=$(find "$TMP_ROOT/legacy-backups" -mindepth 1 -maxdepth 1 -name "$name.toml.symlink-install*" -print -quit)
    [ -n "$backup" ]
    [ "$(readlink "$backup")" = "$legacy_target/$name.toml" ]
done

backup_failure="$TMP_ROOT/backup-failure"
mkdir -p "$backup_failure" "$TMP_ROOT/agent-backups"
for name in "${agent_names[@]}"; do
    ln -s "$legacy_target/$name.toml" "$backup_failure/$name.toml"
done
printf '%s\n' keep >"$TMP_ROOT/agent-backups/existing"
backup_inode=$(stat -f '%i' "$TMP_ROOT/agent-backups/existing")
set +e
AGENTS_SETUP_FAIL_BACKUP=1 \
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$backup_failure" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_target" \
CODEX_AGENTS_BACKUP_DIR_OVERRIDE="$TMP_ROOT/agent-backups" \
    /bin/bash "$SETUP" >"$TMP_ROOT/agent-backup-failure.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
for name in "${agent_names[@]}"; do
    [ "$(readlink "$backup_failure/$name.toml")" = "$legacy_target/$name.toml" ]
done
[ "$(cat "$TMP_ROOT/agent-backups/existing")" = keep ]
[ "$(stat -f '%i' "$TMP_ROOT/agent-backups/existing")" = "$backup_inode" ]

backup_snapshot="$TMP_ROOT/agent-backup-snapshot"
mkdir -p "$backup_snapshot/home/backups" "$backup_snapshot/backup-dir"
for name in "${agent_names[@]}"; do
    ln -s "$legacy_target/$name.toml" "$backup_snapshot/home/$name.toml"
done
printf '%s\n' existing >"$backup_snapshot/home/backups/existing"
chmod 640 "$backup_snapshot/home/backups/existing"
printf '%s\n' preserve >"$backup_snapshot/backup-dir/non-target"
snapshot_state \
    "home=$backup_snapshot/home" \
    "backups=$backup_snapshot/home/backups" \
    "non-target=$backup_snapshot/backup-dir" >"$TMP_ROOT/agent-backup-snapshot.before"
set +e
AGENTS_SETUP_FAIL_BACKUP=1 \
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$backup_snapshot/home" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_target" \
CODEX_AGENTS_BACKUP_DIR_OVERRIDE="$backup_snapshot/home/backups" \
    /bin/bash "$SETUP" >"$TMP_ROOT/agent-backup-snapshot.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
snapshot_state \
    "home=$backup_snapshot/home" \
    "backups=$backup_snapshot/home/backups" \
    "non-target=$backup_snapshot/backup-dir" >"$TMP_ROOT/agent-backup-snapshot.after"
cmp -s "$TMP_ROOT/agent-backup-snapshot.before" "$TMP_ROOT/agent-backup-snapshot.after"

rollback_source="$TMP_ROOT/rollback-source"
rollback_local="$TMP_ROOT/rollback-local"
mkdir -p "$rollback_source" "$rollback_local"
for name in "${agent_names[@]}"; do
    printf 'name = "%s"\ndescription = "test"\nmodel = "test"\nmodel_reasoning_effort = "low"\nsandbox_mode = "read-only"\ndeveloper_instructions = "test"\n' "$name" >"$rollback_source/$name.toml"
done
printf '%s\n' preserve >"$rollback_local/non-target"
mkdir -p "$rollback_local/backups"
printf '%s\n' existing >"$rollback_local/backups/existing"
for name in "${agent_names[@]}"; do
    ln -s "$legacy_target/$name.toml" "$rollback_local/$name.toml"
done
for name in "${agent_names[@]}"; do
    stat -f '%i' "$rollback_local/$name.toml" >"$TMP_ROOT/rollback-$name.inode"
done
rollback_backup_inode=$(stat -f '%i' "$rollback_local/backups/existing")
snapshot_state \
    "local=$rollback_local" \
    "source=$rollback_source" >"$TMP_ROOT/agent-rollback.before"
set +e
AGENTS_SETUP_FAIL_AFTER=2 \
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$rollback_source" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$rollback_local" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_target" \
    /bin/bash "$SETUP" >"$TMP_ROOT/rollback.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
for name in "${agent_names[@]}"; do
    [ -L "$rollback_local/$name.toml" ]
    [ "$(readlink "$rollback_local/$name.toml")" = "$legacy_target/$name.toml" ]
    [ "$(stat -f '%i' "$rollback_local/$name.toml")" = "$(cat "$TMP_ROOT/rollback-$name.inode")" ]
done
[ "$(cat "$rollback_local/non-target")" = preserve ]
[ "$(cat "$rollback_local/backups/existing")" = existing ]
[ "$(stat -f '%i' "$rollback_local/backups/existing")" = "$rollback_backup_inode" ]
[ "$(find "$rollback_local/backups" -mindepth 1 -maxdepth 1 -type f -name existing | wc -l | tr -d ' ')" = 1 ]
snapshot_state \
    "local=$rollback_local" \
    "source=$rollback_source" >"$TMP_ROOT/agent-rollback.after"
cmp -s "$TMP_ROOT/agent-rollback.before" "$TMP_ROOT/agent-rollback.after"

printf '%s\n' '[PASS] agents setup scenarios'
