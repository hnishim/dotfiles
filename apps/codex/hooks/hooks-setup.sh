#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
INSTALLER="$SCRIPT_DIR/install-codex-hooks.py"
CODEX_HOME_DIR="${1:-${CODEX_HOME_DIR_OVERRIDE:-${CODEX_HOME:-$HOME/.codex}}}"

if [ "$#" -gt 1 ]; then
    printf '%s\n' '使い方: hooks-setup.sh [codex-home]' >&2
    exit 2
fi
if [ ! -f "$INSTALLER" ]; then
    printf '[ERROR] Hooks installer is missing: %s\n' "$INSTALLER" >&2
    exit 1
fi

exec /usr/bin/python3 "$INSTALLER" "$CODEX_HOME_DIR"
