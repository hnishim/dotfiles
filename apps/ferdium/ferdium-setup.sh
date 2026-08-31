#!/bin/bash

# Ferdium カスタムレシピ同期スクリプト
# iCloud上のレシピファイルをローカルのFerdiumレシピディレクトリにシンボリックリンクで同期する

# 共通ライブラリを読み込み
source "$(dirname "$0")/../../lib/common.sh"

# --- 変数定義 ---

SCRIPT_DIR=$(get_script_dir)
ICLOUD_GCAL_DIR="$SCRIPT_DIR/recipes/google-calendar"
ICLOUD_USER_JS="$ICLOUD_GCAL_DIR/user.js"
ICLOUD_WEBVIEW_JS="$ICLOUD_GCAL_DIR/webview.js"

LOCAL_GCAL_DIR="$HOME/Library/Application Support/Ferdium/recipes/google-calendar"
LOCAL_USER_JS="$LOCAL_GCAL_DIR/user.js"
LOCAL_WEBVIEW_JS="$LOCAL_GCAL_DIR/webview.js"

MANIFEST="$ICLOUD_GCAL_DIR/upstream-manifest"
BACKUP_ROOT="$HOME/Library/Application Support/Ferdium-dotfiles-backups/google-calendar"
WEBVIEW_UPSTREAM_SHA=""
BACKUP_PATH=""
USER_TARGET_STATE=""
WEBVIEW_TARGET_STATE=""

echo "=== Ferdium カスタムレシピ同期スクリプト ==="

# --- 前提条件チェック ---
log_info "前提条件をチェック中..."
check_path "$ICLOUD_USER_JS" "user.js（dotfiles）" "file" || exit 1
check_path "$ICLOUD_WEBVIEW_JS" "webview.js（dotfiles）" "file" || exit 1
log_success "前提条件チェック完了"

# --- ローカルディレクトリの作成 ---
ensure_directory "$LOCAL_GCAL_DIR" "ローカルFerdiumレシピディレクトリ" || exit 1

manifest_value() {
    local key="$1"
    awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$MANIFEST"
}

file_sha256() {
    shasum -a 256 "$1" | awk '{ print $1 }'
}

preflight_target() {
    local label="$1"
    local source="$2"
    local target="$3"
    local state_variable="$4"
    local state=""
    local target_sha=""

    if [ -L "$target" ]; then
        if check_symlink "$target" "$source"; then
            state="correct-link"
        else
            log_error "$label は異なるリンクまたは壊れたリンクのため変更しません: $target"
            return 1
        fi
    elif [ ! -e "$target" ]; then
        state="missing"
    elif [ -d "$target" ]; then
        log_error "$label はディレクトリのため変更しません: $target"
        return 1
    elif [ -f "$target" ]; then
        if [ "$label" = "webview.js" ]; then
            if ! target_sha=$(file_sha256 "$target"); then
                log_error "$label の読み取りに失敗したため変更しません: $target"
                return 1
            fi
            if [ "$target_sha" = "$WEBVIEW_UPSTREAM_SHA" ]; then
                state="known-upstream"
            else
                log_error "$label は既知upstream SHA-256と一致しない通常ファイルのため変更しません: $target"
                return 1
            fi
        else
            log_error "$label はmanifest entryのない通常ファイルのため変更しません: $target"
            return 1
        fi
    else
        log_error "$label は対応していない競合のため変更しません: $target"
        return 1
    fi

    printf -v "$state_variable" '%s' "$state"
}

preflight_backup() {
    local backup_parent
    backup_parent=$(dirname -- "$BACKUP_ROOT")
    BACKUP_PATH="$BACKUP_ROOT/webview.js.$WEBVIEW_UPSTREAM_SHA"

    if [ -L "$backup_parent" ] || { [ -e "$backup_parent" ] && [ ! -d "$backup_parent" ]; }; then
        log_error "upstream backupの親ディレクトリが競合しているため変更しません: $backup_parent"
        return 1
    fi
    if [ -L "$BACKUP_ROOT" ] || { [ -e "$BACKUP_ROOT" ] && [ ! -d "$BACKUP_ROOT" ]; }; then
        log_error "upstream backup rootが競合しているため変更しません: $BACKUP_ROOT"
        return 1
    fi
    if [ -d "$BACKUP_ROOT" ]; then
        if [ ! -w "$BACKUP_ROOT" ]; then
            log_error "upstream backup rootに書き込めないため変更しません: $BACKUP_ROOT"
            return 1
        fi
    else
        local writable_parent="$BACKUP_ROOT"
        local next_parent
        while [ ! -e "$writable_parent" ] && [ ! -L "$writable_parent" ]; do
            next_parent=$(dirname -- "$writable_parent")
            if [ "$next_parent" = "$writable_parent" ]; then
                log_error "upstream backup rootの作成先を確認できないため変更しません: $BACKUP_ROOT"
                return 1
            fi
            writable_parent="$next_parent"
        done
        if [ -L "$writable_parent" ] || [ ! -d "$writable_parent" ]; then
            log_error "upstream backup rootの作成先が競合しているため変更しません: $writable_parent"
            return 1
        fi
        if [ ! -w "$writable_parent" ]; then
            log_error "upstream backup rootの作成先に書き込めないため変更しません: $writable_parent"
            return 1
        fi
    fi
    if [ -L "$BACKUP_PATH" ] || [ -d "$BACKUP_PATH" ]; then
        log_error "upstream backup pathが競合しているため変更しません: $BACKUP_PATH"
        return 1
    fi
    if [ -e "$BACKUP_PATH" ] && [ ! -f "$BACKUP_PATH" ]; then
        log_error "upstream backup pathが通常ファイルではないため変更しません: $BACKUP_PATH"
        return 1
    fi
    if [ -f "$BACKUP_PATH" ]; then
        local backup_sha
        if ! backup_sha=$(file_sha256 "$BACKUP_PATH"); then
            log_error "既存upstream backupの読み取りに失敗したため変更しません: $BACKUP_PATH"
            return 1
        fi
        if [ "$backup_sha" != "$WEBVIEW_UPSTREAM_SHA" ]; then
            log_error "既存upstream backupのSHA-256が一致しないため上書きしません: $BACKUP_PATH"
            return 1
        fi
    fi
}

