"""Regression tests for defaults-setup.sh dictionary-entry shortcuts."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SHELL_SCRIPT = REPO_ROOT / "defaults" / "defaults-setup.sh"


def _read_helper_and_shortcut_calls() -> tuple[str, list[str]]:
    source = SHELL_SCRIPT.read_text(encoding="utf-8")
    helper_start = source.index("set_user_dict_entry() {")
    helper_end = source.index("\n# --- Language & Region ---", helper_start)
    helper = source[helper_start:helper_end]

    lines = source.splitlines()
    calls: list[str] = []
    index = 0
    while index < len(lines):
        line = lines[index]
        if (
            line.startswith("set_user_dict_entry com.apple.finder NSUserKeyEquivalents")
            or line.startswith("set_user_dict_entry com.apple.Preview NSUserKeyEquivalents")
        ):
            call_lines = [line]
            while call_lines[-1].rstrip().endswith("\\"):
                index += 1
                call_lines.append(lines[index])
            call = "\n".join(call_lines)
            if '"Show Next Tab"' in call or '"Show Previous Tab"' in call:
                calls.append(call)
        index += 1

    if len(calls) != 4:
        raise AssertionError(f"Expected four Finder/Preview shortcut calls, got {len(calls)}")
    return helper, calls


FAKE_DEFAULTS = """#!/bin/sh
case "$1" in
  read)
    printf '%s\\n' dictionary
    ;;
  write)
    printf '%s\\n' "$@" >> "$FAKE_WRITE_LOG"
    exit "$FAKE_WRITE_STATUS"
    ;;
  *)
    exit 2
    ;;
esac
"""

FAKE_PLUTIL = """#!/bin/sh
count=0
if [ -f "$FAKE_READ_COUNT" ]; then
  IFS= read -r count < "$FAKE_READ_COUNT"
fi
count=$((count + 1))
printf '%s\\n' "$count" > "$FAKE_READ_COUNT"
if [ "$count" -eq 1 ]; then
  printf '%s' "$FAKE_READBACK_BEFORE"
else
  printf '%s' "$FAKE_READBACK_AFTER"
fi
"""


def _run_call(
    helper: str,
    call: str,
    *,
    before: str,
    after: str = "",
    write_status: int = 0,
) -> tuple[subprocess.CompletedProcess[str], str]:
    with tempfile.TemporaryDirectory() as temporary_directory:
        root = Path(temporary_directory)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        write_log = root / "writes.log"
        read_count = root / "read-count"
        (fake_bin / "defaults").write_text(FAKE_DEFAULTS, encoding="utf-8")
        (fake_bin / "plutil").write_text(FAKE_PLUTIL, encoding="utf-8")
        for command in (fake_bin / "defaults", fake_bin / "plutil"):
            command.chmod(0o755)

        harness = (
            "#!/usr/bin/env bash\n"
            "set -u\n"
            "DEFAULTS_FAILURES=0\n"
            "DEFAULTS_CHANGED=0\n"
            "mark_changed() { DEFAULTS_CHANGED=1; }\n"
            f"{helper}\n"
            f"{call}\n"
            "printf 'failures=%s changed=%s\\n' \"$DEFAULTS_FAILURES\" \"$DEFAULTS_CHANGED\"\n"
        )
        harness_path = root / "run.sh"
        harness_path.write_text(harness, encoding="utf-8")

        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{fake_bin}:{environment.get('PATH', '')}",
                "FAKE_WRITE_LOG": str(write_log),
                "FAKE_READ_COUNT": str(read_count),
                "FAKE_READBACK_BEFORE": before,
                "FAKE_READBACK_AFTER": after,
                "FAKE_WRITE_STATUS": str(write_status),
            }
        )
        result = subprocess.run(
            ["bash", str(harness_path)],
            cwd=root,
            env=environment,
            capture_output=True,
            text=True,
        )
        writes = write_log.read_text(encoding="utf-8") if write_log.exists() else ""
        return result, writes


class DefaultsDictEntryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.helper, cls.calls = _read_helper_and_shortcut_calls()
        cls.values = ("@~→", "@~←", "@~→", "@~←")
        cls.encoded_values = (r"@~\\U2192", r"@~\\U2190", r"@~\\U2192", r"@~\\U2190")

    def test_existing_unicode_arrows_do_not_trigger_rewrites(self) -> None:
        for call, expected in zip(self.calls, self.values):
            with self.subTest(expected=expected, call=call.splitlines()[0]):
                result, writes = _run_call(self.helper, call, before=expected)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("[INFO] Already set:", result.stdout)
                self.assertIn("failures=0 changed=0", result.stdout)
                self.assertEqual(writes, "")

    def test_mismatched_values_are_written_and_verified(self) -> None:
        for call, expected, encoded in zip(
            self.calls, self.values, self.encoded_values
        ):
            with self.subTest(expected=expected, call=call.splitlines()[0]):
                result, writes = _run_call(
                    self.helper, call, before="@~wrong", after=expected
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("[SUCCESS] Updated:", result.stdout)
                self.assertIn("failures=0 changed=1", result.stdout)
                self.assertEqual(writes.splitlines()[-1], encoded)

    def test_defaults_write_failure_is_counted(self) -> None:
        result, writes = _run_call(
            self.helper,
            self.calls[0],
            before="@~wrong",
            write_status=73,
        )
        self.assertIn("[WARN] Failed to set:", result.stdout)
        self.assertIn("failures=1 changed=0", result.stdout)
        self.assertTrue(writes)

    def test_post_write_readback_mismatch_is_counted(self) -> None:
        result, writes = _run_call(
            self.helper,
            self.calls[0],
            before="@~wrong",
            after="@~still-wrong",
        )
        self.assertIn("[WARN] Verification failed:", result.stdout)
        self.assertIn("failures=1 changed=0", result.stdout)
        self.assertTrue(writes)


if __name__ == "__main__":
    unittest.main()
