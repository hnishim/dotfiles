#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
DEFAULT_HARNESS_ROOT="$DOTFILES_ROOT/../harness"
HARNESS_ROOT="${CODEX_HARNESS_ROOT_OVERRIDE:-$DEFAULT_HARNESS_ROOT}"
SOURCE_DIR="${CODEX_AGENTS_SOURCE_DIR_OVERRIDE:-$HARNESS_ROOT/agents}"
TARGET_DIR="${LOCAL_CODEX_AGENTS_DIR_OVERRIDE:-$HOME/.codex/agents}"
PYTHON_EXECUTABLE="${PYTHON_EXECUTABLE:-$(command -v python3 2>/dev/null || true)}"

[ -d "$SOURCE_DIR" ] || { printf '[ERROR] Agent source is missing: %s\n' "$SOURCE_DIR" >&2; exit 1; }

agent_names=()
while IFS= read -r -d '' path; do
    name=${path##*/}
    name=${name%.toml}
    [ -n "$name" ] || {
        printf '[ERROR] Agent definition has an empty name: %s\n' "$path" >&2
        exit 1
    }
    agent_names+=("$name")
done < <(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.toml' -print0)
[ "${#agent_names[@]}" -gt 0 ] || {
    printf '[ERROR] Agent source has no TOML definitions: %s\n' "$SOURCE_DIR" >&2
    exit 1
}

same_target() {
    local left="$1"
    local right="$2"
    [ "$("$PYTHON_EXECUTABLE" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$left")" = \
      "$("$PYTHON_EXECUTABLE" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$right")" ]
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
sandbox_mode = data.get("sandbox_mode")
if sandbox_mode is not None and (not isinstance(sandbox_mode, str) or not sandbox_mode.strip()):
    raise SystemExit("invalid sandbox_mode")
if "reviewer" in expected_name.lower() and sandbox_mode != "read-only":
    raise SystemExit("read-only Agent lacks sandbox_mode = read-only")
PY
}

for name in "${agent_names[@]}"; do
    validate_agent "$SOURCE_DIR/$name.toml" "$name"
done

target_state=missing
if [ -L "$TARGET_DIR" ]; then
    if same_target "$TARGET_DIR" "$SOURCE_DIR"; then
        target_state=correct
    else
        printf '[ERROR] unknown Agent root conflict: %s\n' "$TARGET_DIR" >&2
        exit 1
    fi
elif [ -e "$TARGET_DIR" ]; then
    printf '[ERROR] unknown Agent root conflict: %s\n' "$TARGET_DIR" >&2
    exit 1
fi

if [ "$target_state" = correct ]; then
    printf '%s\n' '[SUCCESS] Agents root already points to the harness source (changed: 0, existing: 1)'
    exit 0
fi

parent=$(dirname -- "$TARGET_DIR")
if [ ! -d "$parent" ]; then
    mkdir -p "$parent"
fi

temporary="$parent/.$(basename "$TARGET_DIR").symlink-install-$$"
[ ! -e "$temporary" ] && [ ! -L "$temporary" ] || {
    printf '[ERROR] temporary Agent root link already exists: %s\n' "$temporary" >&2
    exit 1
}
ln -s "$SOURCE_DIR" "$temporary"
if [ -e "$TARGET_DIR" ] || [ -L "$TARGET_DIR" ]; then
    rm -f -- "$temporary"
    printf '[ERROR] Agent target appeared during installation: %s\n' "$TARGET_DIR" >&2
    exit 1
fi
"$PYTHON_EXECUTABLE" - "$temporary" "$TARGET_DIR" <<'PY'
import os
import sys

os.replace(sys.argv[1], sys.argv[2])
PY
temporary=""

changed=1
printf '[SUCCESS] Agents root installed (changed: %s, existing: 0)\n' "$changed"
