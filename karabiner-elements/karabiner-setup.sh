#!/bin/bash

# Karabiner-Elements設定ファイル同期スクリプト
# iCloud上の設定ファイルをローカルのKarabiner-Elements設定にシンボリックリンクで同期する

set -euo pipefail  # エラー時に即座に終了、未定義変数の使用を禁止

# 前提
# 以下パスにある `karabiner_grabber` を、以下の設定箇所に追加
# パス：`/Library/Application Support/org.pqrs/Karabiner-Elements/bin/`
# 設定箇所：`System settings` → `Privacy & Security` → `Full Disk Access`

# 変数定義
# Local path
LOCAL_KARABINER_DIR="$HOME/.config/karabiner"
LOCAL_KARABINER_JSON="$LOCAL_KARABINER_DIR/karabiner.json"
LOCAL_KARABINER_EDN="$HOME/.config/karabiner.edn"
LOCAL_BACKUP_DIR="$LOCAL_KARABINER_DIR/_backup"

# iCloud path
ICLOUD_KARABINER_JSON="$HOME/Library/Mobile Documents/com~apple~CloudDocs/dotfiles/karabiner-elements/karabiner.json"
ICLOUD_KARABINER_EDN="$HOME/Library/Mobile Documents/com~apple~CloudDocs/dotfiles/karabiner-elements/goku/karabiner.edn"

# バックアップ用の日付（_YYYYMMDD形式）を取得
BACKUP_DATE=$(date +%Y%m%d)

echo "=== Karabiner-Elements設定ファイル同期スクリプト ==="
echo "開始時刻: $(date)"

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

# iCloud設定ファイルの存在確認
if [ ! -f "$ICLOUD_KARABINER_JSON" ]; then
    log_error "$ICLOUD_KARABINER_JSON が存在しません。パスを確認してください。"
    exit 1
fi

# goku設定ファイルの存在確認
if [ ! -f "$ICLOUD_KARABINER_EDN" ]; then
    log_error "$ICLOUD_KARABINER_EDN が存在しません。パスを確認してください。"
    exit 1
fi

# ローカルKarabinerディレクトリの存在確認
if [ ! -d "$LOCAL_KARABINER_DIR" ]; then
    log_error "$LOCAL_KARABINER_DIR ディレクトリが存在しません。作成してから再実行してください。"
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

echo ""
log_info "シンボリックリンクの状態を確認・作成します..."

# --- karabiner.json の同期 ---
if [ -L "$LOCAL_KARABINER_JSON" ] && [ "$(readlink "$LOCAL_KARABINER_JSON")" = "$ICLOUD_KARABINER_JSON" ]; then
    log_success "karabiner.json は既に正しくリンクされています。スキップします。"
else
    log_info "karabiner.json の設定を開始します..."
    # 既存ファイルのバックアップ (ファイル、ディレクトリ、シンボリックリンクのいずれかが存在する場合)
    if [ -e "$LOCAL_KARABINER_JSON" ] || [ -L "$LOCAL_KARABINER_JSON" ]; then
        mv "$LOCAL_KARABINER_JSON" "$LOCAL_BACKUP_DIR/karabiner_${BACKUP_DATE}.json"
        log_success "既存の karabiner.json をバックアップしました: karabiner_${BACKUP_DATE}.json"
    fi
    # シンボリックリンクの作成
    ln -sf "$ICLOUD_KARABINER_JSON" "$LOCAL_KARABINER_JSON"
    if [ -L "$LOCAL_KARABINER_JSON" ]; then
        log_success "karabiner.json のシンボリックリンクを作成しました"
    else
        log_error "karabiner.json のシンボリックリンク作成に失敗しました"
        exit 1
    fi
fi

# --- karabiner.edn (goku) の同期 ---
if [ -L "$LOCAL_KARABINER_EDN" ] && [ "$(readlink "$LOCAL_KARABINER_EDN")" = "$ICLOUD_KARABINER_EDN" ]; then
    log_success "karabiner.edn は既に正しくリンクされています。スキップします。"
else
    log_info "karabiner.edn の設定を開始します..."
    # 既存ファイルのバックアップ (ファイル、ディレクトリ、シンボリックリンクのいずれかが存在する場合)
    if [ -e "$LOCAL_KARABINER_EDN" ] || [ -L "$LOCAL_KARABINER_EDN" ]; then
        mv "$LOCAL_KARABINER_EDN" "$LOCAL_BACKUP_DIR/karabiner_${BACKUP_DATE}.edn"
        log_success "既存の karabiner.edn をバックアップしました: karabiner_${BACKUP_DATE}.edn"
    fi
    # シンボリックリンクの作成
    ln -sf "$ICLOUD_KARABINER_EDN" "$LOCAL_KARABINER_EDN"
    if [ -L "$LOCAL_KARABINER_EDN" ]; then
        log_success "karabiner.edn のシンボリックリンクを作成しました"
    else
        log_error "karabiner.edn のシンボリックリンク作成に失敗しました"
        exit 1
    fi
fi

echo ""
log_success "=== 同期完了 ==="
echo "終了時刻: $(date)"
echo ""
echo "作成されたシンボリックリンク:"
echo "  karabiner.json: $LOCAL_KARABINER_JSON -> $ICLOUD_KARABINER_JSON"
echo "  karabiner.edn:  $LOCAL_KARABINER_EDN -> $ICLOUD_KARABINER_EDN"
echo ""
echo "バックアップファイル:"
echo "  $LOCAL_BACKUP_DIR/"