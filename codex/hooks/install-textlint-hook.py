#!/usr/bin/env python3
"""Install the Codex textlint Stop hook without replacing existing hooks."""

from __future__ import annotations

import json
import os
import shlex
import shutil
import stat
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise SystemExit(f"JSONのトップレベルがオブジェクトではありません: {path}")
    return value


def write_json_atomically(path: Path, value: dict[str, Any], mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        with temporary_path.open("w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
        os.chmod(temporary_path, mode)
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def backup_file(path: Path, backup_dir: Path) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_path = backup_dir / f"hooks.json.{timestamp}"
    counter = 1
    while backup_path.exists():
        backup_path = backup_dir / f"hooks.json.{timestamp}.{counter}"
        counter += 1
    shutil.copy2(path, backup_path)
    return backup_path


def main() -> int:
    repository_hooks_dir = Path(__file__).resolve().parent
    hook_source = repository_hooks_dir / "textlint-stop-hook.py"
    fragment_path = repository_hooks_dir / "textlint-hooks.json"
    codex_home = Path(
        sys.argv[1]
        if len(sys.argv) > 1
        else os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))
    ).expanduser()

    if not hook_source.is_file() or not fragment_path.is_file():
        raise SystemExit("textlint hookのソースファイルが見つかりません")

    hooks_dir = codex_home / "hooks"
    hook_destination = hooks_dir / hook_source.name
    hooks_json = codex_home / "hooks.json"
    backups_dir = codex_home / "backups"

    hooks_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(hook_source, hook_destination)
    os.chmod(hook_destination, 0o755)

    fragment = load_json(fragment_path)
    if hooks_json.is_symlink():
        raise SystemExit(f"hooks.jsonがシンボリックリンクのため変更を中止しました: {hooks_json}")

    if hooks_json.exists():
        target = load_json(hooks_json)
        target_mode = stat.S_IMODE(hooks_json.stat().st_mode)
    else:
        target = {}
        target_mode = 0o600

    target_hooks = target.setdefault("hooks", {})
    if not isinstance(target_hooks, dict):
        raise SystemExit(f"hooks.jsonのhooksがオブジェクトではありません: {hooks_json}")

    fragment_hooks = fragment.get("hooks", {})
    if not isinstance(fragment_hooks, dict):
        raise SystemExit("textlint hooks fragmentのhooksがオブジェクトではありません")
    fragment_stop_groups = fragment_hooks.get("Stop", [])
    if not isinstance(fragment_stop_groups, list):
        raise SystemExit("textlint hooks fragmentのStopが配列ではありません")

    existing_stop_groups = target_hooks.get("Stop", [])
    if not isinstance(existing_stop_groups, list):
        raise SystemExit(f"hooks.jsonのStopが配列ではありません: {hooks_json}")
    if "Stop" not in target_hooks:
        target_hooks["Stop"] = existing_stop_groups

    existing_commands = set()
    for group in existing_stop_groups:
        if not isinstance(group, dict):
            continue
        for handler in group.get("hooks", []):
            if isinstance(handler, dict) and isinstance(handler.get("command"), str):
                existing_commands.add(handler["command"])

    hook_command = f"/usr/bin/python3 {shlex.quote(str(hook_destination))}"
    changed = False
    for group in fragment_stop_groups:
        if not isinstance(group, dict):
            continue
        handlers = group.get("hooks", [])
        if not isinstance(handlers, list):
            continue

        copied_handlers = []
        for handler in handlers:
            if not isinstance(handler, dict):
                continue
            copied_handler = dict(handler)
            copied_handler["command"] = hook_command
            copied_handlers.append(copied_handler)
        if not copied_handlers:
            continue
        if all(handler["command"] in existing_commands for handler in copied_handlers):
            continue

        copied_group = dict(group)
        copied_group["hooks"] = copied_handlers
        existing_stop_groups.append(copied_group)
        existing_commands.update(handler["command"] for handler in copied_handlers)
        changed = True

    if changed:
        if hooks_json.exists():
            backup_path = backup_file(hooks_json, backups_dir)
            print(f"[INFO] 既存のhooks.jsonをバックアップしました: {backup_path}")
        write_json_atomically(hooks_json, target, target_mode)
        print(f"[SUCCESS] textlint Stop hookを設定しました: {hooks_json}")
    else:
        print(f"[INFO] textlint Stop hookは既に設定されています: {hooks_json}")

    print(f"[INFO] hook本体を配置しました: {hook_destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
