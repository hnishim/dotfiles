#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../../.." && pwd)
HARNESS_ROOT="${CODEX_HARNESS_ROOT_OVERRIDE:-$(cd "$DOTFILES_ROOT/.." && pwd)/harness}"
SETUP="$DOTFILES_ROOT/apps/codex/agents/agents-setup.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agents-setup-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

agent_names=(fixture-agent-a fixture-agent-b)
managed_name="${agent_names[0]}"

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

write_agent_set() {
    local directory="$1"
    local value="${2:-test}"
    mkdir -p "$directory"
    for name in "${agent_names[@]}"; do
        printf 'name = "%s"\ndescription = "%s"\nmodel = "test"\nmodel_reasoning_effort = "low"\ndeveloper_instructions = "test"\n' \
            "$name" "$value" >"$directory/$name.toml"
    done
}

write_agent_definition() {
    local directory="$1"
    local name="$2"
    local sandbox_mode="${3:-}"
    mkdir -p "$directory"
    printf 'name = "%s"\ndescription = "test"\nmodel = "test"\nmodel_reasoning_effort = "low"\ndeveloper_instructions = "test"\n' \
        "$name" >"$directory/$name.toml"
    if [ -n "$sandbox_mode" ]; then
        printf 'sandbox_mode = "%s"\n' "$sandbox_mode" >>"$directory/$name.toml"
    fi
}

assert_root_link() {
    local target="$1"
    local source="$2"
    [ -L "$target" ]
    [ "$(readlink "$target")" = "$source" ]
    for name in "${agent_names[@]}"; do
        [ -f "$target/$name.toml" ]
    done
}

python3 - "$HARNESS_ROOT" <<'PY'
import sys
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
paths = sorted((root / "agents").glob("*.toml"))
assert paths, root / "agents"
for path in paths:
    name = path.stem
    assert path.is_file() and not path.is_symlink(), path
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    assert data["name"] == name
    for field in ("description", "model", "model_reasoning_effort", "developer_instructions"):
        assert isinstance(data[field], str) and data[field].strip(), (name, field)
PY

source_dir="$TMP_ROOT/source"
legacy_dir="$TMP_ROOT/legacy"
write_agent_set "$source_dir" current
write_agent_set "$legacy_dir" legacy

# Copy the planned setup into an isolated repository-shaped fixture.  Running
# without source overrides proves that SCRIPT_DIR-relative defaults resolve to
# the fixture Harness and the old dotfiles/codex/agents source, without
# touching the real repository or its Harness.
default_fixture="$TMP_ROOT/default-layout"
mkdir -p "$default_fixture/apps/codex/agents" "$default_fixture/harness/agents" \
    "$default_fixture/codex/agents"
cp "$SETUP" "$default_fixture/apps/codex/agents/agents-setup.sh"
chmod 755 "$default_fixture/apps/codex/agents/agents-setup.sh"
write_agent_set "$default_fixture/harness/agents" harness-default
write_agent_set "$default_fixture/codex/agents" legacy-default
default_fixture_target="$TMP_ROOT/default-layout-home/.codex/agents"
env -u CODEX_AGENTS_SOURCE_DIR_OVERRIDE \
    -u CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE \
    -u CODEX_HARNESS_ROOT_OVERRIDE \
    -u LOCAL_CODEX_AGENTS_DIR_OVERRIDE \
    HOME="$TMP_ROOT/default-layout-home" \
    /bin/bash "$default_fixture/apps/codex/agents/agents-setup.sh" >"$TMP_ROOT/default-layout.log"
assert_root_link "$default_fixture_target" "$default_fixture/harness/agents"
default_legacy_backup=$(find "$TMP_ROOT/default-layout-home/.codex/backups" -mindepth 1 -maxdepth 1 -name 'agents.symlink-install.*' -print -quit 2>/dev/null || true)
[ -z "$default_legacy_backup" ]
default_legacy_home="$TMP_ROOT/default-legacy-home"
mkdir -p "$default_legacy_home/.codex"
ln -s "$default_fixture/codex/agents" "$default_legacy_home/.codex/agents"
env -u CODEX_AGENTS_SOURCE_DIR_OVERRIDE \
    -u CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE \
    -u CODEX_HARNESS_ROOT_OVERRIDE \
    -u LOCAL_CODEX_AGENTS_DIR_OVERRIDE \
    HOME="$default_legacy_home" \
    /bin/bash "$default_fixture/apps/codex/agents/agents-setup.sh" >"$TMP_ROOT/default-legacy-layout.log"
