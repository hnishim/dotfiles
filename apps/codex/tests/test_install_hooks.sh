#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
HARNESS_ROOT="${CODEX_HARNESS_ROOT_OVERRIDE:-$(cd "$DOTFILES_ROOT/.." && pwd)/harness}"
INSTALLER="$DOTFILES_ROOT/apps/codex/install-codex-hooks.py"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/install-hooks-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

run_install() {
    /usr/bin/python3 "$INSTALLER" "$1"
}

run_install_with_source() {
    local home="$1"
    local source="$2"
    local template="$3"
    HOOKS_SOURCE_ROOT_OVERRIDE="$source" \
    HOOKS_TEMPLATE_OVERRIDE="$template" \
        run_install "$home"
}

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
        kind = "symlink"
        value = "link:" + os.readlink(path)
    elif stat.S_ISREG(info.st_mode):
        kind = "file"
        value = "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
    elif stat.S_ISDIR(info.st_mode):
        kind = "directory"
        value = ""
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

for name in gh_normal_context_guard.py textlint-boundary.py textlint-pretool-hook.py textlint-posttool-hook.py; do
    [ -f "$HARNESS_ROOT/hooks/runtime/$name" ]
    [ ! -L "$HARNESS_ROOT/hooks/runtime/$name" ]
done

home="$TMP_ROOT/first"
mkdir -p "$home"
run_install "$home" >"$TMP_ROOT/first.log"
[ -L "$home/hooks" ]
[ "$(readlink "$home/hooks")" = "$HARNESS_ROOT/hooks/runtime" ]
[ -L "$home/hooks.json" ]
[ "$(readlink "$home/hooks.json")" = "$HARNESS_ROOT/hooks/.runtime/hooks.json" ]
/usr/bin/python3 -m json.tool "$HARNESS_ROOT/hooks/.runtime/hooks.json" >/dev/null
/usr/bin/python3 - "$HARNESS_ROOT/hooks/.runtime/hooks.json" "$HARNESS_ROOT/hooks/runtime" <<'PY'
import json
import sys
from pathlib import Path

config = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
runtime = str(Path(sys.argv[2]))
expected = {
    "PreToolUse": [
        {
            "matcher": "^Bash$",
            "hooks": [{
                "type": "command",
                "command": f"/usr/bin/python3 {runtime}/gh_normal_context_guard.py",
                "timeout": 5,
                "statusMessage": "Checking GitHub CLI execution context",
            }],
        },
        {
            "matcher": ".*",
            "hooks": [{
                "type": "command",
                "command": f"/usr/bin/python3 {runtime}/textlint-pretool-hook.py",
                "timeout": 120,
                "statusMessage": "Notionへ渡す文章をtextlintで整えています",
            }],
        },
    ],
    "PostToolUse": [{
        "matcher": ".*",
        "hooks": [{
            "type": "command",
            "command": f"/usr/bin/python3 {runtime}/textlint-posttool-hook.py",
            "timeout": 120,
            "statusMessage": "ローカル文章ファイルをtextlintで整えています",
        }],
    }],
}
assert config["hooks"] == expected
PY

first_hooks_inode=$(stat -f '%i' "$home/hooks")
first_json_inode=$(stat -f '%i' "$home/hooks.json")
first_runtime_inode=$(stat -f '%i' "$HARNESS_ROOT/hooks/.runtime/hooks.json")
run_install "$home" >"$TMP_ROOT/first-repeat.log"
[ "$(stat -f '%i' "$home/hooks")" = "$first_hooks_inode" ]
[ "$(stat -f '%i' "$home/hooks.json")" = "$first_json_inode" ]
[ "$(stat -f '%i' "$HARNESS_ROOT/hooks/.runtime/hooks.json")" = "$first_runtime_inode" ]

legacy="$TMP_ROOT/legacy"
mkdir -p "$legacy"
ln -s "$DOTFILES_ROOT/codex/hooks" "$legacy/hooks"
ln -s "$DOTFILES_ROOT/codex/hooks.json" "$legacy/hooks.json"
run_install "$legacy" >"$TMP_ROOT/legacy.log"
[ "$(readlink "$legacy/hooks")" = "$HARNESS_ROOT/hooks/runtime" ]
[ "$(readlink "$legacy/hooks.json")" = "$HARNESS_ROOT/hooks/.runtime/hooks.json" ]
[ -d "$legacy/backups" ]

