#!/usr/bin/env python3
"""Apply textlint fixes to supported Notion write payload fields."""

from __future__ import annotations

import copy
import importlib.util
import json
import sys
from pathlib import Path
from typing import Any


def load_helpers() -> Any:
    spec = importlib.util.spec_from_file_location(
        "textlint_boundary",
        Path(__file__).with_name("textlint-boundary.py"),
    )
    if spec is None or spec.loader is None:
        raise ImportError("textlint-boundary.py could not be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CREATE_PAGE_TOOLS = {
    "mcp__codex_apps__notion_notion_create_pages",
    "mcp__notion_molcure__notion_create_pages",
}
UPDATE_PAGE_TOOLS = {
    "mcp__codex_apps__notion_notion_update_page",
    "mcp__notion_molcure__notion_update_page",
}


def emit(payload: dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False))


def tool_name(payload: dict[str, Any]) -> str:
    for key in ("tool_name", "toolName", "name"):
        value = payload.get(key)
        if isinstance(value, str):
            return value.lower()
    tool = payload.get("tool")
    if isinstance(tool, dict) and isinstance(tool.get("name"), str):
        return tool["name"].lower()
    return ""


def input_location(payload: dict[str, Any]) -> tuple[str, dict[str, Any]] | None:
    for key in ("tool_input", "toolInput", "input", "arguments"):
        value = payload.get(key)
        if isinstance(value, dict):
            return key, value
    return None


def operation(name: str, data: dict[str, Any]) -> str | None:
    if name in CREATE_PAGE_TOOLS:
        return "create_pages"
    if name in UPDATE_PAGE_TOOLS:
        command = data.get("command")
        return command if command in {"insert_content", "replace_content", "update_content"} else None
    return None


def fix_operation(data: dict[str, Any], operation_name: str, helpers: Any) -> bool:
    changed = False
    if operation_name == "create_pages":
        pages = data.get("pages")
        if isinstance(pages, list):
            for page in pages:
                if isinstance(page, dict) and isinstance(page.get("content"), str):
                    fixed = helpers.fix_text(page["content"], "notion-page.md")
                    changed |= fixed != page["content"]
                    page["content"] = fixed
    elif operation_name == "insert_content":
        if isinstance(data.get("content"), str):
            fixed = helpers.fix_text(data["content"], "notion-page.md")
            changed = fixed != data["content"]
            data["content"] = fixed
    elif operation_name == "replace_content":
        if isinstance(data.get("new_str"), str):
            fixed = helpers.fix_text(data["new_str"], "notion-page.md")
            changed = fixed != data["new_str"]
            data["new_str"] = fixed
    else:
        updates = data.get("content_updates")
        if isinstance(updates, list):
            for update in updates:
                if isinstance(update, dict) and isinstance(update.get("new_str"), str):
                    fixed = helpers.fix_text(update["new_str"], "notion-page.md")
                    changed |= fixed != update["new_str"]
                    update["new_str"] = fixed
    return changed


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0

    selected = input_location(payload)
    if selected is None:
        return 0

    _, original_input = selected
    operation_name = operation(tool_name(payload), original_input)
    if operation_name is None:
        return 0

    updated_input = copy.deepcopy(original_input)
    helpers = load_helpers()
    changed = fix_operation(updated_input, operation_name, helpers)
    if not changed:
        return 0
    emit(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "updatedInput": updated_input,
            }
        }
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