assert_root_link "$default_legacy_home/.codex/agents" "$default_fixture/harness/agents"
default_legacy_backup=$(find "$default_legacy_home/.codex/backups" -mindepth 1 -maxdepth 1 -name 'agents.symlink-install.*' -print -quit)
[ -L "$default_legacy_backup" ]
[ "$(readlink "$default_legacy_backup")" = "$default_fixture/codex/agents" ]

fresh_target="$TMP_ROOT/fresh-home/.codex/agents"
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$fresh_target" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
    /bin/bash "$SETUP" >"$TMP_ROOT/fresh.log"
assert_root_link "$fresh_target" "$source_dir"
fresh_inode=$(stat -f '%i' "$fresh_target")
fresh_before=$(snapshot_state "target=$fresh_target")
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$fresh_target" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
    /bin/bash "$SETUP" >"$TMP_ROOT/repeat.log"
assert_root_link "$fresh_target" "$source_dir"
[ "$(stat -f '%i' "$fresh_target")" = "$fresh_inode" ]
[ "$fresh_before" = "$(snapshot_state "target=$fresh_target")" ]
[ ! -e "$TMP_ROOT/fresh-home/.codex/backups" ]

temporary_collision_parent="$TMP_ROOT/temporary-collision/.codex"
temporary_collision_target="$temporary_collision_parent/agents"
temporary_collision_backups="$temporary_collision_parent/backups"
temporary_collision_link="$temporary_collision_parent/.agents.symlink-install-f1"
mkdir -p "$temporary_collision_backups"
ln -s "$source_dir" "$temporary_collision_link"
printf '%s\n' existing >"$temporary_collision_backups/existing"
temporary_collision_before=$(snapshot_state \
    "parent=$temporary_collision_parent" \
    "target=$temporary_collision_target" \
    "backups=$temporary_collision_backups")
set +e
AGENTS_SETUP_INSTALL_ID_OVERRIDE=f1 \
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$temporary_collision_target" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
CODEX_AGENTS_BACKUP_DIR_OVERRIDE="$temporary_collision_backups" \
    /bin/bash "$SETUP" >"$TMP_ROOT/temporary-collision.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ ! -e "$temporary_collision_target" ]
[ ! -L "$temporary_collision_target" ]
[ "$temporary_collision_before" = "$(snapshot_state \
    "parent=$temporary_collision_parent" \
    "target=$temporary_collision_target" \
    "backups=$temporary_collision_backups")" ]

current_target="$TMP_ROOT/current/.codex/agents"
mkdir -p "$current_target"
for name in "${agent_names[@]}"; do
    ln -s "$source_dir/$name.toml" "$current_target/$name.toml"
done
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$current_target" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
CODEX_AGENTS_BACKUP_DIR_OVERRIDE="$TMP_ROOT/current-backups" \
    /bin/bash "$SETUP" >"$TMP_ROOT/current.log"
assert_root_link "$current_target" "$source_dir"
current_backup=$(find "$TMP_ROOT/current-backups" -mindepth 1 -maxdepth 1 -name 'agents.symlink-install.*' -print -quit)
[ -n "$current_backup" ]
[ -d "$current_backup" ]
for name in "${agent_names[@]}"; do
    [ "$(readlink "$current_backup/$name.toml")" = "$source_dir/$name.toml" ]
done

legacy_children_target="$TMP_ROOT/legacy-children/.codex/agents"
mkdir -p "$legacy_children_target"
for name in "${agent_names[@]}"; do
    ln -s "$legacy_dir/$name.toml" "$legacy_children_target/$name.toml"
done
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$legacy_children_target" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
CODEX_AGENTS_BACKUP_DIR_OVERRIDE="$TMP_ROOT/legacy-children-backups" \
    /bin/bash "$SETUP" >"$TMP_ROOT/legacy-children.log"
assert_root_link "$legacy_children_target" "$source_dir"
legacy_children_backup=$(find "$TMP_ROOT/legacy-children-backups" -mindepth 1 -maxdepth 1 -name 'agents.symlink-install.*' -print -quit)
[ -d "$legacy_children_backup" ]
for name in "${agent_names[@]}"; do
    [ "$(readlink "$legacy_children_backup/$name.toml")" = "$legacy_dir/$name.toml" ]
done

legacy_root_target="$TMP_ROOT/legacy-root/.codex/agents"
mkdir -p "$(dirname "$legacy_root_target")" "$TMP_ROOT/legacy-root-backups"
ln -s "$legacy_dir" "$legacy_root_target"
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$legacy_root_target" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
CODEX_AGENTS_BACKUP_DIR_OVERRIDE="$TMP_ROOT/legacy-root-backups" \
    /bin/bash "$SETUP" >"$TMP_ROOT/legacy-root.log"
