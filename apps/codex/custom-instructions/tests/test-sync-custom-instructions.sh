#!/bin/bash

set -euo pipefail

if [ "${FAKE_HELPER_MODE:-0}" = "1" ]; then
    case "${1:-}" in
        --status)
            if [ -n "${FAKE_EVENTS:-}" ]; then
                printf '%s\n' helper:status >>"$FAKE_EVENTS"
            fi
            if [ "${FAKE_STATUS_VARIANT:-authorized}" = "output-only" ]; then
                status_output=$(printf '%s\n' "source=$FAKE_STATUS_SOURCE" "skills=$FAKE_STATUS_SKILLS" \
                    'output=/wrong-output' "mirror=$FAKE_STATUS_MIRROR")
            elif [ "${FAKE_STATUS_VARIANT:-authorized}" = "mirror-only" ]; then
                status_output=$(printf '%s\n' "source=$FAKE_STATUS_SOURCE" "skills=$FAKE_STATUS_SKILLS" \
                    "output=$FAKE_STATUS_OUTPUT" 'mirror=/wrong-mirror')
            elif [ "${FAKE_STATUS_VARIANT:-authorized}" = "source-missing" ]; then
                status_output=$(printf '%s\n' 'source=/missing-source' "skills=$FAKE_STATUS_SKILLS" \
                    "output=$FAKE_STATUS_OUTPUT" "mirror=$FAKE_STATUS_MIRROR")
            elif [ "${FAKE_STATUS_VARIANT:-authorized}" = "skills-missing" ]; then
                status_output=$(printf '%s\n' "source=$FAKE_STATUS_SOURCE" 'skills=/missing-skills' \
                    "output=$FAKE_STATUS_OUTPUT" "mirror=$FAKE_STATUS_MIRROR")
            else
                status_output=$(printf '%s\n' "source=$FAKE_STATUS_SOURCE" "skills=$FAKE_STATUS_SKILLS" \
                    "output=$FAKE_STATUS_OUTPUT" "mirror=$FAKE_STATUS_MIRROR")
            fi
            if [ -n "${FAKE_STATUS_OUTPUT_LOG:-}" ]; then
                printf '%s\n' "$status_output" >"$FAKE_STATUS_OUTPUT_LOG"
            fi
            printf '%s\n' "$status_output"
            exit 0
            ;;
        --sync)
            if [ -n "${FAKE_EVENTS:-}" ]; then
                printf '%s\n' helper:sync >>"$FAKE_EVENTS"
            fi
            if [ "${FAKE_STATUS_REQUIRED:-0}" = "1" ] &&
               [ "$(sed -n '1p' "$FAKE_EVENTS")" != 'helper:status' ]; then
                exit 1
            fi
            exit 0
            ;;
        --snapshot)
            [ "$#" -eq 2 ] || exit 64
            [ -d "$2" ] && [ ! -L "$2" ] || exit 1
            [ "$(dirname -- "$2")" = "$FAKE_STATUS_MIRROR" ] || exit 1
            # Legacy frontmatter/Notion normalization scenarios use the
            # preconstructed fixture as their independent fake source.
            cp -R "$FAKE_STATUS_MIRROR/custom-instructions-sync" "$2/custom-instructions-sync"
            cp -R "$FAKE_STATUS_MIRROR/skills-notion-sync" "$2/skills-notion-sync"
            if [ -n "${FAKE_EVENTS:-}" ]; then
                printf '%s\n' helper:snapshot >>"$FAKE_EVENTS"
            fi
            exit 0
            ;;
    esac
fi

