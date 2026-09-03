#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
SETUP="$DOTFILES_ROOT/setup-macos.sh"

python3 - "$SETUP" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(r"setup_scripts=\(\n(?P<body>.*?)\n\)", source, re.S)
if not match:
    raise AssertionError("setup-macos.sh has no setup_scripts array")

entries = re.findall(r'^\s+"([^"]+)"\s*$', match.group("body"), re.M)
assert entries.count("apps/codex/codex-setup.sh") == 1, entries
for forbidden in (
    "apps/codex/agents-setup.sh",
    "apps/codex/agents/agents-setup.sh",
    "apps/codex/skills/skills-setup.sh",
    "apps/codex/custom-instructions-sync/custom-instructions-setup.sh",
    "apps/codex/custom-instructions/custom-instructions-setup.sh",
    "apps/codex/hooks/hooks-setup.sh",
):
    assert forbidden not in entries, (forbidden, entries)
assert source.count('"$DOTFILES_ROOT/$script"') == 1

print("[PASS] setup-macos Codex entrypoint-only contract")
PY
