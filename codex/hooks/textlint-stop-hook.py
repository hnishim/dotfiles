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

    candidates.append(str(Path(__file__).resolve().parents[2] / "bin" / "textlint"))

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


def textlint_environment() -> dict[str, str]:
    """Provide GUI-launched hooks with common pnpm installation paths."""
    environment = os.environ.copy()
    path_entries = [
        environment.get("PNPM_HOME"),
        str(Path.home() / ".local" / "share" / "pnpm"),
        str(Path.home() / "Library" / "pnpm"),
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]
    current_path = environment.get("PATH", "")
    environment["PATH"] = os.pathsep.join(
        entry for entry in (*path_entries, current_path) if entry
    )
    return environment


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


def source_line(message: str, line_number: int) -> str | None:
    lines = message.splitlines()
    if 1 <= line_number <= len(lines):
        return lines[line_number - 1]
    return None


def format_findings(message: str, raw_findings: str) -> str:
    """Return actionable diagnostics while retaining the original response context."""
    try:
        report = json.loads(raw_findings)
    except json.JSONDecodeError:
        return raw_findings

    if not isinstance(report, list):
        return raw_findings

    formatted: list[str] = []
    for file_report in report:
        if not isinstance(file_report, dict):
            continue
        messages = file_report.get("messages")
        if not isinstance(messages, list):
            continue
        file_path = file_report.get("filePath", "codex-response.md")
        for finding in messages:
            if not isinstance(finding, dict):
                continue
            line = finding.get("line")
            column = finding.get("column")
            message_text = finding.get("message")
            rule_id = finding.get("ruleId")
            if (
                not isinstance(line, int)
                or not isinstance(column, int)
                or not isinstance(message_text, str)
            ):
                continue

            location = f"{line}:{column}"
            line_text = source_line(message, line)
            formatted.append(
                f"- {file_path} {location} {message_text}"
                + (f" [{rule_id}]" if isinstance(rule_id, str) else "")
            )
            if line_text is not None:
                formatted.append(f"  原文: {line_text}")

            fix = finding.get("fix")
            if isinstance(fix, dict) and isinstance(fix.get("text"), str):
                fix_text = fix["text"]
                formatted.append(
                    "  textlintの自動修正候補: "
                    + ("スペースを挿入" if fix_text == " " else repr(fix_text))
                )

    return "\n".join(formatted) if formatted else raw_findings


def build_correction_reason(message: str, raw_findings: str) -> str:
    diagnostics = format_findings(message, raw_findings)
    return (
        "textlint/prh で文章上の指摘が検出されました。"
        "元の回答の内容・構成・固有名詞・ファイルパス・検証結果は保持し、"
        "下記の表記上の指摘だけを最小限修正した回答を作成してください。"
        "要約、削除、再調査、別タスクへの変更は禁止です。"
        "修正後の回答本文だけを出力してください。\n\n"
        "違反箇所と原文:\n"
        f"{diagnostics}"
    )


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
        "json",
        "--no-color",
    ]

    try:
        result = subprocess.run(
            command,
            input=message,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=textlint_environment(),
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

    reason = build_correction_reason(message, findings)
    if len(reason) > MAX_REASON_LENGTH:
        reason = reason[:MAX_REASON_LENGTH].rstrip() + "\n[…truncated]"
    emit({"decision": "block", "reason": reason})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
