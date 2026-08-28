#!/usr/bin/env python3
"""Install the harness Hooks with preflight checks and rollback."""

from __future__ import annotations

import json
import os
import shutil
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


HOOK_FILES = (
    "gh_normal_context_guard.py",
    "textlint-boundary.py",
    "textlint-pretool-hook.py",
    "textlint-posttool-hook.py",
)


def same_target(left: Path, right: Path) -> bool:
    return os.path.realpath(left) == os.path.realpath(right)


def unique_backup_path(directory: Path, name: str) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    candidate = directory / f"{name}.symlink-install.{timestamp}.{os.getpid()}"
    counter = 1
    while candidate.exists() or candidate.is_symlink():
        candidate = directory / (
            f"{name}.symlink-install.{timestamp}.{os.getpid()}.{counter}"
        )
        counter += 1
    return candidate


def read_template(path: Path, runtime: Path) -> dict[str, Any]:
    raw = path.read_text(encoding="utf-8")
    rendered = raw.replace("__HOOKS_RUNTIME__", str(runtime.resolve()))
    value = json.loads(rendered)
    if not isinstance(value, dict) or not isinstance(value.get("hooks"), dict):
        raise ValueError(f"Hooks template must contain a hooks object: {path}")
    if "__HOOKS_RUNTIME__" in rendered:
        raise ValueError(f"Hooks template contains an unresolved placeholder: {path}")
    return value


def validate_source(source_root: Path) -> tuple[Path, Path, dict[str, Any]]:
    runtime = source_root / "runtime"
    template = Path(
        os.environ.get("HOOKS_TEMPLATE_OVERRIDE", str(source_root / "hooks.json.tmpl"))
    ).expanduser()
    if not runtime.is_dir() or runtime.is_symlink():
        raise ValueError(f"Hooks runtime source is missing: {runtime}")
    for name in HOOK_FILES:
        path = runtime / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"Hooks runtime file is missing or not regular: {path}")
    if (runtime / "textlint-stop-hook.py").exists():
        raise ValueError("Archived textlint stop hook is present in runtime")
    if not template.is_file() or template.is_symlink():
        raise ValueError(f"Hooks template is missing or not regular: {template}")
    return runtime, template, read_template(template, runtime)


def classify(destination: Path, current: Path, legacy: Path) -> str:
    if not destination.exists() and not destination.is_symlink():
        return "missing"
    if destination.is_symlink() and same_target(destination, current):
        return "correct"
    if destination.is_symlink() and same_target(destination, legacy):
        return "legacy"
    return "conflict"


def generated_snapshot(path: Path) -> tuple[bool, Path | None]:
    if not path.exists() and not path.is_symlink():
        return False, None
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Generated Hooks config is not a regular file: {path}")
    snapshot = path.with_name(f".{path.name}.rollback-{os.getpid()}")
    if snapshot.exists() or snapshot.is_symlink():
        raise ValueError(f"Generated Hooks snapshot already exists: {snapshot}")
    os.link(path, snapshot)
    return True, snapshot


def write_generated(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.is_file() and not path.is_symlink():
        if path.read_bytes() == content and (path.stat().st_mode & 0o777) == 0o600:
            return
    temporary = path.with_name(f".{path.name}.install-{os.getpid()}")
    if temporary.exists() or temporary.is_symlink():
        raise ValueError(f"Temporary Hooks config already exists: {temporary}")
    temporary.write_bytes(content)
    temporary.chmod(0o600)
    os.replace(temporary, path)


def main() -> int:
    harness_root = Path(
        os.environ.get(
            "CODEX_HARNESS_ROOT_OVERRIDE",
            str(Path(__file__).resolve().parents[2] / "harness"),
        )
    ).expanduser()
    source_root = Path(
        os.environ.get("HOOKS_SOURCE_ROOT_OVERRIDE", str(harness_root / "hooks"))
    ).expanduser()
    runtime, _, config = validate_source(source_root)
    rendered = (json.dumps(config, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    generated = source_root / ".runtime" / "hooks.json"
    home = Path(
        sys.argv[1]
        if len(sys.argv) > 1
        else os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))
    ).expanduser()
    if len(sys.argv) > 2:
        raise SystemExit("使い方: install-hooks.py [codex-home]")

    legacy_root = Path(__file__).resolve().parents[2] / "dotfiles" / "codex"
    targets = (
        (home / "hooks", runtime, legacy_root / "hooks"),
        (home / "hooks.json", generated, legacy_root / "hooks.json"),
    )
    states = [classify(destination, current, legacy) for destination, current, legacy in targets]
    if "conflict" in states:
        conflict = targets[states.index("conflict")][0]
        raise SystemExit(f"既存のHooks宛先が競合しています: {conflict}")

    had_generated, generated_snapshot_path = generated_snapshot(generated)
    backup_directory = home / "backups"
    changed_destinations: list[Path] = []
    moved_destinations: list[Path] = []
    moved_backups: list[Path] = []
    created_backup_directory = False
    try:
        home.mkdir(parents=True, exist_ok=True)
        if any(state == "legacy" for state in states):
            if os.environ.get("HOOKS_INSTALL_FAIL_BACKUP") == "1":
                raise RuntimeError("injected Hooks backup failure")
            if not backup_directory.exists():
                backup_directory.mkdir(parents=True)
                created_backup_directory = True

        write_generated(generated, rendered)
        for (destination, current, _), state in zip(targets, states):
            if state == "correct":
                continue
            if state == "legacy":
                backup = unique_backup_path(backup_directory, destination.name)
                shutil.move(str(destination), str(backup))
                moved_destinations.append(destination)
                moved_backups.append(backup)
            temporary = destination.with_name(
                f".{destination.name}.symlink-install-{os.getpid()}"
            )
            if temporary.exists() or temporary.is_symlink():
                raise RuntimeError(f"temporary Hooks link already exists: {temporary}")
            destination.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(current.resolve(), temporary)
            os.replace(temporary, destination)
            changed_destinations.append(destination)
            if os.environ.get("HOOKS_INSTALL_FAIL_AFTER") == "1":
                raise RuntimeError("injected Hooks install failure")

        if not same_target(home / "hooks", runtime) or not same_target(home / "hooks.json", generated):
            raise RuntimeError("Hooks link verification failed")
        if generated_snapshot_path is not None:
            generated_snapshot_path.unlink()
    except Exception as error:
        for destination in reversed(changed_destinations):
            if destination.exists() or destination.is_symlink():
                destination.unlink()
        for destination, backup in reversed(list(zip(moved_destinations, moved_backups))):
            if backup.exists() or backup.is_symlink():
                if destination.exists() or destination.is_symlink():
                    destination.unlink()
                shutil.move(str(backup), str(destination))
        if generated_snapshot_path is not None and generated_snapshot_path.exists():
            if generated.exists() or generated.is_symlink():
                generated.unlink()
            os.replace(generated_snapshot_path, generated)
        elif not had_generated and (generated.exists() or generated.is_symlink()):
            generated.unlink()
        if created_backup_directory:
            try:
                backup_directory.rmdir()
            except OSError:
                pass
        raise SystemExit(f"Hooks install failed and was rolled back: {error}")

    print(f"[SUCCESS] Hooks installed: {home}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
