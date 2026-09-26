"""HIR-312: Warp Tab Config setup and safe, idempotent linking contracts.

The tests use a temporary HOME; they do not start Warp or run maintenance.
"""
import os
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SETUP = ROOT / "apps" / "warp" / "warp-setup.sh"
SOURCE = ROOT / "apps" / "warp" / "tab_configs" / "weekly-maintenance.toml"
KEYBINDINGS = ROOT / "apps" / "warp" / "keybindings.yaml"


class WarpWeeklyMaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hir312 home with spaces ")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name) / "home with spaces"
        self.home.mkdir()
        self.warp = self.home / ".warp"
        self.configs = self.warp / "tab_configs"
        self.configs.mkdir(parents=True)
        self.target = self.configs / "weekly-maintenance.toml"
        self.unrelated = self.configs / "unrelated.toml"
        self.unrelated.write_text("preserve this other Warp config\n", encoding="utf-8")

    def run_setup(self):
        env = dict(os.environ, HOME=str(self.home))
        return subprocess.run(
            ["/bin/bash", str(SETUP)], cwd=ROOT, env=env,
            capture_output=True, text=True, timeout=30,
        )

    def test_tab_config_runs_only_the_installed_manual_entry(self):
        with SOURCE.open("rb") as stream:
            config = tomllib.load(stream)
        self.assertEqual(config["name"], "weekly-maintenance")
        self.assertEqual(len(config["panes"]), 1)
        pane = config["panes"][0]
        self.assertEqual(pane["id"], "main")
        self.assertEqual(pane["type"], "terminal")
        commands = pane["commands"]
        self.assertIsInstance(commands, list)
        self.assertEqual(len(commands), 1)
        self.assertEqual(
            commands[0],
            'bash "$HOME/Library/Application Support/my.launchd.weekly-maintenance/weekly-maintenance.sh" run',
        )
        self.assertNotIn("/private/tmp", SOURCE.read_text(encoding="utf-8"))
        self.assertNotIn("hir311_", SOURCE.read_text(encoding="utf-8"))

    def test_setup_links_target_without_changing_other_config_or_keybindings(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.target.is_symlink())
        self.assertEqual(self.target.resolve(), SOURCE.resolve())
        self.assertTrue((self.warp / "keybindings.yaml").is_symlink())
        self.assertEqual((self.warp / "keybindings.yaml").resolve(), KEYBINDINGS.resolve())
        self.assertEqual(self.unrelated.read_text(encoding="utf-8"), "preserve this other Warp config\n")

    def test_setup_is_idempotent(self):
        first = self.run_setup()
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.run_setup()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(self.target.resolve(), SOURCE.resolve())
        self.assertEqual(self.unrelated.read_text(encoding="utf-8"), "preserve this other Warp config\n")

    def test_conflicting_file_fails_without_overwriting(self):
        self.target.write_text("preexisting user's config\n", encoding="utf-8")
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.read_text(encoding="utf-8"), "preexisting user's config\n")
        self.assertEqual(self.unrelated.read_text(encoding="utf-8"), "preserve this other Warp config\n")

    def test_conflicting_symlink_fails_without_repointing(self):
        self.target.symlink_to(self.unrelated)
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.target.resolve(), self.unrelated.resolve())
        self.assertEqual(self.unrelated.read_text(encoding="utf-8"), "preserve this other Warp config\n")


if __name__ == "__main__":
    unittest.main()
