"""Searchセットアップ入口の引数処理と実行順を検証する。"""

from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "search-setup.sh"

MOCK = """#!/bin/sh
line="$(basename "$0")"
for arg in "$@"; do
  line="$line|$arg"
done
printf '%s\\n' "$line" >> "$SEARCH_ENTRYPOINT_CALLS"
"""


class SearchEntrypointTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        self.log = root / "calls.txt"
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for command in ("python3", "bash"):
            path = bin_dir / command
            path.write_text(MOCK, encoding="utf-8")
            path.chmod(0o755)
        self.env = dict(os.environ)
        self.env["PATH"] = str(bin_dir) + os.pathsep + os.environ["PATH"]
        self.env["SEARCH_ENTRYPOINT_CALLS"] = str(self.log)

    def run_setup(self, *args):
        result = subprocess.run(["/bin/bash", str(SCRIPT), *args], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [
            (parts[0], Path(parts[1]).name, parts[2:])
            for line in self.log.read_text().splitlines()
            if (parts := line.split("|"))
        ]

    def test_no_arguments_runs_both_setups(self):
        self.assertEqual(self.run_setup(), [
            ("python3", "search-routes-setup.py", ["--check"]),
            ("bash", "search-preferences-setup.sh", ["--check"]),
            ("bash", "search-preferences-setup.sh", []),
            ("python3", "search-routes-setup.py", []),
        ])

    def test_check_only_never_applies(self):
        self.assertEqual(self.run_setup("--check"), [
            ("python3", "search-routes-setup.py", ["--check", "--check"]),
            ("bash", "search-preferences-setup.sh", ["--check"]),
        ])

    def test_options_forwarded_without_array_expansion(self):
        self.assertEqual(self.run_setup("--config", "/tmp/routes.json", "--support-dir", "/tmp/search"), [
            ("python3", "search-routes-setup.py", ["--check", "--config", "/tmp/routes.json", "--support-dir", "/tmp/search"]),
            ("bash", "search-preferences-setup.sh", ["--check"]),
            ("bash", "search-preferences-setup.sh", []),
            ("python3", "search-routes-setup.py", ["--config", "/tmp/routes.json", "--support-dir", "/tmp/search"]),
        ])


if __name__ == "__main__":
    unittest.main()
