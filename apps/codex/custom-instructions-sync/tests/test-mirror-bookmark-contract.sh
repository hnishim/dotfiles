#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
DOTFILES_ROOT=$(cd -- "$SCRIPT_DIR/../../../.." && pwd)
SWIFT_SOURCE="$SCRIPT_DIR/../CustomInstructionsSync.swift"
SETUP_SOURCE="$DOTFILES_ROOT/apps/codex/codex-setup.sh"
SYNC_SOURCE="$SCRIPT_DIR/../sync-custom-instructions"

python3 - "$SWIFT_SOURCE" "$SETUP_SOURCE" "$SYNC_SOURCE" <<'PY'
import sys
from pathlib import Path

swift_source = Path(sys.argv[1]).read_text(encoding="utf-8")
setup_source = Path(sys.argv[2]).read_text(encoding="utf-8")
sync_source = Path(sys.argv[3]).read_text(encoding="utf-8")

swift_contracts = (
    'static let mirrorKey = "mirrorFolderBookmark"',
    'guard (2...5).contains(arguments.count)',
    'print("mirror=\\(access.mirrorURL.path)")',
    'access.mirrorURL.startAccessingSecurityScopedResource()',
    'try validateMirrorLayout(access.mirrorURL, expectedSkills: Set(stableSkills.keys))',
    'static func mirrorItemKind(at url: URL) -> MirrorItemKind',
    'case .symbolicLink, .regularFile, .other:',
    'try replaceSkillsMirror(stableSkills, in: access.mirrorURL)',
)
for contract in swift_contracts:
    if contract not in swift_source:
        raise AssertionError(f"missing Swift mirror bookmark contract: {contract}")

setup_contracts = (
    'MIRROR_ROOT="$APPLICATION_SUPPORT_DIR/mirrors"',
    '"$HELPER_EXECUTABLE" --authorize "$CODEX_HOME_DIR" "$CUSTOM_INSTRUCTIONS_DIR_HINT" "$SKILLS_DIR_HINT" "$MIRROR_ROOT"',
    'authorized_mirror_root=$(printf',
    '[ "$authorized_output_dir" != "$CODEX_HOME_DIR" ]',
    'preflight_mirror_root "$MIRROR_ROOT"',
    '"$DEFAULTS_EXECUTABLE" delete "$BOOKMARK_DOMAIN"',
)
for contract in setup_contracts:
    if contract not in setup_source:
        raise AssertionError(f"missing setup mirror bookmark contract: {contract}")

sync_contracts = (
    'MIRROR_ROOT="${NOTION_SYNC_MIRROR_ROOT_OVERRIDE:-$(dirname -- "$NOTION_CONFIG")/mirrors}"',
    'MIRROR_DIR="$MIRROR_ROOT/custom-instructions-sync"',
    'SKILLS_MIRROR_DIR="$MIRROR_ROOT/skills-notion-sync"',
)
for contract in sync_contracts:
    if contract not in sync_source.replace("$", "$"):
        raise AssertionError(f"missing sync mirror root contract: {contract}")

if swift_source.index('try validateMirrorLayout(access.mirrorURL, expectedSkills: Set(stableSkills.keys))') \
        > swift_source.index('let mirrorDirectory ='):
    raise AssertionError("mirror layout must be validated before mirror writes")
if swift_source.index('try validateMirrorLayout(outputFolderURL, expectedSkills: Set(files.keys))') \
        > swift_source.index('try fileManager.removeItem(at: mirrorURL)'):
    raise AssertionError("Skills mirror layout must be revalidated before replacement")
if setup_source.index('preflight_mirror_root "$MIRROR_ROOT"') \
        > setup_source.index('mkdir -p "$CODEX_HOME_DIR"'):
    raise AssertionError("mirror root must be preflighted before setup creates or chmods it")
if 'return lstat(path, &information)' not in swift_source:
    raise AssertionError("mirror layout validation must use lstat semantics")

print("[PASS] mirror bookmark and Application Support contract")
PY
