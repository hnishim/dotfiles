#!/bin/bash

set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SWIFT_SOURCE="$SCRIPT_DIR/../CustomInstructionsSync.swift"
TEST_SOURCE="$SCRIPT_DIR/mirror-layout-test.swift"
TMP_ROOT=$(mktemp -d /tmp/hir99-mirror-layout.XXXXXX)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

swiftc "$SWIFT_SOURCE" "$TEST_SOURCE" \
    -DTESTING \
    -o "$TMP_ROOT/mirror-layout-test" \
    -framework AppKit -O -parse-as-library \
    -module-cache-path "$TMP_ROOT/swift-module-cache"

"$TMP_ROOT/mirror-layout-test" "$TMP_ROOT/fixtures"

source "$SCRIPT_DIR/../../../../lib/common.sh"
source "$SCRIPT_DIR/../mirror-layout.sh"

shell_fixture="$TMP_ROOT/shell-fixture/skills-notion-sync"
mkdir -p "$shell_fixture/example" "$shell_fixture/writing-references"
printf '%s\n' skill >"$shell_fixture/example/SKILL.md"
printf '%s\n' reference >"$shell_fixture/writing-references/example.md"
printf '%s\n' 'Finder metadata' >"$shell_fixture/.DS_Store"
printf '%s\n' 'Finder metadata' >"$shell_fixture/example/.DS_Store"
preflight_mirror_tree "$shell_fixture" skills

printf '%s\n' unexpected >"$shell_fixture/example/unexpected.txt"
if preflight_mirror_tree "$shell_fixture" skills 2>/dev/null; then
    echo "[ERROR] shell mirror layout accepted an unexpected file" >&2
    exit 1
fi

echo '[PASS] shell mirror metadata handling'

generated_source="$TMP_ROOT/generated-source"
generated_skills_source="$TMP_ROOT/generated-skills-source"
generated_custom="$TMP_ROOT/generated-custom-mirror"
generated_skills="$TMP_ROOT/generated-skills-mirror"
mkdir -p "$generated_source" "$generated_skills_source/example" "$generated_skills_source/writing-references" \
    "$generated_custom" "$generated_skills/example" "$generated_skills/writing-references"
printf '%s\n' custom >"$generated_source/custom-instructions.md"
printf '%s\n' openai >"$generated_source/openai-instructions.md"
printf '%s\n' profile >"$generated_source/user-profile.md"
printf '%s\n' skill >"$generated_skills_source/example/SKILL.md"
printf '%s\n' reference >"$generated_skills_source/writing-references/example.md"
printf '%s\n\n%s\n' custom openai >"$generated_custom/custom-instructions.md"
printf '%s\n' profile >"$generated_custom/user-profile.md"
printf '%s\n' skill >"$generated_skills/example/SKILL.md"
printf '%s\n' reference >"$generated_skills/writing-references/example.md"
printf '%s\n' 'Finder metadata' >"$generated_custom/.DS_Store"
printf '%s\n' 'Finder metadata' >"$generated_skills/.DS_Store"
printf '%s\n' 'Finder metadata' >"$generated_skills/example/.DS_Store"
validate_generated_mirrors "$generated_source" "$generated_skills_source" "$generated_custom" "$generated_skills"

echo '[PASS] generated mirror metadata handling'
