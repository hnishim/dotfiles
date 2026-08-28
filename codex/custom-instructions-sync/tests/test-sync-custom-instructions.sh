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
DEV_ROOT=$(cd -- "$SCRIPT_DIR/../../../.." && pwd)
HARNESS_ROOT=${CODEX_HARNESS_ROOT_OVERRIDE:-$DEV_ROOT/harness}
SYNC_SCRIPT="$DEV_ROOT/dotfiles/codex/custom-instructions-sync/sync-custom-instructions"
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

CODEX_HOME="$TMP_ROOT/codex"
MIRROR_DIR="$CODEX_HOME/custom-instructions-sync"
SKILLS_MIRROR_DIR="$CODEX_HOME/skills-notion-sync"
CONFIG_DIR="$TMP_ROOT/config"
FAKE_STATE_DIR="$TMP_ROOT/pages"
FAKE_META_DIR="$TMP_ROOT/meta"
FAKE_EDIT_LOG="$TMP_ROOT/edits.log"
FAKE_QUERY_JSON="$TMP_ROOT/query.json"
CONFIG="$CONFIG_DIR/notion-pages.conf"
HELPER="$TMP_ROOT/helper"
NTN="$TMP_ROOT/ntn"

mkdir -p "$MIRROR_DIR" "$SKILLS_MIRROR_DIR" "$CONFIG_DIR" "$FAKE_STATE_DIR" "$FAKE_META_DIR"
cp "$0" "$HELPER"
cp "$0" "$NTN"
chmod 755 "$HELPER" "$NTN"

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
  YAML.safe_load(match[1], permitted_classes: [], aliases: false).fetch("name")
end
results = names.each_with_index.map do |name, index|
  {
    "object" => "page",
    "id" => "page-#{index}",
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
    "$SYNC_SCRIPT" "$HELPER" "$NTN" "$CODEX_HOME" "$CONFIG"
}

edit_count() {
    if [ -f "$FAKE_EDIT_LOG" ]; then
        wc -l <"$FAKE_EDIT_LOG" | tr -d ' '
    else
        printf '0\n'
    fi
}

skill_count=$(find "$SKILLS_MIRROR_DIR" -type f -name '*.md' | wc -l | tr -d ' ')
syncable_skill_count=$((skill_count - 9))
if ! run_sync >"$TMP_ROOT/first.log" 2>&1; then
    /bin/cat "$TMP_ROOT/first.log" >&2
    exit 1
fi
expected_count=$((syncable_skill_count + 2))
[ "$(edit_count)" -eq "$expected_count" ] || {
    /bin/cat "$TMP_ROOT/first.log" >&2
    printf '[ERROR] 初回更新件数が不正です: expected=%s actual=%s\n' "$expected_count" "$(edit_count)" >&2
    exit 1
}

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

/usr/bin/jq 'del(.results[0])' "$FAKE_QUERY_JSON" >"$TMP_ROOT/missing.json"
if FAKE_QUERY_JSON="$TMP_ROOT/missing.json" run_sync >"$TMP_ROOT/missing.log" 2>&1; then
    /bin/cat "$TMP_ROOT/missing.log" >&2
    printf '[ERROR] Notionページ不足を検出できませんでした。\n' >&2
    exit 1
fi
[ "$(edit_count)" -eq $((expected_count + 1)) ] || {
    printf '[ERROR] ページ不足時に部分更新が発生しました。\n' >&2
    exit 1
}

/usr/bin/jq '.results += [.results[0]]' "$FAKE_QUERY_JSON" >"$TMP_ROOT/duplicate.json"
if FAKE_QUERY_JSON="$TMP_ROOT/duplicate.json" run_sync >"$TMP_ROOT/duplicate.log" 2>&1; then
    /bin/cat "$TMP_ROOT/duplicate.log" >&2
    printf '[ERROR] Codex ID重複を検出できませんでした。\n' >&2
    exit 1
fi

printf '%s\n' '---' 'name: explain' '---' '# duplicate source' >"$SKILLS_MIRROR_DIR/writing-references/duplicate.md"
if run_sync >"$TMP_ROOT/source-duplicate.log" 2>&1; then
    /bin/cat "$TMP_ROOT/source-duplicate.log" >&2
    printf '[ERROR] frontmatter name重複を検出できませんでした。\n' >&2
    exit 1
fi
rm -f "$SKILLS_MIRROR_DIR/writing-references/duplicate.md"

printf '%s\n' '---' 'description: missing name' '---' '# missing name' >"$SKILLS_MIRROR_DIR/writing-references/missing-name.md"
if run_sync >"$TMP_ROOT/missing-name.log" 2>&1; then
    /bin/cat "$TMP_ROOT/missing-name.log" >&2
    printf '[ERROR] frontmatter name欠落を検出できませんでした。\n' >&2
    exit 1
fi
[ "$(edit_count)" -eq $((expected_count + 1)) ] || {
    printf '[ERROR] name欠落時に部分更新が発生しました。\n' >&2
    exit 1
}
rm -f "$SKILLS_MIRROR_DIR/writing-references/missing-name.md"

printf '[SUCCESS] isolated sync tests passed (%s mirror files, %s synced skill files).\n' "$skill_count" "$syncable_skill_count"
