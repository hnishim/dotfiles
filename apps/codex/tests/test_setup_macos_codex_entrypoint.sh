#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
SETUP="$DOTFILES_ROOT/setup-macos.sh"
PACKAGES="$DOTFILES_ROOT/brew/packages.yml"
AGENTS_SETUP="$DOTFILES_ROOT/apps/codex/agents/agents-setup.sh"

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

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/setup-macos-python-path-test.XXXXXX")
trap 'rm -rf -- "$TMP_ROOT"' EXIT

FIXTURE_ROOT="$TMP_ROOT/dotfiles"
HOMEBREW_BIN="$TMP_ROOT/homebrew/bin"
EXPECTED_PYTHON="$HOMEBREW_BIN/python3"
mkdir -p "$FIXTURE_ROOT/lib" "$FIXTURE_ROOT/brew" "$HOMEBREW_BIN"
cp "$SETUP" "$FIXTURE_ROOT/setup-macos.sh"
chmod 755 "$FIXTURE_ROOT/setup-macos.sh"

cat >"$FIXTURE_ROOT/lib/common.sh" <<'SH'
set -euo pipefail
log_header() { :; }
log_info() { :; }
log_success() { :; }
log_error() { printf '[ERROR] %s\n' "$1" >&2; }
SH

cat >"$FIXTURE_ROOT/brew/brew-setup.sh" <<SH
#!/bin/bash
set -euo pipefail
export PATH="$HOMEBREW_BIN:\$PATH"
SH
chmod 755 "$FIXTURE_ROOT/brew/brew-setup.sh"

cat >"$EXPECTED_PYTHON" <<'SH'
#!/bin/bash
exit 0
SH
chmod 755 "$EXPECTED_PYTHON"

setup_scripts=(
    "defaults/defaults-setup.sh"
    "nextdns/nextdns-setup.sh"
    "duti/duti-setup.sh"
    "apps/snapzy/snapzy-setup.sh"
    "karabiner-elements/karabiner-setup.sh"
    "gitignore/global-gitignore-setup.sh"
    "apps/codex/codex-setup.sh"
    "apps/warp/warp-setup.sh"
    "apps/espanso/espanso-setup.sh"
    "apps/cursor/cursor-setup.sh"
    "apps/ferdium/ferdium-setup.sh"
    "apps/amphetamine/amphetamine-setup.sh"
    "textlint/textlint-setup.sh"
    "hammerspoon/hammerspoon-setup.sh"
)

for script in "${setup_scripts[@]}"; do
    path="$FIXTURE_ROOT/$script"
    mkdir -p "$(dirname -- "$path")"
    if [ "$script" = "apps/codex/codex-setup.sh" ]; then
        cat >"$path" <<SH
#!/bin/bash
set -euo pipefail
resolved=\$(command -v python3)
if [ "\$resolved" != "$EXPECTED_PYTHON" ]; then
    printf '[FAIL] Codex setup resolved python3 to %s; expected %s\n' "\$resolved" "$EXPECTED_PYTHON" >&2
    exit 1
fi
SH
    else
        cat >"$path" <<'SH'
#!/bin/bash
set -euo pipefail
exit 0
SH
    fi
    chmod 755 "$path"
done

PATH="/usr/bin:/bin" /bin/bash "$FIXTURE_ROOT/setup-macos.sh" >"$TMP_ROOT/setup.log" 2>&1
printf '%s\n' '[PASS] setup-macos propagates Homebrew PATH to Codex setup'

python3 - "$PACKAGES" "$AGENTS_SETUP" <<'PY'
import re
import sys
from pathlib import Path

packages = Path(sys.argv[1]).read_text(encoding="utf-8")
agents_setup = Path(sys.argv[2]).read_text(encoding="utf-8")

formulae_match = re.search(r"^formulae:\s*\n(?P<body>(?:^[ \t]+-.*\n)+)", packages, re.M)
if not formulae_match:
    raise AssertionError("packages.yml has no formulae list")
formulae = formulae_match.group("body")
assert re.search(r"^\s*-\s+python3(?:\s*(?:#.*)?)?$", formulae, re.M), formulae
assert not re.search(r"^\s*-\s+python@\d", formulae, re.M), formulae

assert "command -v python3" in agents_setup
assert "brew --prefix" not in agents_setup
assert not re.search(r"python@\d", agents_setup)

print("[PASS] Python dependency and Agents responsibility contract")
PY
