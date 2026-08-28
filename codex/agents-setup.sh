#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
HARNESS_ROOT="${CODEX_HARNESS_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/../.." && pwd)/harness}"
SOURCE_DIR="${CODEX_AGENTS_SOURCE_DIR_OVERRIDE:-$HARNESS_ROOT/agents}"
TARGET_DIR="${LOCAL_CODEX_AGENTS_DIR_OVERRIDE:-$HOME/.codex/agents}"
LEGACY_SOURCE_DIR="${CODEX_AGENTS_LEGACY_SOURCE_DIR_OVERRIDE:-$SCRIPT_DIR/agents}"
BACKUP_DIR="${CODEX_AGENTS_BACKUP_DIR_OVERRIDE:-$(dirname "$TARGET_DIR")/backups}"
FAIL_AFTER="${AGENTS_SETUP_FAIL_AFTER:-0}"
PYTHON_EXECUTABLE="${PYTHON_EXECUTABLE:-$(command -v python3 2>/dev/null || true)}"

agent_names=(planner plan-reviewer implementer reviewer git-actions)

[ -d "$SOURCE_DIR" ] || { printf '[ERROR] Agent source is missing: %s\n' "$SOURCE_DIR" >&2; exit 1; }
[ -n "$LEGACY_SOURCE_DIR" ] || { printf '%s\n' '[ERROR] legacy Agent source is not resolvable' >&2; exit 1; }

same_target() {
    local left="$1"
    local right="$2"
    [ "$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$left")" = \
      "$(/usr/bin/python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$right")" ]
}

validate_agent() {
    local path="$1"
    local name="$2"
    [ -f "$path" ] && [ ! -L "$path" ] || {
        printf '[ERROR] Agent definition is not a regular file: %s\n' "$path" >&2
        return 1
    }
    [ -n "$PYTHON_EXECUTABLE" ] && [ -x "$PYTHON_EXECUTABLE" ] || {
        printf '%s\n' '[ERROR] python3 is required to validate Agent TOML' >&2
        return 1
    }
    "$PYTHON_EXECUTABLE" - "$path" "$name" <<'PY'
import sys

try:
    import tomllib
except ImportError:
    raise SystemExit("python3 with tomllib is required to validate Agent TOML")

path, expected_name = sys.argv[1:]
with open(path, "rb") as stream:
    data = tomllib.load(stream)

required_strings = (
    "name",
    "description",
    "model",
    "model_reasoning_effort",
    "developer_instructions",
)
for key in required_strings:
    value = data.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"missing or invalid Agent field: {key}")
if data["name"] != expected_name:
    raise SystemExit("Agent name does not match filename")
if expected_name in {"planner", "plan-reviewer", "reviewer"}:
    if data.get("sandbox_mode") != "read-only":
        raise SystemExit("read-only Agent lacks sandbox_mode = read-only")
PY
}

sources=()
states=()
destinations=()
for name in "${agent_names[@]}"; do
    source="$SOURCE_DIR/$name.toml"
    destination="$TARGET_DIR/$name.toml"
    validate_agent "$source" "$name"
    sources+=("$source")
    destinations+=("$destination")

    if [ -e "$destination" ] || [ -L "$destination" ]; then
        if [ -L "$destination" ] && same_target "$destination" "$source"; then
            states+=(correct)
        elif [ -L "$destination" ] && same_target "$destination" "$LEGACY_SOURCE_DIR/$name.toml"; then
            states+=(legacy)
        else
            printf '[ERROR] Agent destination conflict: %s\n' "$destination" >&2
            exit 1
        fi
    else
        states+=(missing)
    fi
done

target_created=false
mkdir -p "$(dirname "$TARGET_DIR")"
if [ -e "$TARGET_DIR" ] || [ -L "$TARGET_DIR" ]; then
    [ -d "$TARGET_DIR" ] && [ ! -L "$TARGET_DIR" ] || {
        printf '[ERROR] Agent target is not a directory: %s\n' "$TARGET_DIR" >&2
        exit 1
    }
else
    mkdir "$TARGET_DIR"
    target_created=true
fi

rollback_needed=true
created_links=()
moved_destinations=()
moved_backups=()
rollback() {
    [ "$rollback_needed" = true ] || return 0
    local index
    for ((index=${#created_links[@]}-1; index>=0; index--)); do
        rm -f -- "${created_links[$index]}"
    done
    for ((index=${#moved_destinations[@]}-1; index>=0; index--)); do
        destination="${moved_destinations[$index]}"
        backup="${moved_backups[$index]}"
        if [ -e "$backup" ] || [ -L "$backup" ]; then
            [ ! -e "$destination" ] && [ ! -L "$destination" ] || rm -f -- "$destination"
            mv "$backup" "$destination"
        fi
    done
    if [ "$target_created" = true ] && [ -d "$TARGET_DIR" ]; then
        rmdir "$TARGET_DIR" 2>/dev/null || true
    fi
}
trap rollback EXIT

changed=0
skipped=0
for index in "${!agent_names[@]}"; do
    state="${states[$index]}"
    destination="${destinations[$index]}"
    source="${sources[$index]}"
    if [ "$state" = correct ]; then
        skipped=$((skipped + 1))
        continue
    fi

    if [ "$state" = legacy ]; then
        mkdir -p "$BACKUP_DIR"
        [ "${AGENTS_SETUP_FAIL_BACKUP:-0}" = 1 ] && {
            printf '%s\n' '[ERROR] injected Agent backup failure' >&2
            exit 1
        }
        backup="$BACKUP_DIR/$(basename "$destination").symlink-install.$(date '+%Y%m%d-%H%M%S').$$"
        counter=1
        while [ -e "$backup" ] || [ -L "$backup" ]; do
            backup="$BACKUP_DIR/$(basename "$destination").symlink-install.$(date '+%Y%m%d-%H%M%S').$$.$counter"
            counter=$((counter + 1))
        done
        mv "$destination" "$backup"
        moved_destinations+=("$destination")
        moved_backups+=("$backup")
    fi

    temporary="$TARGET_DIR/.$(basename "$destination").symlink-install-$$"
    [ ! -e "$temporary" ] && [ ! -L "$temporary" ] || {
        printf '[ERROR] temporary Agent link already exists: %s\n' "$temporary" >&2
        exit 1
    }
    ln -s "$source" "$temporary"
    mv "$temporary" "$destination"
    created_links+=("$destination")
    changed=$((changed + 1))
    if [ "$FAIL_AFTER" -gt 0 ] && [ "$changed" -ge "$FAIL_AFTER" ]; then
        printf '%s\n' '[ERROR] injected Agent setup failure' >&2
        exit 1
    fi
done

rollback_needed=false
trap - EXIT
printf '[SUCCESS] Agents installed (changed: %s, existing: %s)\n' "$changed" "$skipped"
