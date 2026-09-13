#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
ASSET_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

python3 - "$ASSET_DIR" <<'PY'
import sys
from pathlib import Path

asset_dir = Path(sys.argv[1])
setup = asset_dir / "custom-instructions-setup.sh"
info = asset_dir / "Info.plist"
new_plist = asset_dir / "my.notion.sync.plist"
old_plist = asset_dir / "com.hnishim.custom-instructions-sync.plist"

for path in (setup, info, new_plist):
    if not path.is_file():
        raise AssertionError(f"missing namespace artifact: {path}")
if old_plist.exists():
    raise AssertionError(f"legacy LaunchAgent source plist remains active: {old_plist}")

setup_source = setup.read_text(encoding="utf-8")
info_source = info.read_text(encoding="utf-8")
plist_source = new_plist.read_text(encoding="utf-8")

required_setup = (
    "LABEL='my.notion.sync'",
    "BOOKMARK_DOMAIN='my.notion.sync.helper'",
    'APPLICATION_SUPPORT_DIR="${CUSTOM_INSTRUCTIONS_SUPPORT_DIR_OVERRIDE:-$HOME/Library/Application Support/$LABEL}"',
    'MODULE_CACHE_DIR="${CUSTOM_INSTRUCTIONS_MODULE_CACHE_OVERRIDE:-$HOME/Library/Caches/$LABEL/SwiftModuleCache}"',
)
for expected in required_setup:
    if expected not in setup_source:
        raise AssertionError(f"missing namespace setup contract: {expected}")

for legacy in (
    "com.hnishim.custom-instructions-sync",
    "com.hnishim.custom-instructions-sync-helper",
):
    if legacy in setup_source or legacy in info_source or legacy in plist_source:
        raise AssertionError(f"legacy active namespace remains: {legacy}")

if "<string>my.notion.sync.helper</string>" not in info_source:
    raise AssertionError("helper bundle identifier is not my.notion.sync.helper")
if "<string>my.notion.sync</string>" not in plist_source:
    raise AssertionError("LaunchAgent Label is not my.notion.sync")

print("[PASS] custom-instructions namespace contract")
PY
