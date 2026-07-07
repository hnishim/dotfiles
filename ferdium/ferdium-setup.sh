#!/bin/bash

# Ferdium カスタムレシピ同期スクリプト
# iCloud上のレシピファイルをローカルのFerdiumレシピディレクトリにシンボリックリンクで同期する

# 共通ライブラリを読み込み
source "$(dirname "$0")/../lib/common.sh"

# --- 変数定義 ---

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ICLOUD_GCAL_DIR="$SCRIPT_DIR/recipes/google-calendar"
ICLOUD_USER_JS="$ICLOUD_GCAL_DIR/user.js"
ICLOUD_WEBVIEW_JS="$ICLOUD_GCAL_DIR/webview.js"

LOCAL_GCAL_DIR="$HOME/Library/Application Support/Ferdium/recipes/google-calendar"
LOCAL_USER_JS="$LOCAL_GCAL_DIR/user.js"
LOCAL_WEBVIEW_JS="$LOCAL_GCAL_DIR/webview.js"
LOCAL_BACKUP_DIR="$LOCAL_GCAL_DIR/_backup"

echo "=== Ferdium カスタムレシピ同期スクリプト ==="

# --- 前提条件チェック ---
log_info "前提条件をチェック中..."
check_path "$ICLOUD_USER_JS" "user.js（dotfiles）" "file" || exit 1
check_path "$ICLOUD_WEBVIEW_JS" "webview.js（dotfiles）" "file" || exit 1
log_success "前提条件チェック完了"

# --- ローカルディレクトリの作成 ---
log_info "ローカルFerdiumレシピディレクトリを確認・作成中..."
mkdir -p "$LOCAL_GCAL_DIR"
log_success "ディレクトリを確認しました: $LOCAL_GCAL_DIR"

# --- バックアップディレクトリの作成 ---
create_backup_dir "$LOCAL_BACKUP_DIR"

echo ""
log_info "シンボリックリンクの状態を確認・作成します..."

# --- シンボリックリンクの確認・作成 ---
create_symlink "$ICLOUD_USER_JS" "$LOCAL_USER_JS" "$LOCAL_BACKUP_DIR" "user" "user.js" || exit 1
create_symlink "$ICLOUD_WEBVIEW_JS" "$LOCAL_WEBVIEW_JS" "$LOCAL_BACKUP_DIR" "webview" "webview.js" || exit 1

# --- 完了メッセージ ---
symlinks_info="  user.js: $LOCAL_USER_JS -> $ICLOUD_USER_JS
  webview.js: $LOCAL_WEBVIEW_JS -> $ICLOUD_WEBVIEW_JS"

show_completion_message "Ferdium カスタムレシピ同期" "$symlinks_info" "$LOCAL_BACKUP_DIR"
