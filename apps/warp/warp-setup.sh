#!/bin/bash

# Warp keybindings設定ファイル同期スクリプト
# iCloud上のkeybindings.yamlをローカルのWarp設定ディレクトリにシンボリックリンクで同期する

# 共通ライブラリを読み込み
source "$(dirname "$0")/../../lib/common.sh"

# --- 変数定義 ---

# スクリプト自身の場所を基準にiCloud上の設定ファイルのパスを決定
SCRIPT_DIR=$(get_script_dir)
ICLOUD_KEYBINDINGS_FILE="$SCRIPT_DIR/keybindings.yaml"
ICLOUD_MAINTENANCE_TAB_CONFIG="$SCRIPT_DIR/tab_configs/weekly-maintenance.toml"

# ローカルのWarp設定パス
LOCAL_WARP_DIR="$HOME/.warp"
LOCAL_KEYBINDINGS_FILE="$LOCAL_WARP_DIR/keybindings.yaml"
LOCAL_TAB_CONFIG_DIR="$LOCAL_WARP_DIR/tab_configs"
LOCAL_MAINTENANCE_TAB_CONFIG="$LOCAL_TAB_CONFIG_DIR/weekly-maintenance.toml"

echo "=== Warp keybindings設定ファイル同期スクリプト ==="

# --- メイン処理 ---

# 1. 前提条件チェック
log_info "前提条件をチェック中..."
check_path "$ICLOUD_KEYBINDINGS_FILE" "実体ファイル" "file" || exit 1
check_path "$ICLOUD_MAINTENANCE_TAB_CONFIG" "週次メンテナンスTab Config" "file" || exit 1
log_success "前提条件チェック完了"

# 2. ローカルWarp設定ディレクトリの作成
ensure_directory "$LOCAL_WARP_DIR" "ローカルWarp設定ディレクトリ" || exit 1
ensure_directory "$LOCAL_TAB_CONFIG_DIR" "ローカルWarp Tab Configディレクトリ" || exit 1

echo ""
log_info "シンボリックリンクの状態を確認・作成します..."

# 4. シンボリックリンクの確認・作成
create_symlink "$ICLOUD_KEYBINDINGS_FILE" "$LOCAL_KEYBINDINGS_FILE" "keybindings.yaml" || exit 1
create_symlink "$ICLOUD_MAINTENANCE_TAB_CONFIG" "$LOCAL_MAINTENANCE_TAB_CONFIG" "weekly-maintenance.toml" || exit 1

# 完了メッセージの表示
symlinks_info="  keybindings.yaml: $LOCAL_KEYBINDINGS_FILE -> $ICLOUD_KEYBINDINGS_FILE
  weekly-maintenance.toml: $LOCAL_MAINTENANCE_TAB_CONFIG -> $ICLOUD_MAINTENANCE_TAB_CONFIG"

show_completion_message "Warp keybindings設定ファイル同期" "$symlinks_info" ""
