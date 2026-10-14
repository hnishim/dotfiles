#!/usr/bin/env python3
"""HIR-355 permanent regression tests for recurring AzooKey table sync."""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
APP_SOURCE = ROOT / "apps" / "azookey"
COMMON_SOURCE = ROOT / "lib" / "common.sh"
LABEL = "my.azookey.sync"
STATE_ATTRIBUTE = "my.azookey.sync.last-synced.sha256"
KEEP_ATTRIBUTE = "com.example.hir355.keep"
TABLE_REL = Path("Library/Containers/dev.ensan.inputmethod.azooKeyMac/Data/Library/"
                 "Application Support/azooKeyMac/CustomInputTable")
RUNTIME_REL = Path("Library/Application Support/my.azookey.sync")
SAMPLE_TSV = "ca\tか\nky\tき\n"

@unittest.skipUnless(sys.platform == "darwin", "requires macOS shell, xattr, and filesystem behavior")
class CustomTableSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hir355 azookey ")
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.repo = base / "fixture dotfiles"
        self.app = self.repo / "apps/azookey"
        self.home = base / "home with spaces"
        self.bin = base / "fake bin"
        self.launchctl_log = base / "launchctl.log"
        self.active_marker = base / "launchctl.active"
        shutil.copytree(APP_SOURCE, self.app)
        (self.repo / "lib").mkdir(parents=True)
        shutil.copy2(COMMON_SOURCE, self.repo / "lib/common.sh")
        self.source_dir = self.app / "CustomInputTable"
        self.source_tsv = self.source_dir / "custom_input_table.tsv"
        self.source_dir.mkdir(parents=True, exist_ok=True)
        self.source_tsv.write_text(SAMPLE_TSV, encoding="utf-8")
        self.home.mkdir()
        self.bin.mkdir()
        self.table_dir = self.home / TABLE_REL
        self.table_tsv = self.table_dir / "custom_input_table.tsv"
        self.launch_agent = self.home / "Library/LaunchAgents" / f"{LABEL}.plist"
        self.runtime_dir = self.home / RUNTIME_REL
        self.sync_script = self.app / "azookey-custom-table-sync.sh"
        self.fake_launchctl()

    def fake_launchctl(self):
        command = self.bin / "launchctl"
        command.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n" "$*" >> "$LAUNCHCTL_TEST_LOG"\n'
            'case "$1" in\n'
            ' print) test -e "$LAUNCHCTL_TEST_ACTIVE" ;;\n'
            ' bootstrap) : > "$LAUNCHCTL_TEST_ACTIVE" ;;\n'
            ' bootout) if test "$LAUNCHCTL_TEST_BOOTOUT_FAIL" = 1; then exit 72; fi; rm -f "$LAUNCHCTL_TEST_ACTIVE" ;;\n'
            ' *) exit 73 ;;\n'
            'esac\n', encoding="utf-8")
        command.chmod(0o755)

    def env(self, **overrides):
        value = dict(os.environ)
        value.update({"HOME": str(self.home), "PATH": str(self.bin) + os.pathsep + value.get("PATH", ""),
                      "TMPDIR": self.tmp.name, "LAUNCHCTL_TEST_LOG": str(self.launchctl_log),
                      "LAUNCHCTL_TEST_ACTIVE": str(self.active_marker), "LAUNCHCTL_TEST_BOOTOUT_FAIL": "0",
                      "TEST_RUNTIME_DIR": str(self.runtime_dir), "TEST_LAUNCH_AGENT": str(self.launch_agent)})
        value.update(overrides)
        return value

    def run_setup(self, **overrides):
        return subprocess.run(["/bin/bash", str(self.app / "azookey-setup.sh")], cwd=self.repo,
                              env=self.env(**overrides), capture_output=True, text=True,
                              errors="replace", timeout=30)

    def run_helper(self, **overrides):
        return subprocess.run(["/bin/bash", str(self.sync_script), str(self.source_tsv), str(self.table_tsv)],
                              cwd=self.repo, env=self.env(**overrides), capture_output=True,
                              text=True, errors="replace", timeout=30)

    def fake_command(self, name, body):
        path = self.bin / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def fake_xattr_faults(self):
        self.fake_command("xattr", "#!/bin/sh\n"
            'if [ "$1" = "-p" ] && [ "$TEST_XATTR_READ_FAIL" = 1 ]; then exit 81; fi\n'
            'if [ "$1" = "-p" ] && [ "$TEST_XATTR_READBACK_FAIL" = 1 ] && [ -e "$TEST_XATTR_WRITE_MARKER" ]; then exit 85; fi\n'
            'if [ "$1" = "-p" ] && [ "$TEST_XATTR_READBACK_MISMATCH" = 1 ] && [ -e "$TEST_XATTR_WRITE_MARKER" ]; then printf "%064d\n" 0; exit 0; fi\n'
            'if [ "$1" = "-w" ] && [ "$TEST_XATTR_WRITE_FAIL" = 1 ]; then exit 82; fi\n'
            'if [ "$1" = "-w" ]; then /usr/bin/xattr "$@" || exit $?; { [ "$TEST_XATTR_READBACK_FAIL" = 1 ] || [ "$TEST_XATTR_READBACK_MISMATCH" = 1 ]; } && : > "$TEST_XATTR_WRITE_MARKER"; exit 0; fi\n'
            'if [ "$1" != "-p" ] && [ "$1" != "-w" ] && [ "$TEST_XATTR_LIST_FAIL" = 1 ]; then exit 83; fi\n'
            'exec /usr/bin/xattr "$@"\n')

    def set_attr(self, name, value):
        result = subprocess.run(["xattr", "-w", name, value, str(self.table_dir)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def get_attr(self, name=STATE_ATTRIBUTE):
        result = subprocess.run(["xattr", "-p", name, str(self.table_dir)], capture_output=True, text=True)
        return result.stdout.rstrip("\n") if result.returncode == 0 else None

    def attr_names(self):
        result = subprocess.run(["xattr", str(self.table_dir)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return set(result.stdout.splitlines())

    def assert_runtime_removed(self):
        self.assertFalse(self.runtime_dir.exists())
        self.assertFalse(self.runtime_dir.is_symlink())

    def assert_no_bootstrap(self):
        lines = self.launchctl_log.read_text().splitlines() if self.launchctl_log.exists() else []
        self.assertFalse(any(line.split(maxsplit=1)[0] == "bootstrap" for line in lines), lines)

    def assert_no_table_temps(self):
        if self.table_dir.is_dir() and not self.table_dir.is_symlink():
            self.assertEqual([p.name for p in self.table_dir.iterdir() if p != self.table_tsv], [])

    def test_setup_initializes_missing_and_empty_targets_without_runtime_assets(self):
        for empty in (False, True):
            with self.subTest(empty=empty):
                if self.table_dir.exists():
                    shutil.rmtree(self.table_dir)
                if empty:
                    self.table_dir.mkdir(parents=True)
                result = self.run_setup()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue(self.table_dir.is_dir())
                self.assertFalse(self.table_dir.is_symlink())
                self.assertEqual(self.table_tsv.read_bytes(), self.source_tsv.read_bytes())
                self.assertEqual(self.get_attr(), hashlib.sha256(self.source_tsv.read_bytes()).hexdigest())
                self.assert_runtime_removed()
                self.assertFalse(self.launch_agent.exists())
                self.assert_no_bootstrap()
                self.assert_no_table_temps()
                if empty:
                    shutil.rmtree(self.table_dir)

    def test_setup_syncs_source_updates_without_runtime_storage(self):
        self.table_dir.mkdir(parents=True)
        self.table_tsv.write_bytes(self.source_tsv.read_bytes())
        self.set_attr(STATE_ATTRIBUTE, hashlib.sha256(self.table_tsv.read_bytes()).hexdigest())
        self.source_tsv.write_text("ca\tか\nku\tく\n", encoding="utf-8")
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.table_tsv.read_bytes(), self.source_tsv.read_bytes())
        self.assertEqual(self.get_attr(), hashlib.sha256(self.source_tsv.read_bytes()).hexdigest())
        self.assert_runtime_removed()
        self.assertFalse(self.launch_agent.exists())
        self.assert_no_bootstrap()

    def test_helper_reconciles_missing_state_and_preserves_other_attributes(self):
        self.table_dir.mkdir(parents=True)
        self.table_tsv.write_bytes(self.source_tsv.read_bytes())
        self.set_attr(KEEP_ATTRIBUTE, "keep")
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.get_attr(), hashlib.sha256(self.source_tsv.read_bytes()).hexdigest())
        self.assertEqual(self.get_attr(KEEP_ATTRIBUTE), "keep")
        self.assertIn(KEEP_ATTRIBUTE, self.attr_names())
        self.assertIn("SYNC_STATE_RECONCILED", result.stdout)
        self.assertFalse(self.runtime_dir.exists())

    def test_helper_blocks_different_tables_without_state(self):
        self.table_dir.mkdir(parents=True)
        self.table_tsv.write_text("old\tお\n", encoding="utf-8")
        original = self.table_tsv.read_bytes()
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("initial_contents_differ", result.stdout + result.stderr)
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertIsNone(self.get_attr())
        self.assertFalse(self.runtime_dir.exists())

    def test_helper_preserves_independent_edit_and_never_persists_log(self):
        self.table_dir.mkdir(parents=True)
        self.table_tsv.write_bytes(self.source_tsv.read_bytes())
        old_hash = hashlib.sha256(self.table_tsv.read_bytes()).hexdigest()
        self.set_attr(STATE_ATTRIBUTE, old_hash)
        self.table_tsv.write_text("zx\tざ\n", encoding="utf-8")
        independent = self.table_tsv.read_bytes()
        self.source_tsv.write_text("ca\tか\nke\tけ\n", encoding="utf-8")
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("destination_changed_independently", result.stdout + result.stderr)
        self.assertEqual(self.table_tsv.read_bytes(), independent)
        self.assertEqual(self.get_attr(), old_hash)
        self.assertFalse(self.runtime_dir.exists())
        self.assertNotIn("zx", result.stdout + result.stderr)

    def test_helper_rejects_corrupt_persistent_attribute(self):
        self.table_dir.mkdir(parents=True)
        self.table_tsv.write_text("old\tお\n", encoding="utf-8")
        self.set_attr(STATE_ATTRIBUTE, "invalid")
        original = self.table_tsv.read_bytes()
        self.source_tsv.write_text("ca\tか\nke\tけ\n", encoding="utf-8")
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("state_invalid", result.stdout + result.stderr)
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertEqual(self.get_attr(), "invalid")
        self.assertFalse(self.runtime_dir.exists())

    def test_helper_fails_closed_on_attribute_list_and_read_errors(self):
        self.table_dir.mkdir(parents=True)
        self.table_tsv.write_text("old\tお\n", encoding="utf-8")
        old_hash = hashlib.sha256(self.table_tsv.read_bytes()).hexdigest()
        self.set_attr(STATE_ATTRIBUTE, old_hash)
        self.source_tsv.write_text("ca\tか\nke\tけ\n", encoding="utf-8")
        self.fake_xattr_faults()
        listing = self.run_helper(TEST_XATTR_LIST_FAIL="1")
        reading = self.run_helper(TEST_XATTR_READ_FAIL="1")
        self.assertNotEqual(listing.returncode, 0)
        self.assertNotIn("initial_contents_differ", listing.stdout + listing.stderr)
        self.assertNotEqual(reading.returncode, 0)
        self.assertIn("state_read_failed", reading.stdout + reading.stderr)
        self.assertEqual(self.table_tsv.read_bytes(), b"old\t\xe3\x81\x8a\n")
        self.assertEqual(self.get_attr(), old_hash)

    def test_helper_state_write_failure_recovers_after_atomic_replace(self):
        self.table_dir.mkdir(parents=True)
        self.table_tsv.write_bytes(self.source_tsv.read_bytes())
        old_hash = hashlib.sha256(self.table_tsv.read_bytes()).hexdigest()
        self.set_attr(STATE_ATTRIBUTE, old_hash)
        self.set_attr(KEEP_ATTRIBUTE, "keep")
        self.source_tsv.write_text("ca\tか\nmo\tも\n", encoding="utf-8")
        self.fake_xattr_faults()
        failure = self.run_helper(TEST_XATTR_WRITE_FAIL="1")
        self.assertNotEqual(failure.returncode, 0)
        self.assertIn("state_write_after_replace_failed", failure.stdout + failure.stderr)
        self.assertEqual(self.table_tsv.read_bytes(), self.source_tsv.read_bytes())
        self.assertEqual(self.get_attr(), old_hash)
        retry = self.run_helper()
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertEqual(self.get_attr(), hashlib.sha256(self.source_tsv.read_bytes()).hexdigest())
        self.assertEqual(self.get_attr(KEEP_ATTRIBUTE), "keep")

    def test_helper_readback_failure_is_reported_and_retry_reconciles(self):
        self.table_dir.mkdir(parents=True)
        self.table_tsv.write_bytes(self.source_tsv.read_bytes())
        self.fake_xattr_faults()
        marker = Path(self.tmp.name) / "xattr-wrote"
        failed = self.run_helper(TEST_XATTR_READBACK_FAIL="1", TEST_XATTR_WRITE_MARKER=str(marker))
        self.assertNotEqual(failed.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertEqual(self.get_attr(), hashlib.sha256(self.source_tsv.read_bytes()).hexdigest())
        retry = self.run_helper()
        self.assertEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertEqual(self.get_attr(), hashlib.sha256(self.source_tsv.read_bytes()).hexdigest())

    def test_helper_rejects_mismatched_state_readback(self):
        self.table_dir.mkdir(parents=True)
        self.table_tsv.write_bytes(self.source_tsv.read_bytes())
        self.fake_xattr_faults()
        marker = Path(self.tmp.name) / "xattr-wrote"
        result = self.run_helper(TEST_XATTR_READBACK_MISMATCH="1",
                                 TEST_XATTR_WRITE_MARKER=str(marker))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertEqual(self.table_tsv.read_bytes(), self.source_tsv.read_bytes())
        self.assertEqual(self.get_attr(), hashlib.sha256(self.source_tsv.read_bytes()).hexdigest())
        self.assertFalse(self.runtime_dir.exists())

    def test_helper_atomic_replace_keeps_parent_attributes(self):
        self.table_dir.mkdir(parents=True)
        self.table_tsv.write_text("old\tお\n", encoding="utf-8")
        self.set_attr(STATE_ATTRIBUTE, hashlib.sha256(self.table_tsv.read_bytes()).hexdigest())
        self.set_attr(KEEP_ATTRIBUTE, "keep")
        self.source_tsv.write_text("ca\tか\nko\tこ\n", encoding="utf-8")
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.get_attr(), hashlib.sha256(self.source_tsv.read_bytes()).hexdigest())
        self.assertEqual(self.get_attr(KEEP_ATTRIBUTE), "keep")
        self.assert_no_table_temps()

    def test_invalid_and_missing_source_preserve_destination_and_attribute(self):
        self.table_dir.mkdir(parents=True)
        self.table_tsv.write_bytes(self.source_tsv.read_bytes())
        state = hashlib.sha256(self.table_tsv.read_bytes()).hexdigest()
        self.set_attr(STATE_ATTRIBUTE, state)
        original = self.table_tsv.read_bytes()
        for invalid in (b"", b"one-column\n", b"\xff\xfe"):
            with self.subTest(invalid=invalid):
                self.source_tsv.write_bytes(invalid)
                result = self.run_helper()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.table_tsv.read_bytes(), original)
                self.assertEqual(self.get_attr(), state)
        mode = self.source_tsv.stat().st_mode & 0o777
        self.source_tsv.chmod(0)
        try:
            unreadable = self.run_helper()
        finally:
            self.source_tsv.chmod(mode)
        self.assertNotEqual(unreadable.returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertEqual(self.get_attr(), state)
        self.source_tsv.unlink()
        missing = self.run_helper()
        self.assertNotEqual(missing.returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertEqual(self.get_attr(), state)

    def test_source_change_during_copy_preserves_previous_table_and_state(self):
        self.table_dir.mkdir(parents=True)
        self.table_tsv.write_bytes(self.source_tsv.read_bytes())
        state = hashlib.sha256(self.table_tsv.read_bytes()).hexdigest()
        self.set_attr(STATE_ATTRIBUTE, state)
        self.source_tsv.write_text("ca\tか\nko\tこ\n", encoding="utf-8")
        mutation = Path(self.tmp.name) / "source mutation.tsv"
        mutation.write_text("ca\tか\nki\tき\n", encoding="utf-8")
        self.fake_command("cp", "#!/bin/sh\n"
            'case "$2" in */.custom_input_table.tsv.*) /bin/cp "$@" || exit $?; '
            '/bin/cp "$AZOOKEY_TEST_MUTATION_FILE" "$1" || exit $?; exit 0;; esac\n'
            'exec /bin/cp "$@"\n')
        result = self.run_helper(AZOOKEY_TEST_MUTATION_FILE=str(mutation))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source_changed_during_copy", result.stdout + result.stderr)
        self.assertEqual(self.source_tsv.read_bytes(), mutation.read_bytes())
        self.assertEqual(self.table_tsv.read_bytes(), SAMPLE_TSV.encode())
        self.assertEqual(self.get_attr(), state)
        self.assert_no_table_temps()

    def test_helper_copy_and_atomic_replace_failures_preserve_table_and_state(self):
        self.table_dir.mkdir(parents=True)
        self.table_tsv.write_bytes(self.source_tsv.read_bytes())
        state = hashlib.sha256(self.table_tsv.read_bytes()).hexdigest()
        self.set_attr(STATE_ATTRIBUTE, state)
        self.source_tsv.write_text("ca\tか\nmi\tみ\n", encoding="utf-8")
        self.fake_command("cp", "#!/bin/sh\ncase \"$2\" in */.custom_input_table.tsv.*) [ \"$TEST_FAIL_COPY\" = 1 ] && { printf partial > \"$2\"; exit 74; };; esac\nexec /bin/cp \"$@\"\n")
        copy_failure = self.run_helper(TEST_FAIL_COPY="1")
        self.assertNotEqual(copy_failure.returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), SAMPLE_TSV.encode())
        self.assertEqual(self.get_attr(), state)
        self.assert_no_table_temps()
        self.fake_command("mv", "#!/bin/sh\nlast=\"\"; for arg in \"$@\"; do last=\"$arg\"; done\n[ \"$TEST_FAIL_MV\" = 1 ] && [ \"$last\" = \"$TEST_TARGET\" ] && exit 75\nexec /bin/mv \"$@\"\n")
        replace_failure = self.run_helper(TEST_FAIL_MV="1", TEST_TARGET=str(self.table_tsv))
        self.assertNotEqual(replace_failure.returncode, 0)
        self.assertIn("atomic_replace_failed", replace_failure.stdout + replace_failure.stderr)
        self.assertEqual(self.table_tsv.read_bytes(), SAMPLE_TSV.encode())
        self.assertEqual(self.get_attr(), state)
        self.assert_no_table_temps()

if __name__ == "__main__":
    unittest.main()