assert_root_link "$legacy_root_target" "$source_dir"
legacy_root_backup=$(find "$TMP_ROOT/legacy-root-backups" -mindepth 1 -maxdepth 1 -name 'agents.symlink-install.*' -print -quit)
[ -L "$legacy_root_backup" ]
[ "$(readlink "$legacy_root_backup")" = "$legacy_dir" ]

collision_target="$TMP_ROOT/collision/.codex/agents"
collision_backups="$TMP_ROOT/collision/.codex/backups"
mkdir -p "$(dirname "$collision_target")" "$collision_backups"
ln -s "$legacy_dir" "$collision_target"
collision_name='agents.symlink-install.20260101-000000.fixture'
printf '%s\n' preserve >"$collision_backups/$collision_name"
collision_inode=$(stat -f '%i' "$collision_backups/$collision_name")
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$collision_target" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
CODEX_AGENTS_BACKUP_DIR_OVERRIDE="$collision_backups" \
AGENTS_SETUP_BACKUP_TIMESTAMP_OVERRIDE=20260101-000000 \
AGENTS_SETUP_BACKUP_PID_OVERRIDE=fixture \
    /bin/bash "$SETUP" >"$TMP_ROOT/collision.log"
assert_root_link "$collision_target" "$source_dir"
[ "$(cat "$collision_backups/$collision_name")" = preserve ]
[ "$(stat -f '%i' "$collision_backups/$collision_name")" = "$collision_inode" ]
collision_backup="$collision_backups/$collision_name.1"
[ -L "$collision_backup" ]
[ "$(readlink "$collision_backup")" = "$legacy_dir" ]

for kind in wrong-root regular-file unknown-entry; do
    conflict_target="$TMP_ROOT/$kind/.codex/agents"
    mkdir -p "$(dirname "$conflict_target")"
    case "$kind" in
        wrong-root)
            wrong_dir="$TMP_ROOT/$kind/wrong"
            mkdir -p "$wrong_dir"
            ln -s "$wrong_dir" "$conflict_target"
            ;;
        regular-file)
            printf '%s\n' preserve >"$conflict_target"
            ;;
        unknown-entry)
            mkdir -p "$conflict_target"
            ln -s "$source_dir/$managed_name.toml" "$conflict_target/$managed_name.toml"
            printf '%s\n' preserve >"$conflict_target/unknown"
            ;;
    esac
    before=$(snapshot_state "target=$conflict_target")
    if CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
       LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$conflict_target" \
       CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
       /bin/bash "$SETUP" >"$TMP_ROOT/$kind.log" 2>&1; then
        printf '[FAIL] Agent %s conflict unexpectedly succeeded\n' "$kind" >&2
        exit 1
    fi
    [ "$before" = "$(snapshot_state "target=$conflict_target")" ]
done

for child_kind in unrelated-child broken-child; do
    child_target="$TMP_ROOT/$child_kind/.codex/agents"
    child_backups="$TMP_ROOT/$child_kind/.codex/backups"
    mkdir -p "$child_target" "$child_backups"
    for name in "${agent_names[@]}"; do
        if [ "$name" = "$managed_name" ]; then
            if [ "$child_kind" = unrelated-child ]; then
                unrelated_file="$TMP_ROOT/$child_kind/unrelated/$managed_name.toml"
                mkdir -p "$(dirname "$unrelated_file")"
                printf '%s\n' unrelated >"$unrelated_file"
                ln -s "$unrelated_file" "$child_target/$name.toml"
            else
                ln -s "$TMP_ROOT/$child_kind/missing/$managed_name.toml" "$child_target/$name.toml"
            fi
        else
            ln -s "$source_dir/$name.toml" "$child_target/$name.toml"
        fi
    done
    printf '%s\n' existing >"$child_backups/existing"
    before=$(snapshot_state "target=$child_target" "backups=$child_backups")
    if CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
       LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$child_target" \
       CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
       CODEX_AGENTS_BACKUP_DIR_OVERRIDE="$child_backups" \
       /bin/bash "$SETUP" >"$TMP_ROOT/$child_kind.log" 2>&1; then
        printf '[FAIL] Agent %s child target unexpectedly succeeded\n' "$child_kind" >&2
        exit 1
    fi
    [ "$before" = "$(snapshot_state "target=$child_target" "backups=$child_backups")" ]
done

missing_source="$TMP_ROOT/missing-source"
missing_target="$TMP_ROOT/missing-source-target/.codex/agents"
mkdir -p "$missing_source"
if CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$missing_source" \
   LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$missing_target" \
   CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
   /bin/bash "$SETUP" >"$TMP_ROOT/missing-source.log" 2>&1; then
    printf '%s\n' '[FAIL] missing Agent source unexpectedly succeeded' >&2
    exit 1
