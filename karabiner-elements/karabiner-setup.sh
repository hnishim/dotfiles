#!/bin/bash

# Karabiner-Elements設定ファイル同期スクリプト
# iCloud上の設定ファイルをローカルのKarabiner-Elements設定にシンボリックリンクで同期する
#
# Mimiなどのshell_commandからウインドウを操作する設定では、実行主体である
# `karabiner_console_user_server` にAccessibility許可が必要です。
# この許可はmacOSのTCC管理下にあり、dotfilesから自動付与できないため、
# 初回セットアップ後またはKarabiner更新後にシステム設定で手動確認します。

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
LOCAL_KARABINER_JSON="$LOCAL_KARABINER_DIR/karabiner.json"
LOCAL_KARABINER_EDN="$HOME/.config/karabiner.edn"
LOCAL_BACKUP_DIR="$LOCAL_KARABINER_DIR/_backup"
LOCAL_ASSETS_DIR="$LOCAL_KARABINER_DIR/.local"
TWO_PANES_FINDER_NAME="two-panes-finder.applescript"
TWO_PANES_FINDER_LINK="$LOCAL_ASSETS_DIR/$TWO_PANES_FINDER_NAME"
TWO_PANES_FINDER_SEARCH_ROOT="${TWO_PANES_FINDER_SEARCH_ROOT:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/Dev/scripts}"
MIMI_RESIZE_NAME="mimi-resize.sh"
MIMI_RESIZE_SOURCE="$SCRIPT_DIR/$MIMI_RESIZE_NAME"
MIMI_RESIZE_LINK="$LOCAL_ASSETS_DIR/$MIMI_RESIZE_NAME"

# Repository path
ICLOUD_KARABINER_JSON="$SCRIPT_DIR/karabiner.json"
ICLOUD_KARABINER_EDN="$SCRIPT_DIR/goku/karabiner.edn"

echo "=== Karabiner-Elements設定ファイル同期スクリプト ==="
echo "開始時刻: $(date)"

# 前提条件チェック
log_info "前提条件をチェック中..."

# iCloud設定ファイルの存在確認
check_path "$ICLOUD_KARABINER_JSON" "iCloud karabiner.json" "file" || exit 1
check_path "$ICLOUD_KARABINER_EDN" "iCloud karabiner.edn" "file" || exit 1
check_path "$MIMI_RESIZE_SOURCE" "Mimiラッパースクリプト" "file" || exit 1

# ローカルKarabinerディレクトリの存在確認
check_path "$LOCAL_KARABINER_DIR" "ローカルKarabinerディレクトリ" "directory" || exit 1

log_success "前提条件チェック完了"

# バックアップディレクトリの作成
create_backup_dir "$LOCAL_BACKUP_DIR"

echo ""
log_info "シンボリックリンクの状態を確認・作成します..."

# --- karabiner.json の同期 ---
create_symlink "$ICLOUD_KARABINER_JSON" "$LOCAL_KARABINER_JSON" "$LOCAL_BACKUP_DIR" "karabiner" "karabiner.json" || exit 1

# --- karabiner.edn (goku) の同期 ---
create_symlink "$ICLOUD_KARABINER_EDN" "$LOCAL_KARABINER_EDN" "$LOCAL_BACKUP_DIR" "karabiner" "karabiner.edn" || exit 1

# --- ローカル依存スクリプトの検出・リンク ---
log_info "ローカル依存スクリプトを確認します..."
mkdir -p "$LOCAL_ASSETS_DIR"

two_panes_finder_source=""
if [ -d "$TWO_PANES_FINDER_SEARCH_ROOT" ]; then
    two_panes_finder_source=$(find "$TWO_PANES_FINDER_SEARCH_ROOT" -type f -name "$TWO_PANES_FINDER_NAME" -print -quit)
fi

if [ -n "$two_panes_finder_source" ]; then
    if [ -e "$TWO_PANES_FINDER_LINK" ] && [ ! -L "$TWO_PANES_FINDER_LINK" ]; then
        log_warning "Two-panes Finderのローカルリンク先が通常ファイルです。置き換えません: $TWO_PANES_FINDER_LINK"
    elif ln -sfn "$two_panes_finder_source" "$TWO_PANES_FINDER_LINK"; then
        log_success "Two-panes Finderをローカル依存としてリンクしました: $TWO_PANES_FINDER_LINK"
    else
        log_warning "Two-panes Finderのローカルリンク作成に失敗しました: $TWO_PANES_FINDER_LINK"
    fi
else
    log_warning "Two-panes Finderスクリプトが見つかりません。検索先: $TWO_PANES_FINDER_SEARCH_ROOT"
fi

if [ -e "$MIMI_RESIZE_LINK" ] && [ ! -L "$MIMI_RESIZE_LINK" ]; then
    log_warning "Mimiラッパーのローカルリンク先が通常ファイルです。置き換えません: $MIMI_RESIZE_LINK"
elif ln -sfn "$MIMI_RESIZE_SOURCE" "$MIMI_RESIZE_LINK"; then
    log_success "Mimiラッパーをローカル依存としてリンクしました: $MIMI_RESIZE_LINK"
else
    log_error "Mimiラッパーのローカルリンク作成に失敗しました: $MIMI_RESIZE_LINK"
    exit 1
fi

# --- goku を実行して karabiner.json を更新 ---
log_info "goku を実行して karabiner.json の内容を更新します..."

# goku コマンドの存在確認
check_command "goku" "'brew install yqrashawn/goku/goku' を実行してインストールしてください。" || exit 1

# goku を実行して設定を karabiner.json に反映
if goku; then
    log_success "goku を実行し、karabiner.json を正常に更新しました。"
    # JSONが事前生成済みでも、実行中のKarabinerが旧設定を保持している場合がある。
    # setup後の読み込み状態を保証するため、差分の有無にかかわらず再起動する。
    log_info "現在の設定を確実に読み込むため、Karabiner-Elementsを再起動します..."
    restart_process "Karabiner-Elements" "org.pqrs.service.agent.karabiner_console_user_server" || exit 1
    log_info "MimiをKarabinerから使う場合は、システム設定 > プライバシーとセキュリティ > アクセシビリティで karabiner_console_user_server がオンであることを確認してください。"
else
    log_error "goku の実行に失敗しました。karabiner.edn の内容を確認してください。"
    exit 1
fi

# 完了メッセージの表示
symlinks_info="  karabiner.json: $LOCAL_KARABINER_JSON -> $ICLOUD_KARABINER_JSON
  karabiner.edn:  $LOCAL_KARABINER_EDN -> $ICLOUD_KARABINER_EDN"

show_completion_message "Karabiner-Elements設定ファイル同期" "$symlinks_info" "$LOCAL_BACKUP_DIR"
