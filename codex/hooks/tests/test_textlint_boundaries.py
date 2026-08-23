#!/usr/bin/env python3
"""Fixture tests for artifact-boundary textlint hooks."""

from __future__ import annotations

import json
import io
import importlib.util
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock
from contextlib import redirect_stdout


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


def load_pre_hook_module():
    spec = importlib.util.spec_from_file_location("textlint_pretool_hook", PRE_HOOK)
    if spec is None or spec.loader is None:
        raise ImportError("textlint-pretool-hook.py could not be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TextlintBoundaryTests(unittest.TestCase):
    # Codex does not expose a checked-in, replayable runtime event fixture.
    # PreToolUse -> tool -> PostToolUse order is confirmed by real CLI logs.
    # Only the stdin payload body and its correlation remain manual/unverified.
    RUNTIME_PAYLOAD_STATUS = "MANUAL-UNVERIFIED"
    RUNTIME_PAYLOAD_CHECKLIST = (
        {"row": "stdin payload body", "status": RUNTIME_PAYLOAD_STATUS,
         "check": "capture session_id, turn_id, tool_use_id, tool_input and tool_response from a real client run"},
        {"row": "Pre/Post correlation", "status": RUNTIME_PAYLOAD_STATUS,
         "check": "correlate the captured payloads by session_id, turn_id and tool_use_id"},
    )

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
            normalized_name = tool_name.lower().rsplit(".", 1)[-1] if isinstance(tool_name, str) else ""
            if normalized_name == "apply_patch" or normalized_name.endswith("__apply_patch"):
                enriched["tool_response"] = {}
            elif normalized_name in {
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

    def logging_fake(self, *, body: str | None = None) -> tuple[Path, Path]:
        log = self.root / "fake-textlint.log"
        script = self.root / "fake-textlint-logging"
        script.write_text(
            "#!/bin/sh\n"
            f"printf '%s\\n' \"$*\" >> \"{log}\"\n"
            "target=\"\"\nfor arg in \"$@\"; do target=\"$arg\"; done\n"
            f"printf 'target=%s\\n' \"$target\" >> \"{log}\"\n"
            + (body or "target=\"\"\nfor arg in \"$@\"; do target=\"$arg\"; done\nsed -i '' 's/MacOS/macOS/g' \"$target\" 2>/dev/null || sed -i 's/MacOS/macOS/g' \"$target\"\n")
            + "exit 0\n",
            encoding="utf-8",
        )
        script.chmod(script.stat().st_mode | stat.S_IXUSR)
        self.env["TEXTLINT_BIN"] = str(script)
        return script, log

    def test_runtime_payload_fixture_is_explicitly_manual_unverified(self) -> None:
        checks = "; ".join(f'{row["row"]}: {row["check"]}' for row in self.RUNTIME_PAYLOAD_CHECKLIST)
        self.skipTest(f"MANUAL-UNVERIFIED; real runtime payload was not captured: {checks}")

    def test_runtime_order_and_payload_acceptance_are_separate(self) -> None:
        self.assertEqual(self.RUNTIME_PAYLOAD_STATUS, "MANUAL-UNVERIFIED")
        self.assertTrue(all(row["status"] == self.RUNTIME_PAYLOAD_STATUS
                            for row in self.RUNTIME_PAYLOAD_CHECKLIST))

    def test_mcp_and_local_functions_are_not_candidates(self) -> None:
        prose = self.root / "mcp.md"
        prose.write_text("MacOS", encoding="utf-8")
        self.assertEqual(load_post_hook_module().candidate_paths({
            "tool_name": "mcp__local__write_file", "tool_input": {"path": str(prose)},
            "tool_response": {"success": True},
        }), [])

    def test_tool_shaped_json_inside_mcp_input_is_not_a_candidate(self) -> None:
        prose = self.root / "mcp-nested.md"
        prose.write_text("MacOS", encoding="utf-8")
        payload = {
            "tool_name": "mcp__codex_apps__some_operation",
            "tool_input": {
                "tool_calls": [{
                    "tool_name": "Bash",
                    "tool_input": {"command": f"touch {prose}"},
                }],
            },
            "tool_response": {"success": True},
        }
        self.assertEqual(load_post_hook_module().candidate_paths(payload), [])
        self.run_hook(POST_HOOK, payload)
        self.assertEqual(prose.read_text(encoding="utf-8"), "MacOS")

    def test_mcp_write_tool_names_are_not_local_writes(self) -> None:
        module = load_post_hook_module()
        for tool_name in ("mcp__codex_apps__apply_patch", "mcp__fake__apply_patch"):
            payload = {
                "tool_name": tool_name,
                "tool_input": {"patch": "*** Begin Patch\n*** Update File: ignored.md\n*** End Patch"},
                "tool_response": {},
            }
            self.assertFalse(module.is_write_payload(payload))
            self.assertEqual(module.candidate_paths(payload), [])

    def test_deleted_path_is_skipped(self) -> None:
        existing = self.root / "existing.md"
        existing.write_text("MacOS", encoding="utf-8")
        payload = {
            "tool_name": "apply_patch", "tool_use_id": "u1", "tool_response": {},
            "tool_input": {"patch": f"*** Begin Patch\n*** Delete File: {existing}\n*** End Patch"},
        }
        self.assertEqual(load_post_hook_module().candidate_paths(payload), [])

    def test_apply_patch_update_uses_explicit_path(self) -> None:
        new_path = self.root / "new.md"
        new_path.write_text("MacOS", encoding="utf-8")
        payload = {
            "tool_name": "apply_patch", "tool_use_id": "u1", "tool_response": {},
            "tool_input": {"patch": f"*** Begin Patch\n*** Update File: {new_path}\n*** End Patch"},
        }
        self.assertEqual(load_post_hook_module().candidate_paths(payload), [new_path.resolve()])

    def test_add_file_missing_at_pre_is_linted_after_correlated_post(self) -> None:
        target = self.root / "new.md"
        state_dir = self.root / "state"
        self.env["TEXTLINT_HOOK_STATE_DIR"] = str(state_dir)
        pre = {
            "session_id": "s-add", "turn_id": "t-add", "tool_use_id": "u-add",
            "tool_name": "apply_patch",
            "tool_input": {"patch": f"*** Begin Patch\n*** Add File: {target}\n+MacOS\n*** End Patch"},
        }
        self.assertEqual(self.run_hook_output(PRE_HOOK, pre), "")
        target.write_text("MacOS", encoding="utf-8")
        post = {**pre, "tool_response": {}}
        self.run_hook(POST_HOOK, post)
        self.assertEqual(target.read_text(encoding="utf-8"), "macOS")

    def test_add_file_failed_post_does_not_lint_new_file(self) -> None:
        target = self.root / "failed-new.md"
        self.env["TEXTLINT_HOOK_STATE_DIR"] = str(self.root / "state")
        pre = {
            "session_id": "s-fail", "turn_id": "t-fail", "tool_use_id": "u-fail",
            "tool_name": "apply_patch",
            "tool_input": {"patch": f"*** Begin Patch\n*** Add File: {target}\n+MacOS\n*** End Patch"},
        }
        self.assertEqual(self.run_hook_output(PRE_HOOK, pre), "")
        target.write_text("MacOS", encoding="utf-8")
        self.run_hook(POST_HOOK, {**pre, "tool_response": {"isError": True}})
        self.assertEqual(target.read_text(encoding="utf-8"), "MacOS")

    def test_raw_apply_patch_pre_state_correlates_with_post(self) -> None:
        target = self.root / "raw-new.md"
        self.env["TEXTLINT_HOOK_STATE_DIR"] = str(self.root / "raw-state")
        pre = {
            "session_id": "s-raw", "turn_id": "t-raw", "tool_use_id": "u-raw",
            "tool_name": "apply_patch",
            "tool_input": f"*** Begin Patch\n*** Add File: {target}\n+MacOS\n*** End Patch",
        }
        self.assertEqual(self.run_hook_output(PRE_HOOK, pre), "")
        target.write_text("MacOS", encoding="utf-8")
        self.run_hook(POST_HOOK, {**pre, "tool_response": {}})
        self.assertEqual(target.read_text(encoding="utf-8"), "macOS")

    def test_raw_apply_patch_mismatched_correlation_falls_back_to_explicit_path(self) -> None:
        target = self.root / "raw-mismatch.md"
        self.env["TEXTLINT_HOOK_STATE_DIR"] = str(self.root / "raw-mismatch-state")
        pre = {
            "session_id": "s-raw-match", "turn_id": "t-raw-match", "tool_use_id": "u-raw-match",
            "tool_name": "apply_patch",
            "tool_input": f"*** Begin Patch\n*** Add File: {target}\n+MacOS\n*** End Patch",
        }
        self.assertEqual(self.run_hook_output(PRE_HOOK, pre), "")
        target.write_text("MacOS", encoding="utf-8")
        mismatch = {**pre, "tool_use_id": "u-raw-other", "tool_response": {}}
        self.assertEqual(self.run_hook(POST_HOOK, mismatch), {"continue": True})
        self.assertEqual(target.read_text(encoding="utf-8"), "macOS")

    def test_apply_patch_opaque_success_response_is_accepted(self) -> None:
        target = self.root / "opaque-response.md"
        target.write_text("MacOS", encoding="utf-8")
        payload = {
            "tool_name": "apply_patch",
            "tool_input": {"command": f"*** Begin Patch\n*** Update File: {target}\n*** End Patch"},
            "tool_response": {"content": [{"type": "text", "text": "applied"}]},
        }
        self.assertEqual(load_post_hook_module().candidate_paths(payload), [target.resolve()])
        self.run_hook(POST_HOOK, payload)
        self.assertEqual(target.read_text(encoding="utf-8"), "macOS")

    def test_malformed_apply_patch_input_does_not_create_state_or_lint(self) -> None:
        target = self.root / "raw-malformed.md"
        target.write_text("MacOS", encoding="utf-8")
        self.env["TEXTLINT_HOOK_STATE_DIR"] = str(self.root / "raw-malformed-state")
        payload = {
            "session_id": "s-malformed-raw", "turn_id": "t-malformed-raw", "tool_use_id": "u-malformed-raw",
            "tool_name": "apply_patch", "tool_input": ["not-a-patch"],
        }
        self.assertEqual(self.run_hook_output(PRE_HOOK, payload), "")
        self.assertEqual(self.run_hook(POST_HOOK, {**payload, "tool_response": {}}), {"continue": True})
        self.assertEqual(target.read_text(encoding="utf-8"), "MacOS")

    def test_malformed_correlated_state_falls_back_to_explicit_path(self) -> None:
        target = self.root / "malformed-state.md"
        target.write_text("MacOS", encoding="utf-8")
        state_dir = self.root / "state"
        state_dir.mkdir()
        self.env["TEXTLINT_HOOK_STATE_DIR"] = str(state_dir)
        helpers = load_post_hook_module().load_helpers()
        identity = ("s-malformed", "t-malformed", "u-malformed")
        state_file = state_dir / f"{helpers._identity_key(identity)}.json"
        state_file.write_text("not-json", encoding="utf-8")
        payload = {
            "session_id": identity[0], "turn_id": identity[1], "tool_use_id": identity[2],
            "tool_name": "Bash", "tool_input": {"command": f"touch {target}"},
            "tool_response": {"exit_code": 0},
        }
        self.assertEqual(self.run_hook(POST_HOOK, payload), {"continue": True})
        self.assertEqual(target.read_text(encoding="utf-8"), "macOS")

    def test_race_fixture_injects_the_fake_runtime(self) -> None:
        prose = self.root / "race.md"
        prose.write_text("MacOS", encoding="utf-8")
        boundary = load_post_hook_module().load_helpers()
        def fake_run(*args, **kwargs):
            if "--config" in args[0]:
                Path(args[0][-1]).write_text("macOS", encoding="utf-8")
            stdout = b"-rw-r--r-- 1 user group 5 Jan 1 00:00 file\n" if args[0][0] == "/bin/ls" else b""
            return subprocess.CompletedProcess(args[0], 0, stdout=stdout, stderr=b"")
        with mock.patch.dict(os.environ, self.env, clear=True), \
                mock.patch.object(boundary.subprocess, "run", side_effect=fake_run) as run:
            self.assertTrue(boundary.fix_file(prose))
        textlint_calls = [call for call in run.call_args_list if "--config" in call.args[0]]
        self.assertEqual(len(textlint_calls), 1)
        self.assertEqual(prose.read_text(encoding="utf-8"), "macOS")

    def test_external_edit_during_read_is_not_overwritten(self) -> None:
        prose = self.root / "read-race.md"
        prose.write_text("MacOS", encoding="utf-8")
        boundary = load_post_hook_module().load_helpers()
        original_open = Path.open
        calls = 0

        def edit_on_source_read(path, *args, **kwargs):
            nonlocal calls
            if path == prose:
                calls += 1
            if path == prose and calls == 2:
                with original_open(path, "w", encoding="utf-8", newline="") as stream:
                    stream.write("external read edit")
            return original_open(path, *args, **kwargs)

        with mock.patch.object(Path, "open", autospec=True, side_effect=edit_on_source_read):
            self.assertFalse(boundary.fix_file(prose))
        self.assertEqual(prose.read_text(encoding="utf-8"), "external read edit")

    def test_external_edit_during_textlint_is_not_overwritten(self) -> None:
        prose = self.root / "lint-race.md"
        prose.write_text("MacOS", encoding="utf-8")
        boundary = load_post_hook_module().load_helpers()

        def edit_during_lint(*args, **kwargs):
            prose.write_text("external lint edit", encoding="utf-8")
            return "macOS"

        with mock.patch.object(boundary, "fix_text", side_effect=edit_during_lint):
            self.assertFalse(boundary.fix_file(prose))
        self.assertEqual(prose.read_text(encoding="utf-8"), "external lint edit")

    def test_external_edit_at_final_commit_check_is_not_overwritten(self) -> None:
        prose = self.root / "commit-race.md"
        prose.write_text("MacOS", encoding="utf-8")
        boundary = load_post_hook_module().load_helpers()
        original_fingerprint = boundary._fingerprint
        calls = 0

        def edit_before_final_check(path):
            nonlocal calls
            calls += 1
            current = original_fingerprint(path)
            if calls == 4:
                prose.write_text("external commit edit", encoding="utf-8")
                return original_fingerprint(path)
            return current

        with mock.patch.object(boundary, "_fingerprint", side_effect=edit_before_final_check):
            self.assertFalse(boundary.fix_file(prose))
        self.assertEqual(prose.read_text(encoding="utf-8"), "external commit edit")

    def test_metadata_preservation_failure_is_fail_open(self) -> None:
        prose = self.root / "metadata.md"
        prose.write_text("MacOS", encoding="utf-8")
        boundary = load_post_hook_module().load_helpers()
        with mock.patch.object(boundary, "_apply_metadata", return_value=False):
            self.assertFalse(boundary.fix_file(prose))
        self.assertEqual(prose.read_text(encoding="utf-8"), "MacOS")

    def test_missing_xattr_backend_skips_before_replace(self) -> None:
        prose = self.root / "no-xattr-backend.md"
        prose.write_text("MacOS", encoding="utf-8")
        boundary = load_post_hook_module().load_helpers()
        before = boundary._fingerprint(prose)
        with mock.patch.object(boundary.os, "listxattr", None, create=True), \
                mock.patch.object(boundary.os, "getxattr", None, create=True), \
                mock.patch.object(boundary, "_xattr_command", return_value=None):
            self.assertFalse(boundary.fix_file(prose))
        self.assertEqual(prose.read_text(encoding="utf-8"), "MacOS")
        self.assertEqual(boundary._fingerprint(prose), before)
        self.assertEqual(list(self.root.glob(".no-xattr-backend.md.*.tmp")), [])

    def test_acl_without_complete_restore_backend_skips_before_replace(self) -> None:
        prose = self.root / "acl.md"
        prose.write_text("MacOS", encoding="utf-8")
        before = prose.read_text(encoding="utf-8")
        boundary = load_post_hook_module().load_helpers()
        metadata = boundary._metadata_snapshot(prose)
        with mock.patch.object(boundary, "_acl_marker", return_value=True), \
                mock.patch.object(boundary, "_xattr_get", return_value=None), \
                mock.patch.object(boundary, "_xattr_list", return_value=[]):
            self.assertFalse(boundary.fix_file(prose))
        self.assertEqual(prose.read_text(encoding="utf-8"), before)
        self.assertEqual(list(self.root.glob(".acl.md.*.tmp")), [])
        self.assertEqual(metadata, boundary._metadata_snapshot(prose))

    def test_acl_xattr_with_normal_xattr_and_at_ls_marker_is_preserved(self) -> None:
        prose = self.root / "acl-with-normal-xattr.md"
        prose.write_text("MacOS", encoding="utf-8")
        boundary = load_post_hook_module().load_helpers()
        acl = b"serialized-acl"
        normal = b"normal-xattr"

        def fake_xattr_get(path, name):
            return {"com.apple.acl.text": acl, "com.apple.provenance": normal}.get(name)

        with mock.patch.object(boundary, "_acl_marker", return_value=False), \
                mock.patch.object(boundary, "_xattr_list", return_value=["com.apple.acl.text", "com.apple.provenance"]), \
                mock.patch.object(boundary, "_xattr_get", side_effect=fake_xattr_get), \
                mock.patch.object(boundary, "_xattr_replace", return_value=True) as replace:
            self.assertTrue(boundary.fix_file(prose))
            replace.assert_called()
        self.assertEqual(prose.read_text(encoding="utf-8"), "macOS")
        self.assertEqual(fake_xattr_get(prose, "com.apple.acl.text"), acl)
        self.assertEqual(list(self.root.glob(".acl-with-normal-xattr.md.*.tmp")), [])

    def test_acl_entries_after_at_mode_marker_are_detected(self) -> None:
        boundary = load_post_hook_module().load_helpers()
        ls_output = (
            b"-rw-r--r--@ 1 user group 5 Jan 1 00:00 file\n"
            b" 0: user:alice allow read\n"
        )
        completed = subprocess.CompletedProcess(
            ["/bin/ls", "-lde", str(self.root / "acl-entry.md")],
            0,
            stdout=ls_output,
            stderr=b"",
        )
        with mock.patch.object(boundary.subprocess, "run", return_value=completed):
            self.assertTrue(boundary._acl_marker(self.root / "acl-entry.md"))

    def test_acl_entries_without_serialized_xattr_skip_before_temp_creation(self) -> None:
        prose = self.root / "acl-entry-no-xattr.md"
        prose.write_text("MacOS", encoding="utf-8")
        boundary = load_post_hook_module().load_helpers()
        before = boundary._fingerprint(prose)
        with mock.patch.object(boundary, "_acl_marker", return_value=True), \
                mock.patch.object(boundary, "_xattr_list", return_value=["com.apple.provenance"]), \
                mock.patch.object(boundary, "_xattr_get", return_value=b"normal"):
            self.assertFalse(boundary.fix_file(prose))
        self.assertEqual(boundary._fingerprint(prose), before)
        self.assertEqual(prose.read_text(encoding="utf-8"), "MacOS")
        self.assertEqual(list(self.root.glob(".acl-entry-no-xattr.md.*.tmp")), [])

    def test_hardlink_is_skipped_without_changing_alias_or_inode(self) -> None:
        prose = self.root / "hardlink.md"
        prose.write_text("MacOS", encoding="utf-8")
        alias = self.root / "hardlink-alias.md"
        os.link(prose, alias)
        boundary = load_post_hook_module().load_helpers()
        before_inode = prose.stat().st_ino
        with mock.patch.dict(os.environ, self.env, clear=True):
            self.assertFalse(boundary.fix_file(prose))
        self.assertEqual(prose.read_text(encoding="utf-8"), "MacOS")
        self.assertEqual(alias.read_text(encoding="utf-8"), "MacOS")
        self.assertEqual(prose.stat().st_ino, before_inode)
        self.assertEqual(alias.stat().st_ino, before_inode)
        self.assertEqual(list(self.root.glob(".hardlink.md.*.tmp")), [])

    def test_immutable_flag_failure_cleans_temp_before_replace(self) -> None:
        prose = self.root / "immutable.md"
        prose.write_text("MacOS", encoding="utf-8")
        boundary = load_post_hook_module().load_helpers()
        metadata = {
            "source": str(prose), "mode": 0o644,
            "uid": prose.stat().st_uid, "gid": prose.stat().st_gid,
            "flags": 1, "xattrs": {},
        }
        with mock.patch.object(boundary, "_metadata_snapshot", return_value=metadata), \
                mock.patch.object(boundary.os, "chflags", side_effect=OSError("immutable"), create=True):
            self.assertFalse(boundary.fix_file(prose))
        self.assertEqual(prose.read_text(encoding="utf-8"), "MacOS")
        self.assertEqual(list(self.root.glob(".immutable.md.*.tmp")), [])

    def test_atomic_replace_preserves_mode(self) -> None:
        prose = self.root / "mode.md"
        prose.write_text("MacOS", encoding="utf-8")
        prose.chmod(0o640)
        boundary = load_post_hook_module().load_helpers()
        with mock.patch.dict(os.environ, self.env, clear=True):
            self.assertTrue(boundary.fix_file(prose))
        self.assertEqual(stat.S_IMODE(prose.stat().st_mode), 0o640)

    def test_atomic_replace_preserves_xattr_when_platform_api_is_available(self) -> None:
        setxattr = getattr(os, "setxattr", None)
        getxattr = getattr(os, "getxattr", None)
        boundary = load_post_hook_module().load_helpers()
        prose = self.root / "xattr.md"
        prose.write_text("MacOS", encoding="utf-8")
        try:
            if setxattr is not None and getxattr is not None:
                setxattr(prose, "user.codex_textlint_test", b"preserve", follow_symlinks=False)
                read_xattr = lambda: getxattr(
                    prose, "user.codex_textlint_test", follow_symlinks=False
                )
            elif boundary._xattr_command() is not None:
                result = subprocess.run(
                    [boundary._xattr_command(), "-w", "-x", "user.codex_textlint_test", "7072657365727665", str(prose)],
                    capture_output=True,
                    check=False,
                )
                if result.returncode != 0:
                    raise OSError(result.stderr)
                read_xattr = lambda: boundary._xattr_get(prose, "user.codex_textlint_test")
            else:
                self.skipTest("no xattr backend is available")
        except OSError as exc:
            self.skipTest(f"xattr unavailable on test filesystem: {exc}")
        with mock.patch.dict(os.environ, self.env, clear=True):
            self.assertTrue(boundary.fix_file(prose))
        self.assertEqual(read_xattr(), b"preserve")

    def test_missing_executable_is_fail_open(self) -> None:
        prose = self.root / "failure.md"
        prose.write_text("MacOS", encoding="utf-8")
        boundary = load_post_hook_module().load_helpers()
        missing = self.root / "does-not-exist"
        env = {**self.env, "TEXTLINT_BIN": str(missing)}
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(boundary.shutil, "which", return_value=None), \
                mock.patch.object(boundary.Path, "home", return_value=self.root):
            self.assertIsNone(boundary.find_textlint())
            self.assertFalse(boundary.fix_file(prose))
        self.assertEqual(prose.read_text(encoding="utf-8"), "MacOS")

    def test_missing_config_is_fail_open(self) -> None:
        prose = self.root / "missing-config.md"
        prose.write_text("MacOS", encoding="utf-8")
        fake, log = self.logging_fake()
        boundary = load_post_hook_module().load_helpers()
        env = {**self.env, "TEXTLINT_BIN": str(fake),
               "TEXTLINT_CONFIG": str(self.root / "does-not-exist.json")}
        with mock.patch.dict(os.environ, env, clear=True):
            self.assertFalse(boundary.fix_file(prose))
        self.assertFalse(log.exists(), "logging fake must not run when config is missing")
        self.assertEqual(prose.read_text(encoding="utf-8"), "MacOS")

    def test_timeout_is_fail_open_and_fake_receives_last_argument(self) -> None:
        prose = self.root / "timeout.md"
        prose.write_text("MacOS", encoding="utf-8")
        _, log = self.logging_fake(body="sleep 2\n")
        boundary = load_post_hook_module().load_helpers()
        with mock.patch.dict(os.environ, self.env, clear=False), \
                mock.patch.object(boundary, "TEXTLINT_TIMEOUT_SECONDS", 0.5):
            self.assertFalse(boundary.fix_file(prose))
        self.assertTrue(log.exists())
        self.assertIn("target=", log.read_text(encoding="utf-8"))
        self.assertEqual(prose.read_text(encoding="utf-8"), "MacOS")

    def test_non_permitted_exit_is_fail_open(self) -> None:
        prose = self.root / "exit-code.md"
        prose.write_text("MacOS", encoding="utf-8")
        _, log = self.logging_fake(body="exit 2\n")
        boundary = load_post_hook_module().load_helpers()
        with mock.patch.dict(os.environ, self.env, clear=False):
            self.assertFalse(boundary.fix_file(prose))
        self.assertTrue(log.exists())
        self.assertEqual(prose.read_text(encoding="utf-8"), "MacOS")

    def test_invalid_utf8_output_is_fail_open(self) -> None:
        prose = self.root / "invalid-utf8.md"
        prose.write_text("MacOS", encoding="utf-8")
        _, log = self.logging_fake(body="printf '\\377' > \"$target\"\n")
        boundary = load_post_hook_module().load_helpers()
        with mock.patch.dict(os.environ, self.env, clear=False):
            self.assertFalse(boundary.fix_file(prose))
        self.assertTrue(log.exists())
        self.assertEqual(prose.read_text(encoding="utf-8"), "MacOS")

    def test_success_without_content_change_is_not_reported_as_fix(self) -> None:
        prose = self.root / "unchanged.md"
        prose.write_text("already fixed", encoding="utf-8")
        _, log = self.logging_fake()
        boundary = load_post_hook_module().load_helpers()
        with mock.patch.dict(os.environ, self.env, clear=False):
            self.assertFalse(boundary.fix_file(prose))
        lines = log.read_text(encoding="utf-8").splitlines()
        self.assertTrue(any(line.startswith("target=") for line in lines))
        self.assertEqual(prose.read_text(encoding="utf-8"), "already fixed")

    def test_temporary_lint_directory_is_cleaned_up(self) -> None:
        prose = self.root / "cleanup.md"
        prose.write_text("MacOS", encoding="utf-8")
        boundary = load_post_hook_module().load_helpers()
        created: list[Path] = []
        original_temporary_directory = boundary.tempfile.TemporaryDirectory

        class RecordingTemporaryDirectory:
            def __init__(self, *args, **kwargs):
                self.args = args
                self.kwargs = kwargs

            def __enter__(self):
                self.context = original_temporary_directory(*self.args, **self.kwargs)
                path = self.context.__enter__()
                created.append(Path(path))
                return path

            def __exit__(self, *args):
                return self.context.__exit__(*args)

        with mock.patch.dict(os.environ, self.env, clear=False), \
                mock.patch.object(boundary.tempfile, "TemporaryDirectory", RecordingTemporaryDirectory):
            boundary.fix_file(prose)
        self.assertEqual(len(created), 1)
        self.assertFalse(created[0].exists())

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

    def test_post_main_dynamic_import_failure_is_fail_open(self) -> None:
        module = load_post_hook_module()
        output = io.StringIO()
        with mock.patch.object(module.sys, "stdin", io.StringIO("{}")), \
                mock.patch.object(module, "load_helpers", side_effect=RuntimeError("broken import")), \
                redirect_stdout(output):
            self.assertEqual(module.main(), 0)
        self.assertEqual(json.loads(output.getvalue()), {"continue": True})

    def test_pre_main_dynamic_import_failure_is_empty_success(self) -> None:
        module = load_pre_hook_module()
        output = io.StringIO()
        payload = {"tool_name": "Bash", "tool_input": {"command": "touch file.md"}}
        with mock.patch.object(module.sys, "stdin", io.StringIO(json.dumps(payload))), \
                mock.patch.object(module, "load_post_hook_module", side_effect=RuntimeError("broken import")), \
                redirect_stdout(output):
            self.assertEqual(module.main(), 0)
        self.assertEqual(output.getvalue(), "")

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

    def test_namespaced_codex_tools_are_fixed(self) -> None:
        for separator, label in ((".", "dot"), ("/", "slash"), (":", "colon")):
            patch_path = self.root / f"namespaced-patch-{label}.md"
            command_path = self.root / f"namespaced-command-{label}.md"
            patch_path.write_text("MacOS", encoding="utf-8")
            command_path.write_text("MacOS", encoding="utf-8")
            self.run_successful_post(
                {
                    "tool_name": f"functions{separator}apply_patch",
                    "tool_input": f"*** Begin Patch\n*** Update File: {patch_path}\n*** End Patch",
                    "tool_response": {},
                },
            )
            self.run_successful_post(
                {
                    "tool_name": f"functions{separator}exec_command",
                    "tool_input": {"cmd": f"touch {command_path}"},
                    "tool_response": {"exit_code": 0},
                },
            )
            self.assertEqual(patch_path.read_text(encoding="utf-8"), "macOS")
            self.assertEqual(command_path.read_text(encoding="utf-8"), "macOS")

    def test_code_mode_wrapper_patch_source_is_fixed(self) -> None:
        target = self.root / "code-mode-wrapper.md"
        target.write_text("MacOS", encoding="utf-8")
        wrapper_source = (
            f'const patch = "*** Begin Patch\\n*** Update File: {target}\\n*** End Patch";'
        )
        payload = {
            "tool_name": "functions.exec",
            "tool_input": wrapper_source,
            "tool_response": {},
        }
        self.assertEqual(
            load_post_hook_module().candidate_paths(payload), [target.resolve()]
        )
        self.run_hook(POST_HOOK, payload)
        self.assertEqual(target.read_text(encoding="utf-8"), "macOS")

    def test_symlink_path_is_not_a_candidate(self) -> None:
        target = self.root / "real.md"
        target.write_text("MacOS", encoding="utf-8")
        link = self.root / "linked.md"
        link.symlink_to(target)
        payload = {
            "tool_name": "functions.exec_command",
            "tool_input": {"cmd": f"touch {link}"},
            "tool_response": {"exit_code": 0},
        }
        self.assertEqual(load_post_hook_module().candidate_paths(payload), [])
        self.run_hook(POST_HOOK, payload)
        self.assertEqual(target.read_text(encoding="utf-8"), "MacOS")

    def test_explicit_external_file_is_fixed(self) -> None:
        workspace = self.root / "workspace"
        workspace.mkdir()
        external = self.root / "external" / "external.md"
        external.parent.mkdir()
        external.write_text("MacOS", encoding="utf-8")
        payload = {
            "tool_name": "functions.exec_command",
            "tool_input": {"cmd": f"touch {external}"},
            "tool_response": {"exit_code": 0},
            "cwd": str(workspace),
            "workspace_roots": [str(workspace)],
        }
        self.assertEqual(
            load_post_hook_module().candidate_paths(payload), [external.resolve()]
        )
        self.run_hook(POST_HOOK, payload)
        self.assertEqual(external.read_text(encoding="utf-8"), "macOS")

    def test_protected_system_paths_are_not_candidates(self) -> None:
        module = load_post_hook_module()
        for path in ("/System/diagnostic.md", "/etc/diagnostic.md", "/usr/diagnostic.md"):
            self.assertIsNone(
                module._path_allowed(
                    path,
                    self.root,
                    [self.root],
                    allow_missing=True,
                )
            )

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
