#!/bin/bash

# Espanso設定ディレクトリ同期スクリプト
# dotfiles上の設定ディレクトリをローカルのEspanso設定にシンボリックリンクで同期する

# 共通ライブラリを読み込み
source "$(dirname "$0")/../../lib/common.sh"

# --- 変数定義 ---

# dotfiles上のEspanso設定パス
SCRIPT_DIR=$(get_script_dir)
ICLOUD_CONFIG_DIR="$SCRIPT_DIR/config"
ICLOUD_MATCH_DIR="$SCRIPT_DIR/match"

# ローカルのEspanso設定パス
LOCAL_ESPANSO_DIR="$HOME/Library/Application Support/espanso"
LOCAL_CONFIG_DIR="$LOCAL_ESPANSO_DIR/config"
LOCAL_MATCH_DIR="$LOCAL_ESPANSO_DIR/match"

echo "=== Espanso設定ディレクトリ同期スクリプト ==="

# --- メイン処理 ---

# 1. 前提条件チェック
log_info "前提条件をチェック中..."
check_path "$ICLOUD_CONFIG_DIR" "dotfiles configディレクトリ" "directory" || exit 1
check_path "$ICLOUD_MATCH_DIR" "dotfiles matchディレクトリ" "directory" || exit 1
log_success "前提条件チェック完了"

# 2. ローカル設定ルートの作成
ensure_directory "$LOCAL_ESPANSO_DIR" "Espanso設定ルート" || exit 1

echo ""
log_info "シンボリックリンクの状態を確認・作成します..."

# 3. 設定ディレクトリのシンボリックリンクを確認・作成
create_symlink "$ICLOUD_CONFIG_DIR" "$LOCAL_CONFIG_DIR" "configディレクトリ" || exit 1
create_symlink "$ICLOUD_MATCH_DIR" "$LOCAL_MATCH_DIR" "matchディレクトリ" || exit 1

# 完了メッセージの表示
symlinks_info="  config: $LOCAL_CONFIG_DIR -> $ICLOUD_CONFIG_DIR
  match: $LOCAL_MATCH_DIR -> $ICLOUD_MATCH_DIR"

show_completion_message "Espanso設定ディレクトリ同期" "$symlinks_info" ""
