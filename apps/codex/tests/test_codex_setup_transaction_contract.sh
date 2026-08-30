#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
CODEX_SETUP="$SCRIPT_DIR/../codex-setup.sh"

python3 - "$CODEX_SETUP" <<'PY'
import re
import sys
from pathlib import Path

setup_path = Path(sys.argv[1])
source = setup_path.read_text(encoding="utf-8")

start_marker = '    exec /usr/bin/python3 "$TRANSACTION" ' + "\\" + "\n"
end_marker = '        --command /bin/bash "$SCRIPT_DIR/codex-setup.sh" "$@"'

if source.count(start_marker) != 1:
    raise AssertionError("expected exactly one harness transaction invocation")

start = source.index(start_marker)
end = source.find(end_marker, start)
if end < 0:
    raise AssertionError("transaction invocation has no command boundary")
end += len(end_marker)
invocation = source[start:end]

path_args = re.findall(
    r'^\s+--path\s+"([^"]+)"\s+\\\s*$',
    invocation,
    flags=re.MULTILINE,
)
if not path_args:
    raise AssertionError("transaction invocation has no --path arguments")

for expected in ("$CODEX_HOME_DIR/skills", "$CODEX_HOME_DIR/backups"):
    if path_args.count(expected) != 1:
        raise AssertionError(f"missing or duplicated transaction path: {expected}")

for path_arg in path_args:
    normalized = path_arg.lower()
    if "runtime" in normalized or "archive" in normalized or "system" in normalized:
        raise AssertionError(f"forbidden transaction path: {path_arg}")

print("[PASS] codex-setup transaction Skills path contract")
PY
