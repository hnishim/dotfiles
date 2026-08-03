#!/bin/bash

# dotfilesで管理するAGENTS.mdをCodexホームへシンボリックリンクする

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)

SOURCE_AGENTS_FILE="${DOTFILES_AGENTS_FILE_OVERRIDE:-$SCRIPT_DIR/AGENTS.md}"
CODEX_HOME_DIR="${CODEX_HOME_DIR_OVERRIDE:-${CODEX_HOME:-$HOME/.codex}}"
TARGET_AGENTS_FILE="$CODEX_HOME_DIR/AGENTS.md"
BACKUP_DIR="$CODEX_HOME_DIR/backups"

log_info() {
    printf '[INFO] %s\n' "$1" >&2
}

log_success() {
    printf '[SUCCESS] %s\n' "$1" >&2
}

log_error() {
    printf '[ERROR] %s\n' "$1" >&2
}

if [ ! -f "$SOURCE_AGENTS_FILE" ]; then
    log_error "dotfilesのAGENTS.mdが見つかりません: $SOURCE_AGENTS_FILE"
    exit 1
fi

if [ -e "$CODEX_HOME_DIR" ] && [ ! -d "$CODEX_HOME_DIR" ]; then
    log_error "Codexホームのパスがディレクトリではありません: $CODEX_HOME_DIR"
    exit 1
fi

if [ ! -d "$CODEX_HOME_DIR" ]; then
    mkdir -p "$CODEX_HOME_DIR"
    log_success "Codexホームを作成しました: $CODEX_HOME_DIR"
else
    log_info "Codexホームを確認しました: $CODEX_HOME_DIR"
fi

if [ -L "$TARGET_AGENTS_FILE" ] && [ "$(readlink "$TARGET_AGENTS_FILE")" = "$SOURCE_AGENTS_FILE" ]; then
    log_success "AGENTS.mdは既に正しくリンクされています。"
    exit 0
fi

if [ -e "$TARGET_AGENTS_FILE" ] || [ -L "$TARGET_AGENTS_FILE" ]; then
    mkdir -p "$BACKUP_DIR"
    backup_timestamp=$(date '+%Y%m%d-%H%M%S')
    backup_path="$BACKUP_DIR/AGENTS.md.$backup_timestamp"

    if [ -e "$backup_path" ] || [ -L "$backup_path" ]; then
        log_error "バックアップ先が既に存在します: $backup_path"
        exit 1
    fi

    mv "$TARGET_AGENTS_FILE" "$backup_path"
    log_success "既存のAGENTS.mdをバックアップしました: $backup_path"
fi

ln -s "$SOURCE_AGENTS_FILE" "$TARGET_AGENTS_FILE"

if [ ! -L "$TARGET_AGENTS_FILE" ] || [ "$(readlink "$TARGET_AGENTS_FILE")" != "$SOURCE_AGENTS_FILE" ]; then
    log_error "AGENTS.mdのシンボリックリンク作成に失敗しました。"
    exit 1
fi

log_success "AGENTS.mdをリンクしました: $TARGET_AGENTS_FILE -> $SOURCE_AGENTS_FILE"
