#!/bin/bash

# Karabiner-Elements設定ファイル同期スクリプト
# iCloud上の設定ファイルをローカルのKarabiner-Elements設定にシンボリックリンクで同期する

# 前提
# `Karabiner-Core-Service` を、以下の設定箇所に追加
# 設定箇所：`System settings` → `Privacy & Security` → `Full Disk Access`

# 共通ライブラリを読み込み
source "$(dirname "$0")/../lib/common.sh"

# 変数定義
# Script path
SCRIPT_DIR=$(get_script_dir)

# Local path
LOCAL_KARABINER_DIR="$HOME/.config/karabiner"

# Repository path
ICLOUD_KARABINER_CONFIG="$SCRIPT_DIR/config"
ICLOUD_KARABINER_JSON="$SCRIPT_DIR/config/karabiner.json"
ICLOUD_KARABINER_EDN="$SCRIPT_DIR/goku/karabiner.edn"

echo "=== Karabiner-Elements設定ファイル同期スクリプト ==="
echo "開始時刻: $(date)"

# 前提条件チェック
log_info "前提条件をチェック中..."

# iCloud設定ファイルの存在確認
check_path "$ICLOUD_KARABINER_CONFIG" "iCloud Karabiner設定ディレクトリ" "directory" || exit 1
check_path "$ICLOUD_KARABINER_JSON" "iCloud karabiner.json" "file" || exit 1
check_path "$ICLOUD_KARABINER_EDN" "iCloud karabiner.edn" "file" || exit 1

# ローカル設定ディレクトリの親を作成（既存の競合は変更しない）
ensure_directory "$HOME/.config" "ローカル設定ディレクトリ"

log_success "前提条件チェック完了"

echo ""
log_info "シンボリックリンクの状態を確認・作成します..."

# --- Karabiner設定ディレクトリの同期 ---
create_symlink "$SCRIPT_DIR/config" "$LOCAL_KARABINER_DIR" "Karabiner設定ディレクトリ" || exit 1

# --- goku を実行して karabiner.json を更新 ---
log_info "goku を実行して karabiner.json の内容を更新します..."

# goku コマンドの存在確認
check_command "goku" "'brew install yqrashawn/goku/goku' を実行してインストールしてください。" || exit 1

# goku を実行して設定を karabiner.json に反映
if GOKU_EDN_CONFIG_FILE="$ICLOUD_KARABINER_EDN" goku; then
    log_success "goku を実行し、karabiner.json を正常に更新しました。"
else
    log_error "goku の実行に失敗しました。karabiner.edn の内容を確認してください。"
    exit 1
fi

# 完了メッセージの表示
symlinks_info="  karabiner directory: $LOCAL_KARABINER_DIR -> $ICLOUD_KARABINER_CONFIG
"

show_completion_message "Karabiner-Elements設定ファイル同期" "$symlinks_info" ""
