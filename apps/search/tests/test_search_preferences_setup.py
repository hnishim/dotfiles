"""Searchの利用者設定スクリプトをモックしたmacOSコマンドで検証する。"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "search-preferences-setup.sh"

DEFAULTS_MOCK = r'''#!/bin/sh
state="$MOCK_DEFAULTS_STATE"
cmd="$1"; domain="$2"; key="$3"
[ "$domain" = 'com.officecommun.search' ] || exit 2
if [ "$cmd" = 'read' ] || [ "$cmd" = 'read-type' ]; then
  row=$(awk -F '\t' -v k="$key" '$1 == k {print $2 "\t" $3; exit}' "$state")
  [ -n "$row" ] || exit 1
  kind=${row%%$(printf '\t')*}
  value=${row#*$(printf '\t')}
  if [ "$cmd" = 'read' ]; then printf '%s\n' "$value"; exit 0; fi
  case "$kind" in
    -bool) echo 'Type is boolean';;
    -int) echo 'Type is integer';;
    -float) echo 'Type is float';;
    -string) echo 'Type is string';;
  esac
  exit 0
fi
if [ "$cmd" = 'write' ]; then
  flag="$4"; value="$5"
  if [ "$flag" = '-bool' ]; then
    [ "$value" = 'true' ] && value=1 || value=0
  fi
  awk -F '\t' -v k="$key" '$1 != k {print}' "$state" > "$state.tmp"
  printf '%s\t%s\t%s\n' "$key" "$flag" "$value" >> "$state.tmp"
  mv "$state.tmp" "$state"
  exit 0
fi
exit 2
'''


class PreferencesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "prefs.tsv"
        self.state.write_text("unrelated.key\t-int\t5\n")
        tools = self.root / "bin"
        tools.mkdir()
        for name, content in {
            "defaults": DEFAULTS_MOCK,
            "uname": "#!/bin/sh\nprintf 'Darwin\\n'\n",
            "pgrep": "#!/bin/sh\nexit 1\n",
        }.items():
            path = tools / name
            path.write_text(content)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                        MOCK_DEFAULTS_STATE=str(self.state))

    def call(self, *args):
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.env,
                              text=True, capture_output=True)

    def test_dry_run_is_read_only(self):
        before = self.state.read_text()
        result = self.call("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state.read_text(), before)
        self.assertIn("[CHECK]", result.stdout)

    def test_apply_is_idempotent_and_preserves_others(self):
        self.assertEqual(self.call().returncode, 0)
        saved = dict((line.split("\t")[0], line.split("\t")[1:]) for line in self.state.read_text().splitlines())
        self.assertEqual(saved["unrelated.key"], ["-int", "5"])
        self.assertEqual(saved["mail.webmail"], ["-string", "gmail"])
        self.assertEqual(saved["sidebar.width"], ["-float", "176"])
        self.assertEqual(saved["profiles.oneWindow"], ["-bool", "1"])
        self.assertNotIn("spaces.links.rules", saved)
        self.assertNotIn("icloud.sync", saved)
        result = self.call()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("変更: 0 件", result.stdout)
        self.assertEqual(dict((line.split("\t")[0], line.split("\t")[1:]) for line in self.state.read_text().splitlines()), saved)

    def test_running_search_refuses_write(self):
        pgrep = self.root / "bin" / "pgrep"
        pgrep.write_text("#!/bin/sh\nexit 0\n")
        result = self.call()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state.read_text(), "unrelated.key\t-int\t5\n")


if __name__ == "__main__":
    unittest.main()
