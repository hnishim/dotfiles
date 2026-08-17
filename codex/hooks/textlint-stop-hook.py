#!/usr/bin/env python3
"""Run textlint/prh against Codex's latest assistant response."""

from __future__ import annotations

import json
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


TEXTLINT_TIMEOUT_SECONDS = 120
MAX_REASON_LENGTH = 5000
MAX_CORRECTION_PASSES = 3


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False))


def find_textlint() -> str | None:
    candidates: list[str] = []
    configured_path = os.environ.get("TEXTLINT_BIN")
    if configured_path:
        candidates.append(configured_path)

    discovered_path = shutil.which("textlint")
    if discovered_path:
        candidates.append(discovered_path)

    # Codex may be launched from a GUI and therefore have a reduced PATH.
    candidates.extend(("/opt/homebrew/bin/textlint", "/usr/local/bin/textlint"))

    seen: set[str] = set()
    for candidate in candidates:
        if candidate in seen:
            continue
        seen.add(candidate)
        path = Path(candidate).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def continue_without_blocking(system_message: str | None = None) -> None:
    payload: dict[str, Any] = {"continue": True}
    if system_message:
        payload["systemMessage"] = system_message
    emit(payload)


def state_path(payload: dict[str, Any]) -> Path | None:
    session_id = payload.get("session_id")
    turn_id = payload.get("turn_id")
    if not isinstance(session_id, str) or not isinstance(turn_id, str):
        return None

    state_root = Path(
        os.environ.get("TEXTLINT_HOOK_STATE_DIR", tempfile.gettempdir())
    ).expanduser() / "codex-textlint-stop-hook"
    digest = hashlib.sha256(f"{session_id}:{turn_id}".encode()).hexdigest()
    return state_root / f"{digest}.json"


def read_correction_passes(path: Path | None) -> int:
    if path is None or not path.is_file():
        return 0
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return 0
    passes = value.get("correction_passes") if isinstance(value, dict) else None
    return passes if isinstance(passes, int) and passes >= 0 else 0


def write_correction_passes(path: Path | None, passes: int) -> None:
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    try:
        temporary_path.write_text(
            json.dumps({"correction_passes": passes}) + "\n", encoding="utf-8"
        )
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def clear_correction_state(path: Path | None) -> None:
    if path is not None:
        path.unlink(missing_ok=True)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        continue_without_blocking()
        return 0

    if not isinstance(payload, dict):
        continue_without_blocking()
        return 0

    correction_state = state_path(payload)
    if payload.get("stop_hook_active") is True and correction_state is None:
        # Without stable session/turn identifiers, do not risk an unbounded loop.
        continue_without_blocking()
        return 0

    message = payload.get("last_assistant_message")
    if not isinstance(message, str) or not message.strip():
        clear_correction_state(correction_state)
        continue_without_blocking()
        return 0

    config_path = Path(
        os.environ.get("TEXTLINT_CONFIG", str(Path.home() / ".textlintrc.json"))
    ).expanduser()
    textlint_path = find_textlint()
    if textlint_path is None or not config_path.is_file():
        # textlint-setup.sh may not have run yet on a newly configured Mac.
        clear_correction_state(correction_state)
        continue_without_blocking()
        return 0

    command = [
        textlint_path,
        "--config",
        str(config_path),
        "--stdin",
        "--stdin-filename",
        "codex-response.md",
        "--format",
        "stylish",
        "--no-color",
    ]

    try:
        result = subprocess.run(
            command,
            input=message,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=TEXTLINT_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired:
        clear_correction_state(correction_state)
        continue_without_blocking(
            "textlint hook timed out; the Codex response was not blocked."
        )
        return 0
    except OSError as error:
        clear_correction_state(correction_state)
        continue_without_blocking(
            f"textlint hook could not run ({error}); the Codex response was not blocked."
        )
        return 0

    if result.returncode == 0:
        clear_correction_state(correction_state)
        continue_without_blocking()
        return 0

    findings = (result.stdout or result.stderr).strip()
    if result.returncode != 1:
        clear_correction_state(correction_state)
        continue_without_blocking(
            f"textlint hook failed with exit code {result.returncode}; "
            "the Codex response was not blocked."
        )
        return 0

    if len(findings) > MAX_REASON_LENGTH:
        findings = findings[:MAX_REASON_LENGTH].rstrip() + "\n[…truncated]"

    correction_passes = read_correction_passes(correction_state)
    if correction_passes >= MAX_CORRECTION_PASSES:
        clear_correction_state(correction_state)
        continue_without_blocking(
            "textlint hook detected remaining findings after "
            f"{MAX_CORRECTION_PASSES} correction passes; the response was not blocked."
        )
        return 0

    write_correction_passes(correction_state, correction_passes + 1)

    reason = (
        "textlint/prh で文章上の指摘が検出されました。"
        "指摘を反映した修正版の応答を作成してください。\n\n"
        f"{findings}"
    )
    emit({"decision": "block", "reason": reason})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
