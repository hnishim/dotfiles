#!/usr/bin/env python3
'''Contract tests for the textlint PRH dictionary runtime link.'''

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


TEXTLINT_DIR = Path(__file__).resolve().parents[1]
DOTFILES_ROOT = TEXTLINT_DIR.parent
FIXTURES = Path(__file__).resolve().parent / "fixtures"


def make_executable(path: Path) -> None:
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class TextlintPrhRuntimeLinkTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name) / "dotfiles fixture"
        self.home = self.root / "home"
        self.fake_bin = self.root / "fake-bin"
        self.repo_textlint = self.root / "textlint"
        self.pnpm_log = self.root / "pnpm.log"
        self.textlint_log = self.root / "textlint.log"
        self.home.mkdir(parents=True)
        self.fake_bin.mkdir(parents=True)
        self.repo_textlint.mkdir(parents=True)
        (self.root / "lib").mkdir()
        for name in (
            "package.json",
            "pnpm-lock.yaml",
            ".textlintrc.json",
            "my-prh.yml",
            "textlint-setup.sh",
        ):
            shutil.copy2(TEXTLINT_DIR / name, self.repo_textlint / name)
        shutil.copy2(
            DOTFILES_ROOT / "lib" / "common.sh",
            self.root / "lib" / "common.sh",
        )
        for name in ("fake-pnpm", "fake-node"):
            target = self.fake_bin / name.removeprefix("fake-")
            shutil.copy2(FIXTURES / name, target)
            make_executable(target)
        self.pnpm_log.write_text("", encoding="utf-8")
        self.textlint_log.write_text("", encoding="utf-8")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def env(self) -> dict[str, str]:
        return {
            "HOME": str(self.home),
            "PATH": f"{self.fake_bin}:/usr/bin:/bin",
            "FAKE_PNPM_LOG": str(self.pnpm_log),
            "FAKE_TEXTLINT_LOG": str(self.textlint_log),
        }

    def run_setup(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(self.repo_textlint / "textlint-setup.sh")],
            text=True,
            capture_output=True,
            env=self.env(),
        )

    def test_setup_links_home_prh_to_repository_dictionary(self) -> None:
        result = self.run_setup()

        self.assertEqual(result.returncode, 0, result.stderr)
        link = self.home / "my-prh.yml"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), (self.repo_textlint / "my-prh.yml").resolve())

        rerun = self.run_setup()
        self.assertEqual(rerun.returncode, 0, rerun.stderr)
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), (self.repo_textlint / "my-prh.yml").resolve())

    def test_existing_home_prh_conflict_is_preserved_and_setup_fails(self) -> None:
        link = self.home / "my-prh.yml"
        link.write_text("user-owned dictionary\n", encoding="utf-8")

        result = self.run_setup()

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(link.is_symlink())
        self.assertEqual(link.read_text(encoding="utf-8"), "user-owned dictionary\n")


if __name__ == "__main__":
    unittest.main()
