#!/bin/bash

# Custom InstructionsをCodexとMOLCURE Notionへ同期する。

set -euo pipefail

export LC_ALL=C
export LANG=C
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
ASSET_DIR="$SCRIPT_DIR/custom-instructions-sync"

LABEL='com.hnishim.custom-instructions-sync'
APP_NAME='Custom Instructions Sync.app'
EXECUTABLE_NAME='CustomInstructionsSync'
SWIFT_SOURCE="$ASSET_DIR/CustomInstructionsSync.swift"
INFO_PLIST="$ASSET_DIR/Info.plist"
ENTITLEMENTS="$ASSET_DIR/CustomInstructionsSync.entitlements"
SOURCE_PLIST="$ASSET_DIR/$LABEL.plist"
SYNC_SOURCE="$ASSET_DIR/sync-custom-instructions"
CODEX_HOME_DIR="${CODEX_HOME_DIR_OVERRIDE:-${CODEX_HOME:-$HOME/.codex}}"
CUSTOM_INSTRUCTIONS_DIR_HINT="${CUSTOM_INSTRUCTIONS_DIR_HINT:-$HOME}"
APPLICATIONS_DIR="${CUSTOM_INSTRUCTIONS_APPLICATIONS_DIR_OVERRIDE:-$HOME/Applications}"
APP_PATH="$APPLICATIONS_DIR/$APP_NAME"
HELPER_EXECUTABLE="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
APPLICATION_SUPPORT_DIR="${CUSTOM_INSTRUCTIONS_SUPPORT_DIR_OVERRIDE:-$HOME/Library/Application Support/$LABEL}"
SYNC_EXECUTABLE="$APPLICATION_SUPPORT_DIR/sync-custom-instructions"
NOTION_CONFIG="$APPLICATION_SUPPORT_DIR/notion-pages.conf"
if [ -n "${NTN_EXECUTABLE_OVERRIDE:-}" ]; then
    NTN_EXECUTABLE="$NTN_EXECUTABLE_OVERRIDE"
elif NTN_EXECUTABLE=$(command -v ntn 2>/dev/null); then
    :
else
    NTN_EXECUTABLE="$HOME/.local/bin/ntn"
fi
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR_OVERRIDE:-$HOME/Library/LaunchAgents}"
TARGET_PLIST="$LAUNCH_AGENTS_DIR/$LABEL.plist"
LOG_DIR="${CUSTOM_INSTRUCTIONS_LOG_DIR_OVERRIDE:-$HOME/Library/Logs}"
STDOUT_PATH="$LOG_DIR/$LABEL.log"
STDERR_PATH="$LOG_DIR/$LABEL.err.log"
DOMAIN="gui/$(id -u)"
MODULE_CACHE_DIR="${CUSTOM_INSTRUCTIONS_MODULE_CACHE_OVERRIDE:-$HOME/Library/Caches/$LABEL/SwiftModuleCache}"

log_info() { printf '[INFO] %s\n' "$1" >&2; }
log_success() { printf '[SUCCESS] %s\n' "$1" >&2; }
log_error() { printf '[ERROR] %s\n' "$1" >&2; }

for required_file in "$SWIFT_SOURCE" "$INFO_PLIST" "$ENTITLEMENTS" "$SOURCE_PLIST" "$SYNC_SOURCE"; do
    if [ ! -f "$required_file" ]; then
        log_error "必要なファイルが見つかりません: $required_file"
        exit 1
    fi
done

if [ ! -d "$CUSTOM_INSTRUCTIONS_DIR_HINT" ]; then
    log_error "正本フォルダー候補が見つかりません: $CUSTOM_INSTRUCTIONS_DIR_HINT"
    exit 1
fi

if [ ! -x "$NTN_EXECUTABLE" ]; then
    log_error "Notion CLIが見つかりません: $NTN_EXECUTABLE"
    log_error "公式手順でntnを導入し、MOLCUREへログインしてから再実行してください。"
    exit 1
fi

if ! SWIFTC=$(xcrun --find swiftc 2>/dev/null); then
    log_error "Swiftコンパイラがありません。Command Line Toolsをインストールしてください。"
    exit 1
fi

mkdir -p "$CODEX_HOME_DIR" "$APPLICATIONS_DIR" "$APPLICATION_SUPPORT_DIR" "$LAUNCH_AGENTS_DIR" "$LOG_DIR" "$MODULE_CACHE_DIR"
chmod 700 "$APPLICATION_SUPPORT_DIR"
install -m 755 "$SYNC_SOURCE" "$SYNC_EXECUTABLE"

