#!/bin/bash

source "$(dirname "$0")/../../lib/common.sh"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR="$SCRIPT_DIR/CustomInputTable"
SOURCE_TSV="$SOURCE_DIR/custom_input_table.tsv"
SOURCE_SYNC="$SCRIPT_DIR/azookey-custom-table-sync.sh"
SOURCE_PLIST="$SCRIPT_DIR/launchd/my.azookey.sync.plist"
TABLE_NAME=custom_input_table.tsv

CONTAINER_ROOT="$HOME/Library/Containers/dev.ensan.inputmethod.azooKeyMac"
CONTAINER_DATA="$CONTAINER_ROOT/Data"
CONTAINER_LIBRARY="$CONTAINER_DATA/Library"
CONTAINER_APP_SUPPORT="$CONTAINER_LIBRARY/Application Support"
AZOOKEY_PARENT_DIR="$CONTAINER_APP_SUPPORT/azooKeyMac"
AZOOKEY_TABLE_DIR="$AZOOKEY_PARENT_DIR/CustomInputTable"
AZOOKEY_TABLE_TSV="$AZOOKEY_TABLE_DIR/$TABLE_NAME"

RUNTIME_PARENT="$HOME/Library/Application Support"
RUNTIME_DIR="$RUNTIME_PARENT/my.azookey.sync"
RUNTIME_SCRIPT="$RUNTIME_DIR/azookey-custom-table-sync.sh"
STATE_FILE="$RUNTIME_DIR/last-synced.sha256"
LOG_FILE="$RUNTIME_DIR/sync.log"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
TARGET_PLIST="$LAUNCH_AGENTS_DIR/my.azookey.sync.plist"
LABEL=my.azookey.sync
DOMAIN="gui/$(id -u)"

TEMP_TABLE=""
TEMP_DIR=""
TEMP_SCRIPT=""
TEMP_PLIST=""
TEMP_PLIST_BACKUP=""
AGENT_STOPPED=0
AGENT_REGISTRATION_ATTEMPTED=0
SETUP_COMPLETE=0

