#!/bin/bash

# Espanso設定ファイル同期スクリプト
# dotfiles上の設定ファイルをローカルのEspanso設定にシンボリックリンクで同期する

# 共通ライブラリを読み込み
source "$(dirname "$0")/../lib/common.sh"

# --- 変数定義 ---

# dotfiles上のEspanso設定パス
SCRIPT_DIR=$(get_script_dir)
ICLOUD_DEFAULT_YML="$SCRIPT_DIR/config/default.yml"
ICLOUD_BASE_YML="$SCRIPT_DIR/match/base.yml"

# ローカルのEspanso設定パス
LOCAL_ESPANSO_DIR="$HOME/Library/Application Support/espanso"
LOCAL_CONFIG_DIR="$LOCAL_ESPANSO_DIR/config"
LOCAL_MATCH_DIR="$LOCAL_ESPANSO_DIR/match"
LOCAL_DEFAULT_YML="$LOCAL_CONFIG_DIR/default.yml"
LOCAL_BASE_YML="$LOCAL_MATCH_DIR/base.yml"

echo "=== Espanso設定ファイル同期スクリプト ==="

# --- メイン処理 ---

# 1. 前提条件チェック
log_info "前提条件をチェック中..."
check_path "$ICLOUD_DEFAULT_YML" "dotfiles default.yml" "file" || exit 1
check_path "$ICLOUD_BASE_YML" "dotfiles base.yml" "file" || exit 1
log_success "前提条件チェック完了"

# 2. ローカル設定ディレクトリの作成
for directory in "$LOCAL_CONFIG_DIR" "$LOCAL_MATCH_DIR"; do
    ensure_directory "$directory" "Espanso設定ディレクトリ" || exit 1
done

echo ""
log_info "シンボリックリンクの状態を確認・作成します..."

# 4. シンボリックリンクの確認・作成
create_symlink "$ICLOUD_DEFAULT_YML" "$LOCAL_DEFAULT_YML" "default.yml" || exit 1
create_symlink "$ICLOUD_BASE_YML" "$LOCAL_BASE_YML" "base.yml" || exit 1

# 完了メッセージの表示
symlinks_info="  default.yml: $LOCAL_DEFAULT_YML -> $ICLOUD_DEFAULT_YML
  base.yml: $LOCAL_BASE_YML -> $ICLOUD_BASE_YML"

show_completion_message "Espanso設定ファイル同期" "$symlinks_info" ""
