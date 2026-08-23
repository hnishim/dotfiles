#!/usr/bin/env python3
"""Fixture tests for artifact-boundary textlint hooks."""

from __future__ import annotations

import json
import importlib.util
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


HOOKS_DIR = Path(__file__).resolve().parents[1]
PRE_HOOK = HOOKS_DIR / "textlint-pretool-hook.py"
POST_HOOK = HOOKS_DIR / "textlint-posttool-hook.py"
HOOKS_JSON = HOOKS_DIR.parent / "hooks.json"


def load_post_hook_module():
    spec = importlib.util.spec_from_file_location("textlint_posttool_hook", POST_HOOK)
    if spec is None or spec.loader is None:
        raise ImportError("textlint-posttool-hook.py could not be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TextlintBoundaryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.config = self.root / ".textlintrc.json"
        self.config.write_text("{}\n", encoding="utf-8")
        self.fake_textlint = self.root / "textlint"
        self.fake_textlint.write_text(
            "#!/bin/sh\n"
            "target=\"\"\n"
            "for arg in \"$@\"; do target=\"$arg\"; done\n"
            "sed -i '' 's/MacOS/macOS/g' \"$target\" 2>/dev/null || sed -i 's/MacOS/macOS/g' \"$target\"\n"
            "exit 0\n",
            encoding="utf-8",
        )
        self.fake_textlint.chmod(self.fake_textlint.stat().st_mode | stat.S_IXUSR)
        self.env = {
            **os.environ,
            "TEXTLINT_BIN": str(self.fake_textlint),
            "TEXTLINT_CONFIG": str(self.config),
        }

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def run_hook_output(self, hook: Path, payload: object) -> str:
        result = subprocess.run(
            ["/usr/bin/python3", str(hook)],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            env=self.env,
            check=True,
        )
        return result.stdout

    def run_hook(self, hook: Path, payload: dict) -> dict:
        return json.loads(self.run_hook_output(hook, payload))

    def run_successful_post(self, payload: dict) -> dict:
        """Run a successful PostToolUse fixture with an explicit result shape."""
        enriched = dict(payload)
        if "tool_response" not in enriched:
            tool_name = enriched.get("tool_name", enriched.get("toolName", ""))
            if isinstance(tool_name, str) and (
                tool_name.lower() == "apply_patch" or tool_name.lower().endswith("__apply_patch")
            ):
                enriched["tool_response"] = {}
            elif isinstance(tool_name, str) and tool_name.lower() in {
                "bash", "exec", "exec_command", "unified_exec",
            }:
                enriched["tool_response"] = {"exit_code": 0}
        return self.run_hook(POST_HOOK, enriched)

    def runtime_binary_fixture(self) -> tuple[Path, Path]:
        runtime_binary = (
            self.root
            / "Library"
            / "Application Support"
            / "dotfiles"
            / "textlint"
            / "node_modules"
            / ".bin"
            / "textlint"
        )
        runtime_log = self.root / "runtime.log"
        runtime_binary.parent.mkdir(parents=True)
        runtime_binary.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' \"$*\" >> \"{runtime_log}\"\n"
            "printf '%s\\n' '[]'\n"
            "exit 0\n",
            encoding="utf-8",
        )
        runtime_binary.chmod(runtime_binary.stat().st_mode | stat.S_IXUSR)
        return runtime_binary, runtime_log

    def test_both_hook_entrypoints_execute_runtime_and_resolution_priority(self) -> None:
        stop_path = HOOKS_DIR / "textlint-stop-hook.py"
        post_path = HOOKS_DIR / "textlint-posttool-hook.py"
        _, runtime_log = self.runtime_binary_fixture()
        prose = self.root / "runtime-prose.md"
        prose.write_text("MacOS", encoding="utf-8")
        runtime_env = {
            **os.environ,
            "HOME": self.root.as_posix(),
            "PATH": "/usr/bin:/bin",
            "TEXTLINT_CONFIG": str(self.config),
        }
        runtime_env.pop("TEXTLINT_BIN", None)

        stop_payload = {"last_assistant_message": "plain response"}
        stop_result = subprocess.run(
            ["/usr/bin/python3", str(stop_path)],
            input=json.dumps(stop_payload), text=True, capture_output=True,
            env=runtime_env, check=True,
        )
        self.assertTrue(json.loads(stop_result.stdout)["continue"])
        self.assertTrue(runtime_log.exists(), "Stop hook did not invoke the runtime")
        stop_invocations = runtime_log.read_text(encoding="utf-8").splitlines()
        self.assertGreater(len(stop_invocations), 0)

        post_payload = {
            "tool_name": "Bash",
            "tool_input": {"command": f"touch {prose}"},
            "tool_response": {"exit_code": 0},
            "cwd": str(self.root),
        }
        subprocess.run(
            ["/usr/bin/python3", str(post_path)],
            input=json.dumps(post_payload), text=True, capture_output=True,
            env=runtime_env, check=True,
        )
        post_invocations = runtime_log.read_text(encoding="utf-8").splitlines()
        self.assertGreater(
            len(post_invocations),
            len(stop_invocations),
            "Post hook did not invoke the runtime after the Stop hook",
        )

    def test_notion_create_pages_fixes_only_content(self) -> None:
        for tool_name in (
            "mcp__codex_apps__notion_notion_create_pages",
            "mcp__notion_molcure__notion_create_pages",
        ):
            payload = {
                "tool_name": tool_name,
                "tool_input": {
                    "pages": [{"content": "MacOS の本文", "properties": {"title": "MacOS"}}],
                    "old_str": "MacOS",
                },
            }
            result = self.run_hook(PRE_HOOK, payload)
            self.assertEqual(result["hookSpecificOutput"]["hookEventName"], "PreToolUse")
            self.assertEqual(result["hookSpecificOutput"]["permissionDecision"], "allow")
            updated = result["hookSpecificOutput"]["updatedInput"]
            self.assertEqual(updated["pages"][0]["content"], "macOS の本文")
            self.assertEqual(updated["pages"][0]["properties"]["title"], "MacOS")
            self.assertEqual(updated["old_str"], "MacOS")

    def test_notion_update_variants_fix_supported_fields(self) -> None:
        for tool_name in (
            "mcp__codex_apps__notion_notion_update_page",
            "mcp__notion_molcure__notion_update_page",
        ):
            for command, tool_input, assertion in (
                (
                    "insert_content",
                    {"command": "insert_content", "content": "MacOS", "template": "MacOS"},
                    lambda value: self.assertEqual(value["content"], "macOS"),
                ),
                (
                    "replace_content",
                    {"command": "replace_content", "new_str": "MacOS", "old_str": "MacOS"},
                    lambda value: self.assertEqual(value["new_str"], "macOS"),
                ),
                (
                    "update_content",
                    {"command": "update_content", "content_updates": [{"new_str": "MacOS"}, {"new_str": "plain"}]},
                    lambda value: self.assertEqual(value["content_updates"][0]["new_str"], "macOS"),
                ),
            ):
                result = self.run_hook(PRE_HOOK, {"name": tool_name, "input": tool_input})
                updated = result["hookSpecificOutput"]["updatedInput"]
                self.assertEqual(updated["command"], command)
                assertion(updated)
                self.assertEqual(updated.get("template", "MacOS"), "MacOS")
                self.assertEqual(updated.get("old_str", "MacOS"), "MacOS")

    def test_notion_noop_uses_no_updated_input(self) -> None:
        result = self.run_hook_output(
            PRE_HOOK,
            {
                "tool_name": "mcp__codex_apps__notion_notion_update_page",
                "tool_input": {"command": "replace_content", "new_str": "plain", "old_str": "MacOS"},
            },
        )
        self.assertEqual(result, "")

    def test_non_notion_operation_is_unchanged(self) -> None:
        payload = {"tool_name": "notion.search", "tool_input": {"query": "MacOS"}}
        self.assertEqual(self.run_hook_output(PRE_HOOK, payload), "")

    def test_normal_stop_like_payload_is_not_linted(self) -> None:
        self.assertEqual(self.run_hook_output(PRE_HOOK, {"last_assistant_message": "MacOS"}), "")

    def test_bash_and_unified_exec_paths_are_fixed_but_code_file_is_not(self) -> None:
        prose = self.root / "draft.md"
        prose_txt = self.root / "review.txt"
        code = self.root / "script.py"
        prose.write_text("MacOS", encoding="utf-8")
        prose_txt.write_text("MacOS", encoding="utf-8")
        code.write_text("MacOS", encoding="utf-8")
        self.run_successful_post({"tool_name": "Bash", "tool_input": {"command": f"printf x > {prose}"}})
        self.run_successful_post({"tool_name": "exec_command", "tool_input": {"cmd": f"touch {prose_txt}"}})
        self.run_successful_post({"tool_name": "write_file", "tool_input": {"path": str(code)}})
        self.assertEqual(prose.read_text(encoding="utf-8"), "macOS")
        self.assertEqual(prose_txt.read_text(encoding="utf-8"), "macOS")
        self.assertEqual(code.read_text(encoding="utf-8"), "MacOS")

    def test_quoted_path_with_spaces_is_fixed(self) -> None:
        directory = self.root / "draft email files"
        directory.mkdir()
        prose = directory / "message.md"
        prose.write_text("MacOS", encoding="utf-8")
        self.run_successful_post(
            {"tool_name": "Bash", "tool_input": {"command": f'printf x > "{prose}"'}},
        )
        self.assertEqual(prose.read_text(encoding="utf-8"), "macOS")

    def test_quoted_redirection_content_is_not_a_candidate(self) -> None:
        read_only = self.root / "read-only.md"
        read_only.write_text("MacOS", encoding="utf-8")
        payload = {
            "tool_name": "Bash",
            "tool_input": {"command": f'printf %s ">" {read_only.name}'},
            "tool_response": {"exit_code": 0},
            "cwd": str(self.root),
        }
        self.assertEqual(load_post_hook_module().candidate_paths(payload), [])
        self.run_successful_post(payload)
        self.assertEqual(read_only.read_text(encoding="utf-8"), "MacOS")

    def test_conditional_comparison_is_not_a_candidate(self) -> None:
        for name, command in (
            ("conditional-read.md", "[[ z > conditional-read.md ]]"),
            ("arithmetic-read.md", "(( z > arithmetic-read.md ))"),
        ):
            read_only = self.root / name
            read_only.write_text("MacOS", encoding="utf-8")
            payload = {
                "tool_name": "Bash",
                "tool_input": {"command": command},
                "tool_response": {"exit_code": 0},
                "cwd": str(self.root),
            }
            self.assertEqual(load_post_hook_module().candidate_paths(payload), [])
            self.run_successful_post(payload)
            self.assertEqual(read_only.read_text(encoding="utf-8"), "MacOS")

    def test_touch_reference_operand_is_not_a_candidate(self) -> None:
        reference = self.root / "reference.md"
        target = self.root / "target.md"
        reference.write_text("MacOS", encoding="utf-8")
        target.write_text("MacOS", encoding="utf-8")
        payload = {
            "tool_name": "Bash",
            "tool_input": {"command": "touch -r reference.md target.md"},
            "tool_response": {"exit_code": 0},
            "cwd": str(self.root),
        }
        self.assertEqual(load_post_hook_module().candidate_paths(payload), [target.resolve()])
        self.run_successful_post(payload)
        self.assertEqual(reference.read_text(encoding="utf-8"), "MacOS")
        self.assertEqual(target.read_text(encoding="utf-8"), "macOS")

    def test_apply_patch_and_skill_local_writes_are_fixed(self) -> None:
        draft = self.root / "draft-email.md"
        compatible_patch = self.root / "compatible.txt"
        compatible_command = self.root / "compatible.mdx"
        review = self.root / "review-text.rst"
        draft.write_text("MacOS", encoding="utf-8")
        compatible_patch.write_text("MacOS", encoding="utf-8")
        compatible_command.write_text("MacOS", encoding="utf-8")
        review.write_text("MacOS", encoding="utf-8")
        self.run_successful_post(
            {
                "tool_name": "apply_patch",
                "tool_input": f"*** Begin Patch\n*** Update File: {draft}\n*** End Patch",
                "tool_response": {},
            },
        )
        self.run_successful_post(
            {
                "tool_name": "apply_patch",
                "tool_input": {"patch": f"*** Begin Patch\n*** Update File: {compatible_patch}\n*** End Patch"},
                "tool_response": {},
            },
        )
        self.run_successful_post(
            {
                "tool_name": "apply_patch",
                "tool_input": {"command": f"*** Begin Patch\n*** Update File: {compatible_command}\n*** End Patch"},
                "tool_response": {},
            },
        )
        self.run_successful_post(
            {
                "tool_name": "exec_command",
                "tool_input": {"cmd": f"printf x > {review}", "skill_name": "review-text"},
            },
        )
        self.assertEqual(draft.read_text(encoding="utf-8"), "macOS")
        self.assertEqual(compatible_patch.read_text(encoding="utf-8"), "macOS")
        self.assertEqual(compatible_command.read_text(encoding="utf-8"), "macOS")
        self.assertEqual(review.read_text(encoding="utf-8"), "macOS")

    def test_effective_workdir_wins_for_relative_write_path(self) -> None:
        outside = self.root / "outside"
        workdir = self.root / "effective workdir"
        outside.mkdir()
        workdir.mkdir()
        (outside / "same.md").write_text("MacOS", encoding="utf-8")
        (workdir / "same.md").write_text("MacOS", encoding="utf-8")
        self.run_successful_post(
            {
                "tool_name": "Bash",
                "cwd": str(outside),
                "tool_input": {"command": "printf x > same.md", "workdir": str(workdir)},
            },
        )
        self.assertEqual((workdir / "same.md").read_text(encoding="utf-8"), "macOS")
        self.assertEqual((outside / "same.md").read_text(encoding="utf-8"), "MacOS")

    def test_supported_extensions_use_text_parser_fallback(self) -> None:
        parser_limited_textlint = self.root / "textlint-native-md-txt-only"
        parser_limited_textlint.write_text(
            "#!/bin/sh\n"
            "target=\"\"\n"
            "for arg in \"$@\"; do target=\"$arg\"; done\n"
            "case \"$target\" in *.md|*.txt) ;; *) exit 2;; esac\n"
            "sed -i '' 's/MacOS/macOS/g' \"$target\" 2>/dev/null || sed -i 's/MacOS/macOS/g' \"$target\"\n"
            "exit 0\n",
            encoding="utf-8",
        )
        parser_limited_textlint.chmod(parser_limited_textlint.stat().st_mode | stat.S_IXUSR)
        self.env["TEXTLINT_BIN"] = str(parser_limited_textlint)
        for extension, content in (
            (".md", "MacOS"),
            (".txt", "MacOS"),
            (".mdx", "<p>MacOS</p>"),
            (".html", "<p>MacOS</p>"),
            (".rst", "MacOS\n====="),
        ):
            path = self.root / f"supported{extension}"
            path.write_text(content, encoding="utf-8")
            self.run_successful_post(
                {"tool_name": "exec_command", "tool_input": {"cmd": f"touch {path}"}},
            )
            self.assertIn("macOS", path.read_text(encoding="utf-8"))
        self.assertEqual((self.root / "supported.mdx").read_text(encoding="utf-8"), "<p>macOS</p>")
        self.assertEqual((self.root / "supported.html").read_text(encoding="utf-8"), "<p>macOS</p>")
        self.assertEqual((self.root / "supported.rst").read_text(encoding="utf-8"), "macOS\n=====")

    def test_fallback_preserves_non_prose_regions(self) -> None:
        mdx = self.root / "protected.mdx"
        html = self.root / "protected.html"
        rst = self.root / "protected.rst"
        mdx.write_text(
            "MacOS\n\n"
            "export const MacOS = 1;\n\n"
            "```js\nconst MacOS = 1;\n```\n\n"
            "<p>MacOS</p>\n\n{MacOS}\n",
            encoding="utf-8",
        )
        html.write_text(
            "<p>MacOS</p><code>MacOS</code>"
            "<pre>MacOS</pre><script>const MacOS = 1;</script>"
            "<style>.MacOS { color: red; }</style>",
            encoding="utf-8",
        )
        rst.write_text(
            "MacOS\n\n``MacOS``\n\n"
            "Text::\n\n  const MacOS = 1\n",
            encoding="utf-8",
        )
        for path in (mdx, html, rst):
            self.run_successful_post(
                {"tool_name": "exec_command", "tool_input": {"cmd": f"touch {path}"}},
            )
        self.assertEqual(
            mdx.read_text(encoding="utf-8"),
            "macOS\n\n"
            "export const MacOS = 1;\n\n"
            "```js\nconst MacOS = 1;\n```\n\n"
            "<p>macOS</p>\n\n{MacOS}\n",
        )
        self.assertEqual(
            html.read_text(encoding="utf-8"),
            "<p>macOS</p><code>MacOS</code>"
            "<pre>MacOS</pre><script>const MacOS = 1;</script>"
            "<style>.MacOS { color: red; }</style>",
        )
        self.assertEqual(
            rst.read_text(encoding="utf-8"),
            "macOS\n\n``MacOS``\n\n"
            "Text::\n\n  const MacOS = 1\n",
        )

    def test_mdx_inline_and_indented_code_are_byte_preserved(self) -> None:
        path = self.root / "inline-indented.mdx"
        path.write_text(
            "MacOS `MacOS`\n\n"
            "    const MacOS = 1\n"
            "\n"
            "After MacOS\n",
            encoding="utf-8",
        )
        self.run_successful_post(
            {"tool_name": "exec_command", "tool_input": {"cmd": f"touch {path}"}},
        )
        self.assertEqual(
            path.read_text(encoding="utf-8"),
            "macOS `MacOS`\n\n"
            "    const MacOS = 1\n"
            "\n"
            "After macOS\n",
        )

    def test_mdx_long_inline_delimiter_is_byte_preserved(self) -> None:
        path = self.root / "long-inline.mdx"
        path.write_text(
            "MacOS Before `` `MacOS` `` after\nAfter MacOS\n",
            encoding="utf-8",
        )
        self.run_successful_post(
            {"tool_name": "exec_command", "tool_input": {"cmd": f"touch {path}"}},
        )
        self.assertEqual(
            path.read_text(encoding="utf-8"),
            "macOS Before `` `MacOS` `` after\nAfter macOS\n",
        )

    def test_mdx_five_space_indented_code_is_byte_preserved(self) -> None:
        path = self.root / "five-space.mdx"
        path.write_text(
            "MacOS\n\n"
            "     const MacOS = 1\n"
            "\n"
            "After MacOS\n",
            encoding="utf-8",
        )
        self.run_successful_post(
            {"tool_name": "exec_command", "tool_input": {"cmd": f"touch {path}"}},
        )
        self.assertEqual(
            path.read_text(encoding="utf-8"),
            "macOS\n\n"
            "     const MacOS = 1\n"
            "\n"
            "After macOS\n",
        )

    def test_rst_crlf_literal_block_is_byte_preserved(self) -> None:
        path = self.root / "literal-crlf.rst"
        original = (
            "MacOS\r\n\r\n"
            "Text::\r\n\r\n"
            "    const MacOS = 1\n"
            "\n"
            "After MacOS\r\n"
        )
        path.write_bytes(original.encode("utf-8"))
        self.run_successful_post(
            {"tool_name": "exec_command", "tool_input": {"cmd": f"touch {path}"}},
        )
        expected = (
            "macOS\r\n\r\n"
            "Text::\r\n\r\n"
            "    const MacOS = 1\n"
            "\n"
            "After macOS\r\n"
        )
        self.assertEqual(path.read_bytes(), expected.encode("utf-8"))

    def test_rst_note_prose_is_fixed_but_literal_directive_is_preserved(self) -> None:
        path = self.root / "directives.rst"
        path.write_text(
            "Before MacOS\n\n"
            ".. note::\n"
            "   Note MacOS\n\n"
            ".. code-block:: python\n\n"
            "   const MacOS = 1\n\n"
            "After MacOS\n",
            encoding="utf-8",
        )
        self.run_successful_post(
            {"tool_name": "exec_command", "tool_input": {"cmd": f"touch {path}"}},
        )
        self.assertEqual(
            path.read_text(encoding="utf-8"),
            "Before macOS\n\n"
            ".. note::\n"
            "   Note macOS\n\n"
            ".. code-block:: python\n\n"
            "   const MacOS = 1\n\n"
            "After macOS\n",
        )

    def test_mdx_inline_and_indented_code_preserve_crlf_and_mixed_newlines(self) -> None:
        cases = (
            ("crlf.mdx", "\r\n"),
            ("mixed.mdx", "\r\n"),
        )
        for name, newline in cases:
            path = self.root / name
            if name.startswith("mixed"):
                original = (
                    "MacOS Before `` `MacOS` `` after\r\n\n"
                    "     const MacOS = 1\n\n"
                    "After MacOS\r\n"
                )
                expected = (
                    "macOS Before `` `MacOS` `` after\r\n\n"
                    "     const MacOS = 1\n\n"
                    "After macOS\r\n"
                )
            else:
                original = (
                    "MacOS Before `` `MacOS` `` after\r\n\r\n"
                    "     const MacOS = 1\r\n\r\n"
                    "After MacOS\r\n"
                )
                expected = (
                    "macOS Before `` `MacOS` `` after\r\n\r\n"
                    "     const MacOS = 1\r\n\r\n"
                    "After macOS\r\n"
                )
            path.write_bytes(original.encode("utf-8"))
            self.run_successful_post(
                {"tool_name": "exec_command", "tool_input": {"cmd": f"touch {path}"}},
            )
            self.assertEqual(path.read_bytes(), expected.encode("utf-8"))

    def test_long_fence_does_not_close_on_short_inner_fence(self) -> None:
        path = self.root / "long-fence.mdx"
        path.write_text(
            "MacOS\n\n"
            "````js\n"
            "```\n"
            "const MacOS = 1;\n"
            "````\n\n"
            "After MacOS\n",
            encoding="utf-8",
        )
        self.run_successful_post(
            {"tool_name": "exec_command", "tool_input": {"cmd": f"touch {path}"}},
        )
        self.assertEqual(
            path.read_text(encoding="utf-8"),
            "macOS\n\n"
            "````js\n"
            "```\n"
            "const MacOS = 1;\n"
            "````\n\n"
            "After macOS\n",
        )

    def test_crlf_newlines_are_preserved(self) -> None:
        path = self.root / "crlf.mdx"
        original = (
            "MacOS\r\n\r\n"
            "```js\r\n"
            "const MacOS = 1;\r\n"
            "```\r\n\r\n"
            "After MacOS\r\n"
        )
        path.write_bytes(original.encode("utf-8"))
        self.run_successful_post(
            {"tool_name": "exec_command", "tool_input": {"cmd": f"touch {path}"}},
        )
        expected = (
            "macOS\r\n\r\n"
            "```js\r\n"
            "const MacOS = 1;\r\n"
            "```\r\n\r\n"
            "After macOS\r\n"
        )
        self.assertEqual(path.read_bytes(), expected.encode("utf-8"))

    def test_unprotectable_region_fails_open(self) -> None:
        path = self.root / "token-collision.html"
        path.write_text("<p>MacOS</p> ⟦0000⟧", encoding="utf-8")
        self.run_successful_post(
            {"tool_name": "exec_command", "tool_input": {"cmd": f"touch {path}"}},
        )
        self.assertEqual(path.read_text(encoding="utf-8"), "<p>MacOS</p> ⟦0000⟧")

    def test_adversarial_non_prose_regions_are_byte_preserved(self) -> None:
        mdx = self.root / "adversarial.mdx"
        html = self.root / "adversarial.html"
        rst = self.root / "adversarial.rst"
        mdx.write_text(
            'import {\n  value\n} from "./MacOS";\n\n'
            '<Component path="MacOS > value">MacOS</Component>\n',
            encoding="utf-8",
        )
        html.write_text(
            '<p>MacOS</p><Component path="MacOS > value">MacOS</Component>',
            encoding="utf-8",
        )
        rst.write_text(
            'MacOS\n\n>>> print("MacOS")\nMacOS\n\nAfter MacOS\n',
            encoding="utf-8",
        )
        for path in (mdx, html, rst):
            self.run_successful_post(
                {"tool_name": "exec_command", "tool_input": {"cmd": f"touch {path}"}},
            )
        self.assertEqual(
            mdx.read_text(encoding="utf-8"),
            'import {\n  value\n} from "./MacOS";\n\n'
            '<Component path="MacOS > value">macOS</Component>\n',
        )
        self.assertEqual(
            html.read_text(encoding="utf-8"),
            '<p>macOS</p><Component path="MacOS > value">macOS</Component>',
        )
        self.assertEqual(
            rst.read_text(encoding="utf-8"),
            'macOS\n\n>>> print("MacOS")\nMacOS\n\nAfter macOS\n',
        )

    def test_missing_tool_response_does_not_mutate(self) -> None:
        bash_path = self.root / "missing-result-bash.md"
        patch_path = self.root / "missing-result-patch.md"
        bash_path.write_text("MacOS", encoding="utf-8")
        patch_path.write_text("MacOS", encoding="utf-8")
        payloads = (
            {
                "tool_name": "Bash",
                "tool_input": {"command": f"printf x > {bash_path}"},
            },
            {
                "tool_name": "apply_patch",
                "tool_input": f"*** Begin Patch\n*** Update File: {patch_path}\n*** End Patch",
            },
        )
        for payload in payloads:
            self.assertEqual(load_post_hook_module().candidate_paths(payload), [])
            self.run_hook(POST_HOOK, payload)
        self.assertEqual(bash_path.read_text(encoding="utf-8"), "MacOS")
        self.assertEqual(patch_path.read_text(encoding="utf-8"), "MacOS")

    def test_failed_or_unknown_write_results_do_not_mutate(self) -> None:
        failed_copy = self.root / "failed-copy.md"
        failed_patch = self.root / "failed-patch.md"
        unknown_result = self.root / "unknown-result.md"
        pending_result = self.root / "pending-result.md"
        malformed_result = self.root / "malformed-result.md"
        for path in (failed_copy, failed_patch, unknown_result, pending_result, malformed_result):
            path.write_text("MacOS", encoding="utf-8")

        copy_payload = {
            "tool_name": "Bash",
            "tool_input": {"command": "cp missing-source failed-copy.md"},
            "tool_response": {"exit_code": 1, "stderr": "missing source"},
            "cwd": str(self.root),
        }
        self.assertEqual(load_post_hook_module().candidate_paths(copy_payload), [])
        self.run_hook(POST_HOOK, copy_payload)

        patch_payload = {
            "tool_name": "apply_patch",
            "tool_input": f"*** Begin Patch\n*** Update File: {failed_patch}\n*** End Patch",
            "tool_response": {"success": False, "error": "patch rejected"},
        }
        self.assertEqual(load_post_hook_module().candidate_paths(patch_payload), [])
        self.run_hook(POST_HOOK, patch_payload)

        unknown_payload = {
            "tool_name": "Bash",
            "tool_input": {"command": "printf x > unknown-result.md"},
            "tool_response": {"output": "unclassified result"},
            "cwd": str(self.root),
        }
        self.assertEqual(load_post_hook_module().candidate_paths(unknown_payload), [])
        self.run_hook(POST_HOOK, unknown_payload)

        pending_payload = {
            "tool_name": "Bash",
            "tool_input": {"command": "printf x > pending-result.md"},
            "tool_response": {"status": "pending"},
            "cwd": str(self.root),
        }
        self.assertEqual(load_post_hook_module().candidate_paths(pending_payload), [])
        self.run_hook(POST_HOOK, pending_payload)

        malformed_payload = {
            "tool_name": "Bash",
            "tool_input": {"command": "printf x > malformed-result.md"},
            "tool_response": {"success": "unknown", "ok": 1},
            "cwd": str(self.root),
        }
        self.assertEqual(load_post_hook_module().candidate_paths(malformed_payload), [])
        self.run_hook(POST_HOOK, malformed_payload)

        for path in (failed_copy, failed_patch, unknown_result, pending_result, malformed_result):
            self.assertEqual(path.read_text(encoding="utf-8"), "MacOS")

    def test_unknown_path_and_shell_command_are_ignored(self) -> None:
        prose = self.root / "unknown.md"
        prose.write_text("MacOS", encoding="utf-8")
        self.run_hook(POST_HOOK, {"tool_name": "shell", "tool_input": {"command": str(prose)}})
        self.assertEqual(prose.read_text(encoding="utf-8"), "MacOS")

    def test_read_operation_path_is_not_a_candidate(self) -> None:
        prose = self.root / "readme.md"
        prose.write_text("MacOS", encoding="utf-8")
        payload = {"tool_name": "Read", "tool_input": {"file_path": str(prose)}}
        self.assertEqual(load_post_hook_module().candidate_paths(payload), [])
        self.run_hook(POST_HOOK, payload)
        self.assertEqual(prose.read_text(encoding="utf-8"), "MacOS")

    def test_hooks_json_has_no_unconditional_stop_hook(self) -> None:
        hooks = json.loads(HOOKS_JSON.read_text(encoding="utf-8"))
        self.assertNotIn("Stop", hooks["hooks"])
        self.assertIn("PostToolUse", hooks["hooks"])
        self.assertEqual(
            hooks["hooks"]["PreToolUse"][0]["hooks"][0]["command"].split()[-1],
            "/Users/hnishim/.codex/hooks/gh_normal_context_guard.py",
        )


if __name__ == "__main__":
    unittest.main()