source_missing="$TMP_ROOT/source-missing"
mkdir -p "$source_missing"
cp "$HARNESS_ROOT/hooks/hooks.json.tmpl" "$source_missing/hooks.json.tmpl"
if run_install_with_source "$TMP_ROOT/missing-source" "$source_missing" "$source_missing/hooks.json.tmpl" >"$TMP_ROOT/missing-source.log" 2>&1; then
    printf '%s\n' '[FAIL] missing hooks source unexpectedly succeeded' >&2
    exit 1
fi
[ ! -e "$TMP_ROOT/missing-source/hooks" ]
[ ! -e "$TMP_ROOT/missing-source/hooks.json" ]
[ ! -e "$TMP_ROOT/missing-source/.runtime/hooks.json" ]

invalid="$TMP_ROOT/invalid-template"
mkdir -p "$invalid/runtime"
cp -R "$HARNESS_ROOT/hooks/runtime" "$invalid/runtime"
printf '%s\n' '{invalid' >"$invalid/hooks.json.tmpl"
if run_install_with_source "$TMP_ROOT/invalid-home" "$invalid" "$invalid/hooks.json.tmpl" >"$TMP_ROOT/invalid.log" 2>&1; then
    printf '%s\n' '[FAIL] invalid hooks template unexpectedly succeeded' >&2
    exit 1
fi
[ ! -e "$TMP_ROOT/invalid-home/hooks" ]
[ ! -e "$TMP_ROOT/invalid-home/hooks.json" ]

broken="$TMP_ROOT/broken"
mkdir -p "$broken"
ln -s "$TMP_ROOT/does-not-exist" "$broken/hooks"
if run_install "$broken" >"$TMP_ROOT/broken.log" 2>&1; then
    printf '%s\n' '[FAIL] broken hooks link unexpectedly succeeded' >&2
    exit 1
fi
[ "$(readlink "$broken/hooks")" = "$TMP_ROOT/does-not-exist" ]
[ ! -e "$broken/hooks.json" ]

json_broken="$TMP_ROOT/json-broken"
mkdir -p "$json_broken"
ln -s "$TMP_ROOT/missing-hooks-json" "$json_broken/hooks.json"
if run_install "$json_broken" >"$TMP_ROOT/json-broken.log" 2>&1; then
    printf '%s\n' '[FAIL] broken hooks.json link unexpectedly succeeded' >&2
    exit 1
fi
[ "$(readlink "$json_broken/hooks.json")" = "$TMP_ROOT/missing-hooks-json" ]
[ ! -e "$json_broken/hooks" ]

json_directory="$TMP_ROOT/json-directory"
mkdir -p "$json_directory/hooks.json"
if run_install "$json_directory" >"$TMP_ROOT/json-directory.log" 2>&1; then
    printf '%s\n' '[FAIL] hooks.json directory conflict unexpectedly succeeded' >&2
    exit 1
fi
[ -d "$json_directory/hooks.json" ]
[ ! -e "$json_directory/hooks" ]

missing_parent="$TMP_ROOT/missing-parent/a/b/home"
run_install "$missing_parent" >"$TMP_ROOT/missing-parent.log"
[ -L "$missing_parent/hooks" ]
[ -L "$missing_parent/hooks.json" ]
[ -f "$HARNESS_ROOT/hooks/.runtime/hooks.json" ]

differing="$TMP_ROOT/differing"
mkdir -p "$differing"
ln -s "$TMP_ROOT/other-hooks" "$differing/hooks"
ln -s "$TMP_ROOT/other-hooks.json" "$differing/hooks.json"
if run_install "$differing" >"$TMP_ROOT/differing.log" 2>&1; then
    printf '%s\n' '[FAIL] differing hooks links unexpectedly succeeded' >&2
    exit 1
fi
[ "$(readlink "$differing/hooks")" = "$TMP_ROOT/other-hooks" ]
[ "$(readlink "$differing/hooks.json")" = "$TMP_ROOT/other-hooks.json" ]

directory_conflict="$TMP_ROOT/directory-conflict"
mkdir -p "$directory_conflict/hooks" "$directory_conflict/hooks.json"
if run_install "$directory_conflict" >"$TMP_ROOT/directory-conflict.log" 2>&1; then
    printf '%s\n' '[FAIL] directory hook conflicts unexpectedly succeeded' >&2
    exit 1
