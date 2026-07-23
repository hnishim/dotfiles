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
check_command "brew" "先にHomebrewをインストールしてください。" || exit 1

# dutiの存在チェックとインストール
check_and_install_brew_package "duti" "duti" || exit 1

# 設定ファイルの存在チェック
check_path "$SETTINGS_FILE" "duti設定ファイル" "file" || exit 1

# --- メイン処理 ---

echo "--- Setting default applications using duti ---"
echo "Processing settings from: $SETTINGS_FILE"

duti_output=$(duti "$SETTINGS_FILE" 2>&1)
duti_status=$?

# Cursorが拡張子だけを宣言しているファイル形式では、拡張子ハンドラーの
# 登録後にdutiが動的UTIも設定しようとしてerror -50を返すことがある。
# この既知メッセージだけを分離し、それ以外の出力や終了失敗はエラーにする。
cursor_dynamic_uti_pattern='^failed to set com\.todesktop\.230313mzl4w4u92 as handler for dyn\.[[:alnum:]]+ \(error -50\)$'
cursor_dynamic_uti_warnings=$(printf '%s\n' "$duti_output" | grep -Ec "$cursor_dynamic_uti_pattern" || true)
unexpected_output=$(printf '%s\n' "$duti_output" | grep -Ev "$cursor_dynamic_uti_pattern" || true)

if [ "$duti_status" -ne 0 ] || [ -n "$unexpected_output" ]; then
    if [ -n "$duti_output" ]; then
        printf '%s\n' "$duti_output" >&2
    fi
    log_error "duti設定の適用に失敗しました"
    exit 1
fi

if [ "$cursor_dynamic_uti_warnings" -gt 0 ]; then
    log_info "Cursor固有の${cursor_dynamic_uti_warnings}形式は拡張子ハンドラーのみ登録しました（動的UTIは対象外）"
fi

# 完了メッセージの表示
show_completion_message "duti設定" "" ""
echo "--- Default application settings have been successfully applied! ---"
