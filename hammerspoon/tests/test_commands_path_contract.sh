#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
SETUP_TEST="$DOTFILES_ROOT/hammerspoon/tests/test_hammerspoon_setup.sh"
WORKFLOW="$DOTFILES_ROOT/.github/workflows/tests.yml"

rg -Fq 'PRODUCTION_COMMANDS_ROOT=$(cd -- "$DOTFILES_ROOT/../scripts/commands" && pwd)' "$SETUP_TEST"
rg -Fq 'FIXTURE_COMMANDS_ROOT="$FIXTURE_ROOT/scripts/commands"' "$SETUP_TEST"

if rg -n 'PRODUCTION_RAYCAST_ROOT|FIXTURE_RAYCAST_ROOT|\.\./scripts/raycast|scripts/raycast' "$SETUP_TEST" "$WORKFLOW"; then
    printf '%s\n' 'legacy Raycast directory contract remains in active dotfiles test/CI paths' >&2
    exit 1
fi

rg -Fq 'hammerspoon/tests/test_hammerspoon_setup.sh — requires ../scripts/hammerspoon and ../scripts/commands' "$WORKFLOW"

printf '%s\n' 'commands path contract test passed'