fi
[ -d "$directory_conflict/hooks" ]
[ -d "$directory_conflict/hooks.json" ]

backup_failure="$TMP_ROOT/backup-failure"
backup_failure_source="$TMP_ROOT/backup-failure-source"
mkdir -p "$backup_failure/backups" "$backup_failure_source"
cp -R "$HARNESS_ROOT/hooks/runtime" "$backup_failure_source/runtime"
cp "$HARNESS_ROOT/hooks/hooks.json.tmpl" "$backup_failure_source/hooks.json.tmpl"
mkdir -p "$backup_failure_source/.runtime"
printf '%s\n' generated-before >"$backup_failure_source/.runtime/hooks.json"
chmod 640 "$backup_failure_source/.runtime/hooks.json"
backup_failure_runtime_inode=$(stat -f '%i' "$backup_failure_source/.runtime/hooks.json")
ln -s "$DOTFILES_ROOT/codex/hooks" "$backup_failure/hooks"
ln -s "$DOTFILES_ROOT/codex/hooks.json" "$backup_failure/hooks.json"
printf '%s\n' keep >"$backup_failure/backups/existing"
backup_inode=$(stat -f '%i' "$backup_failure/backups/existing")
set +e
HOOKS_INSTALL_FAIL_BACKUP=1 run_install_with_source "$backup_failure" "$backup_failure_source" "$backup_failure_source/hooks.json.tmpl" >"$TMP_ROOT/backup-failure.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ "$(readlink "$backup_failure/hooks")" = "$DOTFILES_ROOT/codex/hooks" ]
[ "$(readlink "$backup_failure/hooks.json")" = "$DOTFILES_ROOT/codex/hooks.json" ]
[ "$(cat "$backup_failure/backups/existing")" = keep ]
[ "$(stat -f '%i' "$backup_failure/backups/existing")" = "$backup_inode" ]
[ "$(cat "$backup_failure_source/.runtime/hooks.json")" = generated-before ]
[ "$(stat -f '%i' "$backup_failure_source/.runtime/hooks.json")" = "$backup_failure_runtime_inode" ]
[ "$(stat -f '%p' "$backup_failure_source/.runtime/hooks.json")" = 100640 ]
[ "$(find "$backup_failure/backups" -mindepth 1 -maxdepth 1 \( -name 'hooks*symlink-install*' -o -name 'hooks.json*symlink-install*' \) -print | wc -l | tr -d ' ')" = 0 ]

backup_snapshot_home="$TMP_ROOT/backup-snapshot-home"
backup_snapshot_source="$TMP_ROOT/backup-snapshot-source"
mkdir -p "$backup_snapshot_home/backups" "$backup_snapshot_source"
cp -R "$HARNESS_ROOT/hooks/runtime" "$backup_snapshot_source/runtime"
cp "$HARNESS_ROOT/hooks/hooks.json.tmpl" "$backup_snapshot_source/hooks.json.tmpl"
mkdir -p "$backup_snapshot_source/.runtime"
printf '%s\n' generated-before >"$backup_snapshot_source/.runtime/hooks.json"
chmod 640 "$backup_snapshot_source/.runtime/hooks.json"
ln -s "$DOTFILES_ROOT/codex/hooks" "$backup_snapshot_home/hooks"
ln -s "$DOTFILES_ROOT/codex/hooks.json" "$backup_snapshot_home/hooks.json"
printf '%s\n' existing >"$backup_snapshot_home/backups/existing"
chmod 640 "$backup_snapshot_home/backups/existing"
snapshot_state \
    "home=$backup_snapshot_home" \
    "source=$backup_snapshot_source" \
    "backups=$backup_snapshot_home/backups" >"$TMP_ROOT/backup-snapshot.before"
set +e
HOOKS_INSTALL_FAIL_BACKUP=1 run_install_with_source "$backup_snapshot_home" "$backup_snapshot_source" "$backup_snapshot_source/hooks.json.tmpl" >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
snapshot_state \
    "home=$backup_snapshot_home" \
    "source=$backup_snapshot_source" \
    "backups=$backup_snapshot_home/backups" >"$TMP_ROOT/backup-snapshot.after"
