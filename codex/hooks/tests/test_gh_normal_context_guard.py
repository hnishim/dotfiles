#!/usr/bin/env python3
"""Executable subprocess boundaries for the GitHub CLI context guard."""

from __future__ import annotations

import json
import subprocess
import unittest
from pathlib import Path


HOOK = Path(__file__).resolve().parents[1] / "gh_normal_context_guard.py"


class GhNormalContextGuardTests(unittest.TestCase):
    def run_guard(self, payload: object, *, raw: str | None = None) -> str:
        result = subprocess.run(
            ["/usr/bin/python3", str(HOOK)],
            input=raw if raw is not None else json.dumps(payload),
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertEqual(result.stderr, "")
        return result.stdout

    def assert_denied(self, payload: dict) -> None:
        output = self.run_guard(payload)
        response = json.loads(output)
        hook_output = response["hookSpecificOutput"]
        self.assertEqual(hook_output["hookEventName"], "PreToolUse")
        self.assertEqual(hook_output["permissionDecision"], "deny")
        self.assertTrue(hook_output["permissionDecisionReason"])

    def assert_fail_open(self, payload: object, *, raw: str | None = None) -> None:
        self.assertEqual(self.run_guard(payload, raw=raw), "")

    def test_s1_existing_normal_context_allows_both_target_commands(self) -> None:
        for command in ("gh auth status", "gh repo create owner/repo"):
            with self.subTest(command=command):
                self.assertEqual(
                    self.run_guard(
                        {
                            "permission_mode": "bypassPermissions",
                            "tool_input": {
                                "command": command,
                            },
                        }
                    ),
                    "",
                )
                self.assertEqual(
                    self.run_guard(
                        {
                            "tool_input": {
                                "command": command,
                                "sandbox_permissions": "require_escalated",
                            }
                        }
                    ),
                    "",
                )

    def test_s2_target_commands_without_trusted_context_are_denied(self) -> None:
        for command in ("gh auth status", "gh repo create owner/repo"):
            for tool_input in (
                {"command": command},
                {"command": command, "sandbox_permissions": "use_default"},
                {"command": command, "sandbox_permissions": "deny"},
            ):
                with self.subTest(command=command, tool_input=tool_input):
                    self.assert_denied({"tool_input": tool_input})

    def test_s3_malformed_json_non_target_and_unidentifiable_fail_open(self) -> None:
        self.assert_fail_open({}, raw="{not-json")
        self.assert_fail_open({"tool_input": {"command": "printf '%s' ok"}})
        self.assert_fail_open({"tool_input": {"command": "git status"}})
        self.assert_fail_open({"tool_input": {"command": None}})
        self.assert_fail_open({"tool_input": "gh auth status"})
        self.assert_fail_open({"tool_input": {"cmd": None}})

    def test_s4_command_cmd_absolute_path_and_shell_boundaries(self) -> None:
        for field in ("command", "cmd"):
            with self.subTest(field=field):
                self.assert_denied({"tool_input": {field: "gh auth status"}})
                self.assert_denied({"tool_input": {field: "/opt/homebrew/bin/gh repo create owner/repo"}})
                self.assert_denied({"tool_input": {field: "printf x && gh auth status --hostname github.com"}})
                self.assert_denied({"tool_input": {field: "printf x&&gh auth status"}})

                self.assert_fail_open({"tool_input": {field: "gh auth status-extra"}})
                self.assert_fail_open({"tool_input": {field: "github auth status"}})
                self.assert_fail_open({"tool_input": {field: "/tmp/ghx auth status"}})

    def test_s5_desktop_functions_exec_payload_requires_evidence(self) -> None:
        # The available contract evidence identifies tool_name/tool_input and
        # standard permission fields, but no verified Desktop/functions.exec
        # field name, position, and value for a normal macOS context. Do not
        # invent an allow fixture until such evidence is captured.
        self.skipTest("TEST_DESIGN_BLOCKED: no evidence-backed Desktop/functions.exec context payload")


if __name__ == "__main__":
    unittest.main()
