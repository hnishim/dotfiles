#!/usr/bin/env python3
"""Shared fail-open textlint helpers for artifact-boundary hooks."""

from __future__ import annotations

import os
import hashlib
import json
import re
import shutil
import stat
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


TEXTLINT_TIMEOUT_SECONDS = 120
NATIVE_TEXTLINT_EXTENSIONS = {".md", ".txt"}
STATE_TTL_SECONDS = 86400
STATE_DIR_ENV = "TEXTLINT_HOOK_STATE_DIR"
DIAGNOSTIC_LOG_ENV = "TEXTLINT_HOOK_DIAGNOSTIC_LOG"


def parser_extension(filename: str) -> str:
    suffix = Path(filename).suffix.lower()
    return suffix if suffix in NATIVE_TEXTLINT_EXTENSIONS else ".txt"


def syntax_markers(text: str, filename: str) -> tuple[str, ...]:
    """Return syntax markers that the text-only fallback must preserve."""
    suffix = Path(filename).suffix.lower()
    if suffix in {".html", ".mdx"}:
        return tuple(raw for _, _, raw in html_tag_spans(text)) + tuple(
            re.findall(r"^\s*```[^\n]*$|^\s*```\s*$", text, re.MULTILINE)
        )
    if suffix == ".rst":
        return tuple(
            line
            for line in text.splitlines()
            if re.match(r"^\s*\.\.\s+\S+::|^\s*:[^:]+:|^[-=~^\"`+#*]{3,}\s*$", line)
        )
    return ()


def line_spans(text: str) -> list[tuple[int, int, str]]:
    return [
        (match.start(), match.end(), match.group(0))
        for match in re.finditer(r".*(?:\n|$)", text)
        if match.start() < match.end()
    ]


def add_line_span_for_unclosed_block(
    text: str, spans: list[tuple[int, int]], start: int
) -> None:
    line_end = text.find("\n", start)
    if line_end == -1:
        line_end = len(text)
    spans.append((start, len(text)))


def mdx_protected_spans(text: str) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    lines = line_spans(text)
    index = 0
    while index < len(lines):
        start, end, line = lines[index]
        match = re.match(r"^[ \t]*(`{3,}|~{3,})", line)
        if match:
            fence = match.group(1)[0]
            fence_length = len(match.group(1))
            index += 1
            while index < len(lines):
                close_start, close_end, close_line = lines[index]
                if re.match(
                    rf"^[ \t]*{re.escape(fence)}{{{fence_length},}}[ \t]*(?:\r?\n|\r|$)",
                    close_line,
                ):
                    spans.append((start, close_end))
                    break
                index += 1
            else:
                add_line_span_for_unclosed_block(text, spans, start)
            index += 1
            continue
        index += 1

    spans.extend(mdx_esm_spans(text))
    spans.extend(mdx_inline_code_spans(text))
    spans.extend(indented_code_spans(text))
    spans.extend(html_protected_spans(text, include_text_tags=False))
    spans.extend(braced_expression_spans(text))
    return spans


def mdx_inline_code_spans(text: str) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    index = 0
    while index < len(text):
        if text[index] != "`" or (index > 0 and text[index - 1] == "`"):
            index += 1
            continue
        opening_end = index
        while opening_end < len(text) and text[opening_end] == "`":
            opening_end += 1
        delimiter_length = opening_end - index
        cursor = opening_end
        closing_start: int | None = None
        while cursor < len(text):
            if text[cursor] != "`" or (cursor > 0 and text[cursor - 1] == "`"):
                cursor += 1
                continue
            closing_end = cursor
            while closing_end < len(text) and text[closing_end] == "`":
                closing_end += 1
            if closing_end - cursor == delimiter_length:
                closing_start = cursor
                cursor = closing_end
                break
            cursor = closing_end
        if closing_start is None:
            spans.append((index, len(text)))
            break
        spans.append((index, cursor))
        index = cursor
    return spans


def indentation_columns(line: str) -> int:
    columns = 0
    for char in line:
        if char == " ":
            columns += 1
        elif char == "\t":
            columns += 4 - (columns % 4)
        else:
            break
    return columns


def indented_code_spans(text: str) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    lines = line_spans(text)
    index = 0
    while index < len(lines):
        start, end, line = lines[index]
        if indentation_columns(line) < 4 or not line.lstrip(" \t").strip():
            index += 1
            continue
        block_end = end
        next_index = index + 1
        while next_index < len(lines):
            _, next_end, next_line = lines[next_index]
            if next_line.strip() and indentation_columns(next_line) < 4:
                break
            if next_line.strip() or next_index == index + 1:
                block_end = next_end
            next_index += 1
        spans.append((start, block_end))
        index = next_index
    return spans


