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

# バックアップ用の日付（_YYYYMMDD形式）を取得
BACKUP_DATE=$(date +%Y%m%d)

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

echo ""
log_info "シンボリックリンクの状態を確認・作成します..."

# 4. シンボリックリンクの確認・作成
if [ -L "$LOCAL_GIT_IGNORE_FILE" ] && [ "$(readlink "$LOCAL_GIT_IGNORE_FILE")" = "$ICLOUD_IGNORE_FILE" ]; then
    log_success "ignore ファイルは既に正しくリンクされています。スキップします。"
else
    log_info "ignore ファイルの設定を開始します..."
    # 既存ファイルのバックアップ (ファイル、ディレクトリ、シンボリックリンクのいずれかが存在する場合)
    if [ -e "$LOCAL_GIT_IGNORE_FILE" ] || [ -L "$LOCAL_GIT_IGNORE_FILE" ]; then
        mv "$LOCAL_GIT_IGNORE_FILE" "$LOCAL_BACKUP_DIR/ignore_${BACKUP_DATE}"
        log_success "既存の ignore ファイルをバックアップしました: ignore_${BACKUP_DATE}"
    fi
    # シンボリックリンクの作成
    ln -sf "$ICLOUD_IGNORE_FILE" "$LOCAL_GIT_IGNORE_FILE"
    if [ -L "$LOCAL_GIT_IGNORE_FILE" ]; then
        log_success "ignore ファイルのシンボリックリンクを作成しました"
    else
        log_error "ignore ファイルのシンボリックリンク作成に失敗しました"
        exit 1
    fi
fi

# 5. Gitグローバル設定の更新
log_info "Gitのグローバル設定を更新中..."
git config --global core.excludesfile "$LOCAL_GIT_IGNORE_FILE"
log_success "Gitのグローバルignore設定を更新しました: core.excludesfile -> $LOCAL_GIT_IGNORE_FILE"

echo ""
log_success "=== 同期完了 ==="
echo "作成されたシンボリックリンク:"
echo "  ignore: $LOCAL_GIT_IGNORE_FILE -> $ICLOUD_IGNORE_FILE"
echo ""
echo "バックアップファイル:"
echo "  $LOCAL_BACKUP_DIR/"
