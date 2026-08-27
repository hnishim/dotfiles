#!/usr/bin/env python3
"""Contract tests for textlint's shared safe symlink API delegation."""

from pathlib import Path
import os
import shutil
import stat
import subprocess
import tempfile
import unittest


SETUP = Path(__file__).resolve().parents[1] / "textlint-setup.sh"


class TextlintSymlinkContractTests(unittest.TestCase):
    def test_manifest_links_use_common_safe_api(self) -> None:
        text = SETUP.read_text(encoding="utf-8")
        calls = [
            line.strip()
            for line in text.splitlines()
            if line.lstrip().startswith("create_symlink ")
        ]
        self.assertEqual(
            len(calls),
            2,
            "EXPECTED_FAIL: textlint manifest links are not using the shared API",
        )
        expected_mappings = {
            'create_symlink "$PACKAGE_JSON" "$RUNTIME_DIR/package.json"',
            'create_symlink "$LOCKFILE" "$RUNTIME_DIR/pnpm-lock.yaml"',
        }
        for mapping in expected_mappings:
            self.assertTrue(
                any(mapping in call for call in calls),
                f"missing source-to-destination mapping: {mapping}",
            )
        for call in calls:
            self.assertRegex(
                call,
                r'^create_symlink "[^"]*" "[^"]*" "[^"]*" \|\| exit 1$',
                "EXPECTED_FAIL: manifest links still use the split/policy API",
            )

    def test_manifest_conflict_preserves_state_and_skips_pnpm(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home"
            fake_bin = root / "bin"
            textlint_dir = root / "textlint"
            runtime_dir = home / "Library" / "Application Support" / "dotfiles" / "textlint"
            home.mkdir(parents=True)
            fake_bin.mkdir()
            textlint_dir.mkdir()
            (root / "lib").mkdir()
            for name in ("package.json", "pnpm-lock.yaml", ".textlintrc.json", "my-prh.yml", "textlint-setup.sh"):
                shutil.copy2(SETUP.parent / name, textlint_dir / name)
            shutil.copy2(SETUP.parents[1] / "lib" / "common.sh", root / "lib" / "common.sh")
            for fixture in ("fake-pnpm", "fake-node"):
                target = fake_bin / fixture.removeprefix("fake-")
                shutil.copy2(SETUP.parent / "tests" / "fixtures" / fixture, target)
                target.chmod(target.stat().st_mode | stat.S_IXUSR)
            runtime_dir.mkdir(parents=True)
            for conflict_name, conflict_contents, untouched_name in (
                ("pnpm-lock.yaml", "preserve-lock\n", "package.json"),
                ("package.json", "preserve-package\n", "pnpm-lock.yaml"),
            ):
                lock = runtime_dir / "pnpm-lock.yaml"
                package = runtime_dir / "package.json"
                for existing in (lock, package):
                    if existing.exists() or existing.is_symlink():
                        existing.unlink()
                conflict = runtime_dir / conflict_name
                conflict.write_text(conflict_contents, encoding="utf-8")
                profile = home / ".zprofile"
                profile.write_text("export KEEP=1\n", encoding="utf-8")
                pnpm_log = root / "pnpm.log"
                pnpm_log.write_text("", encoding="utf-8")

                result = subprocess.run(
                    ["/bin/bash", str(textlint_dir / "textlint-setup.sh")],
                    text=True,
                    capture_output=True,
                    env={
                        "HOME": str(home),
                        "PATH": f"{fake_bin}:/usr/bin:/bin",
                        "FAKE_PNPM_LOG": str(pnpm_log),
                    },
                )
                self.assertNotEqual(result.returncode, 0, result.stderr)
                self.assertEqual(conflict.read_text(encoding="utf-8"), conflict_contents)
                if conflict_name == "package.json":
                    self.assertFalse(os.path.lexists(runtime_dir / untouched_name))
                else:
                    self.assertTrue((runtime_dir / untouched_name).is_symlink())
                    self.assertEqual(
                        Path(os.readlink(runtime_dir / untouched_name)).resolve(),
                        (textlint_dir / untouched_name).resolve(),
                    )
                self.assertEqual(profile.read_text(encoding="utf-8"), "export KEEP=1\n")
                self.assertEqual(pnpm_log.read_text(encoding="utf-8"), "")


if __name__ == "__main__":
    unittest.main()