def mdx_esm_spans(text: str) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    lines = line_spans(text)
    for index, (start, end, line) in enumerate(lines):
        if not re.match(r"^[ \t]*(?:import|export)\b", line):
            continue
        quote: str | None = None
        escaped = False
        depth = 0
        statement_end: int | None = None
        for continuation_index in range(index, len(lines)):
            _, continuation_end, continuation = lines[continuation_index]
            for char in continuation:
                if quote is not None:
                    if escaped:
                        escaped = False
                    elif char == "\\":
                        escaped = True
                    elif char == quote:
                        quote = None
                    continue
                if char in {"'", '"', "`"}:
                    quote = char
                elif char in "{[(":
                    depth += 1
                elif char in "}])":
                    depth = max(0, depth - 1)
                elif char == ";" and depth == 0:
                    statement_end = continuation_end
                    break
            if statement_end is not None:
                break
            if continuation_index > index and not continuation.strip() and depth == 0:
                statement_end = continuation_end
                break
        spans.append((start, statement_end if statement_end is not None else len(text)))
    return spans


def html_tag_spans(text: str) -> list[tuple[int, int, str]]:
    spans: list[tuple[int, int, str]] = []
    index = 0
    while index < len(text):
        if text.startswith("<!--", index):
            end = text.find("-->", index + 4)
            end = len(text) if end == -1 else end + 3
            spans.append((index, end, text[index:end]))
            index = end
            continue
        if text[index] != "<" or index + 1 >= len(text):
            index += 1
            continue
        next_char = text[index + 1]
        if not (next_char.isalpha() or next_char in "/!?>"):
            index += 1
            continue
        quote: str | None = None
        cursor = index + 1
        while cursor < len(text):
            char = text[cursor]
            if quote is not None:
                if char == quote:
                    quote = None
            elif char in {"'", '"'}:
                quote = char
            elif char == ">":
                cursor += 1
                spans.append((index, cursor, text[index:cursor]))
                index = cursor
                break
            cursor += 1
        else:
            spans.append((index, len(text), text[index:]))
            break
    return spans


def html_protected_spans(text: str, include_text_tags: bool = True) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    tags = html_tag_spans(text)
    spans.extend((start, end) for start, end, _ in tags)
    block_names = {"script", "style", "pre", "code"}
    for index, (start, end, raw) in enumerate(tags):
        opening = re.match(r"<\s*(script|style|pre|code)\b", raw, re.IGNORECASE)
        if not opening:
            continue
        name = opening.group(1)
        block_end = len(text)
        for close_start, close_end, close_raw in tags[index + 1 :]:
            if re.match(rf"</\s*{re.escape(name)}\b", close_raw, re.IGNORECASE):
                block_end = close_end
                break
        spans.append((start, block_end))
    return spans


def braced_expression_spans(text: str) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    index = 0
    while index < len(text):
        if text[index] != "{":
            index += 1
            continue
        start = index
        depth = 0
        quote: str | None = None
        escaped = False
        while index < len(text):
            char = text[index]
            if quote is not None:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
            elif char in {"'", '"', "`"}:
                quote = char
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    spans.append((start, index + 1))
                    break
            index += 1
        else:
            line_start = text.rfind("\n", 0, start) + 1
            line_end = text.find("\n", start)
            spans.append((line_start, len(text) if line_end == -1 else line_end))
        index += 1
    return spans


