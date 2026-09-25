#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)

assert_single_api_contract() {
    local script="$1"
    local expected_count="$2"
    awk -v expected="$expected_count" '
        /^[[:space:]]*create_symlink / {
            if ($0 !~ /^[[:space:]]*create_symlink "[^"]*" "[^"]*" "[^"]*" \|\| exit 1$/) { invalid=1 }
            count++
        }
        END { exit invalid || count != expected ? 1 : 0 }
    ' "$DOTFILES_ROOT/$script"
}

assert_setup_script_registered() {
    awk '
        /^setup_scripts=\(/ { inside=1; next }
        inside && /^\)[[:space:]]*$/ { inside=0 }
        inside && $0 == "    \"hammerspoon/hammerspoon-setup.sh\"" { count++ }
        END { exit count == 1 ? 0 : 1 }
    ' "$DOTFILES_ROOT/setup-macos.sh"
}

assert_codex_entrypoint_contract() {
    /usr/bin/python3 - "$DOTFILES_ROOT/setup-macos.sh" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"setup_scripts=\(\n(?P<body>.*?)\n\)", source, re.S)
if not match:
    raise SystemExit("setup-macos.sh has no setup_scripts array")
entries = re.findall(r'^\s+"([^"]+)"\s*$', match.group("body"), re.M)
if entries.count("apps/codex/codex-setup.sh") != 1:
    raise SystemExit("Codex setup entry is missing or duplicated")
for forbidden in (
    "apps/codex/agents-setup.sh",
    "apps/codex/agents/agents-setup.sh",
    "apps/codex/skills/skills-setup.sh",
    "apps/codex/custom-instructions-sync/custom-instructions-setup.sh",
    "apps/codex/custom-instructions/custom-instructions-setup.sh",
    "apps/codex/hooks/hooks-setup.sh",
):
    if forbidden in entries:
        raise SystemExit(f"Codex feature setup is registered directly: {forbidden}")
PY
}

assert_hammerspoon_contract() {
    local setup="$DOTFILES_ROOT/hammerspoon/hammerspoon-setup.sh"
    local expected='create_symlink "$HAMMERSPOON_SOURCE" "$HAMMERSPOON_TARGET" "Hammerspoon設定" || exit 1'
    local actual
    actual=$(awk '/^[[:space:]]*create_symlink / { print; count++ } END { if (count != 1) exit 1 }' "$setup") || return 1
    [ "$actual" = "$expected" ] || return 1
    ! rg -n -i 'RAYCAST|Raycast|external_scripts|title-case-chicago|two-panes-finder|scripts/raycast' "$setup" >/dev/null
}

