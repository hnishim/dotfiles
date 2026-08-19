#!/usr/bin/env python3
"""Apply textlint fixes after explicit local prose-file writes."""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shlex
import sys
from pathlib import Path
from typing import Any, Iterator


SUPPORTED_EXTENSIONS = {".md", ".txt", ".mdx", ".html", ".rst"}
COMMAND_KEYS = {"command", "cmd"}
WRITE_TOOLS = {"bash", "exec", "exec_command", "unified_exec", "apply_patch"}
RESULT_KEYS = ("tool_response", "toolResponse", "tool_output", "toolOutput")


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


def patch_paths(patch: str) -> Iterator[str]:
    """Extract only explicit Add/Update markers from apply_patch input."""
    for match in re.finditer(
        r"^\*\*\* (?:Add|Update) File: (.+)$", patch, re.MULTILINE
    ):
        yield match.group(1).strip()


def command_paths(command: str) -> Iterator[str]:
    """Extract paths only from bounded, unambiguous write forms.

    Arbitrary shell programs are intentionally not interpreted. apply_patch
    markers and simple redirection/known file utilities are the supported
    forms; compound commands are left untouched.
    """
    if "*** Begin Patch" in command or "*** Add File:" in command or "*** Update File:" in command:
        yield from patch_paths(command)
        return
    if any(token in command for token in ("\n", ";", "|", "&&", "||", "$(`", "`")):
        return
    try:
        lexer = shlex.shlex(command, posix=False, punctuation_chars="><")
        lexer.whitespace_split = True
        raw_tokens = list(lexer)
        tokens = [shlex.split(token)[0] for token in raw_tokens]
    except (ValueError, IndexError):
        return
    if not tokens:
        return
    if any(token in {"[[", "]]", "((", "))"} for token in raw_tokens):
        return

    # Identify output redirection tokens after shell tokenization. This keeps
    # quoted paths (including spaces) intact. Only raw, unquoted operators are
    # redirections; a quoted ">" is ordinary printf/echo data.
    for index, raw_token in enumerate(raw_tokens):
        if raw_token not in {">", ">>"} or index + 1 >= len(raw_tokens):
            continue
        target = tokens[index + 1]
        if not target.startswith("&"):
            yield target

    executable = Path(tokens[0]).name
    if executable == "touch":
        yield from touch_operands(tokens)
    elif executable == "tee":
        for token in tokens[1:]:
            if not token.startswith("-"):
                yield token
    elif executable in {"cp", "mv", "install"} and len(tokens) >= 3:
        destination = tokens[-1]
        if not destination.startswith("-"):
            yield destination


def touch_operands(tokens: list[str]) -> Iterator[str]:
    no_argument_options = {"-a", "-c", "-f", "-h", "-m", "-v"}
    argument_options = {"-A", "-d", "-r", "-t", "--date", "--reference"}
    operands: list[str] = []
    index = 1
    options = True
    while index < len(tokens):
        token = tokens[index]
        if options and token == "--":
            options = False
            index += 1
            continue
        if options and token.startswith("-") and token != "-":
            if token in argument_options:
                if index + 1 >= len(tokens):
                    return
                index += 2
                continue
            if any(token.startswith(f"{option}=") for option in argument_options):
                index += 1
                continue
            if token in no_argument_options or (
                token.startswith("-")
                and not token.startswith("--")
                and all(char in "acfhmv" for char in token[1:])
            ):
                index += 1
                continue
            # An unknown option may consume an operand; fail open.
            return
        operands.append(token)
        index += 1
    yield from operands


def input_values(payload: dict[str, Any]) -> Iterator[Any]:
    for key in ("tool_input", "toolInput", "input", "arguments"):
        if key in payload:
            yield payload[key]


def normalized_tool_name(payload: dict[str, Any]) -> str:
    name = payload.get("tool_name", payload.get("toolName", ""))
    if not isinstance(name, str):
        return ""
    normalized_name = name.lower()
    if normalized_name.endswith("__apply_patch"):
        return "apply_patch"
    return normalized_name


def result_allows_mutation(payload: dict[str, Any]) -> bool:
    present_keys = [key for key in RESULT_KEYS if key in payload]
    if not present_keys:
        return False
    apply_patch_result = normalized_tool_name(payload) == "apply_patch"
    for key in present_keys:
        result = payload[key]
        if not isinstance(result, dict):
            return False
        if not result:
            if apply_patch_result:
                continue
            return False
        validated_success = False
        if "isError" in result:
            if type(result["isError"]) is not bool or result["isError"]:
                return False
            validated_success = True
        for success_key in ("success", "ok"):
            if success_key in result:
                if type(result[success_key]) is not bool or not result[success_key]:
                    return False
                validated_success = True
        for exit_key in ("exit_code", "exitCode", "returncode", "returnCode"):
            if exit_key in result:
                if type(result[exit_key]) is not int or result[exit_key] != 0:
                    return False
                validated_success = True
                break
        status = result.get("status")
        if "status" in result:
            if not isinstance(status, str) or status.lower() not in {"success", "succeeded", "ok", "passed", "completed"}:
                return False
            validated_success = True
        if "error" in result and result["error"] not in (None, "", False):
            return False
        if not validated_success:
            return False
    return True


def effective_workdir(payload: dict[str, Any]) -> Path:
    fallback = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.getcwd()
    workdir: str | None = None
    for value in input_values(payload):
        if isinstance(value, dict) and isinstance(value.get("workdir"), str):
            workdir = value["workdir"]
            break
    if workdir is None:
        for key in ("workdir", "cwd"):
            if isinstance(payload.get(key), str):
                workdir = payload[key]
                break
    base = Path(workdir or fallback).expanduser()
    if not base.is_absolute():
        base = Path(fallback).expanduser() / base
    return base.resolve()


def candidate_paths(payload: dict[str, Any]) -> list[Path]:
    if not result_allows_mutation(payload):
        return []
    normalized_name = normalized_tool_name(payload)
    if normalized_name not in WRITE_TOOLS:
        return []
    values: list[str] = []
    # Parse only write-capable tool inputs. Read-only path fields and free-form
    # tool output are never treated as proof that a file was changed.
    for value in input_values(payload):
        if normalized_name == "apply_patch":
            if isinstance(value, str):
                values.extend(patch_paths(value))
            elif isinstance(value, dict):
                for key in ("patch", "command", "cmd"):
                    patch = value.get(key)
                    if isinstance(patch, str):
                        values.extend(patch_paths(patch))
        elif isinstance(value, dict):
            for command_key in COMMAND_KEYS:
                command = value.get(command_key)
                if isinstance(command, str):
                    values.extend(command_paths(command))
    base = effective_workdir(payload)
    paths: list[Path] = []
    seen: set[Path] = set()
    for value in values:
        path = Path(value).expanduser()
        if not path.is_absolute():
            path = base / path
        path = path.resolve()
        if path.suffix.lower() not in SUPPORTED_EXTENSIONS or not path.is_file() or path in seen:
            continue
        seen.add(path)
        paths.append(path)
    return paths


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        print(json.dumps({"continue": True}))
        return 0
    if not isinstance(payload, dict):
        print(json.dumps({"continue": True}))
        return 0
    helpers = load_helpers()
    for path in candidate_paths(payload):
        helpers.fix_file(path)
    print(json.dumps({"continue": True}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
