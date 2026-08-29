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
LOCAL_NAMESPACED_TOOLS = {
    f"functions{separator}{tool}": tool
    for separator in (".", "/", ":")
    for tool in WRITE_TOOLS
}
RESULT_KEYS = ("tool_response", "toolResponse", "tool_output", "toolOutput")
PROTECTED_SYSTEM_ROOTS = tuple(
    Path(path)
    for path in (
        "/System",
        "/Library",
        "/Applications",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/private/etc",
    )
)


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
        r"(?:^|\r?\n|\\n|\\r\\n)\*\*\* (?:Add|Update) File: ([^\r\n\\\"]+)",
        patch,
        re.MULTILINE,
    ):
        yield match.group(1).strip().strip('"')


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


def has_explicit_patch_input(payload: dict[str, Any]) -> bool:
    for value in input_values(payload):
        if isinstance(value, str):
            if "*** Begin Patch" in value and any(
                marker in value for marker in ("*** Add File:", "*** Update File:")
            ):
                return True
        elif isinstance(value, dict):
            for key in ("patch", "command", "cmd"):
                nested = value.get(key)
                if isinstance(nested, str) and has_explicit_patch_input({"tool_input": nested}):
                    return True
    return False


def normalized_tool_name(payload: dict[str, Any]) -> str:
    name = payload.get("tool_name", payload.get("toolName", ""))
    if not isinstance(name, str):
        return ""
    return write_tool_name(name)


def write_tool_name(name: str) -> str:
    normalized = name.lower().strip()
    if normalized in WRITE_TOOLS:
        return normalized
    # Only the known local functions namespace is normalized. In particular,
    # MCP names such as mcp__codex_apps__apply_patch must remain non-writes.
    if normalized in LOCAL_NAMESPACED_TOOLS:
        return LOCAL_NAMESPACED_TOOLS[normalized]
    return normalized


def is_write_payload(payload: dict[str, Any]) -> bool:
    name = payload.get("tool_name", payload.get("toolName", ""))
    if not isinstance(name, str):
        return False
    return write_tool_name(name) in WRITE_TOOLS


def has_unverified_nested_shape(payload: dict[str, Any]) -> bool:
    return any(
        isinstance(value, dict) and any(
            key in value for key in ("nested_tool_calls", "nestedToolCalls", "tool_calls", "toolCalls")
        )
        for value in input_values(payload)
    )


def result_allows_mutation(payload: dict[str, Any]) -> bool:
    present_keys = [key for key in RESULT_KEYS if key in payload]
    if not present_keys:
        return False
    apply_patch_result = normalized_tool_name(payload) == "apply_patch"
    explicit_patch_result = apply_patch_result or has_explicit_patch_input(payload)
    for key in present_keys:
        result = payload[key]
        if not isinstance(result, dict):
            if explicit_patch_result and result is not None:
                continue
            return False
        if not result:
            if explicit_patch_result:
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
            if explicit_patch_result:
                # apply_patch may return a model-facing object such as
                # {"content": [...]} without a success flag. Treat the
                # absence of an explicit error as success.
                continue
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


def _workspace_roots(payload: dict[str, Any]) -> list[Path] | None:
    raw = payload.get("workspace_roots", payload.get("workspaceRoots"))
    if raw is None:
        return None
    if not isinstance(raw, list) or not raw:
        return []
    roots: list[Path] = []
    for value in raw:
        if not isinstance(value, str) or ".." in Path(value).parts:
            return []
        root = Path(value).expanduser()
        if not root.is_absolute():
            root = effective_workdir(payload) / root
        try:
            if root.is_symlink():
                return []
            roots.append(root.resolve(strict=True))
        except OSError:
            return []
    return roots


def _has_symlink_component(path: Path) -> bool:
    current = Path(path.anchor) if path.is_absolute() else Path()
    for part in path.parts[1:] if path.is_absolute() else path.parts:
        current /= part
        try:
            # macOS exposes temporary directories through these standard
            # aliases; other symlink components are ambiguous and fail open.
            if current.is_symlink() and current not in {Path("/var"), Path("/tmp")}:
                return True
        except OSError:
            return True
    return False


def _under_root(path: Path, roots: list[Path]) -> bool:
    return any(path == root or root in path.parents for root in roots)


def _is_protected_system_path(path: Path) -> bool:
    return _under_root(path, list(PROTECTED_SYSTEM_ROOTS))


