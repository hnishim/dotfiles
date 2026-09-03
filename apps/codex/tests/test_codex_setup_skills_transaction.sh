#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
CODEX_SETUP="$DOTFILES_ROOT/apps/codex/codex-setup.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/codex-skills-transaction-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

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

fixture_harness="$TMP_ROOT/harness"
codex_home="$TMP_ROOT/home/.codex"
target="$codex_home/skills"
backups="$codex_home/backups"
archive_system="$TMP_ROOT/archive-system"
fake_bin="$TMP_ROOT/bin"
fake_apps="$TMP_ROOT/apps"
fake_support="$TMP_ROOT/support"
fake_launch_agents="$TMP_ROOT/launch-agents"
fake_logs="$TMP_ROOT/logs"
fake_cache="$TMP_ROOT/cache"
legacy_custom="$codex_home/custom-instructions-sync"
legacy_skills="$codex_home/skills-notion-sync"

mkdir -p "$fixture_harness/custom-instructions" "$fixture_harness/hooks/runtime" \
    "$fixture_harness/skills/example" "$fixture_harness/skills/writing-references" \
    "$fixture_harness/skills/.system/nested" \
    "$fixture_harness/agents" "$target/legacy" "$backups" "$archive_system" \
    "$legacy_custom" "$legacy_skills/example" "$fake_bin"
cp "$DOTFILES_ROOT/../harness/transaction.py" "$fixture_harness/transaction.py"
printf '%s\n' custom >"$fixture_harness/custom-instructions/custom-instructions.md"
printf '%s\n' openai >"$fixture_harness/custom-instructions/openai-instructions.md"
printf '%s\n' profile >"$fixture_harness/custom-instructions/user-profile.md"
printf '%s\n' skill >"$fixture_harness/skills/example/SKILL.md"
printf '%s\n' reference >"$fixture_harness/skills/writing-references/example.md"
printf '%s\n' plugin >"$fixture_harness/skills/.system/.codex-system-skills.marker"
printf '%s\n' opaque >"$fixture_harness/skills/.system/state"
printf '%s\n' nested >"$fixture_harness/skills/.system/nested/state"
printf '%s\n' '{}' >"$fixture_harness/hooks/hooks.json.tmpl"
for name in fixture-agent-a fixture-agent-b; do
    printf 'name = "%s"\ndescription = "test"\nmodel = "test"\nmodel_reasoning_effort = "low"\ndeveloper_instructions = "test"\n' \
        "$name" >"$fixture_harness/agents/$name.toml"
done

printf '%s\n' archive >"$archive_system/state"
printf '%s\n' old >"$target/legacy/old.txt"
ln -s "$fixture_harness/skills/example" "$target/legacy-child"
ln -s "$archive_system" "$target/.system"
printf '%s\n' legacy-custom >"$legacy_custom/custom-instructions.md"
printf '%s\n' legacy-profile >"$legacy_custom/user-profile.md"
printf '%s\n' legacy-skill >"$legacy_skills/example/SKILL.md"
printf '%s\n' existing >"$backups/existing"

