#!/bin/bash

set -euo pipefail

# Executable acceptance tests for the openai-instructions.md source boundary.
# The helper fixture is deliberately test-only because this host cannot build
# the production Swift helper with its installed SDK/toolchain combination.

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../../.." && pwd)
SYNC_SCRIPT="$DOTFILES_ROOT/apps/codex/custom-instructions/sync-custom-instructions"
FIXTURE="$SCRIPT_DIR/fixtures/openai-helper-fixture.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/openai-instructions-contract.XXXXXX")
case "${TMP_ROOT:?}" in
    "${TMPDIR:-/tmp}"/openai-instructions-contract.*) ;;
    *) printf '[ERROR] 想定外のテスト一時パスです: %s\n' "$TMP_ROOT" >&2; exit 1 ;;
esac
cleanup_test_tmp() { rm -rf -- "$TMP_ROOT"; }
trap cleanup_test_tmp EXIT

SOURCE_DIR="$TMP_ROOT/source"
CODEX_HOME="$TMP_ROOT/codex"
MIRROR_ROOT="$TMP_ROOT/support/mirrors"
CONFIG_DIR="$TMP_ROOT/config"
PAGES_DIR="$TMP_ROOT/pages"
EDIT_LOG="$TMP_ROOT/edits.log"
CONFIG="$CONFIG_DIR/notion-pages.conf"
HELPER="$TMP_ROOT/helper"
NTN="$TMP_ROOT/ntn"

mkdir -p "$SOURCE_DIR" "$CODEX_HOME" "$MIRROR_ROOT" "$CONFIG_DIR" "$PAGES_DIR"
printf '%s\n' '# custom marker' >"$SOURCE_DIR/custom-instructions.md"
printf '%s\n' '# shared marker' '## スキルの作成・更新と検証' >"$SOURCE_DIR/openai-instructions.md"
printf '%s\n' '# profile marker' >"$SOURCE_DIR/user-profile.md"
cp "$FIXTURE" "$HELPER"
chmod 755 "$HELPER"

cat >"$CONFIG" <<'EOF'
workspace_id=11111111111111111111111111111111
custom_instructions_page_id=22222222222222222222222222222222
user_profile_page_id=22222222222222222222222222222223
skills_data_source_id=33333333333333333333333333333333
EOF
chmod 600 "$CONFIG"

cat >"$NTN" <<'EOF'
#!/bin/bash
set -euo pipefail
command=${1:-}
case "$command" in
    whoami) exit 0 ;;
    pages)
        subcommand=${2:-}
        page_id=${3:-}
        page_file="$PAGES_DIR/$page_id.md"
        case "$subcommand" in
            edit)
                /usr/bin/ruby -e 'path = ARGV.fetch(0); text = STDIN.read.force_encoding("UTF-8"); text = text.sub(/\A---\r?\n.*?\r?\n---\r?\n?/m, ""); File.write(path, text, mode: "w", encoding: "UTF-8")' "$page_file"
                printf '%s\n' "$page_id" >>"$EDIT_LOG"
                ;;
            get)
                printf '%s\n' '---' '---'
                [ -f "$page_file" ] && /bin/cat "$page_file"
                ;;
            *) exit 64 ;;
        esac
        ;;
    api)
        printf '{"object":"page","id":"%s","properties":{}}\n' "${2##*/}"
        ;;
    datasources)
        printf '%s\n' '{"results":[' \
            '{"object":"page","id":"page-example","properties":{"Codex ID":{"rich_text":[{"plain_text":"example"}]}}},' \
            '{"object":"page","id":"page-prose","properties":{"Codex ID":{"rich_text":[{"plain_text":"prose"}]}}}' \
            '],"has_more":false}' | tr -d '\n'
        printf '\n'
        ;;
    *) exit 64 ;;
esac
EOF
chmod 755 "$NTN"

run_sync() {
    TEST_SOURCE_DIR="$SOURCE_DIR" TEST_CODEX_HOME="$CODEX_HOME" \
        TEST_MIRROR_ROOT="$MIRROR_ROOT" \
        PAGES_DIR="$PAGES_DIR" EDIT_LOG="$EDIT_LOG" \
        TEST_FORCE_UNSTABLE="${TEST_FORCE_UNSTABLE:-0}" TEST_STABILITY_WAIT="${TEST_STABILITY_WAIT:-0}" \
        CUSTOM_INSTRUCTIONS_STABILITY_WAIT=0 NOTION_READBACK_WAIT_SECONDS=0 \
        NOTION_SYNC_MIRROR_ROOT_OVERRIDE="$MIRROR_ROOT" \
        "$SYNC_SCRIPT" "$HELPER" "$NTN" "$CODEX_HOME" "$CONFIG"
}

count_marker() {
    /usr/bin/grep -F -o -- "$1" "$2" | wc -l | tr -d ' '
}

expected_agents="$TMP_ROOT/expected-agents.md"
printf '%s\n\n%s\n\n%s\n' \
    '# custom marker' \
    $'# shared marker\n## スキルの作成・更新と検証' \
    '# profile marker' >"$expected_agents"

scenario_success() {
    run_sync >"$TMP_ROOT/success.log" 2>&1
    cmp -s "$expected_agents" "$CODEX_HOME/AGENTS.md" || return 1
    [ "$(count_marker '# shared marker' "$CODEX_HOME/AGENTS.md")" -eq 1 ] || return 1
    [ "$(count_marker '## スキルの作成・更新と検証' "$CODEX_HOME/AGENTS.md")" -eq 1 ] || return 1
}

