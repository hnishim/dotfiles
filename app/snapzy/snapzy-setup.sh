#!/bin/bash

# Snapzy設定ディレクトリ同期スクリプト
# dotfiles上のSnapzy設定ディレクトリをローカル設定へシンボリックリンクで同期する

# 共通ライブラリを読み込み
source "$(dirname "$0")/../../lib/common.sh"

# --- 変数定義 ---

SCRIPT_DIR=$(get_script_dir)

# Repository側のSnapzy設定ディレクトリ
SNAPZY_SOURCE_DIR="$SCRIPT_DIR"
SNAPZY_CONFIG_FILE="$SNAPZY_SOURCE_DIR/config.toml"

# ローカルSnapzy設定パス
LOCAL_CONFIG_DIR="$HOME/.config"
LOCAL_SNAPZY_DIR="$LOCAL_CONFIG_DIR/snapzy"
LOCAL_BACKUP_DIR="$LOCAL_CONFIG_DIR/_backup"

echo "=== Snapzy設定ディレクトリ同期スクリプト ==="

# --- 前提条件チェック ---
log_info "前提条件をチェック中..."
check_path "$SNAPZY_SOURCE_DIR" "dotfiles Snapzy設定ディレクトリ" "directory" || exit 1
check_path "$SNAPZY_CONFIG_FILE" "dotfiles Snapzy config.toml" "file" || exit 1
log_success "前提条件チェック完了"

# --- ローカル設定ディレクトリ・バックアップディレクトリの作成 ---
ensure_directory "$LOCAL_CONFIG_DIR" "ローカル設定ディレクトリ" || exit 1
create_backup_dir "$LOCAL_BACKUP_DIR"

echo ""
log_info "Snapzy設定ディレクトリのシンボリックリンクを確認・作成します..."

# リンク対象自身の外側にバックアップを置く。
create_symlink "$SNAPZY_SOURCE_DIR" "$LOCAL_SNAPZY_DIR" "$LOCAL_BACKUP_DIR" "snapzy" "Snapzy設定ディレクトリ" || exit 1

# --- 完了メッセージ ---
symlinks_info="  snapzy: $LOCAL_SNAPZY_DIR -> $SNAPZY_SOURCE_DIR"
show_completion_message "Snapzy設定ディレクトリ同期" "$symlinks_info" "$LOCAL_BACKUP_DIR"
