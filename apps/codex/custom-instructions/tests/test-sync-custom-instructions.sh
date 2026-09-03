#!/bin/bash

set -euo pipefail

if [ "${FAKE_HELPER_MODE:-0}" = "1" ] && [ "${1:-}" = "--sync" ]; then
    exit 0
fi

# The same file acts as a no-op helper and a deterministic fake ntn binary when
# it is copied to a temporary path during the isolated test.
fake_notion() {
    local command=$1
    shift

    case "$command" in
        whoami)
            exit 0
            ;;
        datasources)
            /bin/cat "$FAKE_QUERY_JSON"
            exit 0
            ;;
        pages)
            local subcommand=$1
            local page_id=$2
            case "$subcommand" in
                edit)
                    local page_file="$FAKE_STATE_DIR/$page_id.md"
                    /usr/bin/ruby -e 'path = ARGV.fetch(0); text = STDIN.read.force_encoding("UTF-8"); text = text.sub(/\A---\r?\n.*?\r?\n---\r?\n?/m, ""); File.write(path, text, mode: "w", encoding: "UTF-8")' "$page_file"
                    printf '%s\n' "$page_id" >>"$FAKE_EDIT_LOG"
                    ;;
                get)
                    printf '%s\n' '---' '---'
                    if [ -f "$FAKE_STATE_DIR/$page_id.md" ]; then
                        /bin/cat "$FAKE_STATE_DIR/$page_id.md"
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
            if [ "$method" = "PATCH" ]; then
                printf '%s' "$data" >"$FAKE_META_DIR/$page_id.json"
                printf '{"object":"page","id":"%s"}\n' "$page_id"
            else
                if [ -f "$FAKE_META_DIR/$page_id.json" ]; then
                    /usr/bin/jq -c --arg id "$page_id" '{object:"page",id:$id,properties:.properties}' "$FAKE_META_DIR/$page_id.json"
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
    whoami|datasources|pages|api)
        fake_notion "$@"
        exit $?
        ;;
esac

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DEV_ROOT=$(cd -- "$SCRIPT_DIR/../../../../../" && pwd)
SYNC_SCRIPT="$DEV_ROOT/dotfiles/apps/codex/custom-instructions/sync-custom-instructions"
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
FAKE_QUERY_JSON="$TMP_ROOT/query.json"
CONFIG="$CONFIG_DIR/notion-pages.conf"
HELPER="$TMP_ROOT/helper"
NTN="$TMP_ROOT/ntn"

mkdir -p "$MIRROR_DIR" "$SKILLS_MIRROR_DIR" "$LEGACY_MIRROR_DIR" "$LEGACY_SKILLS_MIRROR_DIR" "$CONFIG_DIR" "$FAKE_STATE_DIR" "$FAKE_META_DIR"
printf '%s\n' 'legacy mirror must not be read' >"$LEGACY_MIRROR_DIR/custom-instructions.md"
printf '%s\n' 'legacy mirror must not be read' >"$LEGACY_MIRROR_DIR/user-profile.md"
mkdir -p "$LEGACY_SKILLS_MIRROR_DIR/legacy"
printf '%s\n' '---' 'name: legacy' '---' '# legacy mirror must not be read' >"$LEGACY_SKILLS_MIRROR_DIR/legacy/SKILL.md"
cp "$0" "$HELPER"
cp "$0" "$NTN"
chmod 755 "$HELPER" "$NTN"