def rst_protected_spans(text: str) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    literal_directives = {
        "code",
        "code-block",
        "doctest",
        "literalinclude",
        "parsed-literal",
        "sourcecode",
    }
    spans.extend(
        (match.start(), match.end())
        for match in re.finditer(
            r"``[^`\n]+``|`[^`\n]+`_|:(?:code|literal|math):`[^`\n]+`", text
        )
    )
    lines = line_spans(text)
    for index, (start, end, line) in enumerate(lines):
        indentation = re.match(r"^[ \t]+", line)
        if indentation and line[indentation.end() :].strip():
            spans.append((start, start + len(indentation.group(0))))
        if re.match(r"^[ \t]*>>>", line):
            block_end = end
            next_index = index + 1
            while next_index < len(lines):
                _, next_end, next_line = lines[next_index]
                block_end = next_end
                next_index += 1
                if not next_line.strip():
                    break
            spans.append((start, block_end))
            continue
        directive = re.match(r"^[ \t]*\.\.\s+(\S+)::", line)
        if directive:
            spans.append((start, end))
            if directive.group(1).lower() not in literal_directives:
                next_index = index + 1
                while next_index < len(lines):
                    option_start, option_end, option_line = lines[next_index]
                    if not re.match(r"^[ \t]+:[^:]+:", option_line):
                        break
                    spans.append((option_start, option_end))
                    next_index += 1
                continue
        elif not re.search(r"::[ \t]*(?:\r\n|\r|\n|$)", line):
            continue
        block_end = end
        next_index = index + 1
        while next_index < len(lines):
            next_start, next_end, next_line = lines[next_index]
            if next_line.strip() and not re.match(r"^[ \t]+", next_line):
                break
            if next_line.strip() or next_index == index + 1:
                block_end = next_end
            next_index += 1
        if block_end > end:
            spans.append((start, block_end))
    return spans


def protected_spans(text: str, filename: str) -> list[tuple[int, int]]:
    suffix = Path(filename).suffix.lower()
    if suffix == ".mdx":
        return mdx_protected_spans(text)
    if suffix == ".html":
        return html_protected_spans(text)
    if suffix == ".rst":
        return rst_protected_spans(text)
    return []


def protect_regions(
    text: str, filename: str
) -> tuple[str, list[tuple[str, str]]] | None:
    spans = protected_spans(text, filename)
    if not spans:
        return text, []
    merged: list[tuple[int, int]] = []
    for start, end in sorted(spans):
        if not merged or start > merged[-1][1]:
            merged.append((start, end))
        else:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
    protected: list[tuple[str, str]] = []
    output: list[str] = []
    cursor = 0
    for index, (start, end) in enumerate(merged):
        token = f"⟦{index:04d}⟧"
        if token in text:
            return None
        protected.append((token, text[start:end]))
        output.extend((text[cursor:start], token))
        cursor = end
    output.append(text[cursor:])
    return "".join(output), protected


def restore_regions(text: str, protected: list[tuple[str, str]]) -> str | None:
    restored = text
    for token, original in protected:
        if restored.count(token) != 1:
            return None
        restored = restored.replace(token, original)
    return restored


def preserve_newlines(original: str, fixed: str) -> str | None:
    """Keep the exact original newline sequence at every unchanged boundary."""
    original_newlines = re.findall(r"\r\n|\r|\n", original)
    fixed_newlines = re.findall(r"\r\n|\r|\n", fixed)
    if len(original_newlines) != len(fixed_newlines):
        return None
    if not original_newlines:
        return fixed if not fixed_newlines else None
    fixed_parts = re.split(r"\r\n|\r|\n", fixed)
    if len(fixed_parts) != len(original_newlines) + 1:
        return None
    output: list[str] = []
    for index, newline in enumerate(original_newlines):
        output.extend((fixed_parts[index], newline))
    output.append(fixed_parts[-1])
    return "".join(output)


def _field(payload: dict[str, Any], *names: str) -> str | None:
    for name in names:
        value = payload.get(name)
        if isinstance(value, str) and value:
            return value
    return None


def runtime_identity(payload: dict[str, Any]) -> tuple[str, str, str] | None:
    """Return the official correlation fields when the client supplied them."""
    session_id = _field(payload, "session_id", "sessionId")
    turn_id = _field(payload, "turn_id", "turnId")
    tool_use_id = _field(payload, "tool_use_id", "toolUseId")
    if not all((session_id, turn_id, tool_use_id)):
        return None
    return session_id, turn_id, tool_use_id


def _identity_key(identity: tuple[str, str, str]) -> str:
    material = json.dumps(identity, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


def _state_dir() -> Path:
    configured = os.environ.get(STATE_DIR_ENV)
    if configured:
        return Path(configured).expanduser()
    return Path.home() / ".cache" / "codex-textlint-hook"


def _diagnostic(event: str, reason: str, payload: dict[str, Any] | None = None) -> None:
    """Write a body-free diagnostic record when explicitly requested."""
    destination = os.environ.get(DIAGNOSTIC_LOG_ENV)
    if not destination:
        return
    record: dict[str, str] = {"event": event, "reason": reason}
    if payload is not None:
        identity = runtime_identity(payload)
        if identity is not None:
            record["correlation"] = _identity_key(identity)
    try:
        path = Path(destination).expanduser()
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if path.exists() and path.stat().st_uid != os.getuid():
            return
        with path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + "\n")
        path.chmod(0o600)
    except (OSError, UnicodeError):
        return


