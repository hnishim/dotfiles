#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
# Sets default applications using duti.
# It processes a settings file in the format recommended by the official duti documentation.

# 共通ライブラリを読み込み
source "$(dirname "$0")/../lib/common.sh"

# --- Configuration ---
# Point to the settings file in the same directory as the script.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
SETTINGS_FILE="$SCRIPT_DIR/duti_settings.duti"

# --- 事前チェック ---

# Homebrewの存在チェック
check_homebrew || exit 1

# dutiの存在チェックとインストール
check_and_install_brew_package "duti" "duti" || exit 1

# 設定ファイルの存在チェック
check_path "$SETTINGS_FILE" "duti設定ファイル" "file" || exit 1

# --- メイン処理 ---

echo "--- Setting default applications using duti ---"
echo "Processing settings from: $SETTINGS_FILE"

duti "$SETTINGS_FILE"

# 完了メッセージの表示
show_completion_message "duti設定" "" ""
echo "--- Default application settings have been successfully applied! ---"
