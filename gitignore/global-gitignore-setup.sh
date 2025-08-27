#!/bin/bash

# Git ignore設定ファイル同期スクリプト
# iCloud上のignore.txtをローカルのGitグローバルignore設定にシンボリックリンクで同期する

# 共通ライブラリを読み込み
source "$(dirname "$0")/../lib/common.sh"

# --- 変数定義 ---

# スクリプト自身の場所を基準にiCloud上のignore.txtのパスを決定
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ICLOUD_IGNORE_FILE="$SCRIPT_DIR/ignore"

# ローカルのGit設定パス
LOCAL_GIT_CONFIG_DIR="$HOME/.config/git"
LOCAL_GIT_IGNORE_FILE="$LOCAL_GIT_CONFIG_DIR/ignore"
LOCAL_BACKUP_DIR="$LOCAL_GIT_CONFIG_DIR/_backup"

echo "=== Git ignore設定ファイル同期スクリプト ==="

# --- メイン処理 ---

# 1. 前提条件チェック
log_info "前提条件をチェック中..."
check_path "$ICLOUD_IGNORE_FILE" "実体ファイル" "file" || exit 1
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
create_backup_dir "$LOCAL_BACKUP_DIR"

echo ""
log_info "シンボリックリンクの状態を確認・作成します..."

# 4. シンボリックリンクの確認・作成
create_symlink "$ICLOUD_IGNORE_FILE" "$LOCAL_GIT_IGNORE_FILE" "$LOCAL_BACKUP_DIR" "ignore" "ignore ファイル" || exit 1

# 5. Gitグローバル設定の更新
log_info "Gitのグローバル設定を更新中..."
git config --global core.excludesfile "$LOCAL_GIT_IGNORE_FILE"
log_success "Gitのグローバルignore設定を更新しました: core.excludesfile -> $LOCAL_GIT_IGNORE_FILE"

# 完了メッセージの表示
symlinks_info="  ignore: $LOCAL_GIT_IGNORE_FILE -> $ICLOUD_IGNORE_FILE"

show_completion_message "Git ignore設定ファイル同期" "$symlinks_info" "$LOCAL_BACKUP_DIR"