def _fingerprint(path: Path) -> dict[str, int | str] | None:
    try:
        info = path.stat()
        with path.open("rb") as stream:
            digest = hashlib.sha256(stream.read()).hexdigest()
        return {
            "dev": info.st_dev,
            "ino": info.st_ino,
            "nlink": info.st_nlink,
            "size": info.st_size,
            "mtime_ns": info.st_mtime_ns,
            "sha256": digest,
        }
    except (OSError, UnicodeError):
        return None


def _metadata_snapshot(path: Path) -> dict[str, Any] | None:
    """Capture metadata that an atomic replacement must preserve."""
    try:
        info = path.stat()
        list_xattr = getattr(os, "listxattr", None)
        get_xattr = getattr(os, "getxattr", None)
        xattrs: dict[str, bytes] | None
        if list_xattr is not None and get_xattr is not None:
            names = list_xattr(path, follow_symlinks=False)
            xattrs = {
                name: get_xattr(path, name, follow_symlinks=False)
                for name in names
            }
        else:
            names = _xattr_list(path)
            if names is None:
                return None
            xattrs = {}
            for name in names:
                value = _xattr_get(path, name)
                if value is None:
                    return None
                xattrs[name] = value
        acl_marker = _acl_marker(path)
        if acl_marker is None:
            return None
        acl_xattr = xattrs.get("com.apple.acl.text")
        # macOS can report an ACL in `ls -lde` while omitting the ACL xattr
        # from the xattr listing when normal xattrs coexist with it.  An ACL
        # without its serialized value cannot be restored or verified.
        if acl_marker and acl_xattr is None:
            return None
        acl_present = acl_marker or acl_xattr is not None
        return {
            "source": str(path),
            "mode": stat.S_IMODE(info.st_mode),
            "uid": info.st_uid,
            "gid": info.st_gid,
            "flags": getattr(info, "st_flags", 0),
            "xattrs": xattrs,
            "acl": acl_xattr if acl_present else b"",
        }
    except (OSError, TypeError, UnicodeError):
        return None


def _apply_metadata(path: Path, metadata: dict[str, Any]) -> bool:
    try:
        path.chmod(metadata["mode"])
        if hasattr(os, "chown"):
            info = path.stat()
            if (info.st_uid, info.st_gid) != (metadata["uid"], metadata["gid"]):
                os.chown(path, metadata["uid"], metadata["gid"])
        if metadata["xattrs"] is not None:
            list_xattr = getattr(os, "listxattr", None)
            set_xattr = getattr(os, "setxattr", None)
            if list_xattr is not None and set_xattr is not None:
                existing = set(list_xattr(path, follow_symlinks=False))
                expected = set(metadata["xattrs"])
                for name in existing - expected:
                    os.removexattr(path, name, follow_symlinks=False)
                for name, value in metadata["xattrs"].items():
                    set_xattr(path, name, value, follow_symlinks=False)
            else:
                if not _xattr_replace(path, metadata["xattrs"]):
                    return False
        else:
            return False
        flags = metadata["flags"]
        if flags:
            chflags = getattr(os, "chflags", None)
            if chflags is None:
                return False
            chflags(path, flags)
        acl_marker = _acl_marker(path)
        acl_xattr = metadata["xattrs"].get("com.apple.acl.text")
        acl_present = bool(acl_marker) or acl_xattr is not None
        if acl_marker is None and acl_xattr is None:
            return False
        if metadata["acl"] and (not acl_present or acl_xattr != metadata["acl"]):
            return False
        if not metadata["acl"] and acl_present:
            return False
        return _same_metadata(_metadata_snapshot(path), metadata)
    except (OSError, TypeError, UnicodeError, KeyError):
        return False


