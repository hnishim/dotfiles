#!/usr/bin/env python3
"""Install Codex hooks as symlinks to the dotfiles source of truth."""

from __future__ import annotations

import json
import os
import shutil
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


def unique_backup_path(backup_dir: Path, name: str) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    candidate = backup_dir / f"{name}.symlink-install.{timestamp}"
    counter = 1
    while candidate.exists() or candidate.is_symlink():
        candidate = backup_dir / (
            f"{name}.symlink-install.{timestamp}.{counter}"
        )
        counter += 1
    return candidate


def move_to_backup(path: Path, backup_dir: Path, name: str) -> Path:
    backup_dir.mkdir(parents=True, exist_ok=True)
    backup_path = unique_backup_path(backup_dir, name)
    shutil.move(str(path), str(backup_path))
    return backup_path


def points_to(path: Path, target: Path) -> bool:
    if not path.is_symlink():
        return False
    try:
        return path.resolve(strict=True) == target.resolve(strict=True)
    except OSError:
        return False


def ensure_symlink(
    source: Path,
    destination: Path,
    backup_dir: Path,
    backup_name: str,
) -> tuple[bool, Path | None]:
    source = source.resolve(strict=True)
    if points_to(destination, source):
        return False, None

    backup_path: Path | None = None
    if destination.is_symlink() or destination.exists():
        backup_path = move_to_backup(destination, backup_dir, backup_name)

    temporary_path = destination.with_name(
        f".{destination.name}.symlink-install-{os.getpid()}"
    )
    if temporary_path.exists() or temporary_path.is_symlink():
        raise SystemExit(f"一時リンクが既に存在します: {temporary_path}")

    os.symlink(source, temporary_path)
    os.replace(temporary_path, destination)
    return True, backup_path


def main() -> int:
    repository_codex_dir = Path(__file__).resolve().parent
    source_hooks_dir = repository_codex_dir / "hooks"
    source_hooks_json = repository_codex_dir / "hooks.json"
    codex_home = Path(
        sys.argv[1]
        if len(sys.argv) > 1
        else os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))
    ).expanduser()

    if not source_hooks_dir.is_dir():
        raise SystemExit(f"正本のhooksフォルダーが見つかりません: {source_hooks_dir}")
    if not source_hooks_json.is_file():
        raise SystemExit(f"正本のhooks.jsonが見つかりません: {source_hooks_json}")
    load_json(source_hooks_json)

    codex_home.mkdir(parents=True, exist_ok=True)
    backups_dir = codex_home / "backups"
    changed_json, backup_json = ensure_symlink(
        source_hooks_json,
        codex_home / "hooks.json",
        backups_dir,
        "hooks.json",
    )
    changed_dir, backup_dir = ensure_symlink(
        source_hooks_dir,
        codex_home / "hooks",
        backups_dir,
        "hooks",
    )

    if changed_json:
        print(f"[SUCCESS] hooks.jsonを正本へリンクしました: {codex_home / 'hooks.json'}")
        if backup_json:
            print(f"[INFO] 既存のhooks.jsonを退避しました: {backup_json}")
    else:
        print(f"[INFO] hooks.jsonは既に正本へリンクされています: {codex_home / 'hooks.json'}")

    if changed_dir:
        print(f"[SUCCESS] hooksフォルダーを正本へリンクしました: {codex_home / 'hooks'}")
        if backup_dir:
            print(f"[INFO] 既存のhooksフォルダーを退避しました: {backup_dir}")
    else:
        print(f"[INFO] hooksフォルダーは既に正本へリンクされています: {codex_home / 'hooks'}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
