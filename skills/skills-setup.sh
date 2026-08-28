#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
HARNESS_ROOT="${CODEX_HARNESS_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/../.." && pwd)/harness}"
SOURCE_DIR="${ICLOUD_SKILLS_DIR_OVERRIDE:-$HARNESS_ROOT/skills}"
TARGET_DIR="${LOCAL_CODEX_SKILLS_DIR_OVERRIDE:-$HOME/.codex/skills}"
LEGACY_SOURCE_DIR="${CODEX_SKILLS_LEGACY_SOURCE_DIR_OVERRIDE:-$(cd "$SCRIPT_DIR/../../skills" 2>/dev/null && pwd || true)}"
SYSTEM_DIR="${CODEX_SYSTEM_SKILLS_DIR_OVERRIDE:-$LEGACY_SOURCE_DIR/.system}"
SYSTEM_MARKER_FILE="${CODEX_SYSTEM_SKILLS_MARKER_FILE_OVERRIDE:-$SYSTEM_DIR/.codex-system-skills.marker}"

same_target() {
    local left="$1"
    local right="$2"
    [ "$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$left")" = \
      "$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$right")" ]
}

[ -d "$SOURCE_DIR" ] || { printf '[ERROR] Skills source is missing: %s\n' "$SOURCE_DIR" >&2; exit 1; }
[ -d "$SYSTEM_DIR" ] || { printf '[ERROR] plugin-managed .system is missing: %s\n' "$SYSTEM_DIR" >&2; exit 1; }
if [ -n "${CODEX_SYSTEM_SKILLS_EXPECTED_MARKER:-}" ]; then
    [ -f "$SYSTEM_MARKER_FILE" ] && [ "$(cat "$SYSTEM_MARKER_FILE")" = "$CODEX_SYSTEM_SKILLS_EXPECTED_MARKER" ] || {
        printf '[ERROR] plugin-managed .system provider is not recognized: %s\n' "$SYSTEM_DIR" >&2
        exit 1
    }
elif [ ! -s "$SYSTEM_MARKER_FILE" ]; then
    printf '[ERROR] plugin-managed .system recognition marker is missing: %s\n' "$SYSTEM_MARKER_FILE" >&2
    exit 1
fi

entries=()
while IFS= read -r -d '' entry; do
    name=$(basename "$entry")
    case "$name" in
        .*) continue ;;
    esac
    entries+=("$entry")
done < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -print0 | sort -z)
[ "${#entries[@]}" -gt 0 ] || { printf '%s\n' '[ERROR] no Skills entries found' >&2; exit 1; }

is_known_entry() {
    local candidate="$1"
    local entry
    for entry in "${entries[@]}"; do
        [ "$(basename "$entry")" = "$candidate" ] && return 0
    done
    return 1
}

parent=$(dirname "$TARGET_DIR")
mkdir -p "$parent"

if [ -L "$TARGET_DIR" ]; then
    if ! same_target "$TARGET_DIR" "$LEGACY_SOURCE_DIR" && ! same_target "$TARGET_DIR" "$SOURCE_DIR"; then
        printf '[ERROR] unknown skills root conflict: %s\n' "$TARGET_DIR" >&2
        exit 1
    fi
    backup_root="${CODEX_SKILLS_BACKUP_DIR_OVERRIDE:-$parent/backups}"
    mkdir -p "$backup_root"
    backup="$backup_root/skills.symlink-install.$(date '+%Y%m%d-%H%M%S').$$"
    [ ! -e "$backup" ] || { printf '[ERROR] backup already exists: %s\n' "$backup" >&2; exit 1; }
    [ "${SKILLS_SETUP_FAIL_BACKUP:-0}" = 1 ] && {
        printf '%s\n' '[ERROR] injected Skills backup failure' >&2
        exit 1
    }
    mv "$TARGET_DIR" "$backup"
    original_kind=symlink
else
    if [ -e "$TARGET_DIR" ]; then
        original_kind=directory
        while IFS= read -r -d '' child; do
            if [ "$(basename "$child")" = ".system" ]; then
                same_target "$child" "$SYSTEM_DIR" || {
                    printf '[ERROR] unknown plugin-managed .system conflict: %s\n' "$child" >&2
                    exit 1
                }
            elif is_known_entry "$(basename "$child")"; then
                :
            else
                printf '[ERROR] unknown skills directory conflict: %s\n' "$child" >&2
                exit 1
            fi
        done < <(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print0 | sort -z)
    else
        original_kind=missing
        mkdir -p "$TARGET_DIR"
        target_created=true
    fi
fi

pending_entries=()
if [ -d "$TARGET_DIR" ] && [ ! -L "$TARGET_DIR" ]; then
    for entry in "${entries[@]}"; do
        destination="$TARGET_DIR/$(basename "$entry")"
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            if [ -L "$destination" ] && same_target "$destination" "$entry"; then
                continue
            fi
            printf '[ERROR] existing Skills child conflict: %s\n' "$destination" >&2
            exit 1
        fi
        pending_entries+=("$entry")
    done
else
    pending_entries=("${entries[@]}")
fi
entries=()
for ((index=0; index<${#pending_entries[@]}; index++)); do
    entries+=("${pending_entries[$index]}")
done

staging="$parent/.skills.staging.$$"
rollback_needed=true
created_children=()
created_system=false
cleanup() {
    if [ "$rollback_needed" = true ]; then
        for ((index=0; index<${#created_children[@]}; index++)); do
            rm -rf -- "${created_children[$index]}"
        done
        if [ "$created_system" = true ]; then
            rm -rf -- "$TARGET_DIR/.system"
        fi
        rm -rf -- "$staging"
        if [ "${original_kind:-missing}" = symlink ] && [ -n "${backup:-}" ] && [ -e "$backup" ]; then
            rm -rf -- "$TARGET_DIR"
            mv "$backup" "$TARGET_DIR"
        elif [ "${original_kind:-missing}" = missing ] && [ -d "$TARGET_DIR" ]; then
            rmdir "$TARGET_DIR" 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT

mkdir "$staging"
ln -s "$SYSTEM_DIR" "$staging/.system"
for ((index=0; index<${#entries[@]}; index++)); do
    entry="${entries[$index]}"
    ln -s "$entry" "$staging/$(basename "$entry")"
done

if [ "${SKILLS_SETUP_FAIL_AFTER:-0}" = "1" ]; then
    printf '%s\n' '[ERROR] injected Skills setup failure' >&2
    exit 1
fi

if [ -d "$TARGET_DIR" ] && [ ! -L "$TARGET_DIR" ]; then
    for child in "$staging"/* "$staging"/.[!.]*; do
        [ -e "$child" ] || [ -L "$child" ] || continue
        name=$(basename "$child")
        if [ "$name" = ".system" ]; then
            if [ ! -e "$TARGET_DIR/.system" ] && [ ! -L "$TARGET_DIR/.system" ]; then
                mv "$child" "$TARGET_DIR/.system"
                created_system=true
            else
                rm -rf -- "$child"
            fi
        else
            mv "$child" "$TARGET_DIR/$name"
            created_children+=("$TARGET_DIR/$name")
        fi
    done
    rmdir "$staging"
else
    rm -rf -- "$TARGET_DIR"
    mv "$staging" "$TARGET_DIR"
fi

rollback_needed=false
trap - EXIT
printf '[SUCCESS] Skills child links installed: %s\n' "${#entries[@]}"
