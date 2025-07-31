#!/bin/bash

# Cursor設定ファイル同期スクリプト
# iCloud上の設定ファイルをローカルのCursor設定にシンボリックリンクで同期する

set -euo pipefail  # エラー時に即座に終了、未定義変数の使用を禁止

# 変数定義
# Local path
LOCAL_USER_DIR="$HOME/Library/Application Support/Cursor/User"
LOCAL_SETTINGS_JSON="$LOCAL_USER_DIR/settings.json"
LOCAL_KEYBINDINGS_JSON="$LOCAL_USER_DIR/keybindings.json"
LOCAL_BACKUP_DIR="$LOCAL_USER_DIR/_backup"

# iCloud path
ICLOUD_USER_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/dotfiles/cursor/user-profile"
ICLOUD_SETTINGS_JSON="$ICLOUD_USER_DIR/settings.json"
ICLOUD_KEYBINDINGS_JSON="$ICLOUD_USER_DIR/keybindings.json"

# バックアップ用の日付（_YYYYMMDD形式）を取得
BACKUP_DATE=$(date +%Y%m%d)

echo "=== Cursor設定ファイル同期スクリプト ==="

# 関数定義
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_success() {
    echo "[SUCCESS] $1"
}

# 前提条件チェック
log_info "前提条件をチェック中..."

# iCloudディレクトリの存在確認
if [ ! -d "$ICLOUD_USER_DIR" ]; then
    log_error "$ICLOUD_USER_DIR ディレクトリが存在しません。パスを確認してください。"
    exit 1
fi

# iCloud設定ファイルの存在確認
if [ ! -f "$ICLOUD_SETTINGS_JSON" ]; then
    log_error "$ICLOUD_SETTINGS_JSON が存在しません。パスを確認してください。"
    exit 1
fi

if [ ! -f "$ICLOUD_KEYBINDINGS_JSON" ]; then
    log_error "$ICLOUD_KEYBINDINGS_JSON が存在しません。パスを確認してください。"
    exit 1
fi

# ローカルユーザーディレクトリの存在確認
if [ ! -d "$LOCAL_USER_DIR" ]; then
    log_error "$LOCAL_USER_DIR ディレクトリが存在しません。作成してから再実行してください。"
    exit 1
fi

log_success "前提条件チェック完了"

# バックアップディレクトリの作成
log_info "バックアップディレクトリを作成中..."
if [ ! -d "$LOCAL_BACKUP_DIR" ]; then
    mkdir -p "$LOCAL_BACKUP_DIR"
    log_success "バックアップディレクトリを作成しました: $LOCAL_BACKUP_DIR"
else
    log_info "バックアップディレクトリは既に存在します: $LOCAL_BACKUP_DIR"
fi

# 既存ファイルのバックアップ
log_info "既存ファイルをバックアップ中..."

# settings.jsonのバックアップ
if [ -f "$LOCAL_SETTINGS_JSON" ]; then
    mv "$LOCAL_SETTINGS_JSON" "$LOCAL_BACKUP_DIR/settings_${BACKUP_DATE}.json"
    log_success "settings.jsonをバックアップしました: settings_${BACKUP_DATE}.json"
else
    log_info "既存のsettings.jsonが見つかりません（新規作成）"
fi

# keybindings.jsonのバックアップ
if [ -f "$LOCAL_KEYBINDINGS_JSON" ]; then
    mv "$LOCAL_KEYBINDINGS_JSON" "$LOCAL_BACKUP_DIR/keybindings_${BACKUP_DATE}.json"
    log_success "keybindings.jsonをバックアップしました: keybindings_${BACKUP_DATE}.json"
else
    log_info "既存のkeybindings.jsonが見つかりません（新規作成）"
fi

# シンボリックリンクの作成
log_info "シンボリックリンクを作成中..."

# settings.jsonのシンボリックリンク作成
ln -sf "$ICLOUD_SETTINGS_JSON" "$LOCAL_SETTINGS_JSON"
if [ -L "$LOCAL_SETTINGS_JSON" ]; then
    log_success "settings.jsonのシンボリックリンクを作成しました"
else
    log_error "settings.jsonのシンボリックリンク作成に失敗しました"
    exit 1
fi

# keybindings.jsonのシンボリックリンク作成
ln -sf "$ICLOUD_KEYBINDINGS_JSON" "$LOCAL_KEYBINDINGS_JSON"
if [ -L "$LOCAL_KEYBINDINGS_JSON" ]; then
    log_success "keybindings.jsonのシンボリックリンクを作成しました"
else
    log_error "keybindings.jsonのシンボリックリンク作成に失敗しました"
    exit 1
fi

log_success "=== 同期完了 ==="
echo "作成されたシンボリックリンク:"
echo "  settings.json: $LOCAL_SETTINGS_JSON -> $ICLOUD_SETTINGS_JSON"
echo "  keybindings.json: $LOCAL_KEYBINDINGS_JSON -> $ICLOUD_KEYBINDINGS_JSON"
echo "バックアップファイル:"
echo "  $LOCAL_BACKUP_DIR/"