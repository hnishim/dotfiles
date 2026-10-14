#!/bin/bash

source "$(dirname "$0")/../../lib/common.sh"

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR="$SCRIPT_DIR/CustomInputTable"
SOURCE_TSV="$SOURCE_DIR/custom_input_table.tsv"
SOURCE_SYNC="$SCRIPT_DIR/azookey-custom-table-sync.sh"
TABLE_NAME=custom_input_table.tsv
STATE_ATTRIBUTE=my.azookey.sync.last-synced.sha256
LEGACY_HELPER_SHA256=99e14c6ebc03608b989b552c9a00201a4172f619674ca88feb8c95bc4b79a8da

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
LEGACY_STATE_HASH=""

cleanup() {
    if [ -n "$TEMP_TABLE" ] && { [ -e "$TEMP_TABLE" ] || [ -L "$TEMP_TABLE" ]; }; then
        rm -f "$TEMP_TABLE"
    fi
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ] && [ ! -L "$TEMP_DIR" ]; then
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
    return 0
}

reject_unexpected_entries() {
    local directory="$1"
    local entry
    local name

    for entry in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
        if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
            continue
        fi
        name=$(basename "$entry")
        if [ "$name" != "$TABLE_NAME" ] || [ -L "$entry" ] || [ ! -f "$entry" ]; then
            log_error "用途不明の資産があるため変更しません: $entry"
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

hash_file() {
    local output
    output=$(shasum -a 256 "$1" 2>/dev/null) || return 1
    printf '%s\n' "$output" | awk '{print $1}'
}

is_valid_hash() {
    local value="$1"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]]
}

validate_legacy_state() {
    local path="$1"
    local value

    value=$(python3 - "$path" <<'PY'
import pathlib
import re
import sys

data = pathlib.Path(sys.argv[1]).read_bytes()
match = re.fullmatch(rb"([0-9a-f]{64})(?:\n)?", data)
if match is None:
    raise SystemExit(1)
sys.stdout.write(match.group(1).decode("ascii"))
PY
    ) || return 1
    is_valid_hash "$value" || return 1
    printf '%s' "$value"
}

validate_legacy_log() {
    local path="$1"

    python3 - "$path" <<'PY'
import pathlib
import re
import sys

allowed = {"SYNC_NO_CHANGE", "SYNC_STATE_RECONCILED", "SYNC_UPDATED"}
blocked = {
    "source_path_invalid", "source_missing", "source_unreadable", "source_invalid",
    "destination_directory_invalid", "destination_file_invalid", "state_directory_invalid",
    "state_file_invalid", "state_file_unreadable", "source_hash_failed",
    "destination_hash_failed", "state_read_failed", "state_invalid", "state_write_failed",
    "initial_contents_differ", "destination_changed_independently",
    "temporary_file_create_failed", "source_copy_failed", "copied_table_invalid",
    "source_changed_during_copy", "copied_table_hash_failed",
    "destination_changed_during_copy", "atomic_replace_failed",
    "state_write_after_replace_failed",
}
timestamp = re.compile(rb"(?:[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z|unknown-time) ")
for line in pathlib.Path(sys.argv[1]).read_bytes().splitlines():
    match = timestamp.match(line)
    if match is None:
        raise SystemExit(1)
    result = line[match.end():].decode("ascii", "strict")
    if result in allowed:
        continue
    if result.startswith("SYNC_BLOCKED ") and result[len("SYNC_BLOCKED "):] in blocked:
        continue
    raise SystemExit(1)
PY
}

