#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SETUP="$SCRIPT_DIR/../custom-instructions-setup.sh"

python3 - "$SETUP" <<'PY'
import re
import sys
from pathlib import Path

setup = Path(sys.argv[1]).resolve()
assert setup.is_file(), f"missing planned setup: {setup}"
source = setup.read_text(encoding="utf-8")
assert re.search(r"SCRIPT_DIR=\$\(get_script_dir\)", source)
assert "com.hnishim.custom-instructions-sync" in source
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
    "printf '%s\\n' 'if /usr/bin/grep -Fxq mismatch \"\$FAKE_SETUP_STATE_FILE\"; then'" \
    "printf '%s\\n' \"printf '%s\\n' source=/wrong-source\"" \
    "printf '%s\\n' \"printf '%s\\n' skills=/wrong-skills\"" \
    "printf '%s\\n' \"printf '%s\\n' output=/wrong-output\"" \
    "printf '%s\\n' \"printf '%s\\n' mirror=/wrong-mirror\"" \
    "printf '%s\\n' 'else'" \
    "printf '%s\\n' \"printf '%s\\n' source=$fixture_harness/custom-instructions\"" \
    "printf '%s\\n' \"printf '%s\\n' skills=$fixture_harness/skills\"" \
    "printf '%s\\n' \"printf '%s\\n' output=$codex_home\"" \
    "printf '%s\\n' \"printf '%s\\n' mirror=$fake_support/mirrors\"" \
    "printf '%s\\n' 'fi'" \
    "printf '%s\\n' ';;'" \
    "printf '%s\\n' '--authorize)'" \
    "printf '%s\\n' 'printf \"authorized\\n\" >\"\$FAKE_SETUP_STATE_FILE\"'" \
    "printf '%s\\n' 'printf \"authorize\\n\" >>\"\$FAKE_SETUP_AUTH\"'" \
    "printf '%s\\n' ';;'" \
    "printf '%s\\n' '--sync)'" \
    "printf '%s\\n' 'printf \"sync\\n\" >>\"\$FAKE_SETUP_EVENTS\"'" \
    "printf '%s\\n' \"mkdir -p '$fake_support/mirrors/custom-instructions-sync' '$fake_support/mirrors/skills-notion-sync/example' '$fake_support/mirrors/skills-notion-sync/writing-references'\"" \
    "printf '%s\\n' \"printf '%s\\n\\n%s\\n' custom openai >'$fake_support/mirrors/custom-instructions-sync/custom-instructions.md'\"" \
    "printf '%s\\n' \"printf '%s\\n' profile >'$fake_support/mirrors/custom-instructions-sync/user-profile.md'\"" \
    "printf '%s\\n' \"printf '%s\\n' skill >'$fake_support/mirrors/skills-notion-sync/example/SKILL.md'\"" \
    "printf '%s\\n' \"printf '%s\\n' reference >'$fake_support/mirrors/skills-notion-sync/writing-references/example.md'\"" \
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
chmod 755 "$fake_bin"/*

run_setup() {
    PATH="$fake_bin:$PATH" HOME="$TMP_ROOT/home" FAKE_SWIFTC="$fake_swiftc" \
    FAKE_SETUP_STATE_FILE="$TMP_ROOT/state" FAKE_SETUP_EVENTS="$TMP_ROOT/events" \
    FAKE_SETUP_AUTH="$TMP_ROOT/auth" CUSTOM_INSTRUCTIONS_APPLICATIONS_DIR_OVERRIDE="$fake_apps" \
    CUSTOM_INSTRUCTIONS_SUPPORT_DIR_OVERRIDE="$fake_support" LAUNCH_AGENTS_DIR_OVERRIDE="$fake_launch_agents" \
    CUSTOM_INSTRUCTIONS_LOG_DIR_OVERRIDE="$fake_logs" CUSTOM_INSTRUCTIONS_MODULE_CACHE_OVERRIDE="$fake_cache" \
    CODEX_HARNESS_ROOT_OVERRIDE="$fixture_harness" CODEX_HOME_DIR_OVERRIDE="$codex_home" \
    NTN_EXECUTABLE_OVERRIDE="$TMP_ROOT/missing-ntn" CODEX_HARNESS_PREPARE_ONLY=1 \
        /bin/bash "$SETUP" >"$TMP_ROOT/setup.log" 2>&1 || {
            cat "$TMP_ROOT/setup.log" >&2
            return 1
        }
}

: >"$TMP_ROOT/events"
: >"$TMP_ROOT/auth"
: >"$TMP_ROOT/state"
run_setup
[ "$(cat "$TMP_ROOT/auth")" = authorize ]
[ "$(cat "$TMP_ROOT/state")" = authorized ]
[ "$(cat "$TMP_ROOT/events")" = $'--status\n--status\nsync' ]

: >"$TMP_ROOT/events"
: >"$TMP_ROOT/auth"
printf '%s\n' authorized >"$TMP_ROOT/state"
run_setup
[ ! -s "$TMP_ROOT/auth" ]
[ "$(cat "$TMP_ROOT/events")" = $'--status\n--status\nsync' ]

: >"$TMP_ROOT/events"
: >"$TMP_ROOT/auth"
printf '%s\n' mismatch >"$TMP_ROOT/state"
set +e
run_setup
mismatch_status=$?
set -e
[ "$mismatch_status" -ne 0 ]
[ ! -s "$TMP_ROOT/auth" ]
[ "$(cat "$TMP_ROOT/events")" = $'--status\n--status' ]
printf '%s\n' '[PASS] custom-instructions setup authorization transaction contract'
