#!/usr/bin/env python3
"""Install the harness Hooks with preflight checks and atomic updates."""

from __future__ import annotations

import json
import os
import sys
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


def classify(destination: Path, current: Path) -> str:
    if not destination.exists() and not destination.is_symlink():
        return "missing"
    if destination.is_symlink() and same_target(destination, current):
        return "correct"
    return "conflict"


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


def replace_link(destination: Path, current: Path, state: str) -> None:
    if state == "missing":
        if destination.exists() or destination.is_symlink():
            raise ValueError(f"Hooks destination appeared during installation: {destination}")
    else:
        raise ValueError(f"Unsupported Hooks destination state: {state}")

    temporary = destination.with_name(
        f".{destination.name}.symlink-install-{os.getpid()}"
    )
    if temporary.exists() or temporary.is_symlink():
        raise ValueError(f"Temporary Hooks link already exists: {temporary}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.symlink(current.resolve(), temporary)
        os.replace(temporary, destination)
    except Exception:
        if temporary.exists() or temporary.is_symlink():
            temporary.unlink()
        raise


def main() -> int:
    harness_root = Path(
        os.environ.get(
            "CODEX_HARNESS_ROOT_OVERRIDE",
            str(Path(__file__).resolve().parents[4] / "harness"),
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

    targets = (
        (home / "hooks", runtime),
        (home / "hooks.json", generated),
    )
    states = [classify(destination, current) for destination, current in targets]
    if "conflict" in states:
        conflict = targets[states.index("conflict")][0]
        raise SystemExit(f"既存のHooks宛先が競合しています: {conflict}")

    home.mkdir(parents=True, exist_ok=True)
    write_generated(generated, rendered)
    for (destination, current), state in zip(targets, states):
        if state == "correct":
            continue
        try:
            replace_link(destination, current, state)
        except Exception as error:
            raise SystemExit(f"Hooks install failed: {error}")

    if not same_target(home / "hooks", runtime) or not same_target(home / "hooks.json", generated):
        raise SystemExit("Hooks link verification failed")

    print(f"[SUCCESS] Hooks installed: {home}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
