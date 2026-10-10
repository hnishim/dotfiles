#!/bin/bash

# azooKeyのカスタムローマ字変換表をdotfilesから参照する
source "$(dirname "$0")/../../lib/common.sh"

SCRIPT_DIR=$(get_script_dir)
SOURCE_DIR="$SCRIPT_DIR/CustomInputTable"
SOURCE_TSV="$SOURCE_DIR/custom_input_table.tsv"
AZOOKEY_PARENT_DIR="$HOME/Library/Application Support/azooKeyMac"
AZOOKEY_TABLE_DIR="$AZOOKEY_PARENT_DIR/CustomInputTable"

if [ ! -f "$SOURCE_TSV" ]; then
    log_warning "azooKeyのカスタムローマ字変換TSVが未配置のため、リンク設定をスキップします: $SOURCE_TSV"
    exit 0
fi

ensure_directory "$AZOOKEY_PARENT_DIR" "azooKey設定ディレクトリ" || exit 1
create_symlink "$SOURCE_DIR" "$AZOOKEY_TABLE_DIR" "azooKeyカスタムローマ字変換表" || exit 1