validate_legacy_plist() {
    local path="$1"

    python3 - "$path" "$RUNTIME_SCRIPT" "$AZOOKEY_TABLE_TSV" "$LOG_FILE" "$STATE_FILE" <<'PY'
import os
import pathlib
import plistlib
import sys

plist_path, expected_helper, expected_target, expected_log, expected_state = sys.argv[1:]
try:
    with open(plist_path, "rb") as source:
        values = plistlib.load(source)
except Exception:
    raise SystemExit(1)

if not isinstance(values, dict):
    raise SystemExit(1)
if set(values) != {"Label", "ProgramArguments", "WatchPaths", "RunAtLoad"}:
    raise SystemExit(1)
if values.get("Label") != "my.azookey.sync" or values.get("RunAtLoad") is not True:
    raise SystemExit(1)
arguments = values.get("ProgramArguments")
watch_paths = values.get("WatchPaths")
if not isinstance(arguments, list) or len(arguments) != 5:
    raise SystemExit(1)
if not all(isinstance(item, str) for item in arguments):
    raise SystemExit(1)
if arguments[0] != expected_helper or arguments[2:] != [expected_target, expected_log, expected_state]:
    raise SystemExit(1)
source_path = pathlib.PurePosixPath(arguments[1])
expected_suffix = ("dotfiles", "apps", "azookey", "CustomInputTable", "custom_input_table.tsv")
if not source_path.is_absolute() or ".." in source_path.parts or source_path.parts[-5:] != expected_suffix:
    raise SystemExit(1)
if not str(source_path).startswith("/Users/") or os.path.normpath(str(source_path)) != str(source_path):
    raise SystemExit(1)
if not isinstance(watch_paths, list) or watch_paths != [str(source_path.parent)]:
    raise SystemExit(1)
PY
}

is_retired_plist_name() {
    local name="$1"

    if [ "$name" = "$LABEL.plist.disabled" ]; then
        return 0
    fi
    [[ "$name" =~ ^my\.azookey\.sync\.plist\.disabled\.[1-9][0-9]*$ ]]
}

validate_legacy_helper() {
    local path="$1"
    local digest

    if [ -L "$path" ] || [ ! -f "$path" ]; then
        log_error "旧同期処理が想定した通常ファイルではありません: $path"
        return 1
    fi
    digest=$(hash_file "$path") || {
        log_error "旧同期処理の識別に失敗しました: $path"
        return 1
    }
    if [ "$digest" != "$LEGACY_HELPER_SHA256" ]; then
        log_error "旧同期処理が既知の版と異なるため保全して停止します: $path"
        return 1
    fi
}

