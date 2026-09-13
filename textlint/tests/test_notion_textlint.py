#!/usr/bin/env python3
'''Behavior tests for Notion -> textlint -> targeted Notion update flow.'''

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from textwrap import dedent


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "textlint" / "notion-textlint.py"
CONFIG = ROOT / "textlint" / ".textlintrc.json"
PAGE_ID = "0123456789abcdef0123456789abcdef"
PAGE_URL = f"https://www.notion.so/Test-{PAGE_ID}"


def make_executable(path: Path) -> None:
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def page(markdown: str, *, truncated: bool = False, unknown_block_ids: list[str] | None = None) -> dict:
    return {
        "object": "page_markdown",
        "id": PAGE_ID,
        "markdown": markdown,
        "truncated": truncated,
        "unknown_block_ids": unknown_block_ids or [],
    }


class NotionTextlintCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.home = self.root / "home"
        self.fake_bin = self.root / "fake-bin"
        self.state_path = self.root / "ntn-state.json"
        self.ntn_log = self.root / "ntn.log"
        self.textlint_log = self.root / "textlint.log"
        self.home.mkdir()
        self.fake_bin.mkdir()
        runtime_bin = (
            self.home
            / "Library"
            / "Application Support"
            / "dotfiles"
            / "textlint"
            / "node_modules"
            / ".bin"
        )
        runtime_bin.mkdir(parents=True)

        fake_ntn = self.fake_bin / "ntn"
        fake_ntn.write_text(
            dedent(
                r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

state_path = Path(os.environ["FAKE_NTN_STATE"])
log_path = Path(os.environ["FAKE_NTN_LOG"])
state = json.loads(state_path.read_text(encoding="utf-8"))
args = sys.argv[1:]
method = "GET"
if "-X" in args:
    method = args[args.index("-X") + 1]

record = {"args": args, "method": method}
if "--data" in args:
    raw = args[args.index("--data") + 1]
    record["data"] = json.loads(raw)

with log_path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, ensure_ascii=False) + "\n")

if not args or args[0] != "api":
    print("expected api subcommand", file=sys.stderr)
    sys.exit(90)

if "--notion-version" not in args:
    print("missing --notion-version", file=sys.stderr)
    sys.exit(91)
if args[args.index("--notion-version") + 1] != "2026-03-11":
    print("wrong Notion version", file=sys.stderr)
    sys.exit(92)

if method == "GET":
    gets = state.get("gets", [])
    if not gets:
        print("unexpected GET", file=sys.stderr)
        sys.exit(93)
    response = gets.pop(0)
    state["gets"] = gets
    state_path.write_text(json.dumps(state), encoding="utf-8")
    print(json.dumps(response))
    sys.exit(0)

if method == "PATCH":
    patch = state.get("patch", {})
    response = patch.get(
        "response",
        {
            "object": "page_markdown",
            "id": "fake",
            "markdown": "",
            "truncated": False,
            "unknown_block_ids": [],
        },
    )
    print(json.dumps(response))
    sys.exit(int(patch.get("exit", 0)))

print("unexpected method", file=sys.stderr)
sys.exit(94)
'''
            ),
            encoding="utf-8",
        )
        make_executable(fake_ntn)

        fake_textlint = runtime_bin / "textlint"
        fake_textlint.write_text(
            dedent(
                r'''#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

args = sys.argv[1:]
Path(os.environ["FAKE_TEXTLINT_LOG"]).write_text(
    json.dumps(args, ensure_ascii=False),
    encoding="utf-8",
)
if "--config" not in args or "--fix" not in args:
    print("expected --config and --fix", file=sys.stderr)
    sys.exit(80)
config = Path(args[args.index("--config") + 1]).resolve()
expected = Path(os.environ["FAKE_EXPECTED_TEXTLINT_CONFIG"]).resolve()
if config != expected:
    print(f"unexpected config: {config}", file=sys.stderr)
    sys.exit(81)