# The same file acts as a no-op helper and a deterministic fake ntn binary when
# it is copied to a temporary path during the isolated test.
fake_notion() {
    local command=$1
    shift
    local fake_account=legacy
    local state_dir="$FAKE_STATE_DIR"
    local meta_dir="$FAKE_META_DIR"

    if [ "$command" = "auth" ] && [ "${1:-}" = "token" ]; then
        if [ -n "${FAKE_EVENTS:-}" ]; then
            printf '%s\n' 'credential:ntn-default' >>"$FAKE_EVENTS"
        fi
        printf '%s' "${FAKE_MOLCURE_TOKEN:-}"
        exit 0
    fi

    if [ "${FAKE_ACCOUNT_TEST:-0}" = "1" ]; then
        case "${NOTION_API_TOKEN:-}" in
            "${FAKE_MOLCURE_TOKEN:-__missing_molcure_token__}") fake_account=molcure ;;
            "${FAKE_PERSONAL_TOKEN:-__missing_personal_token__}") fake_account=personal ;;
            "") fake_account=molcure ;;
            *)
                printf '[FAKE ERROR] アカウント別トークンが設定されていません。\n' >&2
                return 91
                ;;
        esac
        if [ "$fake_account" = "molcure" ]; then
            state_dir="$state_dir/molcure"
            meta_dir="$meta_dir/molcure"
        else
            state_dir="$state_dir/personal"
            meta_dir="$meta_dir/personal"
        fi
        mkdir -p "$state_dir" "$meta_dir"
    fi

    account_for_id() {
        case "$1" in
            "${FAKE_MOLCURE_CUSTOM_PAGE_ID:-}"|"${FAKE_MOLCURE_PROFILE_PAGE_ID:-}"|"${FAKE_MOLCURE_DATA_SOURCE_ID:-}"|molcure-page-*) printf '%s' molcure ;;
            "${FAKE_PERSONAL_CUSTOM_PAGE_ID:-}"|"${FAKE_PERSONAL_PROFILE_PAGE_ID:-}"|"${FAKE_PERSONAL_DATA_SOURCE_ID:-}"|personal-page-*) printf '%s' personal ;;
            *) printf '%s' unknown ;;
        esac
    }

    if [ -n "${FAKE_EVENTS:-}" ]; then
        if [ "${FAKE_ACCOUNT_TEST:-0}" = "1" ]; then
            printf 'notion:%s:%s\n' "$fake_account" "$command" >>"$FAKE_EVENTS"
        else
            printf 'notion:%s\n' "$command" >>"$FAKE_EVENTS"
        fi
    fi

    case "$command" in
        whoami)
            if [ "${FAKE_ACCOUNT_TEST:-0}" = "1" ] && [ "${1:-}" = "--json" ]; then
                local fake_user_id=${FAKE_ACTUAL_USER_ID:-}
                local fake_workspace_id=${FAKE_ACTUAL_WORKSPACE_ID:-}
                if [ -z "$fake_user_id" ]; then
                    if [ "$fake_account" = "molcure" ]; then
                        fake_user_id=$FAKE_MOLCURE_USER_ID
                    else
                        fake_user_id=$FAKE_PERSONAL_USER_ID
                    fi
                fi
                if [ -z "$fake_workspace_id" ]; then
                    if [ "$fake_account" = "molcure" ]; then
                        fake_workspace_id=$FAKE_MOLCURE_WORKSPACE_ID
                    else
                        fake_workspace_id=$FAKE_PERSONAL_WORKSPACE_ID
                    fi
                fi
                if [ "$fake_account" = "molcure" ]; then
                    printf '{"object":"bot","id":"bot-molcure","type":"bot","bot":{"owner":{"type":"user","user":{"id":"%s"}},"workspace_id":"%s"}}\n' \
                        "$fake_user_id" "$fake_workspace_id"
                else
                    printf '{"object":"bot","id":"bot-personal","type":"bot","bot":{"owner":{"type":"user","user":{"id":"%s"}},"workspace_id":"%s"}}\n' \
                        "$fake_user_id" "$fake_workspace_id"
                fi
            fi
            exit 0
            ;;
        datasources)
            if [ "${FAKE_ACCOUNT_TEST:-0}" = "1" ]; then
                case "${2:-}" in
                    "$FAKE_MOLCURE_DATA_SOURCE_ID")
                    /bin/cat "$FAKE_MOLCURE_QUERY_JSON"
                    ;;
                    "$FAKE_PERSONAL_DATA_SOURCE_ID")
                    /bin/cat "$FAKE_PERSONAL_QUERY_JSON"
                    ;;
                    *) return 94 ;;
                esac
            else
                /bin/cat "$FAKE_QUERY_JSON"
            fi
            exit 0
            ;;
        pages)
            local subcommand=$1
            local page_id=$2
            case "$subcommand" in
                edit)
                    local page_file="$state_dir/$page_id.md"
                    /usr/bin/ruby -e 'path = ARGV.fetch(0); text = STDIN.read.force_encoding("UTF-8"); text = text.sub(/\A---\r?\n.*?\r?\n---\r?\n?/m, ""); File.write(path, text, mode: "w", encoding: "UTF-8")' "$page_file"
                    if [ "${FAKE_ACCOUNT_TEST:-0}" = "1" ]; then
                        printf '%s:%s:%s\n' "$fake_account" "$(account_for_id "$page_id")" "$page_id" >>"$FAKE_EDIT_LOG"
                        printf 'write:%s:page_edit:%s\n' "$fake_account" "$page_id" >>"$FAKE_EVENTS"
                    else
                        printf '%s\n' "$page_id" >>"$FAKE_EDIT_LOG"
                    fi
                    ;;
                get)
                    printf '%s\n' '---' '---'
                    if [ -f "$state_dir/$page_id.md" ]; then
                        /bin/cat "$state_dir/$page_id.md"
                    fi
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        api)
            local api_path=$1
            shift
            local method=GET
            local data=''
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    -X)
                        method=$2
                        shift 2
                        ;;
                    --data)
                        data=$2
                        shift 2
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            local page_id=${api_path##*/}
            local target_account=$(account_for_id "$page_id")
            if [ "${FAKE_ACCOUNT_TEST:-0}" = "1" ] && [ -n "${FAKE_EVENTS:-}" ]; then
                printf 'request:%s:%s:%s\n' "$fake_account" "$method" "$api_path" >>"$FAKE_EVENTS"
            fi
            if [ "$method" = "PATCH" ]; then
                printf '%s' "$data" >"$meta_dir/$page_id.json"
                if [ "${FAKE_ACCOUNT_TEST:-0}" = "1" ]; then
                    printf '%s:%s:%s\n' "$fake_account" "$target_account" "$page_id" >>"$FAKE_PATCH_LOG"
                    printf 'write:%s:metadata_patch:%s\n' "$fake_account" "$page_id" >>"$FAKE_EVENTS"
                else
                    printf '%s\n' "$page_id" >>"$FAKE_PATCH_LOG"
                fi
                printf '{"object":"page","id":"%s"}\n' "$page_id"
            else
                if [ "${FAKE_ACCOUNT_TEST:-0}" = "1" ] && [[ "$api_path" = /v1/data_sources/* ]]; then
                    local owner_workspace=$FAKE_PERSONAL_WORKSPACE_ID
                    [ "$target_account" = molcure ] && owner_workspace=$FAKE_MOLCURE_WORKSPACE_ID
                    printf '{"object":"data_source","id":"%s","parent":{"type":"workspace","workspace_id":"%s"}}\n' \
                        "$page_id" "$owner_workspace"
                elif [ "${FAKE_ACCOUNT_TEST:-0}" = "1" ] && [ -f "$meta_dir/$page_id.json" ]; then
                    local owner_workspace=$FAKE_PERSONAL_WORKSPACE_ID
                    [ "$target_account" = molcure ] && owner_workspace=$FAKE_MOLCURE_WORKSPACE_ID
                    /usr/bin/jq -c --arg id "$page_id" --arg workspace "$owner_workspace" \
                        '{object:"page",id:$id,parent:{type:"workspace",workspace_id:$workspace},properties:.properties}' \
                        "$meta_dir/$page_id.json"
                elif [ "${FAKE_ACCOUNT_TEST:-0}" = "1" ]; then
                    local owner_workspace=$FAKE_PERSONAL_WORKSPACE_ID
                    [ "$target_account" = molcure ] && owner_workspace=$FAKE_MOLCURE_WORKSPACE_ID
                    /usr/bin/jq -cn --arg id "$page_id" --arg workspace "$owner_workspace" \
                        '{object:"page",id:$id,parent:{type:"workspace",workspace_id:$workspace},properties:{}}'
                elif [ -f "$meta_dir/$page_id.json" ]; then
                    /usr/bin/jq -c --arg id "$page_id" '{object:"page",id:$id,properties:.properties}' "$meta_dir/$page_id.json"
                else
                    /usr/bin/jq -cn --arg id "$page_id" '{object:"page",id:$id,properties:{}}'
                fi
            fi
            ;;
        *)
            return 1
            ;;
    esac
}

case "${1:-}" in
    --sync)
        exit 0
        ;;
    whoami|datasources|pages|api|auth)
        fake_notion "$@"
        exit $?
        ;;
esac

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)
SYNC_SCRIPT="$DOTFILES_ROOT/apps/codex/custom-instructions/sync-custom-instructions"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/skills-notion-sync-test.XXXXXX")
case "${TMP_ROOT:?}" in
    "${TMPDIR:-/tmp}"/skills-notion-sync-test.*) ;;
    *)
        printf '[ERROR] 想定外のテスト一時パスです: %s\n' "$TMP_ROOT" >&2
        exit 1
        ;;
esac
cleanup_test_tmp() {
    rm -rf -- "$TMP_ROOT"
}
trap cleanup_test_tmp EXIT

TRUE_SKILLS=(
    draft-email
    draft-press-release-qa
    draft-proposal
    executive-summary
    explain
    review-text
    translate
)
FALSE_SKILLS=(
    git-add-commit-push
    gmail-to-calendar
    implementation-loop
    initial-plan
    jobcan-fill-attendance
    notion-molcure
    notion-personal
    reflect-textlint-findings
    reply-automatically
)
TRUE_REFERENCES=(
    business-email
    cognitive-rhythm-writing
    communication-writing
    editing-guardrails
    formatting
    markdown-formatting
    proofreading
    prose-basics
    technical-writing
    translation-rules
    writing-improvement
)

HARNESS_ROOT=${CODEX_HARNESS_ROOT_OVERRIDE:-$TMP_ROOT/harness}
CODEX_HOME="$TMP_ROOT/codex"
MIRROR_ROOT="$TMP_ROOT/support/mirrors"
MIRROR_DIR="$MIRROR_ROOT/custom-instructions-sync"
SKILLS_MIRROR_DIR="$MIRROR_ROOT/skills-notion-sync"
LEGACY_MIRROR_DIR="$CODEX_HOME/custom-instructions-sync"
LEGACY_SKILLS_MIRROR_DIR="$CODEX_HOME/skills-notion-sync"
CONFIG_DIR="$TMP_ROOT/config"
FAKE_STATE_DIR="$TMP_ROOT/pages"
FAKE_META_DIR="$TMP_ROOT/meta"
FAKE_EDIT_LOG="$TMP_ROOT/edits.log"
FAKE_PATCH_LOG="$TMP_ROOT/patches.log"
FAKE_QUERY_JSON="$TMP_ROOT/query.json"
FAKE_SECURITY_BIN="$TMP_ROOT/security-bin"
FAKE_SECURITY_EVENTS="$TMP_ROOT/security-events"
CONFIG="$CONFIG_DIR/notion-pages.conf"
HELPER="$TMP_ROOT/helper"
NTN="$TMP_ROOT/ntn"

mkdir -p "$MIRROR_DIR" "$SKILLS_MIRROR_DIR" "$LEGACY_MIRROR_DIR" "$LEGACY_SKILLS_MIRROR_DIR" "$CONFIG_DIR" "$FAKE_STATE_DIR" "$FAKE_META_DIR" "$FAKE_SECURITY_BIN"
printf '%s\n' 'legacy mirror must not be read' >"$LEGACY_MIRROR_DIR/custom-instructions.md"
printf '%s\n' 'legacy mirror must not be read' >"$LEGACY_MIRROR_DIR/user-profile.md"
mkdir -p "$LEGACY_SKILLS_MIRROR_DIR/legacy"
printf '%s\n' '---' 'name: legacy' '---' '# legacy mirror must not be read' >"$LEGACY_SKILLS_MIRROR_DIR/legacy/SKILL.md"
cp "$0" "$HELPER"
cp "$0" "$NTN"
chmod 755 "$HELPER" "$NTN"
cat >"$FAKE_SECURITY_BIN/security" <<'SECURITY_FAKE'
#!/bin/bash
set -euo pipefail
[ "${1:-}" = "find-generic-password" ] || exit 64
shift
service=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        -s)
            service=${2:-}
            shift 2
            ;;
        -a)
            shift 2
            ;;
        -w)
            shift
            ;;
        *)
            shift
            ;;
    esac
done
case "$service" in
    my.notion.molcure) token=${FAKE_MOLCURE_TOKEN:?} ;;
    my.notion.personal) token=${FAKE_PERSONAL_TOKEN:?} ;;
    *) exit 44 ;;
esac
printf 'security-attempt:%s\n' "$service" >>"${FAKE_SECURITY_EVENTS:?}"
if [ "${FAKE_KEYCHAIN_MODE:-present}" != "present" ]; then
    exit 45
fi
printf 'security:%s\n' "$service" >>"${FAKE_SECURITY_EVENTS:?}"
printf '%s' "$token"
SECURITY_FAKE
chmod 755 "$FAKE_SECURITY_BIN/security"

if [ -z "${CODEX_HARNESS_ROOT_OVERRIDE:-}" ]; then
    mkdir -p "$HARNESS_ROOT/custom-instructions" "$HARNESS_ROOT/skills/writing-references"
    printf '%s\n' '# custom fixture' >"$HARNESS_ROOT/custom-instructions/custom-instructions.md"
    printf '%s\n' '# profile fixture' >"$HARNESS_ROOT/custom-instructions/user-profile.md"
    for skill_name in "${TRUE_SKILLS[@]}"; do
        mkdir -p "$HARNESS_ROOT/skills/$skill_name"
        printf '%s\n' '---' "name: $skill_name" 'metadata:' '  notion_sync: "true"' '---' "# $skill_name" \
            >"$HARNESS_ROOT/skills/$skill_name/SKILL.md"
    done
    for skill_name in "${FALSE_SKILLS[@]}"; do
        mkdir -p "$HARNESS_ROOT/skills/$skill_name"
        printf '%s\n' '---' "name: $skill_name" 'metadata:' '  notion_sync: "false"' '---' "# $skill_name" \
            >"$HARNESS_ROOT/skills/$skill_name/SKILL.md"
    done
    for reference_name in "${TRUE_REFERENCES[@]}"; do
        printf '%s\n' '---' "name: $reference_name" 'metadata:' '  notion_sync: "true"' '---' "# $reference_name" \
            >"$HARNESS_ROOT/skills/writing-references/$reference_name.md"
    done
    printf '%s\n' '---' 'name: explain' 'description: explain fixture' 'metadata:' \
        '  notion_sync: "true"' '  notion_role: "Main"' \
        "  notion_tags: '[\"explanation\",\"text\"]'" '---' '# explain' \
        >"$HARNESS_ROOT/skills/explain/SKILL.md"
    printf '%s\n' '---' 'name: business-email' 'metadata:' \
        '  notion_sync: "true"' "  notion_tags: '[]'" '---' '# business-email' \
        >"$HARNESS_ROOT/skills/writing-references/business-email.md"
fi

for source_file in \
    "$HARNESS_ROOT/custom-instructions/custom-instructions.md" \
    "$HARNESS_ROOT/custom-instructions/user-profile.md" \
    "$HARNESS_ROOT"/skills/*/SKILL.md \
    "$HARNESS_ROOT"/skills/writing-references/*.md; do
    if [ ! -f "$source_file" ]; then
        printf '[ERROR] 必須ソースが存在しません: %s\n' "$source_file" >&2
        exit 1
    fi
done

cp "$HARNESS_ROOT/custom-instructions/custom-instructions.md" "$MIRROR_DIR/custom-instructions.md"
cp "$HARNESS_ROOT/custom-instructions/user-profile.md" "$MIRROR_DIR/user-profile.md"

for source_file in "$HARNESS_ROOT"/skills/*/SKILL.md; do
    skill_name=$(basename "$(dirname "$source_file")")
    mkdir -p "$SKILLS_MIRROR_DIR/$skill_name"
    cp "$source_file" "$SKILLS_MIRROR_DIR/$skill_name/SKILL.md"
done
mkdir -p "$SKILLS_MIRROR_DIR/writing-references"
cp "$HARNESS_ROOT"/skills/writing-references/*.md "$SKILLS_MIRROR_DIR/writing-references/"

cat >"$CONFIG" <<'EOF'
workspace_id=11111111111111111111111111111111
custom_instructions_page_id=22222222222222222222222222222222
user_profile_page_id=22222222222222222222222222222223
skills_data_source_id=33333333333333333333333333333333
EOF
chmod 600 "$CONFIG"

/usr/bin/ruby -rjson -ryaml - "$SKILLS_MIRROR_DIR" >"$FAKE_QUERY_JSON" <<'RUBY'
root = ARGV.fetch(0)
paths = Dir[File.join(root, "*", "SKILL.md")] + Dir[File.join(root, "writing-references", "*.md")]
names = paths.sort.map do |path|
  text = File.read(path, encoding: "UTF-8")
  match = text.match(/\A---\r?\n(.*?)\r?\n---\r?\n?/m)
  metadata = YAML.safe_load(match[1], permitted_classes: [], aliases: false)
  metadata.fetch("name") if metadata.fetch("metadata", {})["notion_sync"] == "true"
end.compact
results = names.each_with_index.map do |name, index|
  {
    "object" => "page",
    "id" => "page-#{name}",
    "properties" => {
      "Codex ID" => {"type" => "rich_text", "rich_text" => [{"plain_text" => name}]}
    }
  }
end
puts JSON.generate("results" => results, "has_more" => false)
RUBY

run_sync() {
    FAKE_HELPER_MODE=1 \
    FAKE_ACCOUNT_TEST="${FAKE_ACCOUNT_TEST:-0}" \
    FAKE_STATUS_SOURCE="$HARNESS_ROOT/custom-instructions" \
    FAKE_STATUS_SKILLS="$HARNESS_ROOT/skills" \
    FAKE_STATUS_OUTPUT="$CODEX_HOME" \
    FAKE_STATUS_MIRROR="$MIRROR_ROOT" \
    CUSTOM_INSTRUCTIONS_STABILITY_WAIT=0 \
    NOTION_READBACK_WAIT_SECONDS=0 \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_META_DIR="$FAKE_META_DIR" \
    FAKE_EDIT_LOG="$FAKE_EDIT_LOG" \
    FAKE_PATCH_LOG="$FAKE_PATCH_LOG" \
    FAKE_QUERY_JSON="$FAKE_QUERY_JSON" \
    FAKE_SECURITY_EVENTS="${FAKE_SECURITY_EVENTS:-$TMP_ROOT/security-events}" \
    PATH="${FAKE_SECURITY_BIN:+$FAKE_SECURITY_BIN:}$PATH" \
    NOTION_SYNC_MIRROR_ROOT_OVERRIDE="$MIRROR_ROOT" \
    "$SYNC_SCRIPT" "$HELPER" "$NTN" "$CODEX_HOME" "${SYNC_CONFIG_OVERRIDE:-$CONFIG}"
}

run_sync_with_preflight_fixture() {
    FAKE_HELPER_MODE=1 \
    FAKE_ACCOUNT_TEST="${FAKE_ACCOUNT_TEST:-0}" \
    FAKE_EVENTS="$TMP_ROOT/preflight-events" \
    FAKE_STATUS_OUTPUT_LOG="$TMP_ROOT/status-output" \
    FAKE_STATUS_REQUIRED=1 \
    FAKE_STATUS_VARIANT="$1" \
    FAKE_STATUS_SOURCE="$HARNESS_ROOT/custom-instructions" \
    FAKE_STATUS_SKILLS="$HARNESS_ROOT/skills" \
    FAKE_STATUS_OUTPUT="$CODEX_HOME" \
    FAKE_STATUS_MIRROR="$MIRROR_ROOT" \
    CUSTOM_INSTRUCTIONS_STABILITY_WAIT=0 \
    NOTION_READBACK_WAIT_SECONDS=0 \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_META_DIR="$FAKE_META_DIR" \
    FAKE_EDIT_LOG="$FAKE_EDIT_LOG" \
    FAKE_PATCH_LOG="$FAKE_PATCH_LOG" \
    FAKE_QUERY_JSON="$FAKE_QUERY_JSON" \
    FAKE_SECURITY_EVENTS="${FAKE_SECURITY_EVENTS:-$TMP_ROOT/security-events}" \
    PATH="${FAKE_SECURITY_BIN:+$FAKE_SECURITY_BIN:}$PATH" \
    NOTION_SYNC_MIRROR_ROOT_OVERRIDE="$MIRROR_ROOT" \
    "$SYNC_SCRIPT" "$HELPER" "$NTN" "$CODEX_HOME" "$CONFIG"
}

assert_status_mismatch_stops_before_sync() {
    local variant=$1
    : >"$TMP_ROOT/preflight-events"
    set +e
    run_sync_with_preflight_fixture "$variant" >"$TMP_ROOT/$variant-preflight.log" 2>&1
    local sync_status=$?
    set -e
    [ "$sync_status" -ne 0 ]
    [ "$(cat "$TMP_ROOT/preflight-events")" = 'helper:status' ]
    [ "$(wc -l <"$TMP_ROOT/status-output" | tr -d ' ')" -eq 4 ]
    case "$variant" in
        output-only)
            expected_output=/wrong-output
            expected_mirror=$MIRROR_ROOT
            ;;
        mirror-only)
            expected_output=$CODEX_HOME
            expected_mirror=/wrong-mirror
            ;;
        source-missing)
            expected_source=/missing-source
            expected_output=$CODEX_HOME
            expected_mirror=$MIRROR_ROOT
            ;;
        skills-missing)
            expected_source="$HARNESS_ROOT/custom-instructions"
            expected_skills=/missing-skills
            expected_output=$CODEX_HOME
            expected_mirror=$MIRROR_ROOT
            ;;
    esac
    expected_source=${expected_source:-$HARNESS_ROOT/custom-instructions}
    expected_skills=${expected_skills:-$HARNESS_ROOT/skills}
    expected_status=$(printf '%s\n' "source=$expected_source" "skills=$expected_skills" "output=$expected_output" "mirror=$expected_mirror")
    [ "$(cat "$TMP_ROOT/status-output")" = "$expected_status" ]
    case "$variant" in
        source-missing) [ ! -d "$expected_source" ] ;;
        skills-missing) [ ! -d "$expected_skills" ] ;;
    esac
    [ "$(/usr/bin/grep -c '^helper:sync$' "$TMP_ROOT/preflight-events" || true)" -eq 0 ]
    [ "$(/usr/bin/grep -c '^notion:' "$TMP_ROOT/preflight-events" || true)" -eq 0 ]
}

assert_status_mismatch_stops_before_sync output-only
assert_status_mismatch_stops_before_sync mirror-only
assert_status_mismatch_stops_before_sync source-missing
assert_status_mismatch_stops_before_sync skills-missing

: >"$TMP_ROOT/preflight-events"
run_sync_with_preflight_fixture authorized >"$TMP_ROOT/authorized-preflight.log" 2>&1
expected_status=$(printf '%s\n' "source=$HARNESS_ROOT/custom-instructions" "skills=$HARNESS_ROOT/skills" "output=$CODEX_HOME" "mirror=$MIRROR_ROOT")
[ "$(cat "$TMP_ROOT/status-output")" = "$expected_status" ]
status_line=$(/usr/bin/grep -n '^helper:status$' "$TMP_ROOT/preflight-events" | cut -d: -f1)
sync_line=$(/usr/bin/grep -n '^helper:sync$' "$TMP_ROOT/preflight-events" | cut -d: -f1)
[ -n "$status_line" ]
[ -n "$sync_line" ]
[ "$status_line" -lt "$sync_line" ]
notion_seen=false
while IFS= read -r event; do
    case "$event" in
        notion:*)
            notion_seen=true
            notion_line=$(/usr/bin/grep -n -F "$event" "$TMP_ROOT/preflight-events" | head -n 1 | cut -d: -f1)
            [ "$status_line" -lt "$notion_line" ]
            ;;
    esac
done <"$TMP_ROOT/preflight-events"
[ "$notion_seen" = true ]

edit_count() {
    if [ -f "$FAKE_EDIT_LOG" ]; then
        wc -l <"$FAKE_EDIT_LOG" | tr -d ' '
    else
        printf '0\n'
    fi
}

mirror_file_count=$(find "$SKILLS_MIRROR_DIR" -type f -name '*.md' | wc -l | tr -d ' ')
true_skill_count=${#TRUE_SKILLS[@]}
false_skill_count=${#FALSE_SKILLS[@]}
true_reference_count=${#TRUE_REFERENCES[@]}
false_reference_count=0
total_file_count=$((true_skill_count + false_skill_count + true_reference_count + false_reference_count))
syncable_file_count=$((true_skill_count + true_reference_count))
[ "$mirror_file_count" -eq "$total_file_count" ] || {
    printf '[ERROR] fixture件数が不正です: expected=%s actual=%s\n' "$total_file_count" "$mirror_file_count" >&2
    exit 1
}
[ "$(find "$SKILLS_MIRROR_DIR" -mindepth 2 -path '*/SKILL.md' -type f | while read -r f; do grep -c '^  notion_sync: "true"$' "$f"; done | awk '{s+=$1} END {print s+0}')" -eq "$true_skill_count" ] || exit 1
[ "$(find "$SKILLS_MIRROR_DIR" -mindepth 2 -path '*/SKILL.md' -type f | while read -r f; do grep -c '^  notion_sync: "false"$' "$f"; done | awk '{s+=$1} END {print s+0}')" -eq "$false_skill_count" ] || exit 1
[ "$(find "$SKILLS_MIRROR_DIR/writing-references" -type f -name '*.md' | while read -r f; do grep -c '^  notion_sync: "true"$' "$f"; done | awk '{s+=$1} END {print s+0}')" -eq "$true_reference_count" ] || exit 1
[ "$false_reference_count" -eq 0 ] || exit 1
skill_names=$(find "$SKILLS_MIRROR_DIR" -mindepth 2 -maxdepth 2 -type f -name 'SKILL.md' -exec sh -c 'basename "$(dirname "$1")"' _ {} \; | sort)
expected_skill_names=$(printf '%s\n' "${TRUE_SKILLS[@]}" "${FALSE_SKILLS[@]}" | sort)
[ "$skill_names" = "$expected_skill_names" ] || {
    printf '[ERROR] Skill実名fixture集合が不正です。\nexpected:\n%s\nactual:\n%s\n' "$expected_skill_names" "$skill_names" >&2
    exit 1
}
reference_names=$(find "$SKILLS_MIRROR_DIR/writing-references" -maxdepth 1 -type f -name '*.md' -exec sh -c 'basename "$1" .md' _ {} \; | sort)
expected_reference_names=$(printf '%s\n' "${TRUE_REFERENCES[@]}" | sort)
[ "$reference_names" = "$expected_reference_names" ] || exit 1
! /usr/bin/grep -Fqx 'linear-issue-plan-review' <<<"$skill_names" || exit 1
! /usr/bin/grep -Fqx 'linear-issue-plan-review' <<<"$reference_names" || exit 1
for skill_name in "${TRUE_SKILLS[@]}"; do
    /usr/bin/grep -Fqx "name: $skill_name" "$SKILLS_MIRROR_DIR/$skill_name/SKILL.md" || exit 1
    /usr/bin/grep -Fqx '  notion_sync: "true"' "$SKILLS_MIRROR_DIR/$skill_name/SKILL.md" || exit 1
done
for skill_name in "${FALSE_SKILLS[@]}"; do
    /usr/bin/grep -Fqx "name: $skill_name" "$SKILLS_MIRROR_DIR/$skill_name/SKILL.md" || exit 1
    /usr/bin/grep -Fqx '  notion_sync: "false"' "$SKILLS_MIRROR_DIR/$skill_name/SKILL.md" || exit 1
done
/usr/bin/grep -Fqx 'name: jobcan-fill-attendance' "$SKILLS_MIRROR_DIR/jobcan-fill-attendance/SKILL.md" || exit 1
/usr/bin/grep -Fqx '  notion_sync: "false"' "$SKILLS_MIRROR_DIR/jobcan-fill-attendance/SKILL.md" || exit 1
for reference_name in "${TRUE_REFERENCES[@]}"; do
    /usr/bin/grep -Fqx "name: $reference_name" "$SKILLS_MIRROR_DIR/writing-references/$reference_name.md" || exit 1
    /usr/bin/grep -Fqx '  notion_sync: "true"' "$SKILLS_MIRROR_DIR/writing-references/$reference_name.md" || exit 1
done
if ! run_sync >"$TMP_ROOT/first.log" 2>&1; then
    /bin/cat "$TMP_ROOT/first.log" >&2
    exit 1
fi
expected_count=$((syncable_file_count + 2))
[ "$(edit_count)" -eq "$expected_count" ] || {
    /bin/cat "$TMP_ROOT/first.log" >&2
    printf '[ERROR] 初回更新件数が不正です: expected=%s actual=%s\n' "$expected_count" "$(edit_count)" >&2
    exit 1
}
/usr/bin/jq -e --argjson expected "$syncable_file_count" '(.results | length) == $expected' "$FAKE_QUERY_JSON" >/dev/null || exit 1
if /usr/bin/jq -e '.results[] | .properties["Codex ID"].rich_text[]?.plain_text == "jobcan-fill-attendance"' "$FAKE_QUERY_JSON" >/dev/null; then
    exit 1
fi
if /usr/bin/jq -e '.results[] | .properties["Codex ID"].rich_text[]?.plain_text == "linear-issue-plan-review"' "$FAKE_QUERY_JSON" >/dev/null; then
    exit 1
fi
/usr/bin/grep -Fq "[SUCCESS] SkillsのNotion同期が完了しました（${syncable_file_count}件）。" "$TMP_ROOT/first.log" || exit 1
for skill_name in "${TRUE_SKILLS[@]}"; do
    /usr/bin/grep -Fqx "page-$skill_name" "$FAKE_EDIT_LOG" || exit 1
done
for skill_name in "${FALSE_SKILLS[@]}"; do
    ! /usr/bin/grep -Fqx "page-$skill_name" "$FAKE_EDIT_LOG" || exit 1
done
! /usr/bin/grep -Fqx 'page-jobcan-fill-attendance' "$FAKE_EDIT_LOG" || exit 1
! /usr/bin/grep -Fq 'linear-issue-plan-review' "$FAKE_EDIT_LOG" || exit 1

run_sync >"$TMP_ROOT/second.log" 2>&1
[ "$(edit_count)" -eq "$expected_count" ] || {
    /bin/cat "$TMP_ROOT/second.log" >&2
    printf '[ERROR] 冪等実行でNotion更新が発生しました。\n' >&2
    exit 1
}

printf '\n# isolated test marker\n' >>"$SKILLS_MIRROR_DIR/explain/SKILL.md"
run_sync >"$TMP_ROOT/third.log" 2>&1
[ "$(edit_count)" -eq $((expected_count + 1)) ] || {
    /bin/cat "$TMP_ROOT/third.log" >&2
    printf '[ERROR] 変更ファイルのみの更新件数が不正です。\n' >&2
    exit 1
}
baseline_count=$(edit_count)
/usr/bin/jq -e '.properties.Role.select.name == "Main" and
    ([.properties.Tags.multi_select[].name] == ["explanation","text"])' \
    "$FAKE_META_DIR/page-explain.json" >/dev/null || exit 1
/usr/bin/jq -e '(.properties.Tags.multi_select | length) == 0' \
    "$FAKE_META_DIR/page-business-email.json" >/dev/null || exit 1
patch_count() {
    if [ -f "$FAKE_PATCH_LOG" ]; then wc -l <"$FAKE_PATCH_LOG" | tr -d ' '; else printf '0\n'; fi
}
baseline_patch_count=$(patch_count)

assert_rejected_without_updates() {
    local label=$1
    local expected_error=$2
    local log_file="$TMP_ROOT/$label.log"
    printf '\n# pending update before validation\n' >>"$MIRROR_DIR/custom-instructions.md"
    printf '\n# pending profile update before validation\n' >>"$MIRROR_DIR/user-profile.md"
    if run_sync >"$log_file" 2>&1; then
        /bin/cat "$log_file" >&2
        printf '[ERROR] %sを検出できませんでした。\n' "$label" >&2
        exit 1
    fi
    /usr/bin/grep -Fq -- "$expected_error" "$log_file" || {
        /bin/cat "$log_file" >&2
        printf '[ERROR] %sの固有エラーがありません。\n' "$label" >&2
        exit 1
    }
    [ "$(edit_count)" -eq "$baseline_count" ] && [ "$(patch_count)" -eq "$baseline_patch_count" ] || {
        /bin/cat "$log_file" >&2
        printf '[ERROR] %sで部分更新が発生しました。\n' "$label" >&2
        exit 1
    }
    cp "$HARNESS_ROOT/custom-instructions/custom-instructions.md" "$MIRROR_DIR/custom-instructions.md"
    cp "$HARNESS_ROOT/custom-instructions/user-profile.md" "$MIRROR_DIR/user-profile.md"
}

/usr/bin/jq 'del(.results[0])' "$FAKE_QUERY_JSON" >"$TMP_ROOT/missing.json"
printf '\n# pending update before missing-page validation\n' >>"$MIRROR_DIR/custom-instructions.md"
printf '\n# pending profile update before missing-page validation\n' >>"$MIRROR_DIR/user-profile.md"
if FAKE_QUERY_JSON="$TMP_ROOT/missing.json" run_sync >"$TMP_ROOT/missing.log" 2>&1; then
    /bin/cat "$TMP_ROOT/missing.log" >&2
    printf '[ERROR] Notionページ不足を検出できませんでした。\n' >&2
    exit 1
fi
/usr/bin/grep -Fq 'Notion Skillsデータソースに対応ページがありません' "$TMP_ROOT/missing.log" || {
    /bin/cat "$TMP_ROOT/missing.log" >&2
    printf '[ERROR] Notionページ不足の固有エラーがありません。\n' >&2
    exit 1
}
[ "$(edit_count)" -eq "$baseline_count" ] && [ "$(patch_count)" -eq "$baseline_patch_count" ] || {
    printf '[ERROR] ページ不足時に部分更新が発生しました。\n' >&2
    exit 1
}
cp "$HARNESS_ROOT/custom-instructions/custom-instructions.md" "$MIRROR_DIR/custom-instructions.md"
cp "$HARNESS_ROOT/custom-instructions/user-profile.md" "$MIRROR_DIR/user-profile.md"

# 全候補の検証が終わるまで、本文・プロパティのいずれも更新しない。
printf '%s\n' '---' 'name: missing-notion-sync' 'metadata:' '  notion_role: "Main"' '---' '# missing' >"$SKILLS_MIRROR_DIR/writing-references/missing-notion-sync.md"
assert_rejected_without_updates 'notion-sync-missing' 'notion_sync'
rm -f "$SKILLS_MIRROR_DIR/writing-references/missing-notion-sync.md"

printf '%s\n' '---' 'name: invalid-notion-sync' 'metadata:' '  notion_sync: "maybe"' '---' '# invalid' >"$SKILLS_MIRROR_DIR/writing-references/invalid-notion-sync.md"
assert_rejected_without_updates 'notion-sync-value' 'notion_sync'
rm -f "$SKILLS_MIRROR_DIR/writing-references/invalid-notion-sync.md"

printf '%s\n' '---' 'name: boolean-notion-sync' 'metadata:' '  notion_sync: true' '---' '# boolean' >"$SKILLS_MIRROR_DIR/writing-references/boolean-notion-sync.md"
assert_rejected_without_updates 'notion-sync-boolean' 'notion_sync'
rm -f "$SKILLS_MIRROR_DIR/writing-references/boolean-notion-sync.md"

printf '%s\n' '---' 'name: legacy-notion-sync' 'notion_sync: true' '---' '# legacy' >"$SKILLS_MIRROR_DIR/writing-references/legacy-notion-sync.md"
assert_rejected_without_updates 'notion-sync-legacy' 'notion_sync'
rm -f "$SKILLS_MIRROR_DIR/writing-references/legacy-notion-sync.md"

/usr/bin/jq '.results += [.results[0]]' "$FAKE_QUERY_JSON" >"$TMP_ROOT/duplicate.json"
printf '\n# pending update before Codex ID duplicate validation\n' >>"$MIRROR_DIR/custom-instructions.md"
printf '\n# pending profile update before Codex ID duplicate validation\n' >>"$MIRROR_DIR/user-profile.md"
if FAKE_QUERY_JSON="$TMP_ROOT/duplicate.json" run_sync >"$TMP_ROOT/duplicate.log" 2>&1; then
    /bin/cat "$TMP_ROOT/duplicate.log" >&2
    printf '[ERROR] Codex ID重複を検出できませんでした。\n' >&2
    exit 1
fi
/usr/bin/grep -Fq 'Notion SkillsデータソースでCodex IDが重複しています' "$TMP_ROOT/duplicate.log" || {
    /bin/cat "$TMP_ROOT/duplicate.log" >&2
    printf '[ERROR] Codex ID重複の固有エラーがありません。\n' >&2
    exit 1
}
[ "$(edit_count)" -eq "$baseline_count" ] && [ "$(patch_count)" -eq "$baseline_patch_count" ] || { printf '[ERROR] Codex ID重複時に部分更新が発生しました。\n' >&2; exit 1; }
cp "$HARNESS_ROOT/custom-instructions/custom-instructions.md" "$MIRROR_DIR/custom-instructions.md"
cp "$HARNESS_ROOT/custom-instructions/user-profile.md" "$MIRROR_DIR/user-profile.md"

printf '%s\n' '---' 'name: explain' 'metadata:' '  notion_sync: "true"' '---' '# duplicate source' >"$SKILLS_MIRROR_DIR/writing-references/duplicate.md"
printf '\n# pending update before source duplicate validation\n' >>"$MIRROR_DIR/custom-instructions.md"
printf '\n# pending profile update before source duplicate validation\n' >>"$MIRROR_DIR/user-profile.md"
if run_sync >"$TMP_ROOT/source-duplicate.log" 2>&1; then
    /bin/cat "$TMP_ROOT/source-duplicate.log" >&2
    printf '[ERROR] frontmatter name重複を検出できませんでした。\n' >&2
    exit 1
fi
/usr/bin/grep -Fq 'frontmatterのnameが重複しています' "$TMP_ROOT/source-duplicate.log" || {
    /bin/cat "$TMP_ROOT/source-duplicate.log" >&2
    printf '[ERROR] frontmatter name重複の固有エラーがありません。\n' >&2
    exit 1
}
[ "$(edit_count)" -eq "$baseline_count" ] && [ "$(patch_count)" -eq "$baseline_patch_count" ] || { printf '[ERROR] frontmatter name重複時に部分更新が発生しました。\n' >&2; exit 1; }
rm -f "$SKILLS_MIRROR_DIR/writing-references/duplicate.md"
cp "$HARNESS_ROOT/custom-instructions/custom-instructions.md" "$MIRROR_DIR/custom-instructions.md"
cp "$HARNESS_ROOT/custom-instructions/user-profile.md" "$MIRROR_DIR/user-profile.md"

printf '%s\n' '---' 'description: missing name' 'metadata:' '  notion_sync: "true"' '---' '# missing name' >"$SKILLS_MIRROR_DIR/writing-references/missing-name.md"
printf '\n# pending update before missing name validation\n' >>"$MIRROR_DIR/custom-instructions.md"
printf '\n# pending profile update before missing name validation\n' >>"$MIRROR_DIR/user-profile.md"
if run_sync >"$TMP_ROOT/missing-name.log" 2>&1; then
    /bin/cat "$TMP_ROOT/missing-name.log" >&2
    printf '[ERROR] frontmatter name欠落を検出できませんでした。\n' >&2
    exit 1
fi
/usr/bin/grep -Fq 'フロントマターのnameがありません' "$TMP_ROOT/missing-name.log" || {
    /bin/cat "$TMP_ROOT/missing-name.log" >&2
    printf '[ERROR] frontmatter name欠落の固有エラーがありません。\n' >&2
    exit 1
}
[ "$(edit_count)" -eq "$baseline_count" ] && [ "$(patch_count)" -eq "$baseline_patch_count" ] || {
    printf '[ERROR] name欠落時に部分更新が発生しました。\n' >&2
    exit 1
}
rm -f "$SKILLS_MIRROR_DIR/writing-references/missing-name.md"
cp "$HARNESS_ROOT/custom-instructions/custom-instructions.md" "$MIRROR_DIR/custom-instructions.md"
cp "$HARNESS_ROOT/custom-instructions/user-profile.md" "$MIRROR_DIR/user-profile.md"

assert_invalid_reference() {
    local label=$1
    local expected_error=$2
    shift 2
    printf '%s\n' '---' "name: $label" 'metadata:' "$@" '---' "# $label" >"$SKILLS_MIRROR_DIR/writing-references/$label.md"
    assert_rejected_without_updates "$label" "$expected_error"
    rm -f "$SKILLS_MIRROR_DIR/writing-references/$label.md"
}
printf '%s\n' '---' 'name: metadata-invalid-type' 'metadata: [bad]' '---' '# metadata invalid type' >"$SKILLS_MIRROR_DIR/writing-references/metadata-invalid-type.md"
assert_rejected_without_updates 'metadata-invalid-type' 'metadata'
rm -f "$SKILLS_MIRROR_DIR/writing-references/metadata-invalid-type.md"
assert_invalid_reference 'role-invalid-type' 'notion_role' '  notion_sync: "true"' '  notion_role: [Main]'
assert_invalid_reference 'tags-invalid-json' 'notion_tags' '  notion_sync: "true"' "  notion_tags: 'not-json'"
assert_invalid_reference 'tags-not-array' 'notion_tags' '  notion_sync: "true"' "  notion_tags: '{}'"
assert_invalid_reference 'tags-non-string' 'notion_tags' '  notion_sync: "true"' "  notion_tags: '[1,\"text\"]'"
assert_invalid_reference 'tags-invalid-type' 'notion_tags' '  notion_sync: "true"' '  notion_tags: [text]'
printf '%s\n' '---' 'name: legacy-role' 'metadata:' '  notion_sync: "true"' 'role: "Main"' '---' '# legacy role' >"$SKILLS_MIRROR_DIR/writing-references/legacy-role.md"
assert_rejected_without_updates 'legacy-role' 'role'
rm -f "$SKILLS_MIRROR_DIR/writing-references/legacy-role.md"
printf '%s\n' '---' 'name: legacy-tags' 'metadata:' '  notion_sync: "true"' 'tags: [text]' '---' '# legacy tags' >"$SKILLS_MIRROR_DIR/writing-references/legacy-tags.md"
assert_rejected_without_updates 'legacy-tags' 'tags'
rm -f "$SKILLS_MIRROR_DIR/writing-references/legacy-tags.md"

ACCOUNT_TEST_DIR="$TMP_ROOT/account-test"
mkdir -p "$ACCOUNT_TEST_DIR"
FAKE_MOLCURE_TOKEN='fake-secret-molcure'
FAKE_PERSONAL_TOKEN='fake-secret-personal'
FAKE_MOLCURE_USER_ID='user-molcure'
FAKE_PERSONAL_USER_ID='user-personal'
FAKE_MOLCURE_WORKSPACE_ID='11111111111111111111111111111111'
FAKE_PERSONAL_WORKSPACE_ID='44444444444444444444444444444444'
FAKE_MOLCURE_CUSTOM_PAGE_ID='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
FAKE_MOLCURE_PROFILE_PAGE_ID='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB'
FAKE_MOLCURE_DATA_SOURCE_ID='AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC'
FAKE_PERSONAL_CUSTOM_PAGE_ID='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'
FAKE_PERSONAL_PROFILE_PAGE_ID='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBC'
FAKE_PERSONAL_DATA_SOURCE_ID='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBD'
FAKE_MOLCURE_QUERY_JSON="$ACCOUNT_TEST_DIR/molcure-query.json"
FAKE_PERSONAL_QUERY_JSON="$ACCOUNT_TEST_DIR/personal-query.json"

write_account_config() {
    local path=$1 account=$2 source=$3 user_id=$4 workspace_id=$5
    local custom_page_id=$6 profile_page_id=$7 data_source_id=$8
    cat >"$path" <<EOF
account_id=$account
credential_source=$source
expected_user_id=$user_id
workspace_id=$workspace_id
custom_instructions_page_id=$custom_page_id
user_profile_page_id=$profile_page_id
skills_data_source_id=$data_source_id
EOF
    chmod 600 "$path"
}

write_account_query() {
    local account=$1 path=$2
    /usr/bin/jq --arg prefix "$account-" '.results |= map(.id = ($prefix + .id))' \
        "$FAKE_QUERY_JSON" >"$path"
}

MOLCURE_CONFIG="$ACCOUNT_TEST_DIR/molcure.conf"
PERSONAL_CONFIG="$ACCOUNT_TEST_DIR/personal.conf"
write_account_config "$MOLCURE_CONFIG" molcure ntn-default "$FAKE_MOLCURE_USER_ID" \
    "$FAKE_MOLCURE_WORKSPACE_ID" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB \
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC
write_account_config "$PERSONAL_CONFIG" personal keychain "$FAKE_PERSONAL_USER_ID" \
    "$FAKE_PERSONAL_WORKSPACE_ID" BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBC \
    BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBD

write_account_query molcure "$FAKE_MOLCURE_QUERY_JSON"
write_account_query personal "$FAKE_PERSONAL_QUERY_JSON"

run_account_sync() {
    local account=$1 config=$2 events=$3 log=$4 actual_user_id=${5:-} keychain_mode=${6:-present}
    FAKE_ACCOUNT_TEST=1 \
    FAKE_MOLCURE_TOKEN="$FAKE_MOLCURE_TOKEN" \
    FAKE_PERSONAL_TOKEN="$FAKE_PERSONAL_TOKEN" \
    FAKE_MOLCURE_USER_ID="$FAKE_MOLCURE_USER_ID" \
    FAKE_PERSONAL_USER_ID="$FAKE_PERSONAL_USER_ID" \
    FAKE_MOLCURE_WORKSPACE_ID="$FAKE_MOLCURE_WORKSPACE_ID" \
    FAKE_PERSONAL_WORKSPACE_ID="$FAKE_PERSONAL_WORKSPACE_ID" \
    FAKE_MOLCURE_CUSTOM_PAGE_ID="$FAKE_MOLCURE_CUSTOM_PAGE_ID" \
    FAKE_MOLCURE_PROFILE_PAGE_ID="$FAKE_MOLCURE_PROFILE_PAGE_ID" \
    FAKE_MOLCURE_DATA_SOURCE_ID="$FAKE_MOLCURE_DATA_SOURCE_ID" \
    FAKE_PERSONAL_CUSTOM_PAGE_ID="$FAKE_PERSONAL_CUSTOM_PAGE_ID" \
    FAKE_PERSONAL_PROFILE_PAGE_ID="$FAKE_PERSONAL_PROFILE_PAGE_ID" \
    FAKE_PERSONAL_DATA_SOURCE_ID="$FAKE_PERSONAL_DATA_SOURCE_ID" \
    FAKE_MOLCURE_QUERY_JSON="$FAKE_MOLCURE_QUERY_JSON" \
    FAKE_PERSONAL_QUERY_JSON="$FAKE_PERSONAL_QUERY_JSON" \
    FAKE_KEYCHAIN_MODE="$keychain_mode" \
    FAKE_ACTUAL_USER_ID="$actual_user_id" \
    FAKE_EVENTS="$events" \
    FAKE_SECURITY_EVENTS="$FAKE_SECURITY_EVENTS" \
    SYNC_CONFIG_OVERRIDE="$config" \
        run_sync >"$log" 2>&1
}

account_edit_count() {
    local account=$1
    /usr/bin/grep -c "^$account:" "$FAKE_EDIT_LOG" 2>/dev/null || true
}

assert_account_preflight_precedes_writes() {
    local account=$1 custom_page_id=$2 profile_page_id=$3 data_source_id=$4 events=$5
    local first_write line
    first_write=$(/usr/bin/grep -n '^write:' "$events" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)
    [ -n "$first_write" ] || {
        printf '[ERROR] %sの同期にNotion更新要求がありません。\n' "$account" >&2
        exit 1
    }
    for expected in \
        "request:$account:GET:/v1/pages/$custom_page_id" \
        "request:$account:GET:/v1/pages/$profile_page_id" \
        "request:$account:GET:/v1/data_sources/$data_source_id" \
        "notion:$account:datasources"; do
        line=$(/usr/bin/grep -n -F -x "$expected" "$events" | /usr/bin/head -n 1 | /usr/bin/cut -d: -f1)
        [ -n "$line" ] && [ "$line" -lt "$first_write" ] || {
            printf '[ERROR] %sの全対象事前照合が更新より先に完了していません: %s\n' "$account" "$expected" >&2
            exit 1
        }
    done
}

: >"$FAKE_EDIT_LOG"
: >"$FAKE_PATCH_LOG"
: >"$FAKE_SECURITY_EVENTS"
run_account_sync molcure "$MOLCURE_CONFIG" "$ACCOUNT_TEST_DIR/molcure.events" "$ACCOUNT_TEST_DIR/molcure.log" || {
    /bin/cat "$ACCOUNT_TEST_DIR/molcure.log" >&2
    printf '[ERROR] MOLCUREアカウントの明示選択に失敗しました。\n' >&2
    exit 1
}
molcure_edit_count=$(account_edit_count molcure)
[ "$molcure_edit_count" -gt 0 ] || {
    /bin/cat "$ACCOUNT_TEST_DIR/molcure.log" >&2
    printf '[ERROR] MOLCUREアカウントへ同期しませんでした。\n' >&2
    exit 1
}
/usr/bin/grep -Fqx 'credential:ntn-default' "$ACCOUNT_TEST_DIR/molcure.events" || {
    printf '[ERROR] 既存MOLCURE Keychain経路を使っていません。\n' >&2
    exit 1
}
assert_account_preflight_precedes_writes molcure "$FAKE_MOLCURE_CUSTOM_PAGE_ID" \
    "$FAKE_MOLCURE_PROFILE_PAGE_ID" "$FAKE_MOLCURE_DATA_SOURCE_ID" "$ACCOUNT_TEST_DIR/molcure.events"

run_account_sync personal "$PERSONAL_CONFIG" "$ACCOUNT_TEST_DIR/personal.events" "$ACCOUNT_TEST_DIR/personal.log" || {
    /bin/cat "$ACCOUNT_TEST_DIR/personal.log" >&2
    printf '[ERROR] 個人アカウントの明示選択に失敗しました。\n' >&2
    exit 1
}
personal_edit_count=$(account_edit_count personal)
[ "$personal_edit_count" -gt 0 ] || {
    /bin/cat "$ACCOUNT_TEST_DIR/personal.log" >&2
    printf '[ERROR] 同一内容を個人アカウントへも同期しませんでした。\n' >&2
    exit 1
}
/usr/bin/grep -Fqx 'security:my.notion.personal' "$FAKE_SECURITY_EVENTS" || {
    printf '[ERROR] 個人アカウント用Keychain項目を選択しませんでした。\n' >&2
    exit 1
}
assert_account_preflight_precedes_writes personal "$FAKE_PERSONAL_CUSTOM_PAGE_ID" \
    "$FAKE_PERSONAL_PROFILE_PAGE_ID" "$FAKE_PERSONAL_DATA_SOURCE_ID" "$ACCOUNT_TEST_DIR/personal.events"
! /usr/bin/awk -F: '$1 == "molcure" && $2 == "personal" { found = 1 } END { exit found ? 0 : 1 }' \
    "$FAKE_EDIT_LOG" "$FAKE_PATCH_LOG" || {
    printf '[ERROR] MOLCURE資格情報で個人用Notion対象へ更新しました。\n' >&2
    exit 1
}
! /usr/bin/awk -F: '$1 == "personal" && $2 == "molcure" { found = 1 } END { exit found ? 0 : 1 }' \
    "$FAKE_EDIT_LOG" "$FAKE_PATCH_LOG" || {
    printf '[ERROR] 個人用資格情報でMOLCURE Notion対象へ更新しました。\n' >&2
    exit 1
}
/usr/bin/grep -q '^notion:molcure:' "$ACCOUNT_TEST_DIR/molcure.events"
/usr/bin/grep -q '^notion:personal:' "$ACCOUNT_TEST_DIR/personal.events"
! /usr/bin/grep -q '^notion:personal:' "$ACCOUNT_TEST_DIR/molcure.events"
! /usr/bin/grep -q '^notion:molcure:' "$ACCOUNT_TEST_DIR/personal.events"

assert_account_rejection_has_no_writes() {
    local label=$1 config=$2 actual_user_id=${3:-} keychain_mode=${4:-present}
    local before_edits before_patches
    local test_events="$ACCOUNT_TEST_DIR/$label.events"
    local test_security_events="$ACCOUNT_TEST_DIR/$label.security-events"
    local state_dir="$(dirname -- "$config")/state"
    before_edits=$(wc -l <"$FAKE_EDIT_LOG" | tr -d ' ')
    before_patches=$(wc -l <"$FAKE_PATCH_LOG" | tr -d ' ')
    rm -rf -- "$state_dir"
    mkdir -m 700 -p "$state_dir"
    : >"$test_events"
    : >"$test_security_events"
    FAKE_SECURITY_EVENTS="$test_security_events"
    export FAKE_SECURITY_EVENTS
    if run_account_sync personal "$config" "$test_events" "$ACCOUNT_TEST_DIR/$label.log" \
        "$actual_user_id" "$keychain_mode"; then
        printf '[ERROR] %sを安全に拒否しませんでした。\n' "$label" >&2
        exit 1
    fi
    [ "$(wc -l <"$FAKE_EDIT_LOG" | tr -d ' ')" -eq "$before_edits" ] || {
        printf '[ERROR] %sでNotion本文の部分更新が発生しました。\n' "$label" >&2
        exit 1
    }
    [ "$(wc -l <"$FAKE_PATCH_LOG" | tr -d ' ')" -eq "$before_patches" ] || {
        printf '[ERROR] %sでNotionメタデータの部分更新が発生しました。\n' "$label" >&2
        exit 1
    }
    ! /usr/bin/grep -q '^write:' "$test_events" || {
        printf '[ERROR] %sでNotion更新要求が記録されました。\n' "$label" >&2
        exit 1
    }
    if [ "$label" = missing-credential ]; then
        ! /usr/bin/grep -q '^credential:ntn-default$' "$test_events" || {
            printf '[ERROR] 個人用資格情報がないのに既定資格情報を取得しました。\n' >&2
            exit 1
        }
        ! /usr/bin/grep -q '^notion:' "$test_events" || {
            printf '[ERROR] 個人用資格情報がないのにNotion CLIを呼び出しました。\n' >&2
            exit 1
        }
        /usr/bin/grep -Fqx 'security-attempt:my.notion.personal' "$test_security_events" || {
            printf '[ERROR] 個人用資格情報の取得失敗を確認できません。\n' >&2
            exit 1
        }
        ! /usr/bin/grep -q 'my.notion.molcure' "$test_security_events" || {
            printf '[ERROR] 個人用資格情報がないのに会社用Keychain項目を参照しました。\n' >&2
            exit 1
        }
    fi
}

MISMATCH_CONFIG="$ACCOUNT_TEST_DIR/mismatch.conf"
sed 's/^expected_user_id=user-personal$/expected_user_id=unexpected-user/' "$PERSONAL_CONFIG" >"$MISMATCH_CONFIG"
assert_account_rejection_has_no_writes identity-mismatch "$MISMATCH_CONFIG"

WORKSPACE_MISMATCH_CONFIG="$ACCOUNT_TEST_DIR/workspace-mismatch.conf"
sed 's/^workspace_id=44444444444444444444444444444444$/workspace_id=55555555555555555555555555555555/' \
    "$PERSONAL_CONFIG" >"$WORKSPACE_MISMATCH_CONFIG"
assert_account_rejection_has_no_writes workspace-mismatch "$WORKSPACE_MISMATCH_CONFIG"

UNKNOWN_CONFIG="$ACCOUNT_TEST_DIR/unknown.conf"
sed 's/^account_id=personal$/account_id=unknown/' "$PERSONAL_CONFIG" >"$UNKNOWN_CONFIG"
assert_account_rejection_has_no_writes unknown-account "$UNKNOWN_CONFIG"

UNSET_CONFIG="$ACCOUNT_TEST_DIR/unset.conf"
sed '/^account_id=/d; /^credential_source=/d; /^expected_user_id=/d' "$PERSONAL_CONFIG" >"$UNSET_CONFIG"
assert_account_rejection_has_no_writes unset-account "$UNSET_CONFIG"

UNKNOWN_SOURCE_CONFIG="$ACCOUNT_TEST_DIR/unknown-source.conf"
sed 's/^credential_source=keychain$/credential_source=unknown/' "$PERSONAL_CONFIG" >"$UNKNOWN_SOURCE_CONFIG"
assert_account_rejection_has_no_writes unknown-credential-source "$UNKNOWN_SOURCE_CONFIG"

MISSING_CREDENTIAL_CONFIG="$ACCOUNT_TEST_DIR/missing-credential.conf"
cp "$PERSONAL_CONFIG" "$MISSING_CREDENTIAL_CONFIG"
assert_account_rejection_has_no_writes missing-credential "$MISSING_CREDENTIAL_CONFIG" '' missing

WRONG_TARGET_CONFIG="$ACCOUNT_TEST_DIR/wrong-target.conf"
sed "s/^user_profile_page_id=$FAKE_PERSONAL_PROFILE_PAGE_ID\$/user_profile_page_id=$FAKE_MOLCURE_PROFILE_PAGE_ID/" \
    "$PERSONAL_CONFIG" >"$WRONG_TARGET_CONFIG"
assert_account_rejection_has_no_writes wrong-target-page "$WRONG_TARGET_CONFIG"

WRONG_DATA_SOURCE_CONFIG="$ACCOUNT_TEST_DIR/wrong-data-source.conf"
sed "s/^skills_data_source_id=$FAKE_PERSONAL_DATA_SOURCE_ID\$/skills_data_source_id=$FAKE_MOLCURE_DATA_SOURCE_ID/" \
    "$PERSONAL_CONFIG" >"$WRONG_DATA_SOURCE_CONFIG"
assert_account_rejection_has_no_writes wrong-data-source "$WRONG_DATA_SOURCE_CONFIG"

# A changed snapshot forces both accounts through Notion work concurrently and
# proves that their credentials and completion caches stay independent.
printf '%s\n' '# concurrent account-isolation probe' >>"$HARNESS_ROOT/custom-instructions/custom-instructions.md"
before_concurrent_molcure=$(account_edit_count molcure)
before_concurrent_personal=$(account_edit_count personal)
run_account_sync molcure "$MOLCURE_CONFIG" "$ACCOUNT_TEST_DIR/concurrent-molcure.events" \
    "$ACCOUNT_TEST_DIR/concurrent-molcure.log" &
molcure_pid=$!
run_account_sync personal "$PERSONAL_CONFIG" "$ACCOUNT_TEST_DIR/concurrent-personal.events" \
    "$ACCOUNT_TEST_DIR/concurrent-personal.log" &
personal_pid=$!
molcure_status=0
personal_status=0
wait "$molcure_pid" || molcure_status=$?
wait "$personal_pid" || personal_status=$?
if [ "$molcure_status" -ne 0 ] || [ "$personal_status" -ne 0 ]; then
    /bin/cat "$ACCOUNT_TEST_DIR/concurrent-molcure.log" "$ACCOUNT_TEST_DIR/concurrent-personal.log" >&2
    printf '[ERROR] 同時実行時にアカウント別同期が失敗しました。\n' >&2
    exit 1
fi
[ "$(account_edit_count molcure)" -gt "$before_concurrent_molcure" ] || {
    printf '[ERROR] 同時実行時にMOLCURE側の同期がキャッシュで誤って省略されました。\n' >&2
    exit 1
}
[ "$(account_edit_count personal)" -gt "$before_concurrent_personal" ] || {
    printf '[ERROR] 同時実行時に個人側の同期がキャッシュで誤って省略されました。\n' >&2
    exit 1
}
/usr/bin/grep -q '^notion:molcure:' "$ACCOUNT_TEST_DIR/concurrent-molcure.events"
/usr/bin/grep -q '^notion:personal:' "$ACCOUNT_TEST_DIR/concurrent-personal.events"
! /usr/bin/grep -q '^notion:personal:' "$ACCOUNT_TEST_DIR/concurrent-molcure.events"
! /usr/bin/grep -q '^notion:molcure:' "$ACCOUNT_TEST_DIR/concurrent-personal.events"

for log_file in "$ACCOUNT_TEST_DIR"/*.log; do
    if /usr/bin/grep -F -e "$FAKE_MOLCURE_TOKEN" -e "$FAKE_PERSONAL_TOKEN" "$log_file"; then
        printf '[ERROR] 認証情報が出力へ漏れました: %s\n' "$log_file" >&2
        exit 1
    fi
done

printf '[SUCCESS] account-isolation tests passed; legacy suite had %s mirror files and %s synced files.\n' \
    "$mirror_file_count" "$syncable_file_count"
