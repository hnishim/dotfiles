"""HIR-293: dotfiles setupの配置・登録・失敗境界。

外部プログラムlaunchctlは模擬する。macOS固有のplist加工と実登録は
macOS限定のテスト・Local Acceptanceで別途確認する。
"""
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SETUP = ROOT / "launchd" / "weekly-maintenance-setup.sh"


class WeeklyMaintenanceSetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base / "home with spaces"
        (self.home / "Library").mkdir(parents=True)
        self.source = self.base / "source with spaces"
        (self.source / "scripts").mkdir(parents=True)
        (self.source / "launchd").mkdir()
        self.source_script = self.source / "scripts" / "weekly-maintenance.sh"
        self.source_script.write_text("#!/bin/bash\necho version-one\n", encoding="utf-8")
        self.source_plist = self.source / "launchd" / "my.launchd.weekly-maintenance.plist"
        with self.source_plist.open("wb") as stream:
            plistlib.dump({
                "Label": "my.launchd.weekly-maintenance",
                "ProgramArguments": ["/bin/bash", "/source/script.sh", "check"],
            }, stream)
        self.bin = self.base / "fake bin"
        self.bin.mkdir()
        self.log = self.base / "launchctl.log"
        self.fake_command(
            "launchctl",
            '#!/bin/sh\nprintf "%s\\n" "$*" >> "$LAUNCHCTL_TEST_LOG"\n'
            'case "$1" in\n'
            '  print) exit "${PRINT_RC:-1}" ;;\n'
            '  bootout) exit "${BOOTOUT_FAIL:-0}" ;;\n'
            '  bootstrap) exit "${BOOTSTRAP_FAIL:-0}" ;;\nesac\n',
        )
        self.runtime = (
            self.home / "Library" / "Application Support"
            / "my.launchd.weekly-maintenance" / "weekly-maintenance.sh"
        )
        self.target_plist = (
            self.home / "Library" / "LaunchAgents"
            / "my.launchd.weekly-maintenance.plist"
        )

    def fake_command(self, name, content):
        path = self.bin / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def run_setup(self, **extra):
        env = dict(os.environ)
        env.update({
            "HOME": str(self.home),
            "WEEKLY_MAINTENANCE_ROOT": str(self.source),
            "LAUNCHCTL_TEST_LOG": str(self.log),
            "PATH": str(self.bin) + os.pathsep + env.get("PATH", ""),
            "TMPDIR": str(self.base),
        })
        env.update(extra)
        result = subprocess.run(
            ["/bin/bash", str(SETUP)], env=env, cwd=ROOT,
            capture_output=True, text=True, errors="replace", timeout=30,
        )
        calls = self.log.read_text(encoding="utf-8") if self.log.exists() else ""
        return result, calls

    def test_setup_entrypoint_is_registered_once(self):
        text = (ROOT / "setup-macos.sh").read_text(encoding="utf-8")
        self.assertEqual(
            text.count('"launchd/weekly-maintenance-setup.sh"'), 1,
        )

    def test_missing_source_does_not_register(self):
        self.source_script.unlink()
        result, calls = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("bootstrap", calls)
        self.assertFalse(self.runtime.exists())

    def test_failed_copy_does_not_register_or_replace_existing_runtime(self):
        self.runtime.parent.mkdir(parents=True)
        self.runtime.write_text("previous working copy\n", encoding="utf-8")
        self.fake_command("install", "#!/bin/sh\nexit 42\n")
        result, calls = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("bootstrap", calls)
        self.assertEqual(self.runtime.read_text(), "previous working copy\n")

    def test_unusable_plist_cannot_register(self):
        self.source_plist.write_text("not a valid plist\n", encoding="utf-8")
        result, calls = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("bootstrap", calls)
        self.assertFalse(self.target_plist.exists())

    def test_existing_symlink_runtime_directory_is_not_changed(self):
        real_directory = self.base / "unrelated"
        real_directory.mkdir()
        self.runtime.parent.parent.mkdir(parents=True)
        self.runtime.parent.symlink_to(real_directory, target_is_directory=True)
        result, calls = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("bootstrap", calls)
        self.assertEqual(list(real_directory.iterdir()), [])

    @unittest.skipUnless(sys.platform == "darwin", "macOS plist tools required")
    def test_successful_setup_and_repeat_update_the_runtime_copy(self):
        first, calls = self.run_setup()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertIn("bootstrap", calls)
        self.assertEqual(self.runtime.read_text(), self.source_script.read_text())
        with self.target_plist.open("rb") as stream:
            plist = plistlib.load(stream)
        self.assertEqual(
            plist["ProgramArguments"],
            ["/bin/bash", str(self.runtime), "check"],
        )
        self.source_script.write_text("#!/bin/bash\necho version-two\n")
        second, calls = self.run_setup()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.runtime.read_text(), self.source_script.read_text())
        self.assertEqual(calls.count("bootstrap"), 2)


    @unittest.skipUnless(sys.platform == "darwin", "macOS plist tools required")
    def test_bootstrap_failure_is_reported_as_failure(self):
        result, calls = self.run_setup(BOOTSTRAP_FAIL="42")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            [line.split(" ", 1)[0] for line in calls.splitlines()],
            ["print", "bootstrap"],
        )
        self.assertNotIn("Registered ", result.stdout)

    @unittest.skipUnless(sys.platform == "darwin", "macOS plist tools required")
    def test_existing_registration_boots_out_before_bootstrap(self):
        result, calls = self.run_setup(PRINT_RC="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            calls.splitlines(),
            [
                f"print gui/{os.getuid()}/my.launchd.weekly-maintenance",
                f"bootout gui/{os.getuid()}/my.launchd.weekly-maintenance",
                f"bootstrap gui/{os.getuid()} {self.target_plist}",
            ],
        )

    @unittest.skipUnless(sys.platform == "darwin", "macOS plist tools required")
    def test_failed_bootout_prevents_bootstrap(self):
        result, calls = self.run_setup(PRINT_RC="0", BOOTOUT_FAIL="42")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            [line.split(" ", 1)[0] for line in calls.splitlines()],
            ["print", "bootout"],
        )
        self.assertNotIn("Registered ", result.stdout)


if __name__ == "__main__":
    unittest.main()
