#!/bin/bash

# Warp keybindings設定ファイル同期スクリプト
# iCloud上のkeybindings.yamlをローカルのWarp設定ディレクトリにシンボリックリンクで同期する

set -euo pipefail # エラー時に即座に終了、未定義変数の使用を禁止

# --- 変数定義 ---

# スクリプト自身の場所を基準にiCloud上の設定ファイルのパスを決定
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ICLOUD_KEYBINDINGS_FILE="$SCRIPT_DIR/keybindings.yaml"

# ローカルのWarp設定パス
LOCAL_WARP_DIR="$HOME/.warp"
LOCAL_KEYBINDINGS_FILE="$LOCAL_WARP_DIR/keybindings.yaml"
LOCAL_BACKUP_DIR="$LOCAL_WARP_DIR/_backup"

echo "=== Warp keybindings設定ファイル同期スクリプト ==="

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
if [ ! -f "$ICLOUD_KEYBINDINGS_FILE" ]; then
    log_error "実体ファイルが見つかりません: $ICLOUD_KEYBINDINGS_FILE"
    exit 1
fi
log_success "前提条件チェック完了"

# 2. ローカルWarp設定ディレクトリの作成
log_info "ローカルWarp設定ディレクトリを確認・作成中..."
mkdir -p "$LOCAL_WARP_DIR"
log_success "ディレクトリを作成しました: $LOCAL_WARP_DIR"

# 3. バックアップディレクトリの作成
mkdir -p "$LOCAL_BACKUP_DIR"
log_info "バックアップディレクトリを確認・作成しました: $LOCAL_BACKUP_DIR"

# 4. 既存ファイルのバックアップ
log_info "既存のkeybindings.yamlをバックアップ中..."
if [ -e "$LOCAL_KEYBINDINGS_FILE" ]; then
    BACKUP_FILENAME="keybindings.yaml_$(date +%Y%m%d_%H%M%S)"
    mv "$LOCAL_KEYBINDINGS_FILE" "$LOCAL_BACKUP_DIR/$BACKUP_FILENAME"
    log_success "既存のファイルをバックアップしました: $LOCAL_BACKUP_DIR/$BACKUP_FILENAME"
else
    log_info "既存のファイルは見つかりません（新規作成）"
fi

# 5. シンボリックリンクの作成
log_info "シンボリックリンクを作成中..."
ln -sf "$ICLOUD_KEYBINDINGS_FILE" "$LOCAL_KEYBINDINGS_FILE"
if [ -L "$LOCAL_KEYBINDINGS_FILE" ]; then
    log_success "シンボリックリンクを作成しました"
else
    log_error "シンボリックリンクの作成に失敗しました"
    exit 1
fi

log_success "=== 同期完了 ==="
echo "作成されたシンボリックリンク: $LOCAL_KEYBINDINGS_FILE -> $ICLOUD_KEYBINDINGS_FILE"