if [ -z "${CODEX_HARNESS_ROOT_OVERRIDE:-}" ]; then
    mkdir -p "$HARNESS_ROOT/custom-instructions" "$HARNESS_ROOT/skills/writing-references"
    printf '%s\n' '# custom fixture' >"$HARNESS_ROOT/custom-instructions/custom-instructions.md"
    printf '%s\n' '# profile fixture' >"$HARNESS_ROOT/custom-instructions/user-profile.md"
    for skill_name in "${TRUE_SKILLS[@]}"; do
        mkdir -p "$HARNESS_ROOT/skills/$skill_name"
        printf '%s\n' '---' "name: $skill_name" 'notion_sync: true' '---' "# $skill_name" \
            >"$HARNESS_ROOT/skills/$skill_name/SKILL.md"
    done
    for skill_name in "${FALSE_SKILLS[@]}"; do
        mkdir -p "$HARNESS_ROOT/skills/$skill_name"
        printf '%s\n' '---' "name: $skill_name" 'notion_sync: false' '---' "# $skill_name" \
            >"$HARNESS_ROOT/skills/$skill_name/SKILL.md"
    done
    for reference_name in "${TRUE_REFERENCES[@]}"; do
        printf '%s\n' '---' "name: $reference_name" 'notion_sync: true' '---' "# $reference_name" \
            >"$HARNESS_ROOT/skills/writing-references/$reference_name.md"
    done
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
  metadata.fetch("name") if metadata["notion_sync"] == true
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
    CUSTOM_INSTRUCTIONS_STABILITY_WAIT=0 \
    NOTION_READBACK_WAIT_SECONDS=0 \
    FAKE_STATE_DIR="$FAKE_STATE_DIR" \
    FAKE_META_DIR="$FAKE_META_DIR" \
    FAKE_EDIT_LOG="$FAKE_EDIT_LOG" \
    FAKE_QUERY_JSON="$FAKE_QUERY_JSON" \
    NOTION_SYNC_MIRROR_ROOT_OVERRIDE="$MIRROR_ROOT" \
    "$SYNC_SCRIPT" "$HELPER" "$NTN" "$CODEX_HOME" "$CONFIG"
}

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
[ "$(find "$SKILLS_MIRROR_DIR" -mindepth 2 -path '*/SKILL.md' -type f | while read -r f; do grep -c '^notion_sync: true$' "$f"; done | awk '{s+=$1} END {print s+0}')" -eq "$true_skill_count" ] || exit 1
[ "$(find "$SKILLS_MIRROR_DIR" -mindepth 2 -path '*/SKILL.md' -type f | while read -r f; do grep -c '^notion_sync: false$' "$f"; done | awk '{s+=$1} END {print s+0}')" -eq "$false_skill_count" ] || exit 1
[ "$(find "$SKILLS_MIRROR_DIR/writing-references" -type f -name '*.md' | while read -r f; do grep -c '^notion_sync: true$' "$f"; done | awk '{s+=$1} END {print s+0}')" -eq "$true_reference_count" ] || exit 1
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
    /usr/bin/grep -Fqx 'notion_sync: true' "$SKILLS_MIRROR_DIR/$skill_name/SKILL.md" || exit 1
done
for skill_name in "${FALSE_SKILLS[@]}"; do
    /usr/bin/grep -Fqx "name: $skill_name" "$SKILLS_MIRROR_DIR/$skill_name/SKILL.md" || exit 1
    /usr/bin/grep -Fqx 'notion_sync: false' "$SKILLS_MIRROR_DIR/$skill_name/SKILL.md" || exit 1
