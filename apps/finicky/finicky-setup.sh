#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/../../lib/common.sh"

SOURCE="$SCRIPT_DIR/finicky.js"
CONFIG_DIR="$HOME/.config/finicky"
TARGET="$CONFIG_DIR/finicky.js"

if [ ! -f "$SOURCE" ]; then
    log_error "管理対象のFinicky設定がありません: $SOURCE"
    exit 1
fi

ensure_directory "$HOME/.config" "~/.config" || exit 1
ensure_directory "$CONFIG_DIR" "~/.config/finicky" || exit 1
create_symlink "$SOURCE" "$TARGET" "Finicky設定" || exit 1