fi
grep -Fq "[ERROR] Agent source has no TOML definitions: $missing_source" "$TMP_ROOT/missing-source.log"
[ ! -e "$missing_target" ]

malformed_source="$TMP_ROOT/malformed-source"
malformed_target="$TMP_ROOT/malformed-target/.codex/agents"
write_agent_set "$malformed_source"
printf 'name = "%s"\ndescription = [\n' "$managed_name" >"$malformed_source/$managed_name.toml"
if CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$malformed_source" \
   LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$malformed_target" \
   CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
   /bin/bash "$SETUP" >"$TMP_ROOT/malformed.log" 2>&1; then
    printf '%s\n' '[FAIL] malformed Agent TOML unexpectedly succeeded\n' >&2
    exit 1
fi
[ ! -e "$malformed_target" ]

reviewer_guard_source="$TMP_ROOT/reviewer-guard-source"
reviewer_guard_target="$TMP_ROOT/reviewer-guard-target/.codex/agents"
write_agent_definition "$reviewer_guard_source" reviewer workspace-write
if CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$reviewer_guard_source" \
   LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$reviewer_guard_target" \
   CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
   /bin/bash "$SETUP" >"$TMP_ROOT/reviewer-guard.log" 2>&1; then
    printf '%s\n' '[FAIL] writable reviewer Agent unexpectedly succeeded' >&2
    exit 1
fi
grep -Fq 'read-only Agent lacks sandbox_mode = read-only' "$TMP_ROOT/reviewer-guard.log"
[ ! -e "$reviewer_guard_target" ]

backup_failure_target="$TMP_ROOT/backup-failure/.codex/agents"
backup_failure_backups="$TMP_ROOT/backup-failure/.codex/backups"
mkdir -p "$(dirname "$backup_failure_target")" "$backup_failure_backups"
ln -s "$legacy_dir" "$backup_failure_target"
printf '%s\n' existing >"$backup_failure_backups/existing"
backup_failure_before=$(snapshot_state "target=$backup_failure_target" "backups=$backup_failure_backups")
set +e
AGENTS_SETUP_FAIL_BACKUP=1 \
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$backup_failure_target" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
CODEX_AGENTS_BACKUP_DIR_OVERRIDE="$backup_failure_backups" \
    /bin/bash "$SETUP" >"$TMP_ROOT/backup-failure.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ "$backup_failure_before" = "$(snapshot_state "target=$backup_failure_target" "backups=$backup_failure_backups")" ]

rollback_target="$TMP_ROOT/rollback/.codex/agents"
rollback_backups="$TMP_ROOT/rollback/.codex/backups"
mkdir -p "$rollback_target" "$rollback_backups"
for name in "${agent_names[@]}"; do
    ln -s "$source_dir/$name.toml" "$rollback_target/$name.toml"
done
printf '%s\n' existing >"$rollback_backups/existing"
printf '%s\n' keep >"$TMP_ROOT/rollback/.codex/unrelated"
rollback_before=$(snapshot_state \
    "target=$rollback_target" \
    "backups=$rollback_backups" \
    "unrelated=$TMP_ROOT/rollback/.codex/unrelated")
set +e
AGENTS_SETUP_FAIL_AFTER=1 \
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$rollback_target" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
CODEX_AGENTS_BACKUP_DIR_OVERRIDE="$rollback_backups" \
    /bin/bash "$SETUP" >"$TMP_ROOT/rollback.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
grep -Fq '[ERROR] injected Agent setup failure' "$TMP_ROOT/rollback.log"
[ "$rollback_before" = "$(snapshot_state \
    "target=$rollback_target" \
    "backups=$rollback_backups" \
    "unrelated=$TMP_ROOT/rollback/.codex/unrelated")" ]
for name in "${agent_names[@]}"; do
    [ "$(readlink "$rollback_target/$name.toml")" = "$source_dir/$name.toml" ]
done

missing_target_parent="$TMP_ROOT/failure-missing/.codex"
set +e
AGENTS_SETUP_FAIL_AFTER=1 \
CODEX_AGENTS_SOURCE_DIR_OVERRIDE="$source_dir" \
LOCAL_CODEX_AGENTS_DIR_OVERRIDE="$missing_target_parent/agents" \
CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE="$legacy_dir" \
    /bin/bash "$SETUP" >"$TMP_ROOT/failure-missing.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ ! -e "$missing_target_parent/agents" ]
[ ! -L "$missing_target_parent/agents" ]
[ ! -e "$missing_target_parent" ]
[ ! -L "$missing_target_parent" ]
[ ! -e "$missing_target_parent/backups" ]
[ ! -L "$missing_target_parent/backups" ]

printf '%s\n' '[PASS] agents setup root symlink scenarios'
