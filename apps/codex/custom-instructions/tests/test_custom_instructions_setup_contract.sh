#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SETUP="$SCRIPT_DIR/../custom-instructions-setup.sh"

# Namespace migration is part of this setup contract. Run the focused
# namespace test first so a stale active identifier fails before fixture work.
bash "$SCRIPT_DIR/test-namespace-contract.sh"

python3 - "$SETUP" <<'PY'
import re
import sys
from pathlib import Path

setup = Path(sys.argv[1]).resolve()
assert setup.is_file(), f"missing planned setup: {setup}"
source = setup.read_text(encoding="utf-8")
assert re.search(r"SCRIPT_DIR=\$\(get_script_dir\)", source)
assert "LABEL='my.notion.sync'" in source
assert "BOOKMARK_DOMAIN='my.notion.sync.helper'" in source
assert "com.hnishim.custom-instructions-sync" not in source
assert "CustomInstructionsSync" in source
assert "sync-custom-instructions" in source
assert 'status_output=$' in source
for required in (
    'MIRROR_ROOT="$APPLICATION_SUPPORT_DIR/mirrors"',
    'MIRROR_LAYOUT_SOURCE="$ASSET_DIR/mirror-layout.sh"',
    'source "$MIRROR_LAYOUT_SOURCE"',
    '"$DEFAULTS_EXECUTABLE" delete "$BOOKMARK_DOMAIN"',
):
    assert required in source, required
for forbidden in ("remove_legacy_mirror", "LEGACY_MIRROR_DIR", "LEGACY_SKILLS_MIRROR_DIR"):
    assert forbidden not in source, forbidden

# The moved setup must resolve its own assets from SCRIPT_DIR; it must not
# fall back to the former apps/codex root-relative locations.
for legacy in ("$SCRIPT_DIR/../custom-instructions-sync", "$SCRIPT_DIR/../install-codex-hooks.py"):
    assert legacy not in source, legacy

print("[PASS] custom-instructions setup path and identifier contract")
PY

# Exercise the moved setup with a fake compiled helper.  The fixture models the
# only permitted authorization transition: status failure -> one authorize ->
# status success.  A resolved but mismatching status must stop without sync.
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/custom-instructions-setup-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT
fixture_harness="$TMP_ROOT/harness"
codex_home="$TMP_ROOT/home/.codex"
fake_bin="$TMP_ROOT/bin"
fake_apps="$TMP_ROOT/apps"
fake_support="$TMP_ROOT/support"
fake_launch_agents="$TMP_ROOT/launch-agents"
fake_logs="$TMP_ROOT/logs"
fake_cache="$TMP_ROOT/cache"
mkdir -p "$fixture_harness/custom-instructions" "$fixture_harness/skills/example" \
    "$fixture_harness/skills/writing-references" "$fake_bin"
printf '%s\n' custom >"$fixture_harness/custom-instructions/custom-instructions.md"
printf '%s\n' openai >"$fixture_harness/custom-instructions/openai-instructions.md"
printf '%s\n' profile >"$fixture_harness/custom-instructions/user-profile.md"
printf '%s\n' skill >"$fixture_harness/skills/example/SKILL.md"
printf '%s\n' reference >"$fixture_harness/skills/writing-references/example.md"

