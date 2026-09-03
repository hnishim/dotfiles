#!/bin/bash

set -euo pipefail

if [ "${1:-}" != "--sync" ]; then
    exit 64
fi

: "${TEST_SOURCE_DIR:?}"
: "${TEST_CODEX_HOME:?}"
: "${TEST_MIRROR_ROOT:?}"

read_utf8_source() {
    local path=$1
    local label=$2
    [ -s "$path" ] || {
        printf '[ERROR] 正本が存在しないか空です: %s\n' "$label" >&2
        return 1
    }
    /usr/bin/ruby -e 'path = ARGV.fetch(0); text = File.binread(path); text.force_encoding("UTF-8"); abort unless text.valid_encoding?' "$path" || {
        printf '[ERROR] 正本がUTF-8ではありません: %s\n' "$label" >&2
        return 1
    }
}

snapshot_sources() {
    read_utf8_source "$TEST_SOURCE_DIR/custom-instructions.md" custom-instructions.md
    read_utf8_source "$TEST_SOURCE_DIR/openai-instructions.md" openai-instructions.md
    read_utf8_source "$TEST_SOURCE_DIR/user-profile.md" user-profile.md
    custom_data=$(<"$TEST_SOURCE_DIR/custom-instructions.md")
    openai_data=$(<"$TEST_SOURCE_DIR/openai-instructions.md")
    profile_data=$(<"$TEST_SOURCE_DIR/user-profile.md")
}

snapshot_sources
if [ "${TEST_FORCE_UNSTABLE:-0}" = "1" ]; then
    printf '%s\n' '# changed during read window' >"$TEST_SOURCE_DIR/openai-instructions.md"
fi
if [ "${TEST_STABILITY_WAIT:-0}" != "0" ]; then
    /bin/sleep "$TEST_STABILITY_WAIT"
fi
read_utf8_source "$TEST_SOURCE_DIR/custom-instructions.md" custom-instructions.md
read_utf8_source "$TEST_SOURCE_DIR/openai-instructions.md" openai-instructions.md
read_utf8_source "$TEST_SOURCE_DIR/user-profile.md" user-profile.md
[ "$custom_data" = "$(<"$TEST_SOURCE_DIR/custom-instructions.md")" ] || {
    printf '[ERROR] 正本が安定していません。\n' >&2
    exit 1
}
[ "$openai_data" = "$(<"$TEST_SOURCE_DIR/openai-instructions.md")" ] || {
    printf '[ERROR] 正本が安定していません。\n' >&2
    exit 1
}
[ "$profile_data" = "$(<"$TEST_SOURCE_DIR/user-profile.md")" ] || {
    printf '[ERROR] 正本が安定していません。\n' >&2
    exit 1
}

output="$TEST_CODEX_HOME/AGENTS.md"
mirror="$TEST_MIRROR_ROOT/custom-instructions-sync"
skills="$TEST_MIRROR_ROOT/skills-notion-sync"
mkdir -p "$mirror" "$skills/example" "$skills/writing-references"

printf '%s\n\n%s\n\n%s\n' "$custom_data" "$openai_data" "$profile_data" >"$output"
printf '%s\n\n%s\n' "$custom_data" "$openai_data" >"$mirror/custom-instructions.md"
printf '%s\n' "$profile_data" >"$mirror/user-profile.md"
printf '%s\n' '---' 'name: example' 'notion_sync: true' '---' '# example' >"$skills/example/SKILL.md"
printf '%s\n' '---' 'name: prose' 'notion_sync: true' '---' '# prose' >"$skills/writing-references/prose.md"