def _xattr_command() -> str | None:
    configured = os.environ.get("TEXTLINT_XATTR_BIN")
    candidates = [configured] if configured else []
    candidates.append("/usr/bin/xattr")
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def _acl_marker(path: Path) -> bool | None:
    """Detect a macOS ACL from its mode marker or serialized ACL entries."""
    try:
        result = subprocess.run(
            ["/bin/ls", "-lde", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0 or not isinstance(result.stdout, bytes):
            return None
        lines = result.stdout.splitlines()
        if not lines:
            return None
        mode = lines[0].decode("utf-8").split()[0]
        if len(mode) >= 11 and mode[10] == "+":
            return True
        # With an ACL and ordinary xattrs, macOS may show `@` in the mode
        # string and print the ACL entries below it instead of listing
        # com.apple.acl.text through xattr(1).
        return any(re.match(rb"^\s*\d+:", line) for line in lines[1:])
    except (OSError, UnicodeError, IndexError):
        return None


def _xattr_list(path: Path) -> list[str] | None:
    command = _xattr_command()
    if command is None:
        return None
    try:
        result = subprocess.run(
            [command, str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
        )
        if result.returncode != 0 or not isinstance(result.stdout, bytes):
            return None
        return result.stdout.decode("utf-8").splitlines()
    except (OSError, UnicodeError):
        return None


def _xattr_get(path: Path, name: str) -> bytes | None:
    command = _xattr_command()
    if command is None:
        return None
    try:
        result = subprocess.run(
            [command, "-p", "-x", name, str(path)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        if result.returncode != 0 or not isinstance(result.stdout, bytes):
            return None
        return bytes.fromhex(b"".join(result.stdout.split()).decode("ascii"))
    except (OSError, UnicodeError, ValueError):
        return None


def _xattr_replace(path: Path, expected: dict[str, bytes]) -> bool:
    command = _xattr_command()
    if command is None:
        return False
    existing = _xattr_list(path)
    if existing is None:
        return False
    try:
        for name in set(existing) - set(expected):
            result = subprocess.run(
                [command, "-d", name, str(path)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
            if result.returncode != 0:
                return False
        for name, value in expected.items():
            result = subprocess.run(
                [command, "-w", "-x", name, value.hex(), str(path)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
            if result.returncode != 0:
                return False
        return all(_xattr_get(path, name) == value for name, value in expected.items()) \
            and set(_xattr_list(path) or ()) == set(expected)
    except (OSError, UnicodeError):
        return False


def _same_metadata(left: dict[str, Any] | None, right: dict[str, Any] | None) -> bool:
    if left is None or right is None:
        return False
    return {key: value for key, value in left.items() if key != "source"} == {
        key: value for key, value in right.items() if key != "source"
    }


def _safe_state_dir() -> Path | None:
    directory = _state_dir()
    try:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        directory.chmod(0o700)
        if directory.stat().st_uid != os.getuid():
            return None
        return directory
    except OSError:
        return None


def _cleanup_state(directory: Path, now: float | None = None) -> None:
    cutoff = (time.time() if now is None else now) - STATE_TTL_SECONDS
    try:
        for path in directory.glob("*.json"):
            try:
                if path.stat().st_mtime < cutoff and path.stat().st_uid == os.getuid():
                    path.unlink()
            except OSError:
                continue
    except OSError:
        return


def _write_state(identity: tuple[str, str, str], paths: list[Path]) -> bool:
    directory = _safe_state_dir()
    if directory is None:
        return False
    _cleanup_state(directory)
    records = []
    for path in paths:
        fingerprint = _fingerprint(path)
        records.append({"path": str(path), "fingerprint": fingerprint})
    if not records:
        return False
    target = directory / f"{_identity_key(identity)}.json"
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", dir=directory, prefix=".state-", suffix=".tmp", delete=False
        ) as stream:
            temporary = Path(stream.name)
            json.dump({"created": time.time(), "files": records}, stream)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(0o600)
        os.replace(temporary, target)
        return True
    except (OSError, TypeError, ValueError):
        try:
            temporary.unlink()
        except (OSError, UnboundLocalError):
            pass
        return False


def _read_and_consume_state(identity: tuple[str, str, str]) -> dict[str, Any] | None:
    directory = _safe_state_dir()
    if directory is None:
        return None
    _cleanup_state(directory)
    path = directory / f"{_identity_key(identity)}.json"
    try:
        if path.stat().st_uid != os.getuid():
            return None
        with path.open(encoding="utf-8") as stream:
            state = json.load(stream)
        path.unlink()
        return state if isinstance(state, dict) else None
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None


def prepare_runtime_state(payload: dict[str, Any], paths: list[Path]) -> None:
    identity = runtime_identity(payload)
    if identity is None:
        return
    if not _write_state(identity, paths):
        _diagnostic("pre_state", "no-safe-file-snapshot", payload)


def consume_runtime_state(payload: dict[str, Any]) -> dict[str, Any] | None:
    identity = runtime_identity(payload)
    if identity is None:
        return None
    state = _read_and_consume_state(identity)
    if state is None:
        _diagnostic("post_state", "missing-or-invalid-correlation", payload)
    return state


def find_textlint() -> str | None:
    candidates: list[str] = []
    configured_path = os.environ.get("TEXTLINT_BIN")
    if configured_path:
        candidates.append(configured_path)
    candidates.append(
        str(
            Path.home()
            / "Library"
            / "Application Support"
            / "dotfiles"
            / "textlint"
            / "node_modules"
            / ".bin"
            / "textlint"
        )
    )
    discovered_path = shutil.which("textlint")
    if discovered_path:
        candidates.append(discovered_path)
    # GUI-launched Codex processes can have a reduced PATH.
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


def find_config() -> Path:
    return Path(
        os.environ.get("TEXTLINT_CONFIG", str(Path.home() / ".textlintrc.json"))
    ).expanduser()


def fix_text(text: str, filename: str = "codex-artifact.md") -> str:
    """Return mechanically fixed text, or the original text on any failure."""
    textlint_path = find_textlint()
    config_path = find_config()
    if textlint_path is None or not config_path.is_file():
        return text

    try:
        with tempfile.TemporaryDirectory(prefix="codex-textlint-") as directory:
            protected_input = protect_regions(text, filename)
            if protected_input is None:
                return text
            lint_input, protected = protected_input
            suffix = parser_extension(filename)
            target = Path(directory) / f"artifact{suffix}"
            with target.open("w", encoding="utf-8", newline="") as stream:
                stream.write(lint_input)
            result = subprocess.run(
                [
                    textlint_path,
                    "--config",
                    str(config_path),
                    "--fix",
                    "--no-color",
                    str(target),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=textlint_environment(),
                text=True,
                timeout=TEXTLINT_TIMEOUT_SECONDS,
                check=False,
            )
            # textlint uses exit 1 for remaining findings. --fix may still have
            # made safe mechanical changes, so read the file for both statuses.
            if result.returncode not in (0, 1):
                return text
            with target.open("r", encoding="utf-8", newline="") as stream:
                fixed = stream.read()
            fixed = preserve_newlines(lint_input, fixed)
            if fixed is None:
                return text
            if protected:
                fixed = restore_regions(fixed, protected)
                if fixed is None:
                    return text
            if syntax_markers(text, filename) != syntax_markers(fixed, filename):
                return text
            return fixed
    except (OSError, UnicodeError, subprocess.TimeoutExpired):
        return text


def fix_file(path: Path) -> bool:
    """Fix a local file in place; return whether its contents changed."""
    temporary: Path | None = None
    try:
        # Snapshot before opening the file. The same fingerprint is checked
        # after reading, after textlint, and immediately before replacement.
        before = _fingerprint(path)
        metadata = _metadata_snapshot(path)
        if before is None or before.get("nlink") != 1 or metadata is None:
            _diagnostic("fix_file", "hardlink-or-metadata-unsafe")
            return False
        with path.open("r", encoding="utf-8", newline="") as stream:
            original = stream.read()
        if _fingerprint(path) != before or not _same_metadata(_metadata_snapshot(path), metadata):
            _diagnostic("fix_file", "external-change-during-read")
            return False
        fixed = fix_text(original, path.name)
        if fixed == original:
            return False
        # Re-check after the external process has run. This prevents an edit
        # made concurrently with textlint from being overwritten.
        if _fingerprint(path) != before:
            _diagnostic("fix_file", "external-change-before-write")
            return False
        directory = path.parent
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", newline="", dir=directory,
            prefix=f".{path.name}.", suffix=".tmp", delete=False,
        ) as stream:
            temporary = Path(stream.name)
            stream.write(fixed)
            stream.flush()
            os.fsync(stream.fileno())
        if not _apply_metadata(temporary, metadata):
            _diagnostic("fix_file", "metadata-preservation-failed")
            temporary.unlink(missing_ok=True)
            return False
        # Recheck immediately before atomic replace; a residual scheduling
        # window remains and is intentionally not claimed to be eliminated.
        if _fingerprint(path) != before or not _same_metadata(_metadata_snapshot(path), metadata):
            temporary.unlink(missing_ok=True)
            _diagnostic("fix_file", "external-change-at-atomic-replace")
            return False
        os.replace(temporary, path)
        if not _same_metadata(_metadata_snapshot(path), metadata):
            _diagnostic("fix_file", "metadata-verification-failed")
            return False
        return True
    except (OSError, UnicodeError):
        if temporary is not None:
            try:
                temporary.unlink(missing_ok=True)
            except OSError:
                pass
        return False
