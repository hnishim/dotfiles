#!/usr/bin/env python3
"""Shared fail-open textlint helpers for artifact-boundary hooks."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


TEXTLINT_TIMEOUT_SECONDS = 120
NATIVE_TEXTLINT_EXTENSIONS = {".md", ".txt"}


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


def find_textlint() -> str | None:
    candidates: list[str] = []
    configured_path = os.environ.get("TEXTLINT_BIN")
    if configured_path:
        candidates.append(configured_path)
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
    try:
        with path.open("r", encoding="utf-8", newline="") as stream:
            original = stream.read()
        fixed = fix_text(original, path.name)
        if fixed == original:
            return False
        with path.open("w", encoding="utf-8", newline="") as stream:
            stream.write(fixed)
        return True
    except (OSError, UnicodeError):
        return False
