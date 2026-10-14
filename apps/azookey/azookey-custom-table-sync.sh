#!/bin/bash

set -euo pipefail

TABLE_NAME=custom_input_table.tsv
STATE_ATTRIBUTE=my.azookey.sync.last-synced.sha256
TEMP_TABLE=""

cleanup() {
    if [ -n "$TEMP_TABLE" ] && { [ -e "$TEMP_TABLE" ] || [ -L "$TEMP_TABLE" ]; }; then
        rm -f "$TEMP_TABLE"
    fi
}
trap cleanup EXIT

validate_tsv() {
    local path="$1"

    [ ! -L "$path" ] && [ -f "$path" ] && [ -r "$path" ] && [ -s "$path" ] || return 1
    iconv -f UTF-8 -t UTF-8 "$path" 2>/dev/null | cmp -s - "$path" || return 1
    if LC_ALL=C grep -q "$(printf '\r')" "$path"; then return 1; fi
    LC_ALL=C awk -F '\t' '
        NF != 2 || $1 == "" || $2 == "" { exit 1 }
        END { if (NR == 0) exit 1 }
    ' "$path"
}

if [ "${1:-}" = "--validate" ]; then
    if [ "$#" -ne 2 ] || ! validate_tsv "$2"; then
        printf '%s\n' "TSV_INVALID"
        exit 1
    fi
    printf '%s\n' "TSV_VALID"
    exit 0
fi

if [ "$#" -ne 2 ]; then
    printf '%s\n' "SYNC_BLOCKED invalid_arguments"
    exit 2
fi

SOURCE_TSV="$1"
TARGET_TSV="$2"
TARGET_DIR=$(dirname "$TARGET_TSV")
SOURCE_DIR=$(dirname "$SOURCE_TSV")

emit() {
    printf '%s\n' "$1"
}

fail() {
    emit "SYNC_BLOCKED $1"
    exit 1
}

hash_file() {
    local output
    output=$(shasum -a 256 "$1" 2>/dev/null) || return 1
    printf '%s\n' "${output%% *}"
}

is_valid_hash() {
    local value="$1"

    case "$value" in
        ""|*[!0123456789abcdef]*) return 1 ;;
    esac
    [ "${#value}" -eq 64 ]
}

write_state() {
    local value="$1"
    local readback

    xattr -w "$STATE_ATTRIBUTE" "$value" "$TARGET_DIR" 2>/dev/null || return 1
    readback=$(xattr -p "$STATE_ATTRIBUTE" "$TARGET_DIR" 2>/dev/null) || return 1
    [ "$readback" = "$value" ]
}

if [ -L "$SOURCE_DIR" ] || [ -L "$SOURCE_TSV" ] || [ ! -d "$SOURCE_DIR" ]; then
    fail source_path_invalid
fi
if [ ! -f "$SOURCE_TSV" ]; then fail source_missing; fi
if [ ! -r "$SOURCE_TSV" ]; then fail source_unreadable; fi
if ! validate_tsv "$SOURCE_TSV"; then fail source_invalid; fi
if [ -L "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then fail destination_directory_invalid; fi
if [ -L "$TARGET_TSV" ] || [ ! -f "$TARGET_TSV" ] || [ ! -r "$TARGET_TSV" ]; then
    fail destination_file_invalid
fi

source_hash=$(hash_file "$SOURCE_TSV") || fail source_hash_failed
target_hash=$(hash_file "$TARGET_TSV") || fail destination_hash_failed
attribute_names=$(xattr "$TARGET_DIR" 2>/dev/null) || fail state_list_failed
state_present=0
last_hash=""
if printf '%s\n' "$attribute_names" | LC_ALL=C grep -Fqx "$STATE_ATTRIBUTE"; then
    state_present=1
    last_hash=$(xattr -p "$STATE_ATTRIBUTE" "$TARGET_DIR" 2>/dev/null) || fail state_read_failed
    is_valid_hash "$last_hash" || fail state_invalid
fi

if [ "$source_hash" = "$target_hash" ]; then
    if [ "$state_present" -eq 0 ] || [ "$last_hash" != "$source_hash" ]; then
        write_state "$source_hash" || fail state_write_failed
        emit SYNC_STATE_RECONCILED
    else
        emit SYNC_NO_CHANGE
    fi
    exit 0
fi

if [ "$state_present" -eq 0 ]; then fail initial_contents_differ; fi
if [ "$target_hash" != "$last_hash" ]; then fail destination_changed_independently; fi

TEMP_TABLE=$(mktemp "$TARGET_DIR/.$TABLE_NAME.XXXXXX") || fail temporary_file_create_failed
cp "$SOURCE_TSV" "$TEMP_TABLE" || fail source_copy_failed
validate_tsv "$TEMP_TABLE" || fail copied_table_invalid
cmp -s "$SOURCE_TSV" "$TEMP_TABLE" || fail source_changed_during_copy
staged_hash=$(hash_file "$TEMP_TABLE") || fail copied_table_hash_failed
source_hash_after_copy=$(hash_file "$SOURCE_TSV") || fail source_hash_failed
[ "$source_hash_after_copy" = "$staged_hash" ] || fail source_changed_during_copy
current_target_hash=$(hash_file "$TARGET_TSV") || fail destination_hash_failed
[ "$current_target_hash" = "$last_hash" ] || fail destination_changed_during_copy
[ ! -L "$TARGET_TSV" ] && [ -f "$TARGET_TSV" ] || fail destination_file_invalid
mv "$TEMP_TABLE" "$TARGET_TSV" || fail atomic_replace_failed
TEMP_TABLE=""

write_state "$staged_hash" || fail state_write_after_replace_failed
emit SYNC_UPDATED
