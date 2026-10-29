"""Tests for prune_shots.py with a fake gh and a scratch briefing repo.
Run: python3 -I fleet/test_prune_shots.py"""

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
NOW = time.mktime(time.strptime("2026-10-29", "%Y-%m-%d")) + 12 * 3600

FAKE_GH = """#!/usr/bin/env bash
printf '%s\\n' "$*" >>"$GH_CALLS"
case $1 in
  issue) [[ $2 == list ]] && cat "$GH_ISSUES" ;;
esac
exit 0
"""


def img(path: str) -> str:
    return f'<img src="https://github.com/ajbarea/fleet-briefing/blob/main/shots/{path}?raw=true" width="320">'


class PruneShots(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "brief"
        shots = self.repo / "shots"
        for f in [
            "2026-10-28/a-1-before-dark.png",
            "2026-10-28/a-1-after-dark.png",
            "2026-10-28/b-2-wall-dark.png",
            "2026-10-28/c-3-x.png",
            "2026-10-10/old-9-x.png",
        ]:
            (shots / f).parent.mkdir(parents=True, exist_ok=True)
            (shots / f).write_bytes(b"png")
        (shots / "README.md").write_text(
            "# Screenshots\n\n## 2026-10-10\n\n- old-9-x: a forgotten shot.\n\n## 2026-10-28\n\n"
            "- a-1-{before,after}-dark: judge the before and after.\n"
            "- b-2-wall-dark: judge the wall. https://github.com/x/y/pull/2\n"
            "- **c-3-x**: still open.\n"
            "- Decided in Review #1 and removed.\n"
        )
        g = ["git", "-C", str(self.repo)]
        subprocess.run([*g[:1], "init", "-q", str(self.repo)], check=True)
        subprocess.run([*g, "add", "-A"], check=True)
        subprocess.run(
            [*g, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"],
            check=True,
        )
        gh = self.tmp / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.issues = self.tmp / "issues.json"
        self.calls = self.tmp / "calls"
        self.calls.write_text("")

    def review(
        self, body, comments=(), title="Review: 2026-10-28 screenshots", number=3
    ):
        self.issues.write_text(
            json.dumps(
                [
                    {
                        "number": number,
                        "title": title,
                        "body": body,
                        "comments": [{"body": c} for c in comments],
                    }
                ]
            )
        )

    def run_it(self, *args):
        env = os.environ | {
            "BRIEFING_DIR": str(self.repo),
            "FLEET_GH": str(self.tmp / "gh"),
            "FLEET_STATE": str(self.tmp / "state"),
            "FLEET_NOW": str(NOW),
            "GH_ISSUES": str(self.issues),
            "GH_CALLS": str(self.calls),
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
        }
        out = subprocess.run(
            [sys.executable, "-I", str(HERE / "prune_shots.py"), *args],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout

    BODY = (
        "Tick a box.\n\n## 1. Thing A\n- [x] Looks right\n- [x] Reads right\n\n"
        + img("2026-10-28/a-1-before-dark.png")
        + " "
        + img("2026-10-28/a-1-after-dark.png")
        + "\n\n## 2. Thing B\n- [ ] Looks right\n\n"
        + img("2026-10-28/b-2-wall-dark.png")
        + "\n\n## 3. Thing C\n- [x] ok\n- [ ] also ok\n\n"
        + img("2026-10-28/c-3-x.png")
        + "\n"
    )

    def test_a_dry_run_changes_nothing(self):
        self.review(self.BODY)
        before = (self.repo / "shots/README.md").read_text()
        out = self.run_it()
        self.assertIn(
            "would remove: shots/2026-10-28/a-1-after-dark.png (answered in Review #3 §1)",
            out,
        )
        self.assertIn(
            "would remove: shots/2026-10-10/old-9-x.png (over 14 days old)", out
        )
        self.assertTrue((self.repo / "shots/2026-10-28/a-1-after-dark.png").exists())
        self.assertEqual((self.repo / "shots/README.md").read_text(), before)
        self.assertNotIn("close", self.calls.read_text())

    def test_every_box_ticked_or_routed_removes_that_sections_images(self):
        self.review(
            self.BODY, ["Routed (Heph, 10-29):\n- 2 Thing B: goes to the agent."]
        )
        out = self.run_it("--apply")
        shots = self.repo / "shots"
        gone = sorted(str(p.relative_to(shots)) for p in shots.rglob("*.png"))
        self.assertEqual(gone, ["2026-10-28/c-3-x.png"], out)
        readme = (shots / "README.md").read_text()
        self.assertNotIn("a-1-", readme)
        self.assertNotIn("b-2-", readme)
        self.assertNotIn("old-9-", readme)
        self.assertIn("c-3-x", readme)
        self.assertIn("Decided in Review #1", readme)
        log = subprocess.run(
            ["git", "-C", str(self.repo), "log", "--format=%s", "-1"],
            capture_output=True,
            text=True,
        ).stdout
        self.assertTrue(log.startswith("Shots: remove 4 images"), log)
        self.assertNotIn(
            "issue close", self.calls.read_text(), "section 3 is still open"
        )

    def test_a_section_in_a_comment_counts_and_the_issue_closes_when_all_are_answered(
        self,
    ):
        body = self.BODY.replace("- [ ] Looks right", "- [x] Looks right").replace(
            "- [ ] also ok", "- [x] also ok"
        )
        self.review(body, ["## 4. Late item\n- [x] ok\n"])
        out = self.run_it("--apply")
        self.assertIn("4 of 4 sections answered", out)
        self.assertIn("issue close 3", self.calls.read_text())

    def test_an_issue_that_is_not_a_review_is_ignored(self):
        self.review(self.BODY.replace("- [ ] ", "- [x] "), title="Something else")
        out = self.run_it("--apply")
        self.assertNotIn("answered in", out)
        self.assertTrue((self.repo / "shots/2026-10-28/c-3-x.png").exists())

    def test_an_image_an_open_section_still_shows_is_kept(self):
        # §1 is answered, but §2 (open) compares against the same "before" image.
        body = self.BODY.replace(
            img("2026-10-28/b-2-wall-dark.png"),
            img("2026-10-28/b-2-wall-dark.png")
            + " "
            + img("2026-10-28/a-1-before-dark.png"),
        )
        self.review(body)
        out = self.run_it("--apply")
        self.assertNotIn("a-1-before-dark.png", out)
        self.assertTrue((self.repo / "shots/2026-10-28/a-1-before-dark.png").exists())
        self.assertFalse((self.repo / "shots/2026-10-28/a-1-after-dark.png").exists())

    def test_untracked_edited_and_non_image_files_are_never_removed(self):
        shots = self.repo / "shots"
        (shots / "2026-10-10/untracked-old.png").write_bytes(b"png")
        (shots / "2026-10-28/a-1-after-dark.png").write_bytes(b"edited")
        (shots / "2026-10-10/notes.txt").write_text("x")
        g = ["git", "-C", str(self.repo)]
        subprocess.run([*g, "add", "shots/2026-10-10/notes.txt"], check=True)
        subprocess.run(
            [*g, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "n"],
            check=True,
        )
        self.review(self.BODY)
        out = self.run_it("--apply")
        for kept in [
            "2026-10-10/untracked-old.png",
            "2026-10-28/a-1-after-dark.png",
            "2026-10-10/notes.txt",
        ]:
            self.assertTrue((shots / kept).exists(), kept)
            self.assertNotIn(kept, out)
        self.assertFalse((shots / "2026-10-28/a-1-before-dark.png").exists())
        status = subprocess.run(
            [*g, "status", "--porcelain"], capture_output=True, text=True
        ).stdout
        self.assertEqual(
            sorted(status.split("\n")),
            sorted(
                [
                    "",
                    " M shots/2026-10-28/a-1-after-dark.png",
                    "?? shots/2026-10-10/untracked-old.png",
                ]
            ),
        )

    def test_a_failed_commit_removes_nothing_and_says_so(self):
        hook = self.repo / ".git/hooks/pre-commit"
        hook.write_text("#!/bin/sh\necho 'hook says no' >&2\nexit 1\n")
        hook.chmod(0o755)
        subprocess.run(
            ["git", "-C", str(self.repo), "config", "core.hooksPath", str(hook.parent)],
            check=True,
        )
        before = (self.repo / "shots/README.md").read_text()
        self.review(self.BODY)
        env = os.environ | {
            "BRIEFING_DIR": str(self.repo),
            "FLEET_GH": str(self.tmp / "gh"),
            "FLEET_STATE": str(self.tmp / "state"),
            "FLEET_NOW": str(NOW),
            "GH_ISSUES": str(self.issues),
            "GH_CALLS": str(self.calls),
        }
        out = subprocess.run(
            [sys.executable, "-I", str(HERE / "prune_shots.py"), "--apply"],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(out.returncode, 1, out.stderr)
        self.assertIn("prune failed, nothing removed", out.stdout)
        self.assertTrue((self.repo / "shots/2026-10-28/a-1-after-dark.png").exists())
        self.assertEqual((self.repo / "shots/README.md").read_text(), before)
        status = subprocess.run(
            ["git", "-C", str(self.repo), "status", "--porcelain"],
            capture_output=True,
            text=True,
        ).stdout
        self.assertEqual(status, "")
        self.assertNotIn("close", self.calls.read_text())
        log = (self.tmp / "state" / "log").glob("*")
        self.assertTrue(
            any("shots prune failed" in f.read_text() for f in log if f.is_file())
        )

    def test_the_repo_size_is_reported(self):
        self.review("")
        self.assertRegex(self.run_it(), r"briefing repo: \d+ MB\n")


if __name__ == "__main__":
    unittest.main()