target = Path(args[-1])
text = target.read_text(encoding="utf-8")
target.write_text(text.replace("teh", "the", 1), encoding="utf-8")
'''
            ),
            encoding="utf-8",
        )
        make_executable(fake_textlint)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write_state(
        self,
        gets: list[dict],
        *,
        patch_exit: int = 0,
        patch_response: dict | None = None,
    ) -> None:
        self.state_path.write_text(
            json.dumps(
                {
                    "gets": gets,
                    "patch": {
                        "exit": patch_exit,
                        "response": patch_response or page(""),
                    },
                }
            ),
            encoding="utf-8",
        )
        self.ntn_log.write_text("", encoding="utf-8")

    def env(self) -> dict[str, str]:
        return {
            **os.environ,
            "HOME": str(self.home),
            "PATH": f"{self.fake_bin}:/usr/bin:/bin",
            "FAKE_NTN_STATE": str(self.state_path),
            "FAKE_NTN_LOG": str(self.ntn_log),
            "FAKE_TEXTLINT_LOG": str(self.textlint_log),
            "FAKE_EXPECTED_TEXTLINT_CONFIG": str(CONFIG),
        }

    def run_cli(self, target: str = PAGE_ID) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), target],
            text=True,
            capture_output=True,
            env=self.env(),
        )

    def ntn_calls(self) -> list[dict]:
        if not self.ntn_log.exists() or not self.ntn_log.read_text(encoding="utf-8").strip():
            return []
        return [
            json.loads(line)
            for line in self.ntn_log.read_text(encoding="utf-8").splitlines()
        ]

    def patch_calls(self) -> list[dict]:
        return [call for call in self.ntn_calls() if call["method"] == "PATCH"]

    def test_page_url_is_accepted_and_noop_does_not_patch(self) -> None:
        base = "# Title\n\nNo lint change.\n"
        self.write_state([page(base)])

        result = self.run_cli(PAGE_URL)

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.ntn_calls()
        self.assertEqual([call["method"] for call in calls], ["GET"])
        endpoint = calls[0]["args"][1]
        self.assertIn(PAGE_ID, endpoint.replace("-", ""))
        self.assertEqual(self.patch_calls(), [])

    def test_success_uses_targeted_update_and_verifies_readback(self) -> None:
        base = "# Title\n\nteh value\n"
        fixed = "# Title\n\nthe value\n"
        self.write_state(
            [page(base), page(base), page(fixed)],
            patch_response=page(fixed),
        )

        result = self.run_cli()

        self.assertEqual(result.returncode, 0, result.stderr)
        patches = self.patch_calls()
        self.assertEqual(len(patches), 1)
        payload = patches[0]["data"]
        self.assertEqual(payload["type"], "update_content")
        self.assertNotIn("replace_content", payload)
        self.assertFalse(payload.get("allow_async", False))
        updates = payload["update_content"]["content_updates"]
        self.assertGreaterEqual(len(updates), 1)

        reconstructed = base
        for update in updates:
            old = update["old_str"]
            new = update["new_str"]
            self.assertEqual(reconstructed.count(old), 1)
            reconstructed = reconstructed.replace(old, new, 1)
        self.assertEqual(reconstructed, fixed)

        args = json.loads(self.textlint_log.read_text(encoding="utf-8"))
        self.assertIn("--config", args)
        self.assertEqual(Path(args[args.index("--config") + 1]).resolve(), CONFIG.resolve())

    def test_freshness_mismatch_stops_before_patch(self) -> None:
        base = "# Title\n\nteh value\n"
        changed = "# Title\n\nteh value\n\nConcurrent edit\n"
        self.write_state([page(base), page(changed)])

        result = self.run_cli()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.patch_calls(), [])

    def test_incomplete_markdown_stops_before_lint_or_patch(self) -> None:
        cases = [
            page("# Title\n", truncated=True),
            page("# Title\n", unknown_block_ids=["deadbeef"]),
            page("# Title\n\n<unknown url=\"https://example.invalid\"/>\n"),
        ]
        for response in cases:
            with self.subTest(response=response):
                self.write_state([response])
                self.textlint_log.unlink(missing_ok=True)

                result = self.run_cli()

                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.patch_calls(), [])
                self.assertFalse(self.textlint_log.exists())

    def test_patch_validation_failure_does_not_retry_or_fallback(self) -> None:
        base = "# Title\n\nteh value\n"
        self.write_state(
            [page(base), page(base)],
            patch_exit=1,
            patch_response={
                "object": "error",
                "status": 400,
                "code": "validation_error",
                "message": "old_str is not unique",
            },
        )

        result = self.run_cli()

        self.assertNotEqual(result.returncode, 0)
        patches = self.patch_calls()
        self.assertEqual(len(patches), 1)
        self.assertEqual(patches[0]["data"]["type"], "update_content")

    def test_post_write_concurrent_edit_reports_failure_without_extra_write(self) -> None:
        base = "# Title\n\nteh value\n"
        fixed = "# Title\n\nthe value\n"
        concurrent = "# Title\n\nthe value\n\nConcurrent edit\n"
        self.write_state(
            [page(base), page(base), page(concurrent)],
            patch_response=page(fixed),
        )

        result = self.run_cli()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.patch_calls()), 1)

    def test_duplicate_text_requires_unique_target_context(self) -> None:
        base = "# Title\n\nteh first\n\nteh second\n"
        fixed = "# Title\n\nthe first\n\nteh second\n"
        self.write_state(
            [page(base), page(base), page(fixed)],
            patch_response=page(fixed),
        )

        result = self.run_cli()

        self.assertEqual(result.returncode, 0, result.stderr)
        patches = self.patch_calls()
        self.assertEqual(len(patches), 1)
        updates = patches[0]["data"]["update_content"]["content_updates"]
        self.assertGreaterEqual(len(updates), 1)
        for update in updates:
            self.assertEqual(base.count(update["old_str"]), 1)


if __name__ == "__main__":
    unittest.main()
