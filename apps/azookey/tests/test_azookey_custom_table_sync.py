#!/usr/bin/env python3
"""HIR-353 contract tests; real macOS plist tools, fake launchctl."""
from __future__ import annotations

import hashlib
import os
import plistlib
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
TABLE_REL = Path(
    "Library/Containers/dev.ensan.inputmethod.azooKeyMac/Data/Library/"
    "Application Support/azooKeyMac/CustomInputTable"
)
SAMPLE_TSV = "ca\tか\nky\tき\n"


@unittest.skipUnless(sys.platform == "darwin", "requires macOS plist tools")
class CustomTableSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hir353 azookey ")
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.repo = base / "fixture dotfiles"
        self.app = self.repo / "apps" / "azookey"
        self.home = base / "home with spaces"
        self.bin = base / "fake bin"
        self.log = base / "launchctl.log"
        self.active = base / "launchctl.active"

        shutil.copytree(APP_SOURCE, self.app)
        (self.repo / "lib").mkdir(parents=True)
        shutil.copy2(COMMON_SOURCE, self.repo / "lib" / "common.sh")
        self.source_dir = self.app / "CustomInputTable"
        self.source_tsv = self.source_dir / "custom_input_table.tsv"
        self.source_dir.mkdir(parents=True, exist_ok=True)
        self.source_tsv.write_text(SAMPLE_TSV, encoding="utf-8")

        self.home.mkdir()
        self.bin.mkdir()
        self.table_dir = self.home / TABLE_REL
        self.table_tsv = self.table_dir / "custom_input_table.tsv"
        self.container_parent = self.table_dir.parent
        self.container_parent.mkdir(parents=True)
        self.launch_agent = self.home / "Library/LaunchAgents/my.azookey.sync.plist"
        self._fake_launchctl()

    def _fake_launchctl(self):
        executable = self.bin / "launchctl"
        executable.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n" "$*" >> "$LAUNCHCTL_TEST_LOG"\n'
            'case "$1" in\n'
            ' print) test -e "$LAUNCHCTL_TEST_ACTIVE" ;;\n'
            ' bootstrap) if test "$LAUNCHCTL_TEST_BOOTSTRAP_FAIL" = 1; then exit 71; fi; : > "$LAUNCHCTL_TEST_ACTIVE" ;;\n'
            ' bootout) if test "$LAUNCHCTL_TEST_BOOTOUT_FAIL" = 1; then exit 72; fi; rm -f "$LAUNCHCTL_TEST_ACTIVE" ;;\n'
            ' *) exit 73 ;;\n'
            'esac\n',
            encoding="utf-8",
        )
        executable.chmod(0o755)

    def env(self, **overrides):
        value = dict(os.environ)
        value.update({
            "HOME": str(self.home),
            "PATH": str(self.bin) + os.pathsep + value.get("PATH", ""),
            "TMPDIR": self.tmp.name,
            "LAUNCHCTL_TEST_LOG": str(self.log),
            "LAUNCHCTL_TEST_ACTIVE": str(self.active),
            "LAUNCHCTL_TEST_BOOTSTRAP_FAIL": "0",
            "LAUNCHCTL_TEST_BOOTOUT_FAIL": "0",
        })
        value.update(overrides)
        return value

    def setup_app(self, **overrides):
        return subprocess.run(
            ["/bin/bash", str(self.app / "azookey-setup.sh")],
            cwd=self.repo, env=self.env(**overrides), capture_output=True,
            text=True, errors="replace", timeout=30,
        )

    def plist(self):
        self.assertTrue(self.launch_agent.is_file(), "setup must install my.azookey.sync")
        with self.launch_agent.open("rb") as stream:
            return plistlib.load(stream)

    def run_sync(self, **overrides):
        return subprocess.run(
            self.plist()["ProgramArguments"], cwd=self.repo, env=self.env(**overrides),
            capture_output=True, text=True, errors="replace", timeout=30,
        )

    def fake_command(self, name, script):
        executable = self.bin / name
        executable.write_text(script, encoding="utf-8")
        executable.chmod(0o755)

    def assert_no_table_temporary_files(self):
        leftovers = [entry.name for entry in self.table_dir.iterdir() if entry != self.table_tsv]
        self.assertEqual(leftovers, [])

    def legacy_link(self):
        self.table_dir.symlink_to(self.source_dir, target_is_directory=True)

    def assert_agent(self):
        value = self.plist()
        self.assertEqual(value["Label"], LABEL)
        self.assertTrue(value["RunAtLoad"])
        self.assertEqual(value["WatchPaths"], [str(self.source_dir)])
        self.assertNotIn("StartInterval", value)
        self.assertNotIn("KeepAlive", value)
        self.assertTrue(Path(value["ProgramArguments"][1]).is_file())
        return value

    def test_expected_link_migrates_to_real_directory_and_watch_agent(self):
        self.legacy_link()
        source = self.source_tsv.read_bytes()

        result = self.setup_app()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.table_dir.is_dir())
        self.assertFalse(self.table_dir.is_symlink())
        self.assertEqual(self.table_tsv.read_bytes(), source)
        self.assertEqual(self.source_tsv.read_bytes(), source)
        self.assertTrue(self.active.exists())
        self.assert_agent()
        state_file = Path(self.plist()["ProgramArguments"][-1])
        self.assertEqual(state_file.read_text().strip(), hashlib.sha256(source).hexdigest())

    def test_unknown_link_target_entry_is_preserved_and_blocks_migration(self):
        self.legacy_link()
        extra = self.source_dir / "unexpected.txt"
        extra.write_text("keep\n", encoding="utf-8")

        result = self.setup_app()

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.table_dir.is_symlink())
        self.assertEqual(extra.read_text(encoding="utf-8"), "keep\n")
        self.assertFalse(self.active.exists())

    def test_conflicting_real_container_data_is_preserved(self):
        self.table_dir.mkdir()
        self.table_tsv.write_text("old\tお\n", encoding="utf-8")
        extra = self.table_dir / "other-data"
        extra.write_text("keep\n", encoding="utf-8")

        result = self.setup_app()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.table_tsv.read_text(encoding="utf-8"), "old\tお\n")
        self.assertEqual(extra.read_text(encoding="utf-8"), "keep\n")
        self.assertFalse(self.active.exists())

    def test_dotfiles_change_syncs_once_then_identical_run_is_noop(self):
        self.legacy_link()
        setup = self.setup_app()
        self.assertEqual(setup.returncode, 0, setup.stderr)
        self.assert_agent()
        self.source_tsv.write_text("ca\tか\nku\tく\n", encoding="utf-8")

        changed = self.run_sync()
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertEqual(self.table_tsv.read_text(encoding="utf-8"), "ca\tか\nku\tく\n")
        state_file = Path(self.plist()["ProgramArguments"][-1])
        self.assertEqual(state_file.read_text().strip(), hashlib.sha256(self.source_tsv.read_bytes()).hexdigest())
        inode = self.table_tsv.stat().st_ino
        mtime = self.table_tsv.stat().st_mtime_ns

        unchanged = self.run_sync()

        self.assertEqual(unchanged.returncode, 0, unchanged.stderr)
        self.assertEqual(self.table_tsv.stat().st_ino, inode)
        self.assertEqual(self.table_tsv.stat().st_mtime_ns, mtime)

    def test_independent_container_edit_is_preserved_and_stops_sync(self):
        self.legacy_link()
        setup = self.setup_app()
        self.assertEqual(setup.returncode, 0, setup.stderr)
        self.assert_agent()
        state_file = Path(self.plist()["ProgramArguments"][-1])
        old_state = state_file.read_bytes()
        independent = "zx\tざ\n"
        self.table_tsv.write_text(independent, encoding="utf-8")
        self.source_tsv.write_text("ca\tか\nke\tけ\n", encoding="utf-8")

        result = self.run_sync()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.table_tsv.read_text(encoding="utf-8"), independent)
        self.assertEqual(state_file.read_bytes(), old_state)
        self.assertNotIn("か", result.stdout + result.stderr)
        self.assertNotIn("け", result.stdout + result.stderr)

    def test_empty_malformed_and_non_utf8_source_preserve_destination(self):
        self.legacy_link()
        setup = self.setup_app()
        self.assertEqual(setup.returncode, 0, setup.stderr)
        self.assert_agent()
        original = self.table_tsv.read_bytes()

        for invalid in (b"", b"one-column\n", b"\xff\xfe"):
            with self.subTest(invalid=invalid):
                self.source_tsv.write_bytes(invalid)
                result = self.run_sync()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.table_tsv.read_bytes(), original)

    def test_missing_source_preserves_destination_and_state(self):
        self.legacy_link()
        setup = self.setup_app()
        self.assertEqual(setup.returncode, 0, setup.stderr)
        state_file = Path(self.assert_agent()["ProgramArguments"][-1])
        original = self.table_tsv.read_bytes()
        old_state = state_file.read_bytes()
        self.source_tsv.unlink()

        result = self.run_sync()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertEqual(state_file.read_bytes(), old_state)
        self.assert_no_table_temporary_files()

    def test_unreadable_source_preserves_destination_and_state(self):
        self.legacy_link()
        setup = self.setup_app()
        self.assertEqual(setup.returncode, 0, setup.stderr)
        state_file = Path(self.assert_agent()["ProgramArguments"][-1])
        original = self.table_tsv.read_bytes()
        old_state = state_file.read_bytes()
        self.source_tsv.write_text("ca\tか\nnu\tぬ\n", encoding="utf-8")
        original_mode = self.source_tsv.stat().st_mode & 0o777
        self.source_tsv.chmod(0)
        try:
            result = self.run_sync()
        finally:
            self.source_tsv.chmod(original_mode)

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertEqual(state_file.read_bytes(), old_state)
        self.assert_no_table_temporary_files()

    def test_missing_or_corrupt_sync_state_cannot_replace_destination(self):
        self.legacy_link()
        setup = self.setup_app()
        self.assertEqual(setup.returncode, 0, setup.stderr)
        arguments = self.assert_agent()["ProgramArguments"]
        state_file = Path(arguments[-1])
        original = self.table_tsv.read_bytes()

        state_file.write_text("corrupt\n", encoding="utf-8")
        self.source_tsv.write_text("ca\tか\nko\tこ\n", encoding="utf-8")
        corrupt = self.run_sync()
        self.assertNotEqual(corrupt.returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), original)

        state_file.unlink()
        missing = self.run_sync()
        self.assertNotEqual(missing.returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), original)

    def test_launchagent_failure_does_not_discard_source_or_table(self):
        self.legacy_link()
        original = self.source_tsv.read_bytes()

        result = self.setup_app(LAUNCHCTL_TEST_BOOTSTRAP_FAIL="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.source_tsv.read_bytes(), original)
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertFalse(self.active.exists())
        self.assertNotIn("Registered ", result.stdout)


    def test_repeated_setup_keeps_the_migrated_table_and_avoids_replacing_it(self):
        self.legacy_link()
        first = self.setup_app()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertFalse(self.table_dir.is_symlink())
        inode = self.table_tsv.stat().st_ino
        mtime = self.table_tsv.stat().st_mtime_ns

        second = self.setup_app()

        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.table_tsv.stat().st_ino, inode)
        self.assertEqual(self.table_tsv.stat().st_mtime_ns, mtime)
        self.assertEqual(self.table_tsv.read_text(encoding="utf-8"), SAMPLE_TSV)

    def test_copy_failure_preserves_previous_destination_state_and_cleans_up(self):
        self.legacy_link()
        setup = self.setup_app()
        self.assertEqual(setup.returncode, 0, setup.stderr)
        state_file = Path(self.assert_agent()["ProgramArguments"][-1])
        original = self.table_tsv.read_bytes()
        old_state = state_file.read_bytes()
        self.source_tsv.write_text("ca\tか\nmi\tみ\n", encoding="utf-8")
        self.fake_command(
            "cp",
            "#!/bin/sh\n"
            'if [ "$AZOOKEY_TEST_COPY_FAIL" = 1 ]; then\n'
            '  printf partial > "$2"\n'
            "  exit 74\n"
            "fi\n"
            'exec /bin/cp "$@"\n',
        )

        result = self.run_sync(AZOOKEY_TEST_COPY_FAIL="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertEqual(state_file.read_bytes(), old_state)
        self.assert_no_table_temporary_files()

    def test_replace_failure_preserves_previous_destination_state_and_cleans_up(self):
        self.legacy_link()
        setup = self.setup_app()
        self.assertEqual(setup.returncode, 0, setup.stderr)
        state_file = Path(self.assert_agent()["ProgramArguments"][-1])
        original = self.table_tsv.read_bytes()
        old_state = state_file.read_bytes()
        self.source_tsv.write_text("ca\tか\nmi\tみ\n", encoding="utf-8")
        self.fake_command(
            "mv",
            "#!/bin/sh\n"
            'last=""\n'
            'for arg in "$@"; do last="$arg"; done\n'
            'if [ "$AZOOKEY_TEST_REPLACE_FAIL" = 1 ] && [ "$last" = "$AZOOKEY_TEST_REPLACE_TARGET" ]; then\n'
            "  exit 75\n"
            "fi\n"
            'exec /bin/mv "$@"\n',
        )

        result = self.run_sync(
            AZOOKEY_TEST_REPLACE_FAIL="1",
            AZOOKEY_TEST_REPLACE_TARGET=str(self.table_tsv),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertEqual(state_file.read_bytes(), old_state)
        self.assert_no_table_temporary_files()

    def test_state_write_failure_is_reconciled_on_next_equal_sync(self):
        self.legacy_link()
        setup = self.setup_app()
        self.assertEqual(setup.returncode, 0, setup.stderr)
        state_file = Path(self.assert_agent()["ProgramArguments"][-1])
        old_state = state_file.read_bytes()
        self.source_tsv.write_text("ca\tか\nmo\tも\n", encoding="utf-8")
        runtime_dir = state_file.parent
        old_mode = runtime_dir.stat().st_mode & 0o777
        runtime_dir.chmod(old_mode & ~0o222)
        try:
            failed_state_write = self.run_sync()
        finally:
            runtime_dir.chmod(old_mode)

        self.assertNotEqual(failed_state_write.returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), self.source_tsv.read_bytes())
        self.assertEqual(state_file.read_bytes(), old_state)

        reconciled = self.run_sync()

        self.assertEqual(reconciled.returncode, 0, reconciled.stderr)
        self.assertEqual(state_file.read_text().strip(), hashlib.sha256(self.source_tsv.read_bytes()).hexdigest())

    def test_readme_explains_stop_and_restore_before_git_review(self):
        readme = (self.app / "README.md").read_text(encoding="utf-8")
        self.assertIn("停止", readme)
        self.assertIn("復元", readme)
        self.assertIn("launchctl bootout", readme)
        self.assertIn("CustomInputTable", readme)
        self.assertIn("git diff", readme)



if __name__ == "__main__":
    unittest.main()