fake_swiftc="$fake_bin/fake-swiftc"
printf '%s\n' '#!/bin/bash' 'output=' \
    'while [ "$#" -gt 0 ]; do' \
    '    if [ "$1" = "-o" ]; then output="$2"; shift 2; else shift; fi' \
    'done' \
    'mkdir -p "$(dirname "$output")"' \
    'exec >"$output"' \
    "printf '%s\\n' '#!/bin/bash'" \
    "printf '%s\\n' 'if [ -n \"\${FAKE_HELPER_EVENT_LOG:-}\" ]; then'" \
    "printf '%s\\n' '    printf \"%s\\\\n\" \"\$1\" >>\"\$FAKE_HELPER_EVENT_LOG\"'" \
    "printf '%s\\n' 'fi'" \
    "printf '%s\\n' 'case \"\$1\" in'" \
    "printf '%s\\n' '--status)'" \
    "printf '%s\\n' 'if [ -n \"\$FAKE_HELPER_STATE\" ] && [ -f \"\$FAKE_HELPER_STATE\" ] && /usr/bin/grep -Fxq mismatch \"\$FAKE_HELPER_STATE\"; then'" \
    "printf '%s\\n' \"printf '%s\\\\n' 'source=$fixture_harness/custom-instructions'\"" \
    "printf '%s\\n' \"printf '%s\\\\n' 'skills=$fixture_harness/skills'\"" \
    "printf '%s\\n' \"printf '%s\\\\n' 'output=/nonexistent-home'\"" \
    "printf '%s\\n' \"printf '%s\\\\n' 'mirror=/nonexistent-mirror'\"" \
    "printf '%s\\n' 'elif [ -n \"\$FAKE_HELPER_STATE\" ] && [ -f \"\$FAKE_HELPER_STATE\" ] && /usr/bin/grep -Fxq legacy \"\$FAKE_HELPER_STATE\"; then'" \
    "printf '%s\\n' '    exit 1'" \
    "printf '%s\\n' 'else'" \
    "printf '%s\\n' \"printf '%s\\\\n' 'source=$fixture_harness/custom-instructions'\"" \
    "printf '%s\\n' \"printf '%s\\\\n' 'skills=$fixture_harness/skills'\"" \
    "printf '%s\\n' \"printf '%s\\\\n' 'output=$codex_home'\"" \
    "printf '%s\\n' \"printf '%s\\\\n' 'mirror=$fake_support/mirrors'\"" \
    "printf '%s\\n' 'fi'" \
    "printf '%s\\n' ';;'" \
    "printf '%s\\n' '--sync)'" \
    "printf '%s\\n' \"mkdir -p '$fake_support/mirrors/custom-instructions-sync' '$fake_support/mirrors/skills-notion-sync/example' '$fake_support/mirrors/skills-notion-sync/writing-references'\"" \
    "printf '%s\\n' \"printf '%s\\\\n\\\\n%s\\\\n' custom openai >'$fake_support/mirrors/custom-instructions-sync/custom-instructions.md'\"" \
    "printf '%s\\n' \"printf '%s\\\\n' profile >'$fake_support/mirrors/custom-instructions-sync/user-profile.md'\"" \
    "printf '%s\\n' \"printf '%s\\\\n' skill >'$fake_support/mirrors/skills-notion-sync/example/SKILL.md'\"" \
    "printf '%s\\n' \"printf '%s\\\\n' reference >'$fake_support/mirrors/skills-notion-sync/writing-references/example.md'\"" \
    "printf '%s\\n' ';;'" \
    "printf '%s\\n' '--authorize)'" \
    "printf '%s\\n' \"printf '%s\\\\n' authorized >\\\"\$FAKE_HELPER_STATE\\\"\"" \
    "printf '%s\\n' \"printf '%s\\\\n' authorize >>\\\"\$FAKE_AUTH_LOG\\\"\"" \
    "printf '%s\\n' ';;'" \
    "printf '%s\\n' '*) exit 1 ;;'" \
    "printf '%s\\n' 'esac'" \
    '>\"$output\"' \
    'chmod 755 "$output"' \
    'exit 0' >"$fake_swiftc"
chmod 755 "$fake_swiftc"

printf '%s\n' '#!/bin/bash' \
    'if [ "$1" = "--find" ] && [ "$2" = "swiftc" ]; then' \
    "    printf '%s\\n' '$fake_swiftc'" \
    '    exit 0' \
    'fi' \
    'exit 1' >"$fake_bin/xcrun"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$fake_bin/codesign"
printf '%s\n' '#!/bin/bash' 'rm -rf -- "$2"' 'cp -R -- "$1" "$2"' >"$fake_bin/ditto"
chmod 755 "$fake_bin/xcrun" "$fake_bin/codesign" "$fake_bin/ditto"

