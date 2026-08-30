#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
HARNESS_ROOT="${CODEX_HARNESS_ROOT_OVERRIDE:-$DOTFILES_ROOT/../harness}"
SOURCE_DIR="${ICLOUD_SKILLS_DIR_OVERRIDE:-$HARNESS_ROOT/skills}"
TARGET_DIR="${LOCAL_CODEX_SKILLS_DIR_OVERRIDE:-$HOME/.codex/skills}"
BACKUP_DIR="${CODEX_SKILLS_BACKUP_DIR_OVERRIDE:-$(dirname -- "$TARGET_DIR")/backups}"

[ -d "$SOURCE_DIR" ] || { printf '[ERROR] Skills source is missing: %s\n' "$SOURCE_DIR" >&2; exit 1; }
entries=()
while IFS= read -r -d '' entry; do
    case "$(basename -- "$entry")" in .*) continue ;; esac
    entries+=("$entry")
done < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -print0 | sort -z)
[ "${#entries[@]}" -gt 0 ] || { printf '%s\n' '[ERROR] no Skills entries found' >&2; exit 1; }

same_target() {
    [ "$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1")" = \
      "$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$2")" ]
}

target_state=missing
if [ -L "$TARGET_DIR" ]; then
    same_target "$TARGET_DIR" "$SOURCE_DIR" && target_state=correct || target_state=existing
elif [ -e "$TARGET_DIR" ]; then
    target_state=existing
fi
if [ "$target_state" = correct ]; then
    printf '%s\n' '[SUCCESS] Skills root already points to the harness source (changed: 0, existing: 1)'
    exit 0
fi

parent=$(dirname -- "$TARGET_DIR")
parent_created=false
if [ ! -d "$parent" ]; then mkdir -p "$parent"; parent_created=true; fi
rollback_needed=true
backup_dir_created=false
backup_moved=false
target_installed=false
temporary_created=false
backup=''
temporary=''

rollback() {
    local status=$?
    if [ "$rollback_needed" = true ]; then
        set +e
        if [ "$temporary_created" = true ] && { [ -e "$temporary" ] || [ -L "$temporary" ]; }; then rm -f -- "$temporary"; fi
        if [ "$target_installed" = true ] && { [ -e "$TARGET_DIR" ] || [ -L "$TARGET_DIR" ]; }; then rm -f -- "$TARGET_DIR"; fi
        if [ "$backup_moved" = true ] && { [ -e "$backup" ] || [ -L "$backup" ]; }; then mv -- "$backup" "$TARGET_DIR"; fi
        if [ "$backup_dir_created" = true ]; then rmdir "$BACKUP_DIR" 2>/dev/null || true; fi
        if [ "$parent_created" = true ]; then rmdir "$parent" 2>/dev/null || true; fi
        return "$status"
    fi
    return 0
}
trap rollback EXIT

if [ "$target_state" = existing ]; then
    if [ ! -d "$BACKUP_DIR" ]; then mkdir -p "$BACKUP_DIR"; backup_dir_created=true; fi
    [ -d "$BACKUP_DIR" ] || { printf '[ERROR] Skills backup path is not a directory: %s\n' "$BACKUP_DIR" >&2; exit 1; }
    [ "${SKILLS_SETUP_FAIL_BACKUP:-0}" = 1 ] && { printf '%s\n' '[ERROR] injected Skills backup failure' >&2; exit 1; }
    backup_timestamp="${SKILLS_SETUP_BACKUP_TIMESTAMP_OVERRIDE:-$(date '+%Y%m%d-%H%M%S')}"
    backup_pid="${SKILLS_SETUP_BACKUP_PID_OVERRIDE:-${SKILLS_SETUP_INSTALL_ID_OVERRIDE:-$$}}"
    backup="$BACKUP_DIR/$(basename -- "$TARGET_DIR").symlink-install.$backup_timestamp.$backup_pid"
    counter=1
    while [ -e "$backup" ] || [ -L "$backup" ]; do
        backup="$BACKUP_DIR/$(basename -- "$TARGET_DIR").symlink-install.$backup_timestamp.$backup_pid.$counter"
        counter=$((counter + 1))
    done
    mv -- "$TARGET_DIR" "$backup"
    backup_moved=true
fi

temporary="$parent/.$(basename -- "$TARGET_DIR").symlink-install-${SKILLS_SETUP_INSTALL_ID_OVERRIDE:-$$}"
[ ! -e "$temporary" ] && [ ! -L "$temporary" ] || { printf '[ERROR] temporary Skills root link already exists: %s\n' "$temporary" >&2; exit 1; }
ln -s "$SOURCE_DIR" "$temporary"
temporary_created=true
if [ -e "$TARGET_DIR" ] || [ -L "$TARGET_DIR" ]; then
    printf '[ERROR] Skills target appeared during installation: %s\n' "$TARGET_DIR" >&2
    exit 1
fi
mv -- "$temporary" "$TARGET_DIR"
temporary=''
temporary_created=false
target_installed=true

if [ "${SKILLS_SETUP_FAIL_AFTER:-0}" = 1 ]; then
    printf '%s\n' '[ERROR] injected Skills setup failure' >&2
    exit 1
fi

rollback_needed=false
trap - EXIT
printf '%s\n' '[SUCCESS] Skills root symlink installed (changed: 1, existing: 0)'
