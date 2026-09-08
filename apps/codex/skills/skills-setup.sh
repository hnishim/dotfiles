#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
HARNESS_ROOT="${CODEX_HARNESS_ROOT_OVERRIDE:-$DOTFILES_ROOT/../harness}"
SOURCE_DIR="${ICLOUD_SKILLS_DIR_OVERRIDE:-$HARNESS_ROOT/skills}"
TARGET_DIR="${LOCAL_CODEX_SKILLS_DIR_OVERRIDE:-$HOME/.codex/skills}"

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
if [ "$target_state" = existing ]; then
    printf '[ERROR] existing Skills target conflict: %s\n' "$TARGET_DIR" >&2
    exit 1
fi
if [ ! -d "$parent" ]; then
    mkdir -p "$parent"
fi

temporary="$parent/.$(basename -- "$TARGET_DIR").symlink-install-${SKILLS_SETUP_INSTALL_ID_OVERRIDE:-$$}"
[ ! -e "$temporary" ] && [ ! -L "$temporary" ] || { printf '[ERROR] temporary Skills root link already exists: %s\n' "$temporary" >&2; exit 1; }
ln -s "$SOURCE_DIR" "$temporary"
if [ -e "$TARGET_DIR" ] || [ -L "$TARGET_DIR" ]; then
    rm -f -- "$temporary"
    printf '[ERROR] Skills target appeared during installation: %s\n' "$TARGET_DIR" >&2
    exit 1
fi
mv -- "$temporary" "$TARGET_DIR"
printf '%s\n' '[SUCCESS] Skills root symlink installed (changed: 1, existing: 0)'
