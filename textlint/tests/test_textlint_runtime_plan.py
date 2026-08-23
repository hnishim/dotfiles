#!/usr/bin/env python3
"""Public behavior tests for the managed textlint runtime setup."""

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
CANONICAL_BEGIN = "# BEGIN dotfiles textlint PATH\n"
CANONICAL_END = "# END dotfiles textlint PATH\n"


def make_executable(path: Path) -> None:
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def managed_blocks(text: str) -> list[str]:
    blocks: list[str] = []
    start = 0
    while (begin := text.find(CANONICAL_BEGIN, start)) != -1:
        end = text.find(CANONICAL_END, begin + len(CANONICAL_BEGIN))
        if end == -1:
            break
        end += len(CANONICAL_END)
        blocks.append(text[begin:end])
        start = end
    return blocks


class TextlintRuntimeSetupTests(unittest.TestCase):
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
        for name in ("package.json", "pnpm-lock.yaml", ".textlintrc.json", "my-prh.yml", "textlint-setup.sh"):
            shutil.copy2(TEXTLINT_DIR / name, self.repo_textlint / name)
        shutil.copy2(DOTFILES_ROOT / "lib" / "common.sh", self.root / "lib" / "common.sh")
        for name in ("fake-pnpm", "fake-node"):
            target = self.fake_bin / name.removeprefix("fake-")
            shutil.copy2(FIXTURES / name, target)
            make_executable(target)
        self.pnpm_log.write_text("", encoding="utf-8")
        self.textlint_log.write_text("", encoding="utf-8")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def env(self, **updates: str) -> dict[str, str]:
        return {
            "HOME": str(self.home),
            "PATH": f"{self.fake_bin}:/usr/bin:/bin",
            "FAKE_PNPM_LOG": str(self.pnpm_log),
            "FAKE_TEXTLINT_LOG": str(self.textlint_log),
            **updates,
        }

    def run_setup(self, **updates: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(self.repo_textlint / "textlint-setup.sh")],
            text=True,
            capture_output=True,
            env=self.env(**updates),
        )

    def runtime_dir(self) -> Path:
        return self.home / "Library" / "Application Support" / "dotfiles" / "textlint"

    def test_setup_success_builds_external_runtime_and_executable(self) -> None:
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        binary = self.runtime_dir() / "node_modules" / ".bin" / "textlint"
        self.assertTrue(binary.is_file())
        self.assertTrue(os.access(binary, os.X_OK))
        self.assertFalse((TEXTLINT_DIR / "node_modules").exists())

    def test_success_adds_one_path_block_and_preserves_existing_profile(self) -> None:
        zprofile = self.home / ".zprofile"
        zprofile.write_text("export EXISTING_SETTING=1\n", encoding="utf-8")
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = zprofile.read_text(encoding="utf-8")
        self.assertIn("export EXISTING_SETTING=1\n", text)
        blocks = managed_blocks(text)
        self.assertEqual(len(blocks), 1)
        self.assertIn(
            'export PATH="$HOME/Library/Application Support/dotfiles/textlint/node_modules/.bin:$PATH"\n',
            blocks[0],
        )

    def test_rerun_is_idempotent_and_migrates_old_source_block(self) -> None:
        zprofile = self.home / ".zprofile"
        old_block = (
            CANONICAL_BEGIN
            + 'source "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Dev/dotfiles/shell/dotfiles-path.zsh"\n'
            + CANONICAL_END
        )
        zprofile.write_text("export BEFORE=1\n" + old_block + "export AFTER=1\n", encoding="utf-8")
        first = self.run_setup()
        self.assertEqual(first.returncode, 0, first.stderr)
        text = zprofile.read_text(encoding="utf-8")
        self.assertIn("export BEFORE=1\n", text)
        self.assertIn("export AFTER=1\n", text)
        self.assertNotIn("dotfiles-path.zsh", text)
        self.assertEqual(len(managed_blocks(text)), 1)
        second = self.run_setup()
        self.assertEqual(second.returncode, 0, second.stderr)
        rerun_text = zprofile.read_text(encoding="utf-8")
        self.assertEqual(len(managed_blocks(rerun_text)), 1)
        self.assertIn("export BEFORE=1\n", rerun_text)
        self.assertIn("export AFTER=1\n", rerun_text)
        self.assertNotIn("dotfiles-path.zsh", rerun_text)

    def test_install_or_runtime_failure_leaves_profile_unchanged(self) -> None:
        zprofile = self.home / ".zprofile"
        zprofile.write_text("export KEEP=1\n", encoding="utf-8")

        def assert_profile_preserved() -> None:
            profile_text = zprofile.read_text(encoding="utf-8")
            self.assertIn("export KEEP=1\n", profile_text)
            self.assertEqual(len(managed_blocks(profile_text)), 0)

        failed_install = self.run_setup(FAKE_PNPM_FAIL_AFTER_INSTALL="1")
        self.assertNotEqual(failed_install.returncode, 0)
        assert_profile_preserved()
        failed_version = self.run_setup(FAKE_TEXTLINT_VERSION_FAIL="1")
        self.assertNotEqual(failed_version.returncode, 0)
        assert_profile_preserved()

    def test_legacy_wrappers_are_not_required_or_present(self) -> None:
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((DOTFILES_ROOT / "bin" / "textlint").exists())
        self.assertFalse((DOTFILES_ROOT / "shell" / "dotfiles-path.zsh").exists())


if __name__ == "__main__":
    unittest.main()
