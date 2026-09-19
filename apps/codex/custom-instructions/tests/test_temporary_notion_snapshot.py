#!/usr/bin/env python3
"""HIR-278: integration contracts for ephemeral Notion sync snapshots.

The helper and Notion CLI are controlled fakes. Actual App Sandbox,
security-scoped bookmarks, LaunchAgent and authenticated Notion are NOT tested.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SYNC_SCRIPT = Path(__file__).resolve().parent.parent / "sync-custom-instructions"
CUSTOM_ID = "2" * 32
PROFILE_ID = "3" * 32
SOURCE_ID = "4" * 32


class TemporarySnapshotContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="hir-278-snapshot-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "harness" / "custom-instructions"
        self.skills = self.root / "harness" / "skills"
        self.support = self.root / "support"
        self.mirrors = self.support / "mirrors"
        self.config = self.support / "notion-pages.conf"
        self.codex = self.root / "codex"
        self.pages = self.root / "pages"
        self.events = self.root / "events"
        for path in (self.source, self.skills / "example", self.skills / "writing-references",
                     self.mirrors, self.codex, self.pages):
            path.mkdir(parents=True, exist_ok=True)
        self.write_sources("v1")
        (self.skills / "example" / "SKILL.md").write_text(
            "---\nname: example\nnotion_sync: true\n---\n# example\n", encoding="utf-8")
        (self.skills / "writing-references" / "guide.md").write_text(
            "---\nname: guide\nnotion_sync: false\n---\n# guide\n", encoding="utf-8")
        self.config.write_text(
            "workspace_id=" + "1" * 32 + "\n"
            "custom_instructions_page_id=" + CUSTOM_ID + "\n"
            "user_profile_page_id=" + PROFILE_ID + "\n"
            "skills_data_source_id=" + SOURCE_ID + "\n", encoding="ascii")
        self.helper = self.root / "helper"
        self.helper.write_text(FAKE_HELPER, encoding="utf-8")
        self.helper.chmod(0o700)
        self.notion = self.root / "ntn"
        self.notion.write_text(FAKE_NOTION, encoding="utf-8")
        self.notion.chmod(0o700)
        self.query = self.root / "query.json"
        self.query.write_text(json.dumps({"results": [{
            "object": "page", "id": "page-example",
            "properties": {"Codex ID": {"rich_text": [{"plain_text": "example"}]}}
        }], "has_more": False}), encoding="utf-8")
        self.env = dict(os.environ, FAKE_SOURCE=str(self.source),
                        FAKE_SKILLS=str(self.skills), FAKE_MIRRORS=str(self.mirrors),
                        FAKE_CODEX=str(self.codex), FAKE_PAGES=str(self.pages),
                        FAKE_QUERY=str(self.query), FAKE_EVENTS=str(self.events),
                        NOTION_SYNC_MIRROR_ROOT_OVERRIDE=str(self.mirrors),
                        NOTION_READBACK_WAIT_SECONDS="0")

    def write_sources(self, version):
        for name, content in (
            ("custom-instructions.md", "# custom " + version + "\n"),
            ("openai-instructions.md", "# openai\n"),
            ("user-profile.md", "# profile\n"),
        ):
            (self.source / name).write_text(content, encoding="utf-8")

    def run_sync(self, **extra):
        return subprocess.run([str(SYNC_SCRIPT), str(self.helper), str(self.notion),
                               str(self.codex), str(self.config)],
                              env=dict(self.env, **extra), capture_output=True,
                              text=True, timeout=30)

    def start_sync(self, **extra):
        return subprocess.Popen([str(SYNC_SCRIPT), str(self.helper), str(self.notion),
                                 str(self.codex), str(self.config)],
                                env=dict(self.env, **extra),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def snapshots(self):
        return [p for p in self.mirrors.iterdir() if p.name.startswith("run-")]

    def events_of(self, prefix):
        return [line for line in self.events.read_text().splitlines()
                if line.startswith(prefix)] if self.events.exists() else []

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_deleted_skill_does_not_reappear(self):
        # A deleted source Skill must not be sent again; existing Notion pages
        # are not deleted by synchronization.
        self.assert_ok(self.run_sync())
        expected_custom = (self.source / "custom-instructions.md").read_bytes()
        expected_openai = (self.source / "openai-instructions.md").read_bytes()
        expected_custom += b"\n" + expected_openai
        self.assertEqual((self.pages / (CUSTOM_ID + ".md")).read_bytes(),
                         expected_custom)
        self.assertEqual((self.pages / (PROFILE_ID + ".md")).read_bytes(),
                         (self.source / "user-profile.md").read_bytes())
        self.assertEqual((self.pages / "page-example.md").read_bytes(),
                         (self.skills / "example" / "SKILL.md").read_bytes())

        old_page = self.pages / "page-example.md"
        original_page = old_page.read_bytes()
        edits_before = len(self.events_of("notion:edit-start:page-example"))
        shutil.rmtree(self.skills / "example")
        self.assert_ok(self.run_sync())
        self.assertEqual(len(self.events_of("notion:edit-start:page-example")),
                         edits_before, "a removed Skill was re-sent")
        self.assertEqual(old_page.read_bytes(), original_page,
                         "a removed Skill's Notion page was deleted or modified")
        self.assertEqual(self.snapshots(), [])

    def test_corrupt_legacy_mirror_is_preserved(self):
        # Legacy files are not inputs and unrecognized entries are not deleted.
        old = self.mirrors / "skills-notion-sync"
        old.mkdir()
        (old / "deleted-skill").mkdir()
        (old / "deleted-skill" / "SKILL.md").write_text(
            "---\nname: deleted-skill\nnotion_sync: true\n---\n")
        (old / "foreign").symlink_to(self.root, target_is_directory=True)
        marker = self.root / "unrelated"
        marker.write_text("preserve")
        self.assert_ok(self.run_sync())
        self.assertFalse((self.pages / "page-deleted-skill.md").exists())
        self.assertTrue((old / "foreign").is_symlink())
        self.assertTrue((old / "deleted-skill" / "SKILL.md").exists())
        self.assertEqual(marker.read_text(), "preserve")
        self.assertEqual(self.snapshots(), [])
        self.assertTrue((self.codex / "AGENTS.md").is_file())
        self.assertFalse((self.codex / "AGENTS.md").is_symlink())
        self.assertTrue(self.events_of("helper:snapshot:"))

    def test_readback_failure_preserves_hash_and_cleans_snapshot(self):
        bad = self.run_sync(FAKE_READBACK_MISMATCH="1")
        self.assertNotEqual(bad.returncode, 0, bad.stdout)
        key = hashlib.sha256(b"custom-instructions").hexdigest()
        self.assertFalse((self.support / "state" / (key + ".sha256")).exists())
        self.assertEqual(self.snapshots(), [])
        self.assert_ok(self.run_sync())
        self.assertTrue((self.support / "state" / (key + ".sha256")).exists())

    def test_overlapping_launch_agent_and_manual_sync_are_serialized(self):
        first = self.start_sync(FAKE_PAUSE_EDIT="0.8")
        try:
            deadline = time.monotonic() + 10
            while not self.events_of("notion:edit-start:"):
                self.assertIsNone(first.poll(), "first run stopped before editing")
                self.assertLess(time.monotonic(), deadline, "first run did not edit")
                time.sleep(0.02)
            self.write_sources("v2")
            second = self.start_sync()
            try:
                time.sleep(0.15)
                self.assertEqual(len(self.events_of("helper:snapshot:")), 1,
                                 "second run built a snapshot before acquiring lock")
                out1, err1 = first.communicate(timeout=30)
                self.assertEqual(first.returncode, 0, err1 + out1)
                out2, err2 = second.communicate(timeout=30)
                self.assertEqual(second.returncode, 0, err2 + out2)
            finally:
                if second.poll() is None:
                    second.kill()
                    second.communicate()
        finally:
            if first.poll() is None:
                first.kill()
                first.communicate()
        self.assertIn("custom v2", (self.pages / (CUSTOM_ID + ".md")).read_text())
        custom_snapshot = self.events_of("helper:custom-hash:")
        self.assertEqual(len(custom_snapshot), 2)
        state_key = hashlib.sha256(b"custom-instructions").hexdigest()
        state_hash = (self.support / "state" / (state_key + ".sha256")).read_text().strip()
        self.assertEqual(state_hash, custom_snapshot[-1].split(":")[-1])
        self.assertEqual(self.snapshots(), [])
        count = len(self.events_of("notion:edit-start:"))
        self.assert_ok(self.run_sync())
        self.assertEqual(len(self.events_of("notion:edit-start:")), count,
                         "saved hash incorrectly skipped or repeated a write")

    def test_invalid_authorized_root_stops_before_notion(self):
        other = self.root / "other"
        other.mkdir()
        result = self.run_sync(FAKE_MIRRORS=str(other))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.events_of("notion:edit-start:"), [])
        self.assertEqual(self.snapshots(), [])


FAKE_HELPER = r'''#!/usr/bin/env python3
import hashlib
import os
from pathlib import Path
import sys

src = Path(os.environ["FAKE_SOURCE"])
skills = Path(os.environ["FAKE_SKILLS"])
mirrors = Path(os.environ["FAKE_MIRRORS"])
codex = Path(os.environ["FAKE_CODEX"])
events = Path(os.environ["FAKE_EVENTS"])
def event(value):
    with events.open("a") as stream:
        stream.write(value + "\n")
args = sys.argv[1:]
if args == ["--status"]:
    print("source=" + str(src))
    print("skills=" + str(skills))
    print("output=" + str(codex))
    print("mirror=" + str(mirrors))
elif args == ["--sync"]:
    text = "\n".join((src / name).read_text() for name in (
        "custom-instructions.md", "openai-instructions.md", "user-profile.md"))
    (codex / "AGENTS.md").write_text(text)
    event("helper:sync")
elif len(args) == 2 and args[0] == "--snapshot":
    root = Path(args[1])
    if root.parent != mirrors or not root.is_dir() or root.is_symlink():
        sys.exit(2)
    custom = root / "custom-instructions-sync"
    skill_copy = root / "skills-notion-sync"
    custom.mkdir(mode=0o700)
    skill_copy.mkdir(mode=0o700)
    text = (src / "custom-instructions.md").read_text().rstrip("\n") + "\n\n"
    text += (src / "openai-instructions.md").read_text().rstrip("\n") + "\n"
    (custom / "custom-instructions.md").write_text(text)
    (custom / "user-profile.md").write_bytes((src / "user-profile.md").read_bytes())
    for folder in sorted(skills.iterdir()):
        if folder.is_dir():
            files = [folder / "SKILL.md"] if folder.name != "writing-references" else list(folder.glob("*.md"))
            for file in files:
                if file.is_file():
                    target = skill_copy / folder.name
                    target.mkdir(mode=0o700, exist_ok=True)
                    (target / file.name).write_bytes(file.read_bytes())
                    (target / file.name).chmod(0o600)
    for file in custom.iterdir():
        file.chmod(0o600)
    event("helper:snapshot:" + str(root))
    event("helper:custom-hash:" + hashlib.sha256(text.encode()).hexdigest())
else:
    sys.exit(64)
'''

FAKE_NOTION = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
import time

pages = Path(os.environ["FAKE_PAGES"])
events = Path(os.environ["FAKE_EVENTS"])
args = sys.argv[1:]
def event(value):
    with events.open("a") as stream:
        stream.write(value + "\n")
if args == ["whoami"]:
    print("authenticated")
elif args[:2] == ["datasources", "query"]:
    print(Path(os.environ["FAKE_QUERY"]).read_text())
elif args[:2] == ["pages", "edit"]:
    page = args[2]
    event("notion:edit-start:" + page)
    if page == "2" * 32:
        time.sleep(float(os.environ.get("FAKE_PAUSE_EDIT", "0")))
    (pages / (page + ".md")).write_text(sys.stdin.read())
    event("notion:edit-end:" + page)
elif args[:2] == ["pages", "get"]:
    content = (pages / (args[2] + ".md")).read_text()
    if os.environ.get("FAKE_READBACK_MISMATCH") == "1":
        content = "# deliberately mismatched\n"
    print("---\n---\n" + content)
elif args[0] == "api":
    print(json.dumps({"object":"page", "properties":{}}))
else:
    sys.exit(64)
'''

if __name__ == "__main__":
    unittest.main()
