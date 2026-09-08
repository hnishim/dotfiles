#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../../.." && pwd)
HARNESS_ROOT="${CODEX_HARNESS_ROOT_OVERRIDE:-$(cd "$DOTFILES_ROOT/.." && pwd)/harness}"
HOOKS_SETUP="$DOTFILES_ROOT/apps/codex/hooks/hooks-setup.sh"
INSTALLER="$DOTFILES_ROOT/apps/codex/hooks/install-codex-hooks.py"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/install-hooks-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

SOURCE_HARNESS_ROOT="$HARNESS_ROOT"
HARNESS_ROOT="$TMP_ROOT/harness source"
mkdir -p "$HARNESS_ROOT/hooks"
HARNESS_ROOT=$(cd -P -- "$HARNESS_ROOT" && pwd)
cp -R "$SOURCE_HARNESS_ROOT/hooks/runtime" "$HARNESS_ROOT/hooks/"
cp "$SOURCE_HARNESS_ROOT/hooks/hooks.json.tmpl" "$HARNESS_ROOT/hooks/hooks.json.tmpl"

run_install() {
    CODEX_HARNESS_ROOT_OVERRIDE="$HARNESS_ROOT" \
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

# Run the actual Hooks setup script through a temporary repository-shaped path
# with only its Python installer replaced by an argument-recording stub.  This
# proves that Codex reaches hooks-setup.sh, delegates to the installer, passes
# the resolved Codex home, and propagates installer failure.
[ -f "$HOOKS_SETUP" ]
setup_fixture="$TMP_ROOT/hooks-setup-fixture"
setup_repository="$setup_fixture/repository"
setup_script_dir="$setup_repository/apps/codex/hooks"
setup_home="$setup_fixture/home/.codex"
setup_log="$TMP_ROOT/hooks-setup-args.log"
mkdir -p "$setup_script_dir" "$setup_repository/lib"
ln -s "$HOOKS_SETUP" "$setup_script_dir/hooks-setup.sh"
ln -s "$DOTFILES_ROOT/lib/common.sh" "$setup_repository/lib/common.sh"
/usr/bin/python3 - "$setup_script_dir/install-codex-hooks.py" <<'PY'
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text(
    "#!/usr/bin/env python3\n"
    "import os, sys\n"
    "Path = __import__('pathlib').Path\n"
    "Path(os.environ['HOOKS_SETUP_LOG']).write_text('\\n'.join(sys.argv[1:]) + '\\n', encoding='utf-8')\n"
    "raise SystemExit(31 if os.environ.get('HOOKS_SETUP_FAIL') == '1' else 0)\n",
    encoding="utf-8",
)
path.chmod(0o755)
PY
CODEX_HOME="$setup_home" \
CODEX_HOME_DIR_OVERRIDE="$setup_home" \
CODEX_HARNESS_ROOT_OVERRIDE="$HARNESS_ROOT" \
HOOKS_SETUP_LOG="$setup_log" \
    /bin/bash "$setup_script_dir/hooks-setup.sh"
[ "$(sed -n '1p' "$setup_log")" = "$setup_home" ]
[ "$(wc -l <"$setup_log" | tr -d ' ')" = 1 ]

set +e
CODEX_HOME="$setup_home" \
CODEX_HOME_DIR_OVERRIDE="$setup_home" \
CODEX_HARNESS_ROOT_OVERRIDE="$HARNESS_ROOT" \
HOOKS_SETUP_LOG="$setup_log" \
HOOKS_SETUP_FAIL=1 \
    /bin/bash "$setup_script_dir/hooks-setup.sh" >"$TMP_ROOT/hooks-setup-failure.log" 2>&1
setup_status=$?
set -e
[ "$setup_status" -ne 0 ]

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
import shlex
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
                "command": f"/usr/bin/python3 {shlex.quote(runtime + '/gh_normal_context_guard.py')}",
                "timeout": 5,
                "statusMessage": "Checking GitHub CLI execution context",
            }],
        },
        {
            "matcher": ".*",
            "hooks": [{
                "type": "command",
                "command": f"/usr/bin/python3 {shlex.quote(runtime + '/textlint-pretool-hook.py')}",
                "timeout": 120,
                "statusMessage": "Notionへ渡す文章をtextlintで整えています",
            }],
        },
    ],
    "PostToolUse": [{
        "matcher": ".*",
        "hooks": [{
            "type": "command",
            "command": f"/usr/bin/python3 {shlex.quote(runtime + '/textlint-posttool-hook.py')}",
            "timeout": 120,
            "statusMessage": "ローカル文章ファイルをtextlintで整えています",
        }],
    }],
}
assert config["hooks"] == expected

for entries in config["hooks"].values():
    for entry in entries:
        for hook in entry["hooks"]:
            command = hook["command"]
            parts = shlex.split(command)
            assert len(parts) == 2
            assert parts[0] == "/usr/bin/python3"
            assert parts[1].startswith(runtime + "/")
            assert " " in parts[1]
            assert command != f"/usr/bin/python3 {parts[1]}"
PY

first_hooks_inode=$(stat -f '%i' "$home/hooks")
first_json_inode=$(stat -f '%i' "$home/hooks.json")
first_runtime_inode=$(stat -f '%i' "$HARNESS_ROOT/hooks/.runtime/hooks.json")
run_install "$home" >"$TMP_ROOT/first-repeat.log"
[ "$(stat -f '%i' "$home/hooks")" = "$first_hooks_inode" ]
[ "$(stat -f '%i' "$home/hooks.json")" = "$first_json_inode" ]
[ "$(stat -f '%i' "$HARNESS_ROOT/hooks/.runtime/hooks.json")" = "$first_runtime_inode" ]
[ "$(stat -f '%p' "$HARNESS_ROOT/hooks/.runtime/hooks.json")" = 100600 ]

/usr/bin/python3 - "$HARNESS_ROOT/hooks/hooks.json.tmpl" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
old = "Require normal macOS context before judging GitHub CLI authentication."
new = "Updated hooks config for atomic replacement."
assert old in source
path.write_text(source.replace(old, new), encoding="utf-8")
PY
run_install "$home" >"$TMP_ROOT/changed-template.log"
changed_json_inode=$(stat -f '%i' "$HARNESS_ROOT/hooks/.runtime/hooks.json")
[ "$changed_json_inode" != "$first_runtime_inode" ]
[ "$(stat -f '%p' "$HARNESS_ROOT/hooks/.runtime/hooks.json")" = 100600 ]
/usr/bin/python3 - "$HARNESS_ROOT/hooks/.runtime/hooks.json" <<'PY'
import json
import sys
from pathlib import Path

config = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert config["description"] == "Updated hooks config for atomic replacement."
PY

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

printf '%s\n' '[PASS] hooks installer scenarios'