preflight_legacy_assets() {
    local entry
    local name

    if [ -e "$RUNTIME_DIR" ] || [ -L "$RUNTIME_DIR" ]; then
        if [ -L "$RUNTIME_DIR" ] || [ ! -d "$RUNTIME_DIR" ]; then
            log_error "旧保存先が通常のディレクトリではないため保全して停止します: $RUNTIME_DIR"
            return 1
        fi
        for entry in "$RUNTIME_DIR"/* "$RUNTIME_DIR"/.[!.]* "$RUNTIME_DIR"/..?*; do
            if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
                continue
            fi
            name=$(basename "$entry")
            case "$name" in
                azookey-custom-table-sync.sh)
                    validate_legacy_helper "$entry" || return 1
                    ;;
                last-synced.sha256)
                    if [ -L "$entry" ] || [ ! -f "$entry" ]; then
                        log_error "旧同期状態が通常ファイルではないため保全して停止します: $entry"
                        return 1
                    fi
                    LEGACY_STATE_HASH=$(validate_legacy_state "$entry") || {
                        log_error "旧同期状態の形式が不正なため保全して停止します: $entry"
                        return 1
                    }
                    ;;
                sync.log)
                    if [ -L "$entry" ] || [ ! -f "$entry" ] || ! validate_legacy_log "$entry"; then
                        log_error "旧同期記録が既知の形式ではないため保全して停止します: $entry"
                        return 1
                    fi
                    ;;
                *)
                    if is_retired_plist_name "$name"; then
                        if [ -L "$entry" ] || [ ! -f "$entry" ] || ! validate_legacy_plist "$entry"; then
                            log_error "退役済み定義が既知の形式ではないため保全して停止します: $entry"
                            return 1
                        fi
                    else
                        log_error "旧保存先に用途不明の資産があるため保全して停止します: $entry"
                        return 1
                    fi
                    ;;
            esac
        done
    fi

    if [ -e "$TARGET_PLIST" ] || [ -L "$TARGET_PLIST" ]; then
        if [ -L "$TARGET_PLIST" ] || [ ! -f "$TARGET_PLIST" ] || ! validate_legacy_plist "$TARGET_PLIST"; then
            log_error "LaunchAgent定義が既知の旧形式ではないため保全して停止します: $TARGET_PLIST"
            return 1
        fi
    fi
}

preflight_container_table() {
    if [ -L "$AZOOKEY_TABLE_DIR" ]; then
        local link_target
        link_target=$(readlink "$AZOOKEY_TABLE_DIR") || {
            log_error "既存リンクを確認できないため変更しません"
            return 1
        }
        if [ "$link_target" != "$SOURCE_DIR" ]; then
            log_error "想定外のリンク先を保持して停止します: $link_target"
            return 1
        fi
        reject_unexpected_entries "$SOURCE_DIR" || return 1
        if [ ! -f "$AZOOKEY_TABLE_TSV" ] || [ -L "$AZOOKEY_TABLE_TSV" ] ||
            ! cmp -s "$SOURCE_TSV" "$AZOOKEY_TABLE_TSV"; then
            log_error "リンク先のカスタム表が正本と一致しないため変更しません"
            return 1
        fi
        return 0
    fi
    if [ -e "$AZOOKEY_TABLE_DIR" ]; then
        if [ ! -d "$AZOOKEY_TABLE_DIR" ]; then
            log_error "保存先がディレクトリではないため変更しません"
            return 1
        fi
        reject_unexpected_entries "$AZOOKEY_TABLE_DIR" || return 1
        if { [ -e "$AZOOKEY_TABLE_TSV" ] || [ -L "$AZOOKEY_TABLE_TSV" ]; } &&
            { [ -L "$AZOOKEY_TABLE_TSV" ] || [ ! -f "$AZOOKEY_TABLE_TSV" ]; }; then
            log_error "保存先のTSVが通常ファイルではないため変更しません"
            return 1
        fi
    fi
    return 0
}

write_state_attribute() {
    local directory="$1"
    local value="$2"
    local readback

    xattr -w "$STATE_ATTRIBUTE" "$value" "$directory" 2>/dev/null || return 1
    readback=$(xattr -p "$STATE_ATTRIBUTE" "$directory" 2>/dev/null) || return 1
    [ "$readback" = "$value" ]
}

migrate_state_to_directory() {
    local directory="$1"
    local attribute_names
    local current_value
    local current_legacy_state

    attribute_names=$(xattr "$directory" 2>/dev/null) || {
        log_error "保存先の拡張属性を確認できないため変更しません"
        return 1
    }
    if printf '%s\n' "$attribute_names" | LC_ALL=C grep -Fqx "$STATE_ATTRIBUTE"; then
        current_value=$(xattr -p "$STATE_ATTRIBUTE" "$directory" 2>/dev/null) || {
            log_error "既存の同期状態属性を読み取れないため変更しません"
            return 1
        }
        if ! is_valid_hash "$current_value"; then
            log_error "既存の同期状態属性が不正なため変更しません"
            return 1
        fi
        return 0
    fi
    if [ -n "$LEGACY_STATE_HASH" ]; then
        current_legacy_state=$(validate_legacy_state "$STATE_FILE") || {
            log_error "旧同期状態を再確認できないため変更しません"
            return 1
        }
        if [ "$current_legacy_state" != "$LEGACY_STATE_HASH" ]; then
            log_error "旧同期状態が処理中に変わったため変更しません"
            return 1
        fi
        if ! write_state_attribute "$directory" "$LEGACY_STATE_HASH"; then
            log_error "旧同期状態を保存先へ書き込み、読み戻し確認できないため変更しません"
            return 1
        fi
    fi
}

create_staged_table_directory() {
    TEMP_DIR=$(mktemp -d "$AZOOKEY_PARENT_DIR/.CustomInputTable.migration.XXXXXX") || return 1
    cp "$SOURCE_TSV" "$TEMP_DIR/$TABLE_NAME" || return 1
    cmp -s "$SOURCE_TSV" "$TEMP_DIR/$TABLE_NAME" || return 1
    /bin/bash "$SOURCE_SYNC" --validate "$TEMP_DIR/$TABLE_NAME" >/dev/null || return 1
    migrate_state_to_directory "$TEMP_DIR" || return 1
}

publish_staged_table_directory() {
    if [ -e "$AZOOKEY_TABLE_DIR" ] || [ -L "$AZOOKEY_TABLE_DIR" ]; then
        log_error "保存先が作成済みのため移行を中止します"
        return 1
    fi
    if ! mv -n "$TEMP_DIR" "$AZOOKEY_TABLE_DIR"; then
        log_error "実ディレクトリを配置できません。正本は保持しています"
        return 1
    fi
    if [ -e "$TEMP_DIR" ] || [ -L "$TEMP_DIR" ] ||
        [ -L "$AZOOKEY_TABLE_DIR" ] || [ ! -d "$AZOOKEY_TABLE_DIR" ]; then
        log_error "保存先への配置結果を確認できません"
        return 1
    fi
    TEMP_DIR=""
}

install_source_in_empty_table_dir() {
    TEMP_TABLE=$(mktemp "$AZOOKEY_TABLE_DIR/.$TABLE_NAME.XXXXXX") || return 1
    cp "$SOURCE_TSV" "$TEMP_TABLE" || return 1
    cmp -s "$SOURCE_TSV" "$TEMP_TABLE" || return 1
    /bin/bash "$SOURCE_SYNC" --validate "$TEMP_TABLE" >/dev/null || return 1
    if [ -e "$AZOOKEY_TABLE_TSV" ] || [ -L "$AZOOKEY_TABLE_TSV" ]; then
        log_error "保存先にTSVが作成されたため上書きしません"
        return 1
    fi
    if ! mv -n "$TEMP_TABLE" "$AZOOKEY_TABLE_TSV"; then
        log_error "保存先へ表を配置できません"
        return 1
    fi
    if [ -e "$TEMP_TABLE" ] || [ -L "$TEMP_TABLE" ] ||
        [ -L "$AZOOKEY_TABLE_TSV" ] || [ ! -f "$AZOOKEY_TABLE_TSV" ]; then
        log_error "保存先への表の配置結果を確認できません"
        return 1
    fi
    TEMP_TABLE=""
}

prepare_container_table() {
    if [ -L "$AZOOKEY_TABLE_DIR" ]; then
        local link_target
        local source_attributes

        link_target=$(readlink "$AZOOKEY_TABLE_DIR") || {
            log_error "既存リンクを確認できないため変更しません"
            return 1
        }
        if [ "$link_target" != "$SOURCE_DIR" ]; then
            log_error "想定外のリンク先を保持して停止します: $link_target"
            return 1
        fi
        reject_unexpected_entries "$SOURCE_DIR" || return 1
        if [ ! -f "$AZOOKEY_TABLE_TSV" ] || [ -L "$AZOOKEY_TABLE_TSV" ] ||
            ! cmp -s "$SOURCE_TSV" "$AZOOKEY_TABLE_TSV"; then
            log_error "リンク先のカスタム表が正本と一致しないため変更しません"
            return 1
        fi
        source_attributes=$(xattr "$SOURCE_DIR" 2>/dev/null) || {
            log_error "正本ディレクトリの拡張属性を確認できないためリンクを保持します"
            return 1
        }
        if printf '%s\n' "$source_attributes" | LC_ALL=C grep -Fqx "$STATE_ATTRIBUTE"; then
            log_error "正本ディレクトリに同期状態属性があるため、正本を変更せず停止します"
            return 1
        fi
        create_staged_table_directory || {
            log_error "移行用の実ディレクトリを準備できないため既存リンクを保持します"
            return 1
        }
        if [ -e "$AZOOKEY_TABLE_DIR" ] && [ ! -L "$AZOOKEY_TABLE_DIR" ]; then
            log_error "既存リンクが移行中に変わったため停止します"
            return 1
        fi
        rm "$AZOOKEY_TABLE_DIR" || {
            log_error "既存リンクを外せないため表を変更しません"
            return 1
        }
        if ! publish_staged_table_directory; then
            if [ ! -e "$AZOOKEY_TABLE_DIR" ] && [ ! -L "$AZOOKEY_TABLE_DIR" ]; then
                ln -s "$SOURCE_DIR" "$AZOOKEY_TABLE_DIR" ||
                    log_error "移行に失敗し、元のリンクも復元できませんでした"
            fi
            return 1
        fi
        return 0
    fi

    if [ -e "$AZOOKEY_TABLE_DIR" ]; then
        if [ ! -d "$AZOOKEY_TABLE_DIR" ]; then
            log_error "保存先がディレクトリではないため変更しません"
            return 1
        fi
        reject_unexpected_entries "$AZOOKEY_TABLE_DIR" || return 1
        migrate_state_to_directory "$AZOOKEY_TABLE_DIR" || return 1
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

    mkdir -p "$AZOOKEY_PARENT_DIR" || {
        log_error "AzooKeyの保存先を作成できません"
        return 1
    }
    create_staged_table_directory || {
        log_error "移行用の実ディレクトリを準備できません"
        return 1
    }
    publish_staged_table_directory
}

stop_existing_agent() {
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        if ! launchctl bootout "$DOMAIN/$LABEL"; then
            log_error "旧LaunchAgentを停止できないため表の移行・同期を中止します"
            return 1
        fi
    fi
}

remove_active_plist() {
    if [ -e "$TARGET_PLIST" ] || [ -L "$TARGET_PLIST" ]; then
        if [ -L "$TARGET_PLIST" ] || [ ! -f "$TARGET_PLIST" ] || ! validate_legacy_plist "$TARGET_PLIST"; then
            log_error "LaunchAgent定義が処理中に変わったため保全します: $TARGET_PLIST"
            return 1
        fi
        rm "$TARGET_PLIST" || {
            log_error "停止済みLaunchAgent定義を削除できないため表の移行・同期を中止します"
            return 1
        }
        if [ -e "$TARGET_PLIST" ] || [ -L "$TARGET_PLIST" ]; then
            log_error "LaunchAgent定義の削除を確認できないため表の移行・同期を中止します"
            return 1
        fi
    fi
}

remove_legacy_assets() {
    local entry
    local name

    if [ ! -e "$RUNTIME_DIR" ] && [ ! -L "$RUNTIME_DIR" ]; then
        return 0
    fi
    if [ -L "$RUNTIME_DIR" ] || [ ! -d "$RUNTIME_DIR" ]; then
        log_error "旧保存先が処理中に変わったため保全します: $RUNTIME_DIR"
        return 1
    fi
    preflight_legacy_assets || return 1

    for name in azookey-custom-table-sync.sh sync.log; do
        entry="$RUNTIME_DIR/$name"
        if [ -e "$entry" ] || [ -L "$entry" ]; then
            if [ "$name" = "azookey-custom-table-sync.sh" ]; then
                validate_legacy_helper "$entry" || return 1
            else
                validate_legacy_log "$entry" || return 1
            fi
            if [ -L "$entry" ] || [ ! -f "$entry" ] || ! rm "$entry"; then
                log_error "確認済みの旧資産を削除できません: $entry"
                return 1
            fi
        fi
    done

    for entry in "$RUNTIME_DIR"/* "$RUNTIME_DIR"/.[!.]* "$RUNTIME_DIR"/..?*; do
        if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
            continue
        fi
        name=$(basename "$entry")
        if is_retired_plist_name "$name"; then
            if [ -L "$entry" ] || [ ! -f "$entry" ] || ! validate_legacy_plist "$entry" || ! rm "$entry"; then
                log_error "確認済みの退役定義を削除できません: $entry"
                return 1
            fi
        elif [ "$name" != "last-synced.sha256" ]; then
            log_error "処理中に用途不明の資産が現れたため保全します: $entry"
            return 1
        fi
    done

    entry="$RUNTIME_DIR/last-synced.sha256"
    if [ -e "$entry" ] || [ -L "$entry" ]; then
        if [ -L "$entry" ] || [ ! -f "$entry" ] || ! validate_legacy_state "$entry" >/dev/null || ! rm "$entry"; then
            log_error "確認済みの旧同期状態を削除できません: $entry"
            return 1
        fi
    fi

    rmdir "$RUNTIME_DIR" 2>/dev/null || {
        log_error "既知資産の削除後に旧保存先が空ではないためフォルダーを保持します"
        return 1
    }
}

verify_synced_state() {
    local expected_hash="$1"
    local actual_hash
    local attribute_names

    if [ -L "$AZOOKEY_TABLE_DIR" ] || [ ! -d "$AZOOKEY_TABLE_DIR" ] ||
        [ -L "$AZOOKEY_TABLE_TSV" ] || [ ! -f "$AZOOKEY_TABLE_TSV" ]; then
        log_error "同期先が通常の実ディレクトリとTSVではありません"
        return 1
    fi
    cmp -s "$SOURCE_TSV" "$AZOOKEY_TABLE_TSV" || {
        log_error "同期先と正本が一致しません"
        return 1
    }
    attribute_names=$(xattr "$AZOOKEY_TABLE_DIR" 2>/dev/null) || {
        log_error "同期状態属性を確認できません"
        return 1
    }
    if ! printf '%s\n' "$attribute_names" | LC_ALL=C grep -Fqx "$STATE_ATTRIBUTE"; then
        log_error "同期状態属性が見つかりません"
        return 1
    fi
    actual_hash=$(xattr -p "$STATE_ATTRIBUTE" "$AZOOKEY_TABLE_DIR" 2>/dev/null) || {
        log_error "同期状態属性を読み戻せません"
        return 1
    }
    if [ "$actual_hash" != "$expected_hash" ]; then
        log_error "同期状態属性の読み戻し値が正本と一致しません"
        return 1
    fi
}

log_info "AzooKeyのカスタム表を設定・同期しています..."

if [ -L "$SOURCE_DIR" ] || [ -L "$SOURCE_TSV" ] || [ ! -d "$SOURCE_DIR" ]; then
    log_error "dotfiles側のカスタム表のパスが不正です"
    exit 1
fi
if [ ! -f "$SOURCE_TSV" ] || [ ! -r "$SOURCE_TSV" ]; then
    log_error "dotfiles側のカスタム入力表がないか読み取れません: $SOURCE_TSV"
    exit 1
fi
if [ -L "$SOURCE_SYNC" ] || [ ! -f "$SOURCE_SYNC" ]; then
    log_error "同期処理がないか通常ファイルではありません: $SOURCE_SYNC"
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
    "$LAUNCH_AGENTS_DIR"; do
    ensure_directory_shape "$directory" "保存先" || exit 1
done
ensure_directory_shape "$RUNTIME_DIR" "旧保存先" || exit 1

preflight_legacy_assets || exit 1
preflight_container_table || exit 1
SOURCE_HASH_BEFORE=$(hash_file "$SOURCE_TSV") || {
    log_error "正本のハッシュを確認できません"
    exit 1
}

stop_existing_agent || exit 1
remove_active_plist || exit 1
prepare_container_table || exit 1

/bin/bash "$SOURCE_SYNC" "$SOURCE_TSV" "$AZOOKEY_TABLE_TSV" || {
    log_error "同期を完了できません。正本・同期先と旧資産を保持しています"
    exit 1
}

SOURCE_HASH_AFTER=$(hash_file "$SOURCE_TSV") || {
    log_error "同期後に正本のハッシュを確認できません。旧資産を保持しています"
    exit 1
}
if [ "$SOURCE_HASH_AFTER" != "$SOURCE_HASH_BEFORE" ]; then
    log_error "同期中に正本が変わったため旧資産を保持します"
    exit 1
fi
verify_synced_state "$SOURCE_HASH_BEFORE" || exit 1
remove_legacy_assets || exit 1

printf 'AzooKeyのカスタム表を同期しました: %s\n' "$AZOOKEY_TABLE_TSV"