cmp -s "$TMP_ROOT/backup-snapshot.before" "$TMP_ROOT/backup-snapshot.after"

conflict="$TMP_ROOT/conflict"
mkdir -p "$conflict"
printf '%s\n' preserve >"$conflict/hooks"
inode=$(stat -f '%i' "$conflict/hooks")
if run_install "$conflict" >"$TMP_ROOT/conflict.log" 2>&1; then
    printf '%s\n' '[FAIL] hooks conflict unexpectedly succeeded' >&2
    exit 1
fi
[ "$(cat "$conflict/hooks")" = preserve ]
[ "$(stat -f '%i' "$conflict/hooks")" = "$inode" ]
[ ! -e "$conflict/hooks.json" ]
[ ! -e "$conflict/.runtime/hooks.json" ]

json_conflict="$TMP_ROOT/json-conflict"
mkdir -p "$json_conflict"
printf '%s\n' preserve >"$json_conflict/hooks.json"
json_inode=$(stat -f '%i' "$json_conflict/hooks.json")
if run_install "$json_conflict" >"$TMP_ROOT/json-conflict.log" 2>&1; then
    printf '%s\n' '[FAIL] hooks.json conflict unexpectedly succeeded' >&2
    exit 1
fi
[ "$(cat "$json_conflict/hooks.json")" = preserve ]
[ "$(stat -f '%i' "$json_conflict/hooks.json")" = "$json_inode" ]
[ ! -e "$json_conflict/hooks" ]
[ ! -e "$json_conflict/.runtime/hooks.json" ]

rollback="$TMP_ROOT/rollback"
rollback_source="$TMP_ROOT/rollback-source"
mkdir -p "$rollback" "$rollback/backups" "$rollback_source"
cp -R "$HARNESS_ROOT/hooks/runtime" "$rollback_source/runtime"
cp "$HARNESS_ROOT/hooks/hooks.json.tmpl" "$rollback_source/hooks.json.tmpl"
mkdir -p "$rollback_source/.runtime"
printf '%s\n' old-generated >"$rollback_source/.runtime/hooks.json"
chmod 640 "$rollback_source/.runtime/hooks.json"
rollback_runtime_inode=$(stat -f '%i' "$rollback_source/.runtime/hooks.json")
printf '%s\n' existing >"$rollback/backups/existing"
rollback_backup_inode=$(stat -f '%i' "$rollback/backups/existing")
ln -s "$DOTFILES_ROOT/codex/hooks" "$rollback/hooks"
ln -s "$DOTFILES_ROOT/codex/hooks.json" "$rollback/hooks.json"
snapshot_state \
    "home=$rollback" \
    "source=$rollback_source" \
    "backups=$rollback/backups" >"$TMP_ROOT/rollback.before"
set +e
HOOKS_INSTALL_FAIL_AFTER=1 run_install_with_source "$rollback" "$rollback_source" "$rollback_source/hooks.json.tmpl" >"$TMP_ROOT/rollback.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ "$(readlink "$rollback/hooks")" = "$DOTFILES_ROOT/codex/hooks" ]
[ "$(readlink "$rollback/hooks.json")" = "$DOTFILES_ROOT/codex/hooks.json" ]
[ "$(cat "$rollback_source/.runtime/hooks.json")" = old-generated ]
[ "$(stat -f '%i' "$rollback_source/.runtime/hooks.json")" = "$rollback_runtime_inode" ]
[ "$(stat -f '%p' "$rollback_source/.runtime/hooks.json")" = 100640 ]
[ "$(cat "$rollback/backups/existing")" = existing ]
[ "$(stat -f '%i' "$rollback/backups/existing")" = "$rollback_backup_inode" ]
[ "$(find "$rollback/backups" -mindepth 1 -maxdepth 1 -name 'hooks*symlink-install*' -o -name 'hooks.json*symlink-install*' | wc -l | tr -d ' ')" = 0 ]
snapshot_state \
    "home=$rollback" \
    "source=$rollback_source" \
    "backups=$rollback/backups" >"$TMP_ROOT/rollback.after"
cmp -s "$TMP_ROOT/rollback.before" "$TMP_ROOT/rollback.after"

printf '%s\n' '[PASS] hooks installer scenarios'
