"""Tests for digest.py: daily digest generation for Claude Duet.
Run: python3 -I fleet/test_digest.py
"""

from __future__ import annotations

import datetime
import importlib.util
import pathlib
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("digest", HERE / "digest.py")
assert SPEC and SPEC.loader
digest = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(digest)


class TestDigest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.work = pathlib.Path(self.tmp.name)
        self.briefing_dir = self.work / "briefing"
        self.briefing_dir.mkdir(parents=True)
        self.workspace_root = self.work / "workspace"
        self.workspace_root.mkdir(parents=True)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_parse_needs_you_empty(self) -> None:
        items = digest.parse_needs_you(self.briefing_dir)
        self.assertEqual(items, [])

    def test_parse_needs_you_extracts_and_caps(self) -> None:
        content = """# Needs AJ

## Needs you
- ✅ Finished task that should be omitted
- Decision 1 on API design
- Review PR 123
- Reply to email
- Verify benchmark
- Merge release
- Seventh item that should be excluded by 5-item cap

## Notes
- Other section item
"""
        (self.briefing_dir / "needs-you.md").write_text(content, encoding="utf-8")
        items = digest.parse_needs_you(self.briefing_dir, max_items=5)
        self.assertEqual(len(items), 5)
        self.assertEqual(items[0], "Decision 1 on API design")
        self.assertEqual(items[1], "Review PR 123")
        self.assertNotIn("✅ Finished task that should be omitted", items)
        self.assertNotIn("Seventh item that should be excluded by 5-item cap", items)

    def test_parse_running_now(self) -> None:
        content = """# Fleet Queue

## Running now
- 🔄 klepsydra: test-doctor-debounce-392
- ⚡ talks: rehearsal-tts-138
- Random line without icon

## Up next
- 📋 Sphinx docs audit
"""
        (self.briefing_dir / "queue.md").write_text(content, encoding="utf-8")
        running = digest.parse_running_now(self.briefing_dir)
        self.assertEqual(len(running), 2)
        self.assertIn("klepsydra: test-doctor-debounce-392", running[0])
        self.assertIn("talks: rehearsal-tts-138", running[1])

    def test_build_digest_structure(self) -> None:
        (self.briefing_dir / "needs-you.md").write_text(
            "## Needs you\n- Item A\n- Item B\n", encoding="utf-8"
        )
        (self.briefing_dir / "queue.md").write_text(
            "## Running now\n- 🔄 Agent 1: task\n", encoding="utf-8"
        )

        test_now = datetime.datetime(2026, 11, 16, 14, 30, 0)
        md = digest.build_digest(
            briefing_dir=self.briefing_dir,
            workspace_root=self.workspace_root,
            now=test_now,
        )

        self.assertIn("# Fleet Digest: 2026-11-16", md)
        self.assertIn("## Shipped & Merged", md)
        self.assertIn("## Running Now", md)
        self.assertIn("- 🔄 Agent 1: task", md)
        self.assertIn("## What Needs AJ", md)
        self.assertIn("- Item A", md)
        self.assertIn("- Item B", md)
        # Verify no em-dashes
        self.assertNotIn("—", md)

    def test_main_atomic_write(self) -> None:
        target_file = self.briefing_dir / "today.md"
        rc = digest.main(["--out", str(target_file)])
        self.assertEqual(rc, 0)
        self.assertTrue(target_file.is_file())
        text = target_file.read_text(encoding="utf-8")
        self.assertIn("# Fleet Digest:", text)


if __name__ == "__main__":
    unittest.main()