backup_known_webview() {
    if [ "$WEBVIEW_TARGET_STATE" != "known-upstream" ]; then
        return 0
    fi

    mkdir -p "$BACKUP_ROOT" || {
        log_error "upstream backup rootの作成に失敗したため変更しません: $BACKUP_ROOT"
        return 1
    }

    if [ -e "$BACKUP_PATH" ]; then
        rm -f "$LOCAL_WEBVIEW_JS" || {
            log_error "既知upstream targetを不在化できませんでした: $LOCAL_WEBVIEW_JS"
            return 1
        }
    else
        mv "$LOCAL_WEBVIEW_JS" "$BACKUP_PATH" || {
            log_error "既知upstreamのbackup退避に失敗したため変更しません: $LOCAL_WEBVIEW_JS"
            return 1
        }
    fi

    local backup_sha
    if ! backup_sha=$(file_sha256 "$BACKUP_PATH"); then
        log_error "upstream backupのreadbackに失敗しました: $BACKUP_PATH"
        return 1
    fi
    if [ "$backup_sha" != "$WEBVIEW_UPSTREAM_SHA" ]; then
        log_error "upstream backupのreadback SHA-256が一致しません: $BACKUP_PATH"
        return 1
    fi
    if [ -e "$LOCAL_WEBVIEW_JS" ] || [ -L "$LOCAL_WEBVIEW_JS" ]; then
        log_error "backup後もwebview.js targetが不在になっていません: $LOCAL_WEBVIEW_JS"
        return 1
    fi
}

link_failure_message() {
    log_error "webview.jsのlink作成に失敗しました。backupを保持しています。"
    log_error "target: $LOCAL_WEBVIEW_JS（現在不在であることを確認してください）"
    log_error "backup: $BACKUP_PATH"
    log_error "backup SHA-256: $WEBVIEW_UPSTREAM_SHA"
    log_error "手動復旧: backupを保持したまま、dotfiles sourceからtargetへlinkを作成してください"
}

on_webview_link_exit() {
    local rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && [ "$WEBVIEW_TARGET_STATE" = "known-upstream" ] && [ ! -e "$LOCAL_WEBVIEW_JS" ] && [ ! -L "$LOCAL_WEBVIEW_JS" ]; then
        link_failure_message
    fi
    exit "$rc"
}

# --- 全targetとbackupのread-only preflight ---
log_info "前提条件をチェック中..."
check_path "$MANIFEST" "upstream manifest" "file" || exit 1
local_source_ref=$(manifest_value source_ref)
WEBVIEW_UPSTREAM_SHA=$(awk -F '\t' '$1 == "webview.js" { print $3; exit }' "$MANIFEST")
if [[ ! "$local_source_ref" =~ ^[[:xdigit:]]{40}$ ]] || [[ ! "$WEBVIEW_UPSTREAM_SHA" =~ ^[[:xdigit:]]{64}$ ]]; then
    log_error "upstream manifestの固定refまたはwebview.js SHA-256が不正です"
    exit 1
fi
if awk -F '\t' '$1 == "user.js" { found=1 } END { exit found ? 0 : 1 }' "$MANIFEST"; then
    log_error "user.jsはmanifest entryなしである必要があります"
    exit 1
fi

preflight_failed=0
preflight_target "user.js" "$ICLOUD_USER_JS" "$LOCAL_USER_JS" USER_TARGET_STATE || preflight_failed=1
preflight_target "webview.js" "$ICLOUD_WEBVIEW_JS" "$LOCAL_WEBVIEW_JS" WEBVIEW_TARGET_STATE || preflight_failed=1
if [ "$preflight_failed" -ne 0 ]; then
    exit 1
fi
preflight_backup || exit 1
log_success "targetとupstream backupのpreflight完了"

echo ""
log_info "シンボリックリンクの状態を確認・作成します..."

# --- シンボリックリンクの確認・作成 ---
trap on_webview_link_exit EXIT
backup_known_webview || exit 1
create_symlink "$ICLOUD_USER_JS" "$LOCAL_USER_JS" "user.js" || exit 1
create_symlink "$ICLOUD_WEBVIEW_JS" "$LOCAL_WEBVIEW_JS" "webview.js" || exit 1
trap - EXIT

# --- 完了メッセージ ---
symlinks_info="  user.js: $LOCAL_USER_JS -> $ICLOUD_USER_JS
  webview.js: $LOCAL_WEBVIEW_JS -> $ICLOUD_WEBVIEW_JS"

show_completion_message "Ferdium カスタムレシピ同期" "$symlinks_info" ""