scenario_notion_pages() {
    custom_page="$PAGES_DIR/22222222222222222222222222222222.md"
    profile_page="$PAGES_DIR/22222222222222222222222222222223.md"
    expected_custom="$TMP_ROOT/expected-custom-page.md"
    expected_profile="$TMP_ROOT/expected-profile-page.md"
    printf '%s\n' '# profile marker' >"$expected_profile"
    printf '%s\n\n%s\n%s\n' '# custom marker' '# shared marker' '## スキルの作成・更新と検証' >"$expected_custom"
    cmp -s "$expected_custom" "$custom_page" || return 1
    cmp -s "$expected_profile" "$profile_page" || return 1
    ! /usr/bin/grep -Fq -- '# shared marker' "$profile_page"
}

scenario_idempotence_and_change() {
    cp "$PAGES_DIR/22222222222222222222222222222222.md" "$TMP_ROOT/custom-before.md"
    cp "$PAGES_DIR/22222222222222222222222222222223.md" "$TMP_ROOT/profile-before.md"
    first_count=$(wc -l <"$EDIT_LOG" | tr -d ' ')
    run_sync >"$TMP_ROOT/unchanged.log" 2>&1
    second_count=$(wc -l <"$EDIT_LOG" | tr -d ' ')
    [ "$second_count" -eq "$first_count" ] || return 1
    cmp -s "$TMP_ROOT/custom-before.md" "$PAGES_DIR/22222222222222222222222222222222.md" || return 1
    cmp -s "$TMP_ROOT/profile-before.md" "$PAGES_DIR/22222222222222222222222222222223.md" || return 1

    printf '%s\n%s\n' '# shared marker changed' '## スキルの作成・更新と検証' >"$SOURCE_DIR/openai-instructions.md"
    run_sync >"$TMP_ROOT/changed.log" 2>&1
    third_count=$(wc -l <"$EDIT_LOG" | tr -d ' ')
    [ "$third_count" -eq $((second_count + 1)) ] || return 1
    ! cmp -s "$TMP_ROOT/custom-before.md" "$PAGES_DIR/22222222222222222222222222222222.md" || return 1
    cmp -s "$TMP_ROOT/profile-before.md" "$PAGES_DIR/22222222222222222222222222222223.md" || return 1
    [ "$(tail -n 1 "$EDIT_LOG")" = '22222222222222222222222222222222' ] || return 1
}

scenario_reject_invalid_sources() {
    cp "$CODEX_HOME/AGENTS.md" "$TMP_ROOT/agents-before-invalid.md"
    cp "$PAGES_DIR/22222222222222222222222222222222.md" "$TMP_ROOT/custom-before-invalid.md"
    cp "$PAGES_DIR/22222222222222222222222222222223.md" "$TMP_ROOT/profile-before-invalid.md"
    : >"$SOURCE_DIR/openai-instructions.md"
    if run_sync >"$TMP_ROOT/empty.log" 2>&1; then return 1; fi
    cmp -s "$TMP_ROOT/agents-before-invalid.md" "$CODEX_HOME/AGENTS.md" || return 1
    cmp -s "$TMP_ROOT/custom-before-invalid.md" "$PAGES_DIR/22222222222222222222222222222222.md" || return 1
    cmp -s "$TMP_ROOT/profile-before-invalid.md" "$PAGES_DIR/22222222222222222222222222222223.md" || return 1

    printf '\377\n' >"$SOURCE_DIR/openai-instructions.md"
    if run_sync >"$TMP_ROOT/utf8.log" 2>&1; then return 1; fi
    cmp -s "$TMP_ROOT/agents-before-invalid.md" "$CODEX_HOME/AGENTS.md" || return 1

    rm -f "$SOURCE_DIR/openai-instructions.md"
    if run_sync >"$TMP_ROOT/missing.log" 2>&1; then return 1; fi
    cmp -s "$TMP_ROOT/agents-before-invalid.md" "$CODEX_HOME/AGENTS.md" || return 1
}

scenario_reject_unstable_source() {
    printf '%s\n%s\n' '# shared marker' '## スキルの作成・更新と検証' >"$SOURCE_DIR/openai-instructions.md"
    cp "$CODEX_HOME/AGENTS.md" "$TMP_ROOT/agents-before-unstable.md"
    TEST_FORCE_UNSTABLE=1 TEST_STABILITY_WAIT=0.01 run_sync >"$TMP_ROOT/unstable.log" 2>&1 && return 1
    cmp -s "$TMP_ROOT/agents-before-unstable.md" "$CODEX_HOME/AGENTS.md"
}

failures=0
for scenario in success notion_pages idempotence_and_change reject_invalid_sources reject_unstable_source; do
    if "scenario_$scenario"; then
        printf '[PASS] %s\n' "$scenario"
    else
        printf '[FAIL] %s\n' "$scenario" >&2
        failures=$((failures + 1))
    fi
done

if [ "$failures" -gt 0 ]; then
    printf '[RESULT] %s acceptance scenario(s) failed.\n' "$failures" >&2
    exit 1
fi
printf '[SUCCESS] openai-instructions executable acceptance tests passed.\n'
