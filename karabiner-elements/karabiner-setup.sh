#!/bin/bash

# Karabiner-Elements設定ファイル同期スクリプト
# iCloud上の設定ファイルをローカルのKarabiner-Elements設定にシンボリックリンクで同期する

# 前提
# 以下パスにある `karabiner_grabber` を、以下の設定箇所に追加
# パス：`/Library/Application Support/org.pqrs/Karabiner-Elements/bin/`
# 設定箇所：`System settings` → `Privacy & Security` → `Full Disk Access`

# 共通ライブラリを読み込み
source "$(dirname "$0")/../lib/common.sh"

# 変数定義
# Local path
LOCAL_KARABINER_DIR="$HOME/.config/karabiner"
LOCAL_KARABINER_JSON="$LOCAL_KARABINER_DIR/karabiner.json"
LOCAL_KARABINER_EDN="$HOME/.config/karabiner.edn"
LOCAL_BACKUP_DIR="$LOCAL_KARABINER_DIR/_backup"

# iCloud path
ICLOUD_KARABINER_JSON="$HOME/Library/Mobile Documents/com~apple~CloudDocs/dotfiles/karabiner-elements/karabiner.json"
ICLOUD_KARABINER_EDN="$HOME/Library/Mobile Documents/com~apple~CloudDocs/dotfiles/karabiner-elements/goku/karabiner.edn"

echo "=== Karabiner-Elements設定ファイル同期スクリプト ==="
echo "開始時刻: $(date)"

# 前提条件チェック
log_info "前提条件をチェック中..."

# iCloud設定ファイルの存在確認
check_file "$ICLOUD_KARABINER_JSON" "iCloud karabiner.json" || exit 1
check_file "$ICLOUD_KARABINER_EDN" "iCloud karabiner.edn" || exit 1

# ローカルKarabinerディレクトリの存在確認
check_directory "$LOCAL_KARABINER_DIR" "ローカルKarabinerディレクトリ" || exit 1

log_success "前提条件チェック完了"

# バックアップディレクトリの作成
create_backup_dir "$LOCAL_BACKUP_DIR"

echo ""
log_info "シンボリックリンクの状態を確認・作成します..."

# --- karabiner.json の同期 ---
create_symlink "$ICLOUD_KARABINER_JSON" "$LOCAL_KARABINER_JSON" "$LOCAL_BACKUP_DIR" "karabiner" "karabiner.json" || exit 1

# --- karabiner.edn (goku) の同期 ---
create_symlink "$ICLOUD_KARABINER_EDN" "$LOCAL_KARABINER_EDN" "$LOCAL_BACKUP_DIR" "karabiner" "karabiner.edn" || exit 1

# --- goku を実行して karabiner.json を更新 ---
log_info "goku を実行して karabiner.json の内容を更新します..."

# goku コマンドの存在確認
check_command "goku" "'brew install yqrashawn/goku/goku' を実行してインストールしてください。" || exit 1

# goku を実行して設定を karabiner.json に反映
if goku; then
    log_success "goku を実行し、karabiner.json を正常に更新しました。"

    log_info "Karabiner-Elementsを再起動して設定を反映します..."
    restart_process "Karabiner-Elements" "org.pqrs.service.agent.karabiner_console_user_server" || exit 1
else
    log_error "goku の実行に失敗しました。karabiner.edn の内容を確認してください。"
    exit 1
fi

# 完了メッセージの表示
symlinks_info="  karabiner.json: $LOCAL_KARABINER_JSON -> $ICLOUD_KARABINER_JSON
  karabiner.edn:  $LOCAL_KARABINER_EDN -> $ICLOUD_KARABINER_EDN"

show_completion_message "Karabiner-Elements設定ファイル同期" "$symlinks_info" "$LOCAL_BACKUP_DIR"