assert_karabiner_goku_contract() {
    local setup="$DOTFILES_ROOT/karabiner-elements/karabiner-setup.sh"
    local configured_count
    local bare_count
    local failures=0

    configured_count=$(awk '
        /^[[:space:]]*#/ { next }
        { while (match($0, /GOKU_EDN_CONFIG_FILE="\$ICLOUD_KARABINER_EDN"[[:space:]]+goku/)) { count++; $0 = substr($0, RSTART + RLENGTH) } }
        END { print count + 0 }
    ' "$setup")
    if [ "$configured_count" -ne 1 ]; then
        failures=$((failures + 1))
    fi

    bare_count=$(awk '
        /^[[:space:]]*#/ { next }
        {
            line = $0
            while (match(line, /GOKU_EDN_CONFIG_FILE="\$ICLOUD_KARABINER_EDN"[[:space:]]+goku/)) {
                line = substr(line, 1, RSTART - 1) substr(line, RSTART + RLENGTH)
            }
            if (line ~ /(^|[[:space:];|&])goku([[:space:];|&]|$)/) count++
        }
        END { print count + 0 }
    ' "$setup")
    if [ "$bare_count" -ne 0 ]; then
        failures=$((failures + 1))
    fi

    if rg -n '(^|[;&|[:space:]])(rm|unlink)([[:space:]]|$).*([Kk][Aa][Rr][Aa][Bb][Ii][Nn][Ee][Rr]\.edn|LOCAL_KARABINER_EDN)' "$setup" >/dev/null; then
        failures=$((failures + 1))
    fi

    return "$failures"
}

failures=0
run_contract() {
    local script="$1"
    local expected_count="$2"
    if [ "$script" = "hammerspoon/hammerspoon-setup.sh" ]; then
        if assert_hammerspoon_contract; then
            printf '%s\n' "[PASS] $script"
        else
            printf '%s\n' "[FAIL] $script (current Hammerspoon loader link contract)" >&2
            failures=$((failures + 1))
        fi
    elif assert_single_api_contract "$script" "$expected_count"; then
        printf '%s\n' "[PASS] $script"
    else
        printf '%s\n' "[FAIL] $script (create_symlink call contract)" >&2
        failures=$((failures + 1))
    fi
}

run_contract apps/cursor/cursor-setup.sh 2
run_contract apps/espanso/espanso-setup.sh 2
run_contract apps/ferdium/ferdium-setup.sh 2
run_contract gitignore/global-gitignore-setup.sh 1
run_contract karabiner-elements/karabiner-setup.sh 1
run_contract apps/warp/warp-setup.sh 2
run_contract apps/snapzy/snapzy-setup.sh 1
run_contract textlint/textlint-setup.sh 2
run_contract hammerspoon/hammerspoon-setup.sh 1

if bash -n "$DOTFILES_ROOT/launchd/weekly-maintenance-setup.sh" \
    && rg -q 'RUNTIME_DIR=.*my\.launchd\.weekly-maintenance' "$DOTFILES_ROOT/launchd/weekly-maintenance-setup.sh" \
    && rg -q 'install -m 755' "$DOTFILES_ROOT/launchd/weekly-maintenance-setup.sh" \
    && rg -q 'launchctl bootstrap' "$DOTFILES_ROOT/launchd/weekly-maintenance-setup.sh" \
    && ! rg -q 'create_symlink|com\.hnishim' "$DOTFILES_ROOT/launchd/weekly-maintenance-setup.sh"; then
    printf '%s\n' '[PASS] launchd/weekly-maintenance-setup.sh uses one local runtime copy and the my.launchd label'
else
    printf '%s\n' '[FAIL] launchd/weekly-maintenance-setup.sh runtime and label contract' >&2
    failures=$((failures + 1))
fi

# Agents and Skills install root links without create_symlink. Their actual
# installation and conflict behavior is covered by their existing setup tests.
if assert_karabiner_goku_contract; then
    printf '%s\n' '[PASS] karabiner-elements/karabiner-setup.sh uses one configured Goku call and preserves local karabiner.edn'
else
    printf '%s\n' '[FAIL] karabiner-elements/karabiner-setup.sh Goku input/deletion contract' >&2
    failures=$((failures + 1))
fi

if assert_setup_script_registered; then
    printf '%s\n' '[PASS] setup-macos.sh registers hammerspoon/hammerspoon-setup.sh'
else
    printf '%s\n' '[FAIL] setup-macos.sh Hammerspoon setup registration contract' >&2
    failures=$((failures + 1))
fi

if grep -Fqx '    "apps/codex/skills/skills-setup.sh"' "$DOTFILES_ROOT/setup-macos.sh"; then
    printf '%s\n' '[FAIL] setup-macos.sh runs Skills setup standalone' >&2
    failures=$((failures + 1))
else
    printf '%s\n' '[PASS] setup-macos.sh delegates Skills installation to codex-setup transaction'
fi

if assert_codex_entrypoint_contract; then
    printf '%s\n' '[PASS] setup-macos.sh registers only the Codex aggregate setup'
else
    printf '%s\n' '[FAIL] setup-macos.sh Codex aggregate entrypoint contract' >&2
    failures=$((failures + 1))
fi

[ "$failures" -eq 0 ]
