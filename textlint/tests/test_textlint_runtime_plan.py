#!/usr/bin/env python3
"""Runtime再現用textlint setupの契約テスト。"""

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
WRAPPER = DOTFILES_ROOT / "bin" / "textlint"


def executable(path: Path) -> None:
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def snapshot_tree(root: Path) -> dict[str, tuple[str, bytes | str | None]]:
    snapshot: dict[str, tuple[str, bytes | str | None]] = {}

    def visit(directory: Path, relative: Path = Path(".")) -> None:
        entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        for entry in entries:
            entry_path = Path(entry.path)
            entry_relative = relative / entry.name
            key = entry_relative.as_posix()
            if entry.is_symlink():
                snapshot[key] = ("symlink", os.readlink(entry_path))
            elif entry.is_dir(follow_symlinks=False):
                snapshot[key] = ("directory", None)
                visit(entry_path, entry_relative)
            else:
                snapshot[key] = ("file", entry_path.read_bytes())

    visit(root)
    return snapshot


def snapshot_path(path: Path) -> tuple[str, bytes | str | dict[str, tuple[str, bytes | str | None]] | None]:
    """Capture existence, file kind, and contents without following symlinks."""
    if not os.path.lexists(path):
        return ("missing", None)
    if path.is_symlink():
        return ("symlink", os.readlink(path))
    if path.is_dir():
        return ("directory", snapshot_tree(path))
    return ("file", path.read_bytes())


class TextlintRuntimeSetupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory(prefix="textlint-runtime-")
        self.root = Path(self.temp_dir.name) / "dotfiles fixture with spaces"
        self.home = self.root / "home"
        self.fake_bin = self.root / "fake bin"
        self.repo_textlint = self.root / "textlint"
        self.repo_bin = self.root / "bin"
        self.pnpm_log = self.root / "pnpm.log"
        self.npm_log = self.root / "npm.log"
        self.home.mkdir(parents=True)
        self.fake_bin.mkdir(parents=True)
        self.repo_textlint.mkdir(parents=True)
        self.repo_bin.mkdir(parents=True)
        (self.root / "lib").mkdir()
        shutil.copy2(TEXTLINT_DIR / "package.json", self.repo_textlint / "package.json")
        shutil.copy2(TEXTLINT_DIR / "pnpm-lock.yaml", self.repo_textlint / "pnpm-lock.yaml")
        shutil.copy2(TEXTLINT_DIR / ".textlintrc.json", self.repo_textlint / ".textlintrc.json")
        shutil.copy2(TEXTLINT_DIR / "my-prh.yml", self.repo_textlint / "my-prh.yml")
        shutil.copy2(TEXTLINT_DIR / "textlint-setup.sh", self.repo_textlint / "textlint-setup.sh")
        shutil.copy2(DOTFILES_ROOT / "lib" / "common.sh", self.root / "lib" / "common.sh")
        shutil.copy2(WRAPPER, self.repo_bin / "textlint")
        for name in ("fake-pnpm", "fake-node", "fake-npm"):
            shutil.copy2(FIXTURES / name, self.fake_bin / name.removeprefix("fake-"))
        for path in (
            self.repo_textlint / "textlint-setup.sh",
            self.repo_bin / "textlint",
            self.fake_bin / "pnpm",
            self.fake_bin / "node",
            self.fake_bin / "npm",
        ):
            executable(path)
        self.pnpm_log.write_text("", encoding="utf-8")
        self.npm_log.write_text("", encoding="utf-8")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def env(self, **updates: str) -> dict[str, str]:
        return {
            "HOME": str(self.home),
            "PATH": f"{self.fake_bin}:/usr/bin:/bin",
            "FAKE_PNPM_LOG": str(self.pnpm_log),
            "FAKE_NPM_LOG": str(self.npm_log),
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

    def test_builds_runtime_with_manifest_links_and_physical_node_modules(self) -> None:
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        runtime = self.runtime_dir()
        self.assertEqual(
            os.path.realpath(runtime / "package.json"),
            os.path.realpath(self.repo_textlint / "package.json"),
        )
        self.assertTrue((runtime / "package.json").is_symlink())
        self.assertEqual(
            os.path.realpath(runtime / "pnpm-lock.yaml"),
            os.path.realpath(self.repo_textlint / "pnpm-lock.yaml"),
        )
        self.assertTrue((runtime / "pnpm-lock.yaml").is_symlink())
        self.assertTrue((runtime / "node_modules").is_dir())
        self.assertFalse((runtime / "node_modules").is_symlink())
        runtime_binary = runtime / "node_modules" / ".bin" / "textlint"
        self.assertTrue(runtime_binary.is_file())
        self.assertTrue(os.access(runtime_binary, os.X_OK))
        self.assertFalse((self.repo_textlint / "node_modules").exists())

    def test_setup_does_not_touch_preexisting_repo_home_or_shell_settings(self) -> None:
        zprofile = self.home / ".zprofile"
        zprofile.write_text("export EXISTING_SETTING=1\n", encoding="utf-8")
        home_config = self.home / ".textlintrc.json"
        home_config.write_text("user config\n", encoding="utf-8")
        home_prh = self.home / "my-prh.yml"
        home_prh.write_text("user dictionary\n", encoding="utf-8")
        legacy_node_modules = self.repo_textlint / "node_modules"
        legacy_node_modules.mkdir()
        (legacy_node_modules / "legacy-marker").write_text("preserve\n", encoding="utf-8")
        (legacy_node_modules / "nested").mkdir()
        (legacy_node_modules / "nested" / "keep.txt").write_text("keep\n", encoding="utf-8")
        (legacy_node_modules / "nested" / "link").symlink_to("keep.txt")
        protected = {
            "zprofile": zprofile,
            "home_config": home_config,
            "home_prh": home_prh,
            "repo_node_modules": legacy_node_modules,
        }
        before_first_setup = {
            name: snapshot_path(path) for name, path in protected.items()
        }

        first_result = self.run_setup()
        self.assertEqual(first_result.returncode, 0, first_result.stderr)
        after_first_setup = {
            name: snapshot_path(path) for name, path in protected.items()
        }
        self.assertEqual(after_first_setup, before_first_setup)

        before_second_setup = {
            name: snapshot_path(path) for name, path in protected.items()
        }
        second_result = self.run_setup()
        self.assertEqual(second_result.returncode, 0, second_result.stderr)
        after_second_setup = {
            name: snapshot_path(path) for name, path in protected.items()
        }
        self.assertEqual(after_second_setup, before_second_setup)

    def test_frozen_install_is_requested_and_npm_is_not_used(self) -> None:
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        pnpm_log = self.pnpm_log.read_text(encoding="utf-8")
        self.assertIn("ARGC=4", pnpm_log)
        self.assertIn("ARG_0=--dir", pnpm_log)
        self.assertIn(f"ARG_1={self.runtime_dir()}", pnpm_log)
        self.assertIn("ARG_2=install", pnpm_log)
        self.assertIn("ARG_3=--frozen-lockfile", pnpm_log)
        self.assertEqual(self.npm_log.read_text(encoding="utf-8"), "")

    def test_wrapper_forwards_arguments_to_runtime_binary(self) -> None:
        self.assertEqual(self.run_setup().returncode, 0)
        arguments = ["draft with spaces.md", "", "--rule", "value with spaces"]
        result = subprocess.run(
            [str(self.repo_bin / "textlint"), *arguments],
            text=True,
            capture_output=True,
            env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"ARG_COUNT={len(arguments)}", result.stdout)
        self.assertIn("ARG_0=<draft with spaces.md>", result.stdout)
        self.assertIn("ARG_1=<>", result.stdout)
        self.assertIn("ARG_2=<--rule>", result.stdout)
        self.assertIn("ARG_3=<value with spaces>", result.stdout)

    def test_existing_package_manifest_file_is_not_overwritten(self) -> None:
        runtime = self.runtime_dir()
        runtime.mkdir(parents=True)
        (runtime / "package.json").write_text("user file\n", encoding="utf-8")
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((runtime / "package.json").read_text(encoding="utf-8"), "user file\n")

    def test_existing_lockfile_is_not_overwritten(self) -> None:
        runtime = self.runtime_dir()
        runtime.mkdir(parents=True)
        (runtime / "pnpm-lock.yaml").write_text("user lockfile\n", encoding="utf-8")
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            (runtime / "pnpm-lock.yaml").read_text(encoding="utf-8"),
            "user lockfile\n",
        )

    def test_runtime_symlink_is_not_followed(self) -> None:
        runtime_parent = self.home / "Library" / "Application Support" / "dotfiles"
        runtime_parent.mkdir(parents=True)
        target = self.root / "external-runtime"
        target.mkdir()
        (target / "nested").mkdir()
        (target / "nested" / "keep.txt").write_text("external\n", encoding="utf-8")
        (target / "nested" / "link").symlink_to("keep.txt")
        (runtime_parent / "textlint").symlink_to(target, target_is_directory=True)
        before = snapshot_tree(target)
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((runtime_parent / "textlint").is_symlink())
        self.assertEqual(snapshot_tree(target), before)


if __name__ == "__main__":
    unittest.main()