done
/usr/bin/grep -Fqx 'name: jobcan-fill-attendance' "$SKILLS_MIRROR_DIR/jobcan-fill-attendance/SKILL.md" || exit 1
/usr/bin/grep -Fqx 'notion_sync: false' "$SKILLS_MIRROR_DIR/jobcan-fill-attendance/SKILL.md" || exit 1
for reference_name in "${TRUE_REFERENCES[@]}"; do
    /usr/bin/grep -Fqx "name: $reference_name" "$SKILLS_MIRROR_DIR/writing-references/$reference_name.md" || exit 1
    /usr/bin/grep -Fqx 'notion_sync: true' "$SKILLS_MIRROR_DIR/writing-references/$reference_name.md" || exit 1
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
    [ "$(edit_count)" -eq "$baseline_count" ] || {
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
[ "$(edit_count)" -eq "$baseline_count" ] || {
    printf '[ERROR] ページ不足時に部分更新が発生しました。\n' >&2
    exit 1
}
cp "$HARNESS_ROOT/custom-instructions/custom-instructions.md" "$MIRROR_DIR/custom-instructions.md"
cp "$HARNESS_ROOT/custom-instructions/user-profile.md" "$MIRROR_DIR/user-profile.md"

printf '%s\n' '---' 'name: missing-notion-sync' '---' '# missing notion_sync' \
    >"$SKILLS_MIRROR_DIR/writing-references/missing-notion-sync.md"
assert_rejected_without_updates 'notion-sync-missing' 'frontmatterのnotion_syncがありません'
rm -f "$SKILLS_MIRROR_DIR/writing-references/missing-notion-sync.md"

printf '%s\n' '---' 'name: invalid-notion-sync' 'notion_sync: "true"' '---' '# invalid notion_sync' \
    >"$SKILLS_MIRROR_DIR/writing-references/invalid-notion-sync.md"
assert_rejected_without_updates 'notion-sync-type' 'frontmatterのnotion_syncがbooleanではありません'
rm -f "$SKILLS_MIRROR_DIR/writing-references/invalid-notion-sync.md"

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
[ "$(edit_count)" -eq "$baseline_count" ] || { printf '[ERROR] Codex ID重複時に部分更新が発生しました。\n' >&2; exit 1; }
cp "$HARNESS_ROOT/custom-instructions/custom-instructions.md" "$MIRROR_DIR/custom-instructions.md"
cp "$HARNESS_ROOT/custom-instructions/user-profile.md" "$MIRROR_DIR/user-profile.md"

printf '%s\n' '---' 'name: explain' 'notion_sync: true' '---' '# duplicate source' >"$SKILLS_MIRROR_DIR/writing-references/duplicate.md"
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
[ "$(edit_count)" -eq "$baseline_count" ] || { printf '[ERROR] frontmatter name重複時に部分更新が発生しました。\n' >&2; exit 1; }
rm -f "$SKILLS_MIRROR_DIR/writing-references/duplicate.md"
cp "$HARNESS_ROOT/custom-instructions/custom-instructions.md" "$MIRROR_DIR/custom-instructions.md"
cp "$HARNESS_ROOT/custom-instructions/user-profile.md" "$MIRROR_DIR/user-profile.md"

printf '%s\n' '---' 'notion_sync: true' 'description: missing name' '---' '# missing name' >"$SKILLS_MIRROR_DIR/writing-references/missing-name.md"
printf '\n# pending update before missing name validation\n' >>"$MIRROR_DIR/custom-instructions.md"
printf '\n# pending profile update before missing name validation\n' >>"$MIRROR_DIR/user-profile.md"
if run_sync >"$TMP_ROOT/missing-name.log" 2>&1; then
    /bin/cat "$TMP_ROOT/missing-name.log" >&2
    printf '[ERROR] frontmatter name欠落を検出できませんでした。\n' >&2
    exit 1
fi
/usr/bin/grep -Fq 'frontmatterのnameがありません' "$TMP_ROOT/missing-name.log" || {
    /bin/cat "$TMP_ROOT/missing-name.log" >&2
    printf '[ERROR] frontmatter name欠落の固有エラーがありません。\n' >&2
    exit 1
}
[ "$(edit_count)" -eq "$baseline_count" ] || {
    printf '[ERROR] name欠落時に部分更新が発生しました。\n' >&2
    exit 1
}
rm -f "$SKILLS_MIRROR_DIR/writing-references/missing-name.md"
cp "$HARNESS_ROOT/custom-instructions/custom-instructions.md" "$MIRROR_DIR/custom-instructions.md"
cp "$HARNESS_ROOT/custom-instructions/user-profile.md" "$MIRROR_DIR/user-profile.md"

printf '[SUCCESS] isolated sync tests passed (%s mirror files, %s synced files, %s excluded skills).\n' "$mirror_file_count" "$syncable_file_count" "$false_skill_count"
