#!/usr/bin/env python3
"""Require normal macOS execution for GitHub CLI auth-sensitive commands."""

import json
import re
import sys
from typing import Any


GH_AUTH_STATUS = re.compile(
    r"(?:^|[\s;&|])(?:[^\s;&|]*/)?gh\s+auth\s+status(?:\s|$)"
)
GH_REPO_CREATE = re.compile(
    r"(?:^|[\s;&|])(?:[^\s;&|]*/)?gh\s+repo\s+create(?:\s|$)"
)


def command_from(payload: dict[str, Any]) -> str:
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return ""
    command = tool_input.get("command", tool_input.get("cmd", ""))
    return command if isinstance(command, str) else ""


def runs_in_normal_context(payload: dict[str, Any]) -> bool:
    if payload.get("permission_mode") == "bypassPermissions":
        return True
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return False
    return tool_input.get("sandbox_permissions") == "require_escalated"


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0

    command = command_from(payload)
    if not (GH_AUTH_STATUS.search(command) or GH_REPO_CREATE.search(command)):
        return 0

    if runs_in_normal_context(payload):
        return 0

    message = (
        "GitHub CLI の認証状態は sandbox 内の結果で判定しません。"
        "同じ `gh auth status` または `gh repo create` を "
        "sandbox_permissions=require_escalated の通常 macOS 実行環境で再実行してください。"
        "この拒否をログイン切れの根拠にしたり、Browser Use へ切り替えたりしてはいけません。"
    )
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": message,
                }
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
