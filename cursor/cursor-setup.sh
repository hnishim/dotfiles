#!/bin/bash

# Cursor設定ファイル同期スクリプト
# iCloud上の設定ファイルをローカルのCursor設定にシンボリックリンクで同期する

# 共通ライブラリを読み込み
source "$(dirname "$0")/../lib/common.sh"

# 変数定義
# Local path
LOCAL_USER_DIR="$HOME/Library/Application Support/Cursor/User"
LOCAL_SETTINGS_JSON="$LOCAL_USER_DIR/settings.json"
LOCAL_KEYBINDINGS_JSON="$LOCAL_USER_DIR/keybindings.json"
LOCAL_BACKUP_DIR="$LOCAL_USER_DIR/_backup"

# iCloud path
ICLOUD_CURSOR_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/dotfiles/cursor"
ICLOUD_SETTINGS_JSON="$ICLOUD_CURSOR_DIR/user-profile/settings.json"
ICLOUD_KEYBINDINGS_JSON="$ICLOUD_CURSOR_DIR/user-profile/keybindings.json"
ICLOUD_EXTENSIONS_YML="$ICLOUD_CURSOR_DIR/extensions/extensions.yml"

echo "=== Cursor設定ファイル同期スクリプト ==="

# 前提条件チェック
log_info "前提条件をチェック中..."

# iCloudディレクトリの存在確認
check_directory "$ICLOUD_CURSOR_DIR" "iCloud Cursorディレクトリ" || exit 1

# iCloud設定ファイルの存在確認
check_file "$ICLOUD_SETTINGS_JSON" "iCloud settings.json" || exit 1
check_file "$ICLOUD_KEYBINDINGS_JSON" "iCloud keybindings.json" || exit 1
check_file "$ICLOUD_EXTENSIONS_YML" "iCloud extensions.yml" || exit 1

# コマンドの存在確認
check_command "cursor" "CursorのコマンドラインツールがPATH上にあることを確認してください。" || exit 1
check_command "yq" "'brew install yq' を実行してインストールしてください。" || exit 1

# ローカルユーザーディレクトリの存在確認
check_directory "$LOCAL_USER_DIR" "ローカルCursorユーザーディレクトリ" || exit 1

log_success "前提条件チェック完了"

# バックアップディレクトリの作成
create_backup_dir "$LOCAL_BACKUP_DIR"

echo ""
log_info "シンボリックリンクの状態を確認・作成します..."

# --- settings.json の同期 ---
create_symlink "$ICLOUD_SETTINGS_JSON" "$LOCAL_SETTINGS_JSON" "$LOCAL_BACKUP_DIR" "settings" "settings.json" || exit 1

# --- keybindings.json の同期 ---
create_symlink "$ICLOUD_KEYBINDINGS_JSON" "$LOCAL_KEYBINDINGS_JSON" "$LOCAL_BACKUP_DIR" "keybindings" "keybindings.json" || exit 1

# --- Cursor拡張機能のインストール ---
echo ""
log_info "Cursor拡張機能の状態を確認・インストールします..."

# インストール済み拡張機能のリストを取得
installed_extensions=$(cursor --list-extensions)
log_info "インストール済み拡張機能のリストを取得しました。"

# yqでインストール対象の拡張機能リストを取得
extensions_to_install=$(get_yaml_value "$ICLOUD_EXTENSIONS_YML" '.extensions[]')

echo "$extensions_to_install" | while IFS= read -r extension; do
    # 空行をスキップ
    if [ -z "$extension" ]; then continue; fi

    # 拡張機能が既にインストールされているか確認 (大文字小文字を区別しない)
    if echo "$installed_extensions" | grep -q -i "^${extension}$"; then
        log_success "拡張機能 '$extension' は既にインストールされています。スキップします。"
    else
        log_info "拡張機能 '$extension' をインストールします..."
        if cursor --install-extension "$extension"; then
            log_success "拡張機能 '$extension' のインストールに成功しました。"
        else
            log_error "拡張機能 '$extension' のインストールに失敗しました。"
        fi
    fi
done

# 完了メッセージの表示
symlinks_info="  settings.json: $LOCAL_SETTINGS_JSON -> $ICLOUD_SETTINGS_JSON
  keybindings.json: $LOCAL_KEYBINDINGS_JSON -> $ICLOUD_KEYBINDINGS_JSON"

show_completion_message "Cursor設定ファイル同期" "$symlinks_info" "$LOCAL_BACKUP_DIR"