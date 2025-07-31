#!/bin/bash

# Git ignore設定ファイル同期スクリプト
# iCloud上のignore.txtをローカルのGitグローバルignore設定にシンボリックリンクで同期する

set -euo pipefail # エラー時に即座に終了、未定義変数の使用を禁止

# --- 変数定義 ---

# スクリプト自身の場所を基準にiCloud上のignore.txtのパスを決定
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ICLOUD_IGNORE_FILE="$SCRIPT_DIR/ignore"

# ローカルのGit設定パス
LOCAL_GIT_CONFIG_DIR="$HOME/.config/git"
LOCAL_GIT_IGNORE_FILE="$LOCAL_GIT_CONFIG_DIR/ignore"
LOCAL_BACKUP_DIR="$LOCAL_GIT_CONFIG_DIR/_backup"

echo "=== Git ignore設定ファイル同期スクリプト ==="

# --- 関数定義 ---
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_success() {
    echo "[SUCCESS] $1"
}

# --- メイン処理 ---

# 1. 前提条件チェック
log_info "前提条件をチェック中..."
if [ ! -f "$ICLOUD_IGNORE_FILE" ]; then
    log_error "実体ファイルが見つかりません: $ICLOUD_IGNORE_FILE。実際のファイル名と一致しているか確認してください。"
    exit 1
fi
log_success "前提条件チェック完了"

# 2. ローカルGit設定ディレクトリの作成
log_info "ローカルGit設定ディレクトリを確認・作成中..."
if [ ! -d "$LOCAL_GIT_CONFIG_DIR" ]; then
    mkdir -p "$LOCAL_GIT_CONFIG_DIR"
    log_success "ディレクトリを作成しました: $LOCAL_GIT_CONFIG_DIR"
else
    log_info "ディレクトリは既に存在します: $LOCAL_GIT_CONFIG_DIR"
fi

# 3. バックアップディレクトリの作成
mkdir -p "$LOCAL_BACKUP_DIR"
log_info "バックアップディレクトリを確認・作成しました: $LOCAL_BACKUP_DIR"

# 4. 既存ファイルのバックアップ
log_info "既存のignoreファイルをバックアップ中..."
if [ -e "$LOCAL_GIT_IGNORE_FILE" ]; then
    BACKUP_FILENAME="ignore_$(date +%Y%m%d_%H%M%S)"
    mv "$LOCAL_GIT_IGNORE_FILE" "$LOCAL_BACKUP_DIR/$BACKUP_FILENAME"
    log_success "既存のignoreファイルをバックアップしました: $LOCAL_BACKUP_DIR/$BACKUP_FILENAME"
else
    log_info "既存のignoreファイルは見つかりません（新規作成）"
fi

# 5. シンボリックリンクの作成
log_info "シンボリックリンクを作成中..."
ln -sf "$ICLOUD_IGNORE_FILE" "$LOCAL_GIT_IGNORE_FILE"
if [ -L "$LOCAL_GIT_IGNORE_FILE" ]; then
    log_success "シンボリックリンクを作成しました"
else
    log_error "シンボリックリンクの作成に失敗しました"
    exit 1
fi

log_success "=== 同期完了 ==="
echo "作成されたシンボリックリンク: $LOCAL_GIT_IGNORE_FILE -> $ICLOUD_IGNORE_FILE"