fake_swiftc="$fake_bin/fake-swiftc"
printf '%s\n' '#!/bin/bash' 'output=' \
    'while [ "$#" -gt 0 ]; do' \
    '    if [ "$1" = "-o" ]; then output="$2"; shift 2; else shift; fi' \
    'done' \
    'mkdir -p "$(dirname "$output")"' \
    'exec >"$output"' \
    'printf "%s\\n" "#!/bin/bash" "case \"\${1:-}\" in"' \
    'printf "%s\\n" "--status)"' \
    "printf '%s\\n' 'if [ -n \"\${FAKE_SETUP_EVENTS:-}\" ]; then printf \"%s\\n\" --status >>\"\$FAKE_SETUP_EVENTS\"; fi'" \
    "printf '%s\\n' 'if [ -z \"\${FAKE_SETUP_STATE_FILE:-}\" ] || [ ! -s \"\$FAKE_SETUP_STATE_FILE\" ]; then exit 1; fi'" \
    "printf '%s\\n' 'case \"\$(cat \"\$FAKE_SETUP_STATE_FILE\")\" in'" \
    "printf '%s\\n' 'authorized)'" \
    "printf '%s\\n' \"printf '%s\\n' source=$fixture_harness/custom-instructions\"" \
    "printf '%s\\n' \"printf '%s\\n' skills=$fixture_harness/skills\"" \
    "printf '%s\\n' \"printf '%s\\n' output=$codex_home\"" \
    "printf '%s\\n' \"printf '%s\\n' mirror=$fake_support/mirrors\"" \
    "printf '%s\\n' ';;'" \
    "printf '%s\\n' 'output-only)'" \
    "printf '%s\\n' \"printf '%s\\n' source=$fixture_harness/custom-instructions\"" \
    "printf '%s\\n' \"printf '%s\\n' skills=$fixture_harness/skills\"" \
    "printf '%s\\n' \"printf '%s\\n' output=/wrong-output\"" \
    "printf '%s\\n' \"printf '%s\\n' mirror=$fake_support/mirrors\"" \
    "printf '%s\\n' ';;'" \
    "printf '%s\\n' 'mirror-only)'" \
    "printf '%s\\n' \"printf '%s\\n' source=$fixture_harness/custom-instructions\"" \
    "printf '%s\\n' \"printf '%s\\n' skills=$fixture_harness/skills\"" \
    "printf '%s\\n' \"printf '%s\\n' output=$codex_home\"" \
    "printf '%s\\n' \"printf '%s\\n' mirror=/wrong-mirror\"" \
    "printf '%s\\n' ';;'" \
    "printf '%s\\n' '*) exit 1 ;;'" \
    "printf '%s\\n' 'esac'" \
    "printf '%s\\n' ';;'" \
    "printf '%s\\n' '--authorize)'" \
    "printf '%s\\n' 'printf \"authorized\\n\" >\"\$FAKE_SETUP_STATE_FILE\"'" \
    "printf '%s\\n' 'printf \"authorize:%s\\n\" \"\$#\" >>\"\$FAKE_SETUP_AUTH\"'" \
    "printf '%s\\n' ';;'" \
    "printf '%s\\n' '--sync)'" \
    "printf '%s\\n' 'printf \"sync\\n\" >>\"\$FAKE_SETUP_EVENTS\"'" \
    "printf '%s\\n' \"printf '%s\\n\\n%s\\n\\n%s\\n' custom openai profile >'$codex_home/AGENTS.md'\"" \
    "printf '%s\\n' ';;'" \
    "printf '%s\\n' '*) exit 1 ;;'" \
    "printf '%s\\n' 'esac'" >"$fake_swiftc"
chmod 755 "$fake_swiftc"
printf '%s\n' '#!/bin/bash' \
    '[ "$1" = --find ] && [ "$2" = swiftc ] && { printf "%s\\n" "$FAKE_SWIFTC"; exit 0; }' \
    'exit 1' >"$fake_bin/xcrun"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$fake_bin/codesign"
printf '%s\n' '#!/bin/bash' 'rm -rf -- "$2"' 'cp -R -- "$1" "$2"' >"$fake_bin/ditto"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$fake_bin/plutil"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$fake_bin/launchctl"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$fake_bin/defaults"
printf '%s\n' '#!/bin/bash' 'exit 0' >"$fake_bin/PlistBuddy"
cat >"$fake_bin/security" <<'SECURITY_FAKE'
#!/bin/bash
set -euo pipefail
service=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -s) service=${2:-}; shift 2 ;;
        *) shift ;;
    esac
done
printf 'security:%s\n' "$service" >>"${FAKE_LAUNCH_SECURITY_EVENTS:?}"
case "$service" in
    my.notion.personal) printf '%s' "${FAKE_PERSONAL_TOKEN:?}" ;;
    *) exit 44 ;;