target_before=$(snapshot_tree "$target")
agents_target="$codex_home/agents"
agents_before=$(snapshot_tree "$agents_target")
agents_manifest="$codex_home/AGENTS.md"
agents_manifest_before=$(snapshot_tree "$agents_manifest")
backups_before=$(snapshot_tree "$backups")
system_before=$(snapshot_tree "$fixture_harness/skills/.system")
legacy_custom_before=$(snapshot_tree "$legacy_custom")
legacy_skills_before=$(snapshot_tree "$legacy_skills")
printf '%s\n' mismatch >"$TMP_ROOT/helper-state"
AUTH_LOG="$TMP_ROOT/authorize.log"
HELPER_EVENT_LOG="$TMP_ROOT/helper-events.log"
GATE_EVENT_LOG="$TMP_ROOT/gate-events.log"
: >"$AUTH_LOG"
: >"$HELPER_EVENT_LOG"
: >"$GATE_EVENT_LOG"
set +e
CODEX_HARNESS_PREPARE_ONLY=1 \
PATH="$fake_bin:$PATH" \
HOME="$TMP_ROOT/home" \
CODEX_HARNESS_ROOT_OVERRIDE="$fixture_harness" \
CODEX_HOME_DIR_OVERRIDE="$codex_home" \
CUSTOM_INSTRUCTIONS_APPLICATIONS_DIR_OVERRIDE="$fake_apps" \
CUSTOM_INSTRUCTIONS_SUPPORT_DIR_OVERRIDE="$fake_support" \
LAUNCH_AGENTS_DIR_OVERRIDE="$fake_launch_agents" \
CUSTOM_INSTRUCTIONS_LOG_DIR_OVERRIDE="$fake_logs" \
CUSTOM_INSTRUCTIONS_MODULE_CACHE_OVERRIDE="$fake_cache" \
NTN_EXECUTABLE_OVERRIDE="$TMP_ROOT/missing-ntn" \
FAKE_HELPER_STATE="$TMP_ROOT/helper-state" \
FAKE_AUTH_LOG="$AUTH_LOG" \
FAKE_HELPER_EVENT_LOG="$HELPER_EVENT_LOG" \
FAKE_GATE_EVENT_LOG="$GATE_EVENT_LOG" \
CODEX_SYSTEM_SKILLS_RECOGNITION_COMMAND='printf "%s\\n" system-skills-gate >>"$FAKE_GATE_EVENT_LOG"; exit 1' \
    /bin/bash "$CODEX_SETUP" >"$TMP_ROOT/codex-setup.log" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
[ "$(wc -l <"$AUTH_LOG" | tr -d ' ')" -eq 0 ]
[ "$(cat "$TMP_ROOT/helper-state")" = mismatch ]
[ "$(cat "$HELPER_EVENT_LOG")" = $'--status\n--status' ]
[ ! -s "$GATE_EVENT_LOG" ]
[ "$(snapshot_tree "$target")" = "$target_before" ]
[ "$(snapshot_tree "$agents_target")" = "$agents_before" ]
[ "$(snapshot_tree "$agents_manifest")" = "$agents_manifest_before" ]
[ "$(snapshot_tree "$backups")" = "$backups_before" ]
[ "$(snapshot_tree "$fixture_harness/skills/.system")" = "$system_before" ]
[ "$(snapshot_tree "$legacy_custom")" = "$legacy_custom_before" ]
[ "$(snapshot_tree "$legacy_skills")" = "$legacy_skills_before" ]
[ ! -e "$fake_support" ]
[ -d "$target" ] && [ ! -L "$target" ]
[ "$(readlink "$target/.system")" = "$archive_system" ]
[ "$(readlink "$target/legacy-child")" = "$fixture_harness/skills/example" ]
[ -z "$(find "$backups" -mindepth 1 -maxdepth 1 -name 'skills.symlink-install.*' -print -quit)" ]