cleanup() {
    if [ "$AGENT_STOPPED" -eq 1 ] && [ "$AGENT_REGISTRATION_ATTEMPTED" -eq 0 ] &&
        [ "$SETUP_COMPLETE" -eq 0 ] && [ -f "$TARGET_PLIST" ]; then
        launchctl bootstrap "$DOMAIN" "$TARGET_PLIST" >/dev/null 2>&1 ||
            log_error "セットアップ失敗後に既存LaunchAgentを再登録できませんでした"
    fi
    if [ -n "$TEMP_TABLE" ] && [ -e "$TEMP_TABLE" ]; then rm -f "$TEMP_TABLE"; fi
    if [ -n "$TEMP_SCRIPT" ] && [ -e "$TEMP_SCRIPT" ]; then rm -f "$TEMP_SCRIPT"; fi
    if [ -n "$TEMP_PLIST" ] && [ -e "$TEMP_PLIST" ]; then rm -f "$TEMP_PLIST"; fi
    if [ -n "$TEMP_PLIST_BACKUP" ] && [ -e "$TEMP_PLIST_BACKUP" ]; then rm -f "$TEMP_PLIST_BACKUP"; fi
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -f "$TEMP_DIR/$TABLE_NAME"
        rmdir "$TEMP_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

ensure_directory_shape() {
    local path="$1"
    local label="$2"

    if [ -L "$path" ]; then
        log_error "$labelがシンボリックリンクのため変更しません: $path"
        return 1
    fi
    if [ -e "$path" ] && [ ! -d "$path" ]; then
        log_error "$labelがディレクトリではないため変更しません: $path"
        return 1
    fi
}

ensure_file_shape() {
    local path="$1"
    local label="$2"

    if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
        log_error "$labelが通常ファイルではないため変更しません: $path"
        return 1
    fi
}

reject_unexpected_entries() {
    local directory="$1"
    local entry
    local name

    for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name="${entry##*/}"
        if [ "$name" != "$TABLE_NAME" ] || [ -L "$entry" ] || [ ! -f "$entry" ]; then
            log_error "用途不明の資産があるため移行を中止します: $entry"
            return 1
        fi
    done
    return 0
}

validate_source() {
    if ! /bin/bash "$SOURCE_SYNC" --validate "$SOURCE_TSV" >/dev/null; then
        log_error "カスタム入力表が空か不正なため変更しません"
        return 1
    fi
}

stage_source_in_temp_dir() {
    TEMP_DIR=$(mktemp -d "$AZOOKEY_PARENT_DIR/.CustomInputTable.migration.XXXXXX") || return 1
    cp "$SOURCE_TSV" "$TEMP_DIR/$TABLE_NAME" || return 1
    cmp -s "$SOURCE_TSV" "$TEMP_DIR/$TABLE_NAME" || return 1
    /bin/bash "$SOURCE_SYNC" --validate "$TEMP_DIR/$TABLE_NAME" >/dev/null || return 1
}

install_source_in_empty_table_dir() {
    TEMP_TABLE=$(mktemp "$AZOOKEY_TABLE_DIR/.$TABLE_NAME.XXXXXX") || return 1
    cp "$SOURCE_TSV" "$TEMP_TABLE" || return 1
    cmp -s "$SOURCE_TSV" "$TEMP_TABLE" || return 1
    /bin/bash "$SOURCE_SYNC" --validate "$TEMP_TABLE" >/dev/null || return 1
    mv "$TEMP_TABLE" "$AZOOKEY_TABLE_TSV" || return 1
    TEMP_TABLE=""
}

prepare_container_table() {
    if [ -L "$AZOOKEY_TABLE_DIR" ]; then
        link_target=$(readlink "$AZOOKEY_TABLE_DIR") || {
            log_error "既存リンクを確認できないため移行しません"
            return 1
        }
        if [ "$link_target" != "$SOURCE_DIR" ]; then
            log_error "想定外のリンク先を保持して移行を中止します: $link_target"
            return 1
        fi
        reject_unexpected_entries "$AZOOKEY_TABLE_DIR" || return 1
        if [ ! -f "$AZOOKEY_TABLE_TSV" ] || [ -L "$AZOOKEY_TABLE_TSV" ] ||
            ! cmp -s "$SOURCE_TSV" "$AZOOKEY_TABLE_TSV"; then
            log_error "リンク先のカスタム表が正本と一致しないため移行しません"
            return 1
        fi
        stage_source_in_temp_dir || {
            log_error "移行用コピーを作成できないため変更しません"
            return 1
        }
        rm "$AZOOKEY_TABLE_DIR" || {
            log_error "既存リンクを外せないため変更しません"
            return 1
        }
        if [ -e "$AZOOKEY_TABLE_DIR" ] || [ -L "$AZOOKEY_TABLE_DIR" ]; then
            log_error "保存先が移行中に変わったため変更しません"
            return 1
        fi
        if ! mv "$TEMP_DIR" "$AZOOKEY_TABLE_DIR"; then
            if [ ! -e "$AZOOKEY_TABLE_DIR" ] && [ ! -L "$AZOOKEY_TABLE_DIR" ]; then
                ln -s "$SOURCE_DIR" "$AZOOKEY_TABLE_DIR" ||
                    log_error "移行に失敗し、元のリンクも復元できませんでした"
            fi
            log_error "実ディレクトリを配置できません。正本は保持しています"
            return 1
        fi
        TEMP_DIR=""
        return 0
    fi

    if [ -e "$AZOOKEY_TABLE_DIR" ]; then
        if [ ! -d "$AZOOKEY_TABLE_DIR" ]; then
            log_error "保存先がディレクトリではないため変更しません"
            return 1
        fi
        reject_unexpected_entries "$AZOOKEY_TABLE_DIR" || return 1
        if [ -e "$AZOOKEY_TABLE_TSV" ] || [ -L "$AZOOKEY_TABLE_TSV" ]; then
            if [ -L "$AZOOKEY_TABLE_TSV" ] || [ ! -f "$AZOOKEY_TABLE_TSV" ]; then
                log_error "保存先のTSVが通常ファイルではないため変更しません"
                return 1
            fi
            return 0
        fi
        install_source_in_empty_table_dir || {
            log_error "空の保存先へ表を配置できません"
            return 1
        }
        return 0
    fi

    stage_source_in_temp_dir || {
        log_error "移行用コピーを作成できないため変更しません"
        return 1
    }
    if [ -e "$AZOOKEY_TABLE_DIR" ] || [ -L "$AZOOKEY_TABLE_DIR" ]; then
        log_error "保存先が移行中に作られたため変更しません"
        return 1
    fi
    mv "$TEMP_DIR" "$AZOOKEY_TABLE_DIR" || {
        log_error "実ディレクトリを配置できません。正本は保持しています"
        return 1
    }
    TEMP_DIR=""
}

stop_existing_agent() {
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        launchctl bootout "$DOMAIN/$LABEL" || {
            log_error "稼働中のLaunchAgentを停止できないため変更しません"
            return 1
        }
        AGENT_STOPPED=1
    fi
}

install_runtime_script() {
    TEMP_SCRIPT=$(mktemp "$RUNTIME_DIR/.azookey-custom-table-sync.XXXXXX") || return 1
    install -m 755 "$SOURCE_SYNC" "$TEMP_SCRIPT" || return 1
    mv "$TEMP_SCRIPT" "$RUNTIME_SCRIPT" || return 1
    TEMP_SCRIPT=""
}

install_launch_agent() {
    TEMP_PLIST=$(mktemp "$LAUNCH_AGENTS_DIR/.my.azookey.sync.XXXXXX") || return 1
    cp "$SOURCE_PLIST" "$TEMP_PLIST" || return 1
    /usr/bin/plutil -replace ProgramArguments -array "$TEMP_PLIST" || return 1
    /usr/bin/plutil -insert ProgramArguments.0 -string "$RUNTIME_SCRIPT" "$TEMP_PLIST" || return 1
    /usr/bin/plutil -insert ProgramArguments.1 -string "$SOURCE_TSV" "$TEMP_PLIST" || return 1
    /usr/bin/plutil -insert ProgramArguments.2 -string "$AZOOKEY_TABLE_TSV" "$TEMP_PLIST" || return 1
    /usr/bin/plutil -insert ProgramArguments.3 -string "$LOG_FILE" "$TEMP_PLIST" || return 1
    /usr/bin/plutil -insert ProgramArguments.4 -string "$STATE_FILE" "$TEMP_PLIST" || return 1
    /usr/bin/plutil -replace WatchPaths -array "$TEMP_PLIST" || return 1
    /usr/bin/plutil -insert WatchPaths.0 -string "$SOURCE_DIR" "$TEMP_PLIST" || return 1
    /usr/bin/plutil -lint "$TEMP_PLIST" >/dev/null || return 1

    if [ -f "$TARGET_PLIST" ]; then
        TEMP_PLIST_BACKUP=$(mktemp "$LAUNCH_AGENTS_DIR/.my.azookey.sync.backup.XXXXXX") || return 1
        cp -p "$TARGET_PLIST" "$TEMP_PLIST_BACKUP" || return 1
    fi
    mv "$TEMP_PLIST" "$TARGET_PLIST" || return 1
    TEMP_PLIST=""
    AGENT_REGISTRATION_ATTEMPTED=1
    if launchctl bootstrap "$DOMAIN" "$TARGET_PLIST"; then
        if [ -n "$TEMP_PLIST_BACKUP" ] && [ -e "$TEMP_PLIST_BACKUP" ]; then
            rm -f "$TEMP_PLIST_BACKUP" || log_warning "旧LaunchAgent定義の一時退避を削除できませんでした"
        fi
        TEMP_PLIST_BACKUP=""
        return 0
    fi

    if [ -n "$TEMP_PLIST_BACKUP" ] && [ -e "$TEMP_PLIST_BACKUP" ]; then
        if mv "$TEMP_PLIST_BACKUP" "$TARGET_PLIST"; then
            TEMP_PLIST_BACKUP=""
            if [ "$AGENT_STOPPED" -eq 1 ]; then
                if launchctl bootstrap "$DOMAIN" "$TARGET_PLIST"; then
                    AGENT_STOPPED=0
                else
                    log_error "新しいLaunchAgentの登録に失敗し、旧定義も再登録できませんでした"
                fi
            fi
        else
            log_error "新しいLaunchAgentの登録に失敗しました。旧定義は退避先に残しています: $TEMP_PLIST_BACKUP"
            TEMP_PLIST_BACKUP=""
            return 1
        fi
    fi
    log_error "LaunchAgentの登録に失敗しました"
    return 1
}

log_info "AzooKeyのカスタム表を同期設定しています..."

if [ ! -f "$SOURCE_TSV" ]; then
    log_warning "カスタム入力表がないためAzooKeyの同期設定をスキップします: $SOURCE_TSV"
    exit 0
fi
if [ -L "$SOURCE_DIR" ] || [ -L "$SOURCE_TSV" ] || [ ! -d "$SOURCE_DIR" ]; then
    log_error "dotfiles側のカスタム表のパスが不正です"
    exit 1
fi
if [ ! -f "$SOURCE_SYNC" ] || [ -L "$SOURCE_SYNC" ] ||
    [ ! -f "$SOURCE_PLIST" ] || [ -L "$SOURCE_PLIST" ]; then
    log_error "同期スクリプトまたはLaunchAgent定義がありません"
    exit 1
fi
reject_unexpected_entries "$SOURCE_DIR" || exit 1
validate_source || exit 1

for directory in \
    "$HOME/Library" \
    "$HOME/Library/Containers" \
    "$CONTAINER_ROOT" \
    "$CONTAINER_DATA" \
    "$CONTAINER_LIBRARY" \
    "$CONTAINER_APP_SUPPORT" \
    "$AZOOKEY_PARENT_DIR" \
    "$RUNTIME_PARENT" \
    "$RUNTIME_DIR" \
    "$LAUNCH_AGENTS_DIR"; do
    ensure_directory_shape "$directory" "保存先" || exit 1
done
ensure_file_shape "$RUNTIME_SCRIPT" "同期スクリプト" || exit 1
ensure_file_shape "$STATE_FILE" "同期状態" || exit 1
ensure_file_shape "$LOG_FILE" "同期ログ" || exit 1
ensure_file_shape "$TARGET_PLIST" "LaunchAgent定義" || exit 1

mkdir -p "$AZOOKEY_PARENT_DIR" "$RUNTIME_DIR" "$LAUNCH_AGENTS_DIR" || {
    log_error "同期に必要なディレクトリを作成できません"
    exit 1
}

stop_existing_agent || exit 1
prepare_container_table || exit 1
install_runtime_script || {
    log_error "ローカル実行用スクリプトを配置できません"
    exit 1
}
"$RUNTIME_SCRIPT" "$SOURCE_TSV" "$AZOOKEY_TABLE_TSV" "$LOG_FILE" "$STATE_FILE" || {
    log_error "初回同期を完了できません。保存先と正本を保持しています"
    exit 1
}
install_launch_agent || {
    log_error "LaunchAgentを登録できません。正本と保存先の表は保持しています"
    exit 1
}
SETUP_COMPLETE=1

printf 'Registered %s\n' "$TARGET_PLIST"
printf 'Runtime script: %s\n' "$RUNTIME_SCRIPT"
