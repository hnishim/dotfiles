#!/bin/bash

# iCloud Drive上のweekly-maintenance正本をApplication Supportへ同期し、
# ローカル実行領域をLaunchAgentへ登録する。
source "$(dirname "$0")/../lib/common.sh"

DOTFILES_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
WEEKLY_MAINTENANCE_ROOT="${WEEKLY_MAINTENANCE_ROOT:-$DOTFILES_ROOT/../scripts/launchd/weekly-maintenance}"
SOURCE_SCRIPT="$WEEKLY_MAINTENANCE_ROOT/scripts/weekly-maintenance.sh"
SOURCE_PLIST="$WEEKLY_MAINTENANCE_ROOT/launchd/my.launchd.weekly-maintenance.plist"

RUNTIME_PARENT="$HOME/Library/Application Support"
RUNTIME_DIR="$RUNTIME_PARENT/my.launchd.weekly-maintenance"
RUNTIME_SCRIPT="$RUNTIME_DIR/weekly-maintenance.sh"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME=my.launchd.weekly-maintenance.plist
TARGET_PLIST="$LAUNCH_AGENTS_DIR/$PLIST_NAME"
LABEL=my.launchd.weekly-maintenance
DOMAIN="gui/$(id -u)"

ensure_directory_shape() {
    local path="$1"
    local label="$2"

    if [ -L "$path" ]; then
        log_error "$labelがsymlinkのため変更しません: $path"
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

log_info "weekly-maintenanceのローカル実行領域を構築しています..."
check_path "$SOURCE_SCRIPT" "weekly-maintenance正本スクリプト" "file" || exit 1
check_path "$SOURCE_PLIST" "weekly-maintenance正本plist" "file" || exit 1
ensure_directory_shape "$HOME/Library" "Library" || exit 1
ensure_directory_shape "$RUNTIME_PARENT" "Application Support" || exit 1
ensure_directory_shape "$RUNTIME_DIR" "weekly-maintenance runtime" || exit 1
ensure_directory_shape "$LAUNCH_AGENTS_DIR" "LaunchAgents" || exit 1
ensure_file_shape "$TARGET_PLIST" "登録対象plist" || exit 1

mkdir -p "$RUNTIME_DIR" "$LAUNCH_AGENTS_DIR"

temp_script=$(mktemp "$RUNTIME_DIR/.weekly-maintenance.sh.XXXXXX")
temp_plist=$(mktemp "${TMPDIR:-/tmp}/weekly-maintenance.plist.XXXXXX")
cleanup() {
    rm -f "$temp_script" "$temp_plist"
}
trap cleanup EXIT

# LaunchAgentからiCloud Drive上のスクリプトを直接読ませないため、
# 正本から実行用コピーを毎回生成する。
install -m 755 "$SOURCE_SCRIPT" "$temp_script"
mv "$temp_script" "$RUNTIME_SCRIPT"

cp "$SOURCE_PLIST" "$temp_plist"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:1 $RUNTIME_SCRIPT" "$temp_plist"
plutil -lint "$temp_plist"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$LABEL"
fi
mv "$temp_plist" "$TARGET_PLIST"
launchctl bootstrap "$DOMAIN" "$TARGET_PLIST"

trap - EXIT
printf 'Registered %s\n' "$TARGET_PLIST"
printf 'Runtime script: %s\n' "$RUNTIME_SCRIPT"