printf '%s\n' authorized >"$TMP_ROOT/helper-state"
: >"$AUTH_LOG"
: >"$HELPER_EVENT_LOG"
: >"$GATE_EVENT_LOG"
set +e
CODEX_HARNESS_PREPARE_ONLY=1 \
PATH="$fake_bin:$PATH" \
HOME="$TMP_ROOT/home" \
CODEX_HARNESS_ROOT_OVERRIDE="$fixture_harness" \
CODEX_HOME_DIR_OVERRIDE="$codex_home" \
CUSTOM_INSTRUCTIONS_APPLICATIONS_DIR_OVERRIDE="$fake_apps" \
CUSTOM_INSTRUCTIONS_SUPPORT_DIR_OVERRIDE="$fake_support" \
LAUNCH_AGENTS_DIR_OVERRIDE="$fake_launch_agents" \
CUSTOM_INSTRUCTIONS_LOG_DIR_OVERRIDE="$fake_logs" \
CUSTOM_INSTRUCTIONS_MODULE_CACHE_OVERRIDE="$fake_cache" \
NTN_EXECUTABLE_OVERRIDE="$TMP_ROOT/missing-ntn" \
FAKE_HELPER_STATE="$TMP_ROOT/helper-state" \
FAKE_AUTH_LOG="$AUTH_LOG" \
FAKE_HELPER_EVENT_LOG="$HELPER_EVENT_LOG" \
FAKE_GATE_EVENT_LOG="$GATE_EVENT_LOG" \
CODEX_SYSTEM_SKILLS_RECOGNITION_COMMAND='printf "%s\\n" system-skills-gate >>"$FAKE_GATE_EVENT_LOG"; exit 1' \
    /bin/bash "$CODEX_SETUP" >"$TMP_ROOT/mismatch-codex-setup.log" 2>&1
mismatch_status=$?
set -e
[ "$mismatch_status" -ne 0 ]
[ "$(wc -l <"$AUTH_LOG" | tr -d ' ')" -eq 0 ]
[ "$(cat "$TMP_ROOT/helper-state")" = authorized ]
[ "$(cat "$HELPER_EVENT_LOG")" = $'--status\n--status\n--sync' ]
[ "$(cat "$GATE_EVENT_LOG")" = system-skills-gate ]
[ "$(snapshot_tree "$target")" = "$target_before" ]
[ "$(snapshot_tree "$agents_target")" = "$agents_before" ]
[ "$(snapshot_tree "$agents_manifest")" = "$agents_manifest_before" ]

external_support="$TMP_ROOT/external-support"
mkdir -p "$external_support"
printf '%s\n' external >"$external_support/marker"
external_support_before=$(snapshot_tree "$external_support")
ln -s "$external_support" "$fake_support"
set +e
PATH="$fake_bin:$PATH" \
HOME="$TMP_ROOT/home" \
CODEX_HARNESS_ROOT_OVERRIDE="$fixture_harness" \
CODEX_HOME_DIR_OVERRIDE="$codex_home" \
CUSTOM_INSTRUCTIONS_APPLICATIONS_DIR_OVERRIDE="$fake_apps" \
CUSTOM_INSTRUCTIONS_SUPPORT_DIR_OVERRIDE="$fake_support" \
LAUNCH_AGENTS_DIR_OVERRIDE="$fake_launch_agents" \
CUSTOM_INSTRUCTIONS_LOG_DIR_OVERRIDE="$fake_logs" \
CUSTOM_INSTRUCTIONS_MODULE_CACHE_OVERRIDE="$fake_cache" \
NTN_EXECUTABLE_OVERRIDE="$TMP_ROOT/missing-ntn" \
FAKE_HELPER_STATE="$TMP_ROOT/helper-state" \
FAKE_AUTH_LOG="$AUTH_LOG" \
CODEX_SYSTEM_SKILLS_RECOGNITION_COMMAND='true' \
    /bin/bash "$CODEX_SETUP" >"$TMP_ROOT/symlink-support.log" 2>&1
symlink_status=$?
set -e
[ "$symlink_status" -ne 0 ]
grep -Fq 'Application Supportフォルダーがsymlinkのため停止します' "$TMP_ROOT/symlink-support.log"
[ -L "$fake_support" ]
[ "$(readlink "$fake_support")" = "$external_support" ]
[ "$(snapshot_tree "$external_support")" = "$external_support_before" ]

printf '%s\n' '[PASS] codex setup Skills transaction gate rollback'