def _path_allowed(
    value: str,
    base: Path,
    roots: list[Path] | None,
    allow_missing: bool = False,
) -> Path | None:
    raw = Path(value).expanduser()
    if ".." in raw.parts:
        return None
    path = raw if raw.is_absolute() else base / raw
    # System path aliases such as /var -> /private/var are normal. Reject the
    # target itself if it is a symlink; resolved workspace roots handle parent
    # traversal and outside-workspace targets.
    if _has_symlink_component(path):
        return None
    try:
        resolved = path.resolve(strict=not allow_missing)
    except OSError:
        return None
    if resolved.suffix.lower() not in SUPPORTED_EXTENSIONS:
        return None
    if resolved.exists() and not resolved.is_file():
        return None
    if not resolved.exists() and not allow_missing:
        return None
    if _is_protected_system_path(resolved):
        return None
    # Paths outside workspace_roots are allowed here because candidates are
    # collected only from explicit write inputs. Read-only fields and nested
    # tool-shaped values never reach this function.
    return resolved


def _candidate_values(name: str, values: Iterator[Any]) -> Iterator[str]:
    normalized = write_tool_name(name)
    for value in values:
        if normalized == "apply_patch":
            if isinstance(value, str):
                yield from patch_paths(value)
            elif isinstance(value, dict):
                for key in ("patch", "command", "cmd"):
                    patch = value.get(key)
                    if isinstance(patch, str):
                        yield from patch_paths(patch)
        elif isinstance(value, str) and "*** Begin Patch" in value:
            # Some local code-mode wrappers pass the JavaScript source as the
            # outer exec input. Extract only embedded explicit patch markers;
            # arbitrary JavaScript and read-only paths remain ignored.
            yield from patch_paths(value)
        elif isinstance(value, dict):
            for command_key in COMMAND_KEYS:
                command = value.get(command_key)
                if isinstance(command, str):
                    yield from command_paths(command)


def candidate_paths(
    payload: dict[str, Any],
    state: dict[str, Any] | None = None,
    require_success: bool = True,
) -> list[Path]:
    if require_success and not result_allows_mutation(payload):
        return []
    if not is_write_payload(payload):
        if has_unverified_nested_shape(payload):
            load_helpers()._diagnostic("candidate_paths", "unverified-nested-envelope", payload)
        return []
    payloads = [payload]
    base = effective_workdir(payload)
    roots = _workspace_roots(payload)
    excluded = set()
    for key in ("preexisting_uncommitted", "preexistingUncommitted"):
        raw = payload.get(key)
        if isinstance(raw, list):
            excluded.update(str(Path(item).expanduser().resolve()) for item in raw if isinstance(item, str))
    paths: list[Path] = []
    seen: set[Path] = set()
    for nested in payloads:
        nested_name = nested.get("tool_name", nested.get("toolName", ""))
        if not isinstance(nested_name, str):
            continue
        for value in _candidate_values(nested_name, input_values(nested)):
            path = _path_allowed(value, base, roots, allow_missing=not require_success)
            if path is None or str(path) in excluded or path in seen:
                continue
            seen.add(path)
            paths.append(path)
    if state is not None:
        baseline = {
            item.get("path"): item.get("fingerprint")
            for item in state.get("files", [])
            if isinstance(item, dict) and isinstance(item.get("path"), str)
        }
        paths = [path for path in paths if str(path) in baseline and _fingerprint_changed(path, baseline[str(path)])]
    return paths


def _fingerprint_changed(path: Path, before: Any) -> bool:
    current = _fingerprint(path)
    if before is None:
        return current is not None
    return isinstance(before, dict) and current is not None and current != before


def _fingerprint(path: Path) -> dict[str, int | str] | None:
    return load_helpers()._fingerprint(path)


def _main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        print(json.dumps({"continue": True}))
        return 0
    if not isinstance(payload, dict):
        print(json.dumps({"continue": True}))
        return 0
    helpers = load_helpers()
    state = helpers.consume_runtime_state(payload)
    if helpers.runtime_identity(payload) is not None and state is None:
        # The PostToolUse payload still contains the canonical tool input.
        # Fall back to its explicit write paths when the optional PreToolUse
        # snapshot is unavailable or cannot be correlated. Boundary checks
        # and the successful-result check still apply in candidate_paths().
        helpers._diagnostic("post_state", "fallback-to-explicit-candidates", payload)
    for path in candidate_paths(payload, state):
        helpers.fix_file(path)
    print(json.dumps({"continue": True}))
    return 0


def main() -> int:
    try:
        return _main()
    except Exception:
        # Hook failures must never block the tool invocation and must not echo
        # an untrusted payload into diagnostics.
        print(json.dumps({"continue": True}))
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
