#!/usr/bin/env python3
"""HIR-353 contract tests for one-shot sync through azookey-setup.sh."""
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
TABLE_REL = Path(
    "Library/Containers/dev.ensan.inputmethod.azooKeyMac/Data/Library/"
    "Application Support/azooKeyMac/CustomInputTable"
)
RUNTIME_REL = Path("Library/Application Support/my.azookey.sync")
SAMPLE_TSV = "ca\tか\nky\tき\n"
OLD_PLIST = b"preserve legacy LaunchAgent definition\n"


@unittest.skipUnless(sys.platform == "darwin", "requires macOS shell and filesystem behavior")
class CustomTableSyncTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hir353 azookey ")
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
        self.table_dir.parent.mkdir(parents=True)
        self.launch_agent = self.home / "Library/LaunchAgents" / f"{LABEL}.plist"
        self.runtime_dir = self.home / RUNTIME_REL
        self.state_file = self.runtime_dir / "last-synced.sha256"
        self.sync_log = self.runtime_dir / "sync.log"
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
            'esac\n',
            encoding="utf-8",
        )
        command.chmod(0o755)

    def env(self, **overrides):
        value = dict(os.environ)
        value.update({
            "HOME": str(self.home),
            "PATH": str(self.bin) + os.pathsep + value.get("PATH", ""),
            "TMPDIR": self.tmp.name,
            "LAUNCHCTL_TEST_LOG": str(self.launchctl_log),
            "LAUNCHCTL_TEST_ACTIVE": str(self.active_marker),
            "LAUNCHCTL_TEST_BOOTOUT_FAIL": "0",
        })
        value.update(overrides)
        return value

    def run_setup(self, **overrides):
        return subprocess.run(
            ["/bin/bash", str(self.app / "azookey-setup.sh")],
            cwd=self.repo, env=self.env(**overrides), capture_output=True,
            text=True, errors="replace", timeout=30,
        )

    def run_helper(self, **overrides):
        return subprocess.run(
            ["/bin/bash", str(self.sync_script), str(self.source_tsv),
             str(self.table_tsv), str(self.sync_log), str(self.state_file)],
            cwd=self.repo, env=self.env(**overrides), capture_output=True,
            text=True, errors="replace", timeout=30,
        )

    def fake_command(self, name, body):
        path = self.bin / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def legacy_link(self):
        self.table_dir.symlink_to(self.source_dir, target_is_directory=True)

    def install_old_agent(self, loaded):
        self.launch_agent.parent.mkdir(parents=True, exist_ok=True)
        self.launch_agent.write_bytes(OLD_PLIST)
        if loaded:
            self.active_marker.touch()

    def retired_plists(self):
        return sorted(self.runtime_dir.glob(f"{LABEL}.plist.disabled*")) if self.runtime_dir.is_dir() else []

    def assert_no_bootstrap(self):
        lines = self.launchctl_log.read_text().splitlines() if self.launchctl_log.exists() else []
        self.assertFalse(any(line.split(maxsplit=1)[0] == "bootstrap" for line in lines), lines)

    def assert_old_agent_retired(self):
        self.assertFalse(self.launch_agent.exists())
        self.assertFalse(self.active_marker.exists())
        self.assertIn(OLD_PLIST, [path.read_bytes() for path in self.retired_plists()])
        self.assert_no_bootstrap()

    def assert_retired_plist_path_reported(self, result):
        preserved = [path for path in self.retired_plists() if path.read_bytes() == OLD_PLIST]
        self.assertEqual(len(preserved), 1)
        self.assertIn(str(preserved[0]), result.stdout + result.stderr)

    def assert_no_table_temps(self):
        self.assertEqual([p.name for p in self.table_dir.iterdir() if p != self.table_tsv], [])

    def test_existing_setup_migrates_syncs_and_never_registers_agent(self):
        self.legacy_link()
        original = self.source_tsv.read_bytes()
        first = self.run_setup()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertFalse(self.table_dir.is_symlink())
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertEqual(self.state_file.read_text().strip(), hashlib.sha256(original).hexdigest())
        self.assertFalse(self.launch_agent.exists())
        self.source_tsv.write_text("ca\tか\nku\tく\n", encoding="utf-8")

        changed = self.run_setup()
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertEqual(self.table_tsv.read_text(encoding="utf-8"), "ca\tか\nku\tく\n")
        inode, mtime = self.table_tsv.stat().st_ino, self.table_tsv.stat().st_mtime_ns
        unchanged = self.run_setup()
        self.assertEqual(unchanged.returncode, 0, unchanged.stderr)
        self.assertEqual((self.table_tsv.stat().st_ino, self.table_tsv.stat().st_mtime_ns), (inode, mtime))
        self.assert_no_bootstrap()

    def test_large_multibyte_table_syncs_through_setup(self):
        original = "".join(f"k{n:03d}\tか\n" for n in range(866))
        self.source_tsv.write_text(original, encoding="utf-8")
        self.legacy_link()
        first = self.run_setup()
        self.assertEqual(first.returncode, 0, first.stderr)
        updated = "".join(f"k{n:03d}\tき\n" for n in range(866))
        self.source_tsv.write_text(updated, encoding="utf-8")

        second = self.run_setup()

        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.table_tsv.read_text(encoding="utf-8"), updated)
        self.assertEqual(self.state_file.read_text().strip(), hashlib.sha256(updated.encode()).hexdigest())

    def test_setup_initializes_missing_target_directory_without_agent(self):
        result = self.run_setup()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.table_dir.is_dir())
        self.assertFalse(self.table_dir.is_symlink())
        self.assertEqual(self.table_tsv.read_bytes(), self.source_tsv.read_bytes())
        self.assertEqual(self.state_file.read_text().strip(), hashlib.sha256(self.source_tsv.read_bytes()).hexdigest())
        self.assertFalse(self.launch_agent.exists())
        self.assert_no_bootstrap()
        self.assert_no_table_temps()

    def test_setup_initializes_empty_target_directory_without_agent(self):
        self.table_dir.mkdir()

        result = self.run_setup()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.table_dir.is_dir())
        self.assertFalse(self.table_dir.is_symlink())
        self.assertEqual(self.table_tsv.read_bytes(), self.source_tsv.read_bytes())
        self.assertEqual(self.state_file.read_text().strip(), hashlib.sha256(self.source_tsv.read_bytes()).hexdigest())
        self.assertFalse(self.launch_agent.exists())
        self.assert_no_bootstrap()
        self.assert_no_table_temps()

    def test_independent_table_edit_is_preserved_and_blocks_sync(self):
        self.legacy_link()
        self.assertEqual(self.run_setup().returncode, 0)
        old_state = self.state_file.read_bytes()
        self.table_tsv.write_text("zx\tざ\n", encoding="utf-8")
        self.source_tsv.write_text("ca\tか\nke\tけ\n", encoding="utf-8")

        result = self.run_setup()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.table_tsv.read_text(encoding="utf-8"), "zx\tざ\n")
        self.assertEqual(self.state_file.read_bytes(), old_state)
        self.assertNotIn("zx", self.sync_log.read_text(encoding="utf-8"))

    def test_invalid_missing_and_corrupt_state_inputs_preserve_table(self):
        self.legacy_link()
        self.assertEqual(self.run_setup().returncode, 0)
        original, old_state = self.table_tsv.read_bytes(), self.state_file.read_bytes()
        for invalid in (b"", b"one-column\n", b"\xff\xfe"):
            self.state_file.write_bytes(old_state)
            with self.subTest(invalid=invalid):
                self.source_tsv.write_bytes(invalid)
                self.assertNotEqual(self.run_setup().returncode, 0)
                self.assertEqual(self.table_tsv.read_bytes(), original)
                self.assertEqual(self.state_file.read_bytes(), old_state)
        self.source_tsv.write_text("ca\tか\nko\tこ\n", encoding="utf-8")
        self.state_file.write_text("corrupt\n", encoding="utf-8")
        corrupt_state = self.state_file.read_bytes()
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertEqual(self.state_file.read_bytes(), corrupt_state)
        self.state_file.unlink()
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertFalse(self.state_file.exists())

    def test_unreadable_source_preserves_table_and_state(self):
        self.legacy_link()
        self.assertEqual(self.run_setup().returncode, 0)
        original, state = self.table_tsv.read_bytes(), self.state_file.read_bytes()
        mode = self.source_tsv.stat().st_mode & 0o777
        self.source_tsv.chmod(0)
        try:
            result = self.run_setup()
        finally:
            self.source_tsv.chmod(mode)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertEqual(self.state_file.read_bytes(), state)

    def test_missing_source_preserves_table_state_and_temporary_files(self):
        self.legacy_link()
        self.assertEqual(self.run_setup().returncode, 0)
        original, state = self.table_tsv.read_bytes(), self.state_file.read_bytes()
        self.source_tsv.unlink()

        result = self.run_setup()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), original)
        self.assertEqual(self.state_file.read_bytes(), state)
        self.assert_no_table_temps()

    def test_unknown_source_asset_and_conflicting_container_data_are_preserved(self):
        self.legacy_link()
        extra = self.source_dir / "unexpected"
        extra.write_text("keep\n", encoding="utf-8")
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.table_dir.is_symlink())
        self.assertEqual(extra.read_text(), "keep\n")
        extra.unlink()

        self.table_dir.unlink()
        self.table_dir.mkdir()
        self.table_tsv.write_text("old\tお\n", encoding="utf-8")
        other = self.table_dir / "other-data"
        other.write_text("keep\n", encoding="utf-8")
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.table_tsv.read_text(encoding="utf-8"), "old\tお\n")
        self.assertEqual(other.read_text(), "keep\n")

    def test_copy_replace_and_state_failures_preserve_data(self):
        self.legacy_link()
        self.assertEqual(self.run_setup().returncode, 0)
        original, state = self.table_tsv.read_bytes(), self.state_file.read_bytes()
        self.source_tsv.write_text("ca\tか\nmi\tみ\n", encoding="utf-8")
        self.fake_command("cp",
            '#!/bin/sh\ncase "$2" in */.custom_input_table.tsv.*) [ "$TEST_FAIL_COPY" = 1 ] && { printf partial > "$2"; exit 74; };; esac\nexec /bin/cp "$@"\n')
        self.assertNotEqual(self.run_helper(TEST_FAIL_COPY="1").returncode, 0)
        self.assertEqual((self.table_tsv.read_bytes(), self.state_file.read_bytes()), (original, state))
        self.assert_no_table_temps()

        self.fake_command("mv",
            '#!/bin/sh\nlast=""; for arg in "$@"; do last="$arg"; done\n[ "$TEST_FAIL" = 1 ] && [ "$last" = "$TEST_TARGET" ] && exit 75\nexec /bin/mv "$@"\n')
        replace_failure = self.run_helper(TEST_FAIL="1", TEST_TARGET=str(self.table_tsv))
        self.assertNotEqual(replace_failure.returncode, 0)
        self.assertIn("SYNC_BLOCKED atomic_replace_failed", replace_failure.stdout + replace_failure.stderr)
        self.assertEqual((self.table_tsv.read_bytes(), self.state_file.read_bytes()), (original, state))
        self.assert_no_table_temps()

    def test_source_change_during_copy_preserves_previous_table_and_state(self):
        self.legacy_link()
        self.assertEqual(self.run_setup().returncode, 0)
        original, state = self.table_tsv.read_bytes(), self.state_file.read_bytes()
        self.source_tsv.write_text("ca\tか\nko\tこ\n", encoding="utf-8")
        mutation_file = Path(self.tmp.name) / "source mutation.tsv"
        mutation_file.write_text("ca\tか\nki\tき\n", encoding="utf-8")
        self.fake_command(
            "cp",
            '#!/bin/sh\n'
            'case "$2" in */.custom_input_table.tsv.*)\n'
            '  /bin/cp "$@" || exit $?\n'
            '  /bin/cp "$AZOOKEY_TEST_MUTATION_FILE" "$1" || exit $?\n'
            '  exit 0;;\n'
            'esac\n'
            'exec /bin/cp "$@"\n',
        )

        result = self.run_helper(AZOOKEY_TEST_MUTATION_FILE=str(mutation_file))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source_changed_during_copy", result.stdout + result.stderr)
        self.assertEqual(self.source_tsv.read_bytes(), mutation_file.read_bytes())
        self.assertEqual((self.table_tsv.read_bytes(), self.state_file.read_bytes()), (original, state))
        self.assert_no_table_temps()

    def test_state_write_failure_can_be_reconciled(self):
        self.legacy_link()
        self.assertEqual(self.run_setup().returncode, 0)
        old_state = self.state_file.read_bytes()
        self.source_tsv.write_text("ca\tか\nmo\tも\n", encoding="utf-8")
        mode = self.runtime_dir.stat().st_mode & 0o777
        self.runtime_dir.chmod(mode & ~0o222)
        try:
            failure = self.run_helper()
        finally:
            self.runtime_dir.chmod(mode)
        self.assertNotEqual(failure.returncode, 0)
        self.assertEqual(self.table_tsv.read_bytes(), self.source_tsv.read_bytes())
        self.assertEqual(self.state_file.read_bytes(), old_state)
        self.assertEqual(self.run_helper().returncode, 0)
        self.assertEqual(self.state_file.read_text().strip(), hashlib.sha256(self.source_tsv.read_bytes()).hexdigest())

    def test_loaded_legacy_agent_is_stopped_and_retired_with_contents(self):
        self.install_old_agent(loaded=True)
        self.legacy_link()

        result = self.run_setup()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_old_agent_retired()
        self.assert_retired_plist_path_reported(result)
        self.assertTrue(any(line.startswith("bootout ") for line in self.launchctl_log.read_text().splitlines()))
        self.assertTrue(self.table_tsv.is_file())

    def test_unloaded_legacy_plist_is_retired_too(self):
        self.install_old_agent(loaded=False)
        self.legacy_link()

        result = self.run_setup()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_old_agent_retired()
        self.assertFalse(any(line.startswith("bootout ") for line in self.launchctl_log.read_text().splitlines()))

    def test_retirement_collision_preserves_existing_backup_and_uses_unique_name(self):
        self.runtime_dir.mkdir(parents=True)
        occupied = self.runtime_dir / f"{LABEL}.plist.disabled"
        occupied.write_bytes(b"existing backup\n")
        self.install_old_agent(loaded=False)
        self.legacy_link()

        result = self.run_setup()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(occupied.read_bytes(), b"existing backup\n")
        self.assertGreaterEqual(len(self.retired_plists()), 2)
        self.assertIn(OLD_PLIST, [path.read_bytes() for path in self.retired_plists()])
        self.assert_old_agent_retired()
        self.assert_retired_plist_path_reported(result)

    def test_stop_failure_keeps_plist_and_prevents_table_migration(self):
        self.install_old_agent(loaded=True)
        self.legacy_link()

        result = self.run_setup(LAUNCHCTL_TEST_BOOTOUT_FAIL="1")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("停止できない", result.stdout + result.stderr)
        self.assertEqual(self.launch_agent.read_bytes(), OLD_PLIST)
        self.assertTrue(self.active_marker.exists())
        self.assertTrue(self.table_dir.is_symlink())
        self.assertFalse(self.state_file.exists())
        self.assert_no_bootstrap()

    def test_bad_retirement_directory_fails_closed_and_preserves_old_plist(self):
        self.runtime_dir.parent.mkdir(parents=True, exist_ok=True)
        self.runtime_dir.symlink_to(self.home / "elsewhere", target_is_directory=True)
        self.assertTrue(self.runtime_dir.is_symlink())
        self.install_old_agent(loaded=False)
        self.legacy_link()

        result = self.run_setup()

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.launch_agent.read_bytes(), OLD_PLIST)
        self.assertTrue(self.table_dir.is_symlink())
        self.assertFalse(self.state_file.exists())
        self.assertIn("次回ログイン", result.stdout + result.stderr)
        self.assert_no_bootstrap()

    def test_retirement_move_failure_reports_next_login_risk_and_stops_sync(self):
        self.install_old_agent(loaded=True)
        self.legacy_link()
        self.fake_command("mv",
            '#!/bin/sh\nfor arg in "$@"; do [ "$arg" = "$TEST_MOVE_SOURCE" ] && exit 76; done\nexec /bin/mv "$@"\n')

        result = self.run_setup(TEST_MOVE_SOURCE=str(self.launch_agent))

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.launch_agent.read_bytes(), OLD_PLIST)
        self.assertFalse(self.active_marker.exists())
        self.assertTrue(self.table_dir.is_symlink())
        self.assertFalse(self.state_file.exists())
        self.assertIn("次回ログイン", result.stdout + result.stderr)
        self.assert_no_bootstrap()

    def test_later_failure_does_not_restore_or_restart_old_agent(self):
        self.install_old_agent(loaded=True)
        self.table_dir.mkdir()
        self.table_tsv.write_text("user data\t保持\n", encoding="utf-8")
        extra = self.table_dir / "other-data"
        extra.write_text("keep\n", encoding="utf-8")

        result = self.run_setup()

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.launch_agent.exists())
        self.assertFalse(self.active_marker.exists())
        self.assertEqual(self.table_tsv.read_text(encoding="utf-8"), "user data\t保持\n")
        self.assertEqual(extra.read_text(), "keep\n")
        self.assert_old_agent_retired()

    def test_rerun_keeps_backup_and_never_recreates_launchagent(self):
        self.install_old_agent(loaded=True)
        self.legacy_link()
        self.assertEqual(self.run_setup().returncode, 0)
        before = [(path.name, path.read_bytes()) for path in self.retired_plists()]
        self.source_tsv.write_text("ca\tか\nri\tり\n", encoding="utf-8")

        result = self.run_setup()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.table_tsv.read_text(encoding="utf-8"), "ca\tか\nri\tり\n")
        self.assertEqual(before, [(path.name, path.read_bytes()) for path in self.retired_plists()])
        self.assertFalse(self.launch_agent.exists())
        self.assert_no_bootstrap()

    def test_setup_does_not_depend_on_legacy_plist_template(self):
        (self.app / "launchd" / f"{LABEL}.plist").unlink(missing_ok=True)
        self.legacy_link()

        result = self.run_setup()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.table_tsv.read_text(encoding="utf-8"), SAMPLE_TSV)
        self.assertFalse(self.launch_agent.exists())
        self.assert_no_bootstrap()

    def test_readme_documents_existing_command_and_legacy_retirement(self):
        readme = (self.app / "README.md").read_text(encoding="utf-8")
        command = "bash apps/azookey/azookey-setup.sh"
        self.assertGreaterEqual(readme.count(command), 2)
        self.assertIn("手動同期", readme)
        self.assertIn("LaunchAgent", readme)
        self.assertIn("my.azookey.sync.plist.disabled", readme)
        self.assertIn("次回ログイン", readme)
        self.assertIn("退避", readme)
        self.assertNotIn("WatchPaths", readme)
        self.assertNotIn("RunAtLoad", readme)
        self.assertNotIn("launchctl bootstrap", readme)
        self.assertNotIn("azookey-custom-table-sync.sh を実行", readme)


if __name__ == "__main__":
    unittest.main()