build_root=$(mktemp -d "${TMPDIR:-/tmp}/custom-instructions-sync-build.XXXXXX")
case "${build_root:?}" in
    "${TMPDIR:-/tmp}"/custom-instructions-sync-build.*) ;;
    *)
        log_error "想定外のビルド一時パスです: $build_root"
        exit 1
        ;;
esac

cleanup() {
    case "${build_root:?}" in
        "${TMPDIR:-/tmp}"/custom-instructions-sync-build.*) rm -rf -- "$build_root" ;;
        *) log_error "一時ディレクトリを削除しません: $build_root" ;;
    esac
}
trap cleanup EXIT

build_app="$build_root/$APP_NAME"
mkdir -p "$build_app/Contents/MacOS"
install -m 644 "$INFO_PLIST" "$build_app/Contents/Info.plist"

compile_log="$build_root/swiftc.log"
compile_succeeded=false
if "$SWIFTC" "$SWIFT_SOURCE" \
    -o "$build_app/Contents/MacOS/$EXECUTABLE_NAME" \
    -framework AppKit -O -parse-as-library \
    -module-cache-path "$MODULE_CACHE_DIR" >"$compile_log" 2>&1; then
    compile_succeeded=true
else
    default_sdk=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
    while IFS= read -r sdk_path; do
        [ -n "$sdk_path" ] || continue
        if [ -n "$default_sdk" ] && [ "$sdk_path" -ef "$default_sdk" ]; then
            continue
        fi
        log_info "互換SDKでSwiftヘルパーを構築します: $sdk_path"
        if "$SWIFTC" "$SWIFT_SOURCE" \
            -o "$build_app/Contents/MacOS/$EXECUTABLE_NAME" \
            -framework AppKit -O -parse-as-library \
            -sdk "$sdk_path" -module-cache-path "$MODULE_CACHE_DIR" >"$compile_log" 2>&1; then
            compile_succeeded=true
            break
        fi
    done < <(find /Library/Developer/CommandLineTools/SDKs -maxdepth 1 -type d -name 'MacOSX*.sdk' | sort -Vr)
fi

if [ "$compile_succeeded" != true ]; then
    sed -n '1,120p' "$compile_log" >&2
    log_error "Swiftヘルパーの構築に失敗しました。"
    exit 1
fi

chmod 755 "$build_app/Contents/MacOS/$EXECUTABLE_NAME"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$build_app" >/dev/null
codesign --verify --strict "$build_app"

log_info "Swiftヘルパーを配置します: $APP_PATH"
ditto "$build_app" "$APP_PATH"
codesign --verify --strict "$APP_PATH"

if ! "$HELPER_EXECUTABLE" --status >/dev/null 2>&1; then
    log_info "初回フォルダーアクセス権を設定します。2つのフォルダーを順に選択してください。"
    "$HELPER_EXECUTABLE" --authorize "$CODEX_HOME_DIR" "$CUSTOM_INSTRUCTIONS_DIR_HINT"
fi

status_output=$("$HELPER_EXECUTABLE" --status)
printf '%s\n' "$status_output"
custom_instructions_dir=$(printf '%s\n' "$status_output" | sed -n 's/^source=//p')
authorized_output_dir=$(printf '%s\n' "$status_output" | sed -n 's/^output=//p')

if [ -z "$custom_instructions_dir" ] || [ ! -d "$custom_instructions_dir" ]; then
    log_error "保存済みの正本フォルダーを確認できません。"
    exit 1
fi

if [ "$authorized_output_dir" != "$CODEX_HOME_DIR" ]; then
    log_error "認可済み出力先がCodexホームと一致しません: $authorized_output_dir"
    exit 1
fi

read_local_config() {
    local key=$1
    if [ -f "$NOTION_CONFIG" ]; then
        sed -n "s/^${key}=//p" "$NOTION_CONFIG" | tail -n 1
    fi
    return 0
}

is_notion_id() {
    printf '%s\n' "$1" | grep -Eq '^[0-9A-Fa-f]{32}$|^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
}

