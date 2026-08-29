#!/bin/bash

# dotfilesのHammerspoon loaderをユーザー環境へシンボリックリンクで同期する。
source "$(dirname "$0")/../lib/common.sh"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
HAMMERSPOON_SOURCE="$SCRIPT_DIR/init.lua"
HAMMERSPOON_TARGET_DIRECTORY="$HOME/.hammerspoon"
HAMMERSPOON_TARGET="$HAMMERSPOON_TARGET_DIRECTORY/init.lua"

check_path "$HAMMERSPOON_SOURCE" "Hammerspoon loader" "file" || exit 1
if [ -L "$HAMMERSPOON_TARGET_DIRECTORY" ]; then
    log_error "Hammerspoon設定ディレクトリがsymlinkのため変更しません: $HAMMERSPOON_TARGET_DIRECTORY"
    exit 1
fi
ensure_directory "$HAMMERSPOON_TARGET_DIRECTORY" "Hammerspoon設定ディレクトリ" || exit 1
create_symlink "$HAMMERSPOON_SOURCE" "$HAMMERSPOON_TARGET" "Hammerspoon設定" || exit 1