esac
SECURITY_FAKE
chmod 755 "$fake_bin/security"
chmod 755 "$fake_bin"/*

cat >"$TMP_ROOT/fake-ntn" <<'NTN_FAKE'
#!/bin/bash
set -euo pipefail
command=${1:-}
shift || true
token=${NOTION_API_TOKEN:-}
account=none
if [ "$token" = "${FAKE_PERSONAL_TOKEN:-}" ] && [ -n "$token" ]; then
    account=personal
elif [ "$token" = "${FAKE_MOLCURE_TOKEN:-}" ] && [ -n "$token" ]; then
    account=molcure
elif [ "${FAKE_NTN_SETUP_ACCOUNT:-}" = personal ]; then
    account=personal
elif [ "${FAKE_NTN_SETUP_ACCOUNT:-}" = molcure ]; then
    account=molcure
fi
if [ "$command" != auth ] && [ -n "${FAKE_NTN_ENFORCE_ACCOUNT:-}" ] && [ "$account" != "$FAKE_NTN_ENFORCE_ACCOUNT" ]; then
    printf 'wrong-account:%s:%s\n' "$account" "$command" >>"${FAKE_NTN_EVENTS:?}"
    exit 91
fi
case "$command" in
    whoami)
        printf 'whoami:%s\n' "$account" >>"${FAKE_NTN_EVENTS:?}"
        if [ "${1:-}" = --json ]; then
            case "$account" in
                molcure) printf '{"object":"bot","id":"bot-molcure","type":"bot","bot":{"owner":{"type":"user","user":{"id":"user-molcure"}},"workspace_id":"55555555555555555555555555555555"}}\n' ;;
                personal) printf '{"object":"bot","id":"bot-personal","type":"bot","bot":{"owner":{"type":"user","user":{"id":"user-personal"}},"workspace_id":"44444444444444444444444444444444"}}\n' ;;
                *) exit 92 ;;
            esac
        fi
        ;;
    auth)
        if [ "${1:-}" = token ]; then
            printf 'credential:default\n' >>"${FAKE_NTN_EVENTS:?}"
            printf '%s' "${FAKE_MOLCURE_TOKEN:?}"
        fi
        ;;
    api|datasources|pages)
        printf 'notion:%s:%s\n' "$account" "$command" >>"${FAKE_NTN_EVENTS:?}"
        case " $* " in
            *' -X PATCH '*) printf 'write:%s:patch\n' "$account" >>"${FAKE_NTN_EVENTS:?}" ;;
            *' edit '*) printf 'write:%s:edit\n' "$account" >>"${FAKE_NTN_EVENTS:?}" ;;
        esac
        exit 79
        ;;
    *) exit 64 ;;
esac
NTN_FAKE
chmod 755 "$TMP_ROOT/fake-ntn"

export FAKE_MOLCURE_TOKEN='test-molcure-token-never-print'
export FAKE_NTN_EVENTS="$TMP_ROOT/launch-ntn.events"
export FAKE_LAUNCH_SECURITY_EVENTS="$TMP_ROOT/launch-security.events"
mkdir -p "$fake_support"
cat >"$fake_support/notion-pages.conf" <<'MOLCURE_CONFIG'
account_id=molcure
credential_source=ntn-default
expected_user_id=user-molcure
workspace_id=55555555555555555555555555555555
custom_instructions_page_id=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
user_profile_page_id=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB
skills_data_source_id=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC
MOLCURE_CONFIG
chmod 600 "$fake_support/notion-pages.conf"

run_setup() {
    PATH="$fake_bin:$PATH" HOME="$TMP_ROOT/home" FAKE_SWIFTC="$fake_swiftc" \
    FAKE_SETUP_STATE_FILE="$TMP_ROOT/state" FAKE_SETUP_EVENTS="$TMP_ROOT/events" \
    FAKE_SETUP_AUTH="$TMP_ROOT/auth" CUSTOM_INSTRUCTIONS_APPLICATIONS_DIR_OVERRIDE="$fake_apps" \
    CUSTOM_INSTRUCTIONS_SUPPORT_DIR_OVERRIDE="$fake_support" LAUNCH_AGENTS_DIR_OVERRIDE="$fake_launch_agents" \
    CUSTOM_INSTRUCTIONS_LOG_DIR_OVERRIDE="$fake_logs" CUSTOM_INSTRUCTIONS_MODULE_CACHE_OVERRIDE="$fake_cache" \
    CODEX_HARNESS_ROOT_OVERRIDE="$fixture_harness" CODEX_HOME_DIR_OVERRIDE="$codex_home" \
    NTN_EXECUTABLE_OVERRIDE="${SETUP_NTN_OVERRIDE:-$TMP_ROOT/fake-ntn}" \
    NOTION_ACCOUNT_ID_OVERRIDE="${SETUP_ACCOUNT_OVERRIDE:-}" CODEX_HARNESS_PREPARE_ONLY=1 \
        /bin/bash "$SETUP" >"$TMP_ROOT/setup.log" 2>&1 || {
            if [ "${SETUP_ALLOW_FAILURE:-0}" != 1 ]; then
                cat "$TMP_ROOT/setup.log" >&2
            fi
            return 1
        }
}

: >"$TMP_ROOT/events"
: >"$TMP_ROOT/auth"
: >"$TMP_ROOT/state"
run_setup
[ "$(cat "$TMP_ROOT/auth")" = authorize:5 ]
[ "$(cat "$TMP_ROOT/state")" = authorized ]
[ "$(cat "$TMP_ROOT/events")" = $'--status\n--status\nsync' ]

: >"$TMP_ROOT/events"
: >"$TMP_ROOT/auth"
printf '%s\n' authorized >"$TMP_ROOT/state"
run_setup
[ ! -s "$TMP_ROOT/auth" ]
[ "$(cat "$TMP_ROOT/events")" = $'--status\n--status\nsync' ]

assert_path_mismatch_stops_before_sync() {
    local state=$1
    local plist="$fake_launch_agents/my.notion.sync.plist"
    local plist_before="$TMP_ROOT/$state.plist.before"
    : >"$TMP_ROOT/events"
    : >"$TMP_ROOT/auth"
    printf '%s\n' "$state" >"$TMP_ROOT/state"
    printf '%s\n' "existing-$state-plist" >"$plist"
    cp "$plist" "$plist_before"

    set +e
    run_setup
    local setup_status=$?
    set -e
    [ "$setup_status" -ne 0 ]
    [ ! -s "$TMP_ROOT/auth" ]
    [ "$(cat "$TMP_ROOT/events")" = $'--status\n--status' ]
    cmp -s "$plist_before" "$plist"

    rm -f -- "$plist"
    : >"$TMP_ROOT/events"
    : >"$TMP_ROOT/auth"
    set +e
    run_setup
    setup_status=$?
    set -e
    [ "$setup_status" -ne 0 ]
    [ ! -s "$TMP_ROOT/auth" ]
    [ "$(cat "$TMP_ROOT/events")" = $'--status\n--status' ]
    [ ! -e "$plist" ]
}

assert_path_mismatch_stops_before_sync output-only
assert_path_mismatch_stops_before_sync mirror-only

# Verify setup pins the LaunchAgent to MOLCURE, then execute the exact saved
# ProgramArguments and reject any Personal credential, identity, or write.
: >"$TMP_ROOT/launch-ntn.events"
: >"$TMP_ROOT/launch-security.events"
printf '%s\n' authorized >"$TMP_ROOT/state"
export FAKE_PERSONAL_TOKEN='test-personal-token-never-print'
SETUP_NTN_OVERRIDE="$TMP_ROOT/fake-ntn" run_setup
launch_plist="$fake_launch_agents/my.notion.sync.plist"
launch_program=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$launch_plist")
launch_helper=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$launch_plist")
launch_ntn=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$launch_plist")
launch_codex_home=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:3' "$launch_plist")
launch_notion_config=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:4' "$launch_plist")
[ "$launch_ntn" = "$TMP_ROOT/fake-ntn" ]
[ -f "$launch_notion_config" ]
/usr/bin/grep -Fqx 'account_id=molcure' "$launch_notion_config" || {
    printf '[ERROR] LaunchAgent設定がMOLCUREに固定されていません。\n' >&2
    exit 1
}
/usr/bin/grep -Fqx 'credential_source=ntn-default' "$launch_notion_config" || {
    printf '[ERROR] LaunchAgent設定がMOLCUREのntn既定認証を使っていません。\n' >&2
    exit 1
}
/usr/bin/grep -Fqx 'expected_user_id=user-molcure' "$launch_notion_config"
: >"$TMP_ROOT/launch-ntn.events"
: >"$TMP_ROOT/launch-security.events"
set +e
PATH="$fake_bin:$PATH" HOME="$TMP_ROOT/home" FAKE_NTN_ENFORCE_ACCOUNT=molcure \
    FAKE_SETUP_EVENTS="$TMP_ROOT/launch-helper.events" FAKE_SETUP_STATE_FILE="$TMP_ROOT/state" \
    FAKE_SETUP_AUTH="$TMP_ROOT/auth" FAKE_SWIFTC="$fake_swiftc" \
    NOTION_READBACK_WAIT_SECONDS=0 "$launch_program" "$launch_helper" "$launch_ntn" \
    "$launch_codex_home" "$launch_notion_config" >"$TMP_ROOT/launch-run.log" 2>&1
launch_status=$?
set -e
[ "$launch_status" -ne 0 ] || {
    printf '[ERROR] 不完全なLaunchAgent用模擬環境で同期が成功扱いになりました。\n' >&2
    exit 1
}
/usr/bin/grep -Fqx 'credential:default' "$TMP_ROOT/launch-ntn.events" || {
    printf '[ERROR] LaunchAgent実行がMOLCUREのntn既定認証を使いませんでした。\n' >&2
    exit 1
}
/usr/bin/grep -Fqx 'whoami:molcure' "$TMP_ROOT/launch-ntn.events" || {
    printf '[ERROR] LaunchAgent実行時のNotion認証先がMOLCUREではありません。\n' >&2
    exit 1
}
! /usr/bin/grep -q '^wrong-account:' "$TMP_ROOT/launch-ntn.events" &&
! /usr/bin/grep -q '^whoami:personal$' "$TMP_ROOT/launch-ntn.events" &&
! /usr/bin/grep -q '^notion:personal:' "$TMP_ROOT/launch-ntn.events" &&
! /usr/bin/grep -q '^write:' "$TMP_ROOT/launch-ntn.events" || {
    printf '[ERROR] LaunchAgent実行で個人用NotionへのアクセスまたはNotion書き込みを検出しました。\n' >&2
    exit 1
}
[ ! -s "$TMP_ROOT/launch-security.events" ]

assert_setup_rejected() {
    local config_account=$1
    local setup_ntn=$2
    local account_override=$3
    local config="$fake_support/notion-pages.conf"
    local plist="$fake_launch_agents/my.notion.sync.plist"
    local config_before="$TMP_ROOT/rejected-config.before"
    local plist_before="$TMP_ROOT/rejected-plist.before"
    if [ "$config_account" = personal ]; then
        cat >"$config" <<'PERSONAL_CONFIG'
account_id=personal
credential_source=keychain
expected_user_id=user-personal
workspace_id=44444444444444444444444444444444
custom_instructions_page_id=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
user_profile_page_id=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBC
skills_data_source_id=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBD
PERSONAL_CONFIG
        chmod 600 "$config"
    fi
    cp "$config" "$config_before"
    cp "$plist" "$plist_before"
    : >"$TMP_ROOT/launch-ntn.events"
    : >"$TMP_ROOT/launch-security.events"
    set +e
    SETUP_ALLOW_FAILURE=1 SETUP_NTN_OVERRIDE="$setup_ntn" SETUP_ACCOUNT_OVERRIDE="$account_override" run_setup
    local setup_status=$?
    set -e
    [ "$setup_status" -ne 0 ]
    /usr/bin/grep -Fq 'MOLCURE専用' "$TMP_ROOT/setup.log" || {
        printf '[ERROR] セットアップがMOLCURE専用制約を理由に停止しませんでした。\n' >&2
        exit 1
    }
    [ ! -s "$TMP_ROOT/launch-ntn.events" ]
    [ ! -s "$TMP_ROOT/launch-security.events" ]
    cmp -s "$config_before" "$config"
    cmp -s "$plist_before" "$plist"
}

# A personal override, a saved Personal config, and a missing Notion CLI must
# all fail before credentials, Notion access, or LaunchAgent replacement.
assert_setup_rejected molcure "$TMP_ROOT/fake-ntn" personal
assert_setup_rejected personal "$TMP_ROOT/fake-ntn" ''
assert_setup_rejected molcure "$TMP_ROOT/missing-ntn" ''
printf '%s\n' '[PASS] generated LaunchAgent arguments preserve the explicit MOLCURE Notion account'
printf '%s\n' '[PASS] setup rejects Personal account selections/configuration before Notion or LaunchAgent access'
printf '%s\n' '[PASS] setup authorization transaction contract'