workspace_id="${NOTION_WORKSPACE_ID_OVERRIDE:-$(read_local_config workspace_id)}"
if [ -z "$workspace_id" ]; then
    notion_cli_config="${NOTION_HOME:-$HOME/.config/notion}/config.json"
    if [ -f "$notion_cli_config" ]; then
        workspace_id=$(/usr/bin/plutil -extract defaultWorkspaceIds.prod raw -o - "$notion_cli_config" 2>/dev/null || true)
    fi
fi

custom_page_id="${NOTION_CUSTOM_INSTRUCTIONS_PAGE_ID_OVERRIDE:-$(read_local_config custom_instructions_page_id)}"
profile_page_id="${NOTION_USER_PROFILE_PAGE_ID_OVERRIDE:-$(read_local_config user_profile_page_id)}"

if [ -z "$custom_page_id" ] && [ -t 0 ]; then
    read -r -p '基本的なガイドラインのNotionページID: ' custom_page_id
fi
if [ -z "$profile_page_id" ] && [ -t 0 ]; then
    read -r -p 'ユーザープロファイルのNotionページID: ' profile_page_id
fi

for notion_id in "$workspace_id" "$custom_page_id" "$profile_page_id"; do
    if ! is_notion_id "$notion_id"; then
        log_error "MOLCURE NotionのワークスペースIDまたはページIDを確認できません。"
        exit 1
    fi
done

notion_config_temp="$build_root/notion-pages.conf"
printf 'workspace_id=%s\ncustom_instructions_page_id=%s\nuser_profile_page_id=%s\n' \
    "$workspace_id" "$custom_page_id" "$profile_page_id" >"$notion_config_temp"
install -m 600 "$notion_config_temp" "$NOTION_CONFIG"

if ! NOTION_WORKSPACE_ID="$workspace_id" "$NTN_EXECUTABLE" api v1/users/me >/dev/null; then
    log_error "MOLCURE Notionの認証を確認できません。ntn loginを再実行してください。"
    exit 1
fi

target_agents="$CODEX_HOME_DIR/AGENTS.md"
if [ -L "$target_agents" ]; then
    backup_dir="$CODEX_HOME_DIR/backups"
    backup_timestamp=$(date '+%Y%m%d-%H%M%S')
    backup_path="$backup_dir/AGENTS.md.symlink.$backup_timestamp"
    mkdir -p "$backup_dir"
    if [ -e "$backup_path" ] || [ -L "$backup_path" ]; then
        log_error "バックアップ先が既に存在します: $backup_path"
        exit 1
    fi
    mv "$target_agents" "$backup_path"
    log_success "既存のAGENTS.mdシムリンクをバックアップしました: $backup_path"
fi

log_info "CodexとMOLCURE Notionへの初期同期を実行します。"
"$SYNC_EXECUTABLE" "$HELPER_EXECUTABLE" "$NTN_EXECUTABLE" "$CODEX_HOME_DIR" "$NOTION_CONFIG"

temp_plist="$build_root/$LABEL.plist"

cp "$SOURCE_PLIST" "$temp_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $SYNC_EXECUTABLE" "$temp_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:1 $HELPER_EXECUTABLE" "$temp_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:2 $NTN_EXECUTABLE" "$temp_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:3 $CODEX_HOME_DIR" "$temp_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:4 $NOTION_CONFIG" "$temp_plist"
/usr/libexec/PlistBuddy -c "Set :WatchPaths:0 $custom_instructions_dir" "$temp_plist"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath $STDOUT_PATH" "$temp_plist"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath $STDERR_PATH" "$temp_plist"
plutil -lint "$temp_plist" >/dev/null

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$LABEL"
fi
install -m 600 "$temp_plist" "$TARGET_PLIST"
launchctl bootstrap "$DOMAIN" "$TARGET_PLIST"
launchctl kickstart -k "$DOMAIN/$LABEL"

attempt=1
while [ "$attempt" -le 40 ]; do
    job_state=$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null || true)
    if printf '%s\n' "$job_state" | grep -q 'last exit code = 0'; then
        if [ ! -f "$target_agents" ] || [ -L "$target_agents" ]; then
            log_error "通常ファイルのAGENTS.mdを確認できません: $target_agents"
            exit 1
        fi
        log_success "LaunchAgentの正常終了を確認しました。"
        log_success "Codex用AGENTS.mdを確認しました: $target_agents"
        exit 0
    fi
    sleep 0.25
    attempt=$((attempt + 1))
done

tail -n 40 "$STDERR_PATH" 2>/dev/null || true
log_error "LaunchAgentの正常終了を確認できませんでした。"
exit 1
