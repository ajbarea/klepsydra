"""Tests for tidy.py (`fleet tidy`) in a scratch state folder and a scratch briefing repo.
Run: python3 -I fleet/test_tidy.py

The queue, expired and report cases need techne's cleanup.py: TECHNE_CLEANUP, else
~/ajsoftworks/techne. Without it they fail, unless KLEPSYDRA_NO_TECHNE=1 declares its absence."""

import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
NOW = time.mktime(time.strptime("2026-11-20 12:00", "%Y-%m-%d %H:%M"))  # a Friday
DAY = 86400
TECHNE = os.environ.get("TECHNE_CLEANUP") or str(
    Path.home() / "ajsoftworks/techne/plugins/techne/_shared/cleanup.py"
)
HAVE_TECHNE = Path(TECHNE).is_file()
NEEDS_TECHNE = unittest.skipUnless(
    HAVE_TECHNE or os.environ.get("KLEPSYDRA_NO_TECHNE") != "1", "KLEPSYDRA_NO_TECHNE=1"
)


def git(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", *args],
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def age(path: Path, seconds: float) -> None:
    os.utime(path, (NOW - seconds, NOW - seconds))


HEPH = """# Heph resume state

Rewritten at each handoff.

## START HERE (Fri 11-20, 05:2x, Athena -> next)
- the current state
- 05:30 still current

## Role
Heph runs the fleet (undated, from 10-27).

## 10-28 00:40
- 00:41 old work
- 09:00 more old work

## 2026-11-18 06:00 RECOVERY
- 06:10 two days and six hours ago: dropped
- 23:50 late on the 18th: kept
- 00:10 the 19th, after midnight: kept
  a continuation line of it
- 13:00 the 19th: kept

### Sub-section with no date
- 14:00 still the 19th: kept
"""


class Tidy(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.state = self.tmp / "state"
        self.state.mkdir()
        (self.state / "panes.tsv").write_text("")
        self.brief = self.tmp / "brief"
        self.brief.mkdir()
        git(self.brief, "init", "-q")
        (self.brief / "README.md").write_text("# briefing\n")
        (self.brief / "queue.md").write_text("# Queue\n")
        git(self.brief, "add", "-A")
        git(self.brief, "commit", "-qm", "init")
        self.shots = self.tmp / "shots.py"
        self.shots.write_text("raise SystemExit(0)\n")

    def tidy(
        self, *args: str, now: float = NOW, **env: str
    ) -> subprocess.CompletedProcess:
        e = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith(("GIT_", "FLEET_", "BRIEFING_", "TECHNE_"))
        }
        e |= {
            "FLEET_STATE": str(self.state),
            "BRIEFING_DIR": str(self.brief),
            "FLEET_NOW": str(now),
            "FLEET_PRUNE_SHOTS": str(self.shots),
            "TECHNE_CLEANUP": TECHNE,
            "HOME": str(self.tmp),
            "GIT_AUTHOR_NAME": "t",
            "GIT_AUTHOR_EMAIL": "t@t",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@t",
        }
        e |= env
        return subprocess.run(
            [sys.executable, "-I", str(HERE / "tidy.py"), *args],
            capture_output=True,
            text=True,
            env=e,
            timeout=60,
            check=False,
        )

    # --- HEPH.md ------------------------------------------------------------------------

    def heph(self, text: str = HEPH, written: float = 3600) -> Path:
        p = self.state / "HEPH.md"
        p.write_text(text)
        age(p, written)
        return p

    def test_heph_keeps_the_head_start_here_and_the_last_48_hours(self):
        p = self.heph()
        before = p.stat().st_mtime_ns
        r = self.tidy("--apply", "heph")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        kept = p.read_text()
        self.assertIn("Rewritten at each handoff.", kept)
        self.assertIn("- 05:30 still current", kept)
        for line in (
            "late on the 18th",
            "after midnight",
            "a continuation line",
            "13:00 the 19th",
            "14:00 still",
        ):
            self.assertIn(line, kept)
        for line in ("## Role", "old work", "06:10 two days", "## 10-28"):
            self.assertNotIn(line, kept)
        self.assertEqual(
            p.stat().st_mtime_ns, before, "fleet recover reads HEPH.md's time"
        )
        self.assertIn("drops", r.stdout)

    def test_heph_dry_run_changes_nothing(self):
        p = self.heph()
        r = self.tidy("heph")
        self.assertEqual(r.returncode, 0)
        self.assertIn("would drop", r.stdout)
        self.assertEqual(p.read_text(), HEPH)

    def refused(self, text: str, why: str, **kw) -> None:
        p = self.heph(text, **kw)
        r = self.tidy("--apply", "heph")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn(why, r.stdout)
        self.assertEqual(p.read_text(), text)

    def test_heph_refuses_without_start_here(self):
        self.refused(HEPH.replace("## START HERE", "## Now"), "no ## START HERE block")

    def test_heph_refuses_an_undated_log(self):
        self.refused(
            "# H\n## START HERE\n- x\n## Notes\n- y\n",
            "no line in HEPH.md carries a date",
        )

    def test_heph_refuses_a_date_after_today(self):
        self.refused(HEPH + "\n## 2027-03-01 RECOVERY\n- 01:00 x\n", "after today")

    def test_heph_refuses_while_just_written(self):
        self.refused(HEPH, "was written 30 s ago", written=30)

    def test_heph_refuses_while_another_process_has_it_open(self):
        p = self.heph()
        holder = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys,time; f=open(sys.argv[1]); print('ready', flush=True); time.sleep(60)",
                str(p),
            ],
            stdout=subprocess.PIPE,
            text=True,
        )
        try:
            self.assertEqual(holder.stdout.readline().strip(), "ready")
            r = self.tidy("--apply", "heph")
            self.assertEqual(r.returncode, 1, r.stdout)
            self.assertIn(f"open in pid {holder.pid}", r.stdout)
            self.assertEqual(p.read_text(), HEPH)
        finally:
            holder.kill()
            holder.wait()

    def test_heph_that_is_a_link_is_refused(self):
        real = self.tmp / "real.md"
        real.write_text(HEPH)
        (self.state / "HEPH.md").symlink_to(real)
        r = self.tidy("--apply", "heph")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(real.read_text(), HEPH)

    def test_nothing_happens_outside_the_state_folder(self):
        (self.state / "panes.tsv").unlink()
        brief = self.state / "task-gone.src"
        brief.write_text("x")
        age(brief, 30 * DAY)
        r = self.tidy("--apply", "briefs")
        self.assertEqual(r.returncode, 1)
        self.assertIn("not the fleet's state folder", r.stdout)
        self.assertTrue(brief.exists())

    # --- briefs ---------------------------------------------------------------------------

    def test_briefs_of_live_paused_and_recent_agents_stay(self):
        old = 30 * DAY
        names = {
            "task-live.src": old,  # in panes.tsv
            "fresh-live-20261101-0900.src": old,
            "task-paused.src": old,  # paused.tsv names it
            "task-paused2.src": old,  # named only inside the paused row
            "task-recent-finish.src": old,  # finished 2 days ago
            "task-old-finish.src": old,  # finished 9 days ago: goes
            "fresh-gone-20261101-0900-recover.src": old,  # goes
            "fresh-gone.src": old,  # goes
            "task-new.src": 2 * DAY,  # written lately: stays
            "task-mentioned.src": old,  # its path is a panes.tsv field
            "notes.md": old,  # not a brief
        }
        for n, a in names.items():
            (self.state / n).write_text("x")
            age(self.state / n, a)
        s = self.state
        (s / "panes.tsv").write_text(
            f"%1\tlive\t{s}/task-live.src\tsid1\n%2\tother\t{s}/task-mentioned.src\tsid2\n"
        )
        (s / "paused.tsv").write_text(
            f"paused\tPAUSED 11-01: why\nx\tPAUSED: y\t%9\tpaused2\t{s}/task-paused2.src\tsid\n"
        )
        recent = dt.datetime.fromtimestamp(NOW - 2 * DAY).isoformat()
        older = dt.datetime.fromtimestamp(NOW - 9 * DAY).isoformat()
        (s / "finished.tsv").write_text(
            f"%3\trecent-finish\tb\ts\tw\tc\t{recent}\n%4\told-finish\tb\ts\tw\tc\t{older}\n"
        )
        r = self.tidy("--apply", "briefs")
        self.assertEqual(r.returncode, 0, r.stdout)
        left = {p.name for p in s.iterdir()}
        gone = {
            "task-old-finish.src",
            "fresh-gone-20261101-0900-recover.src",
            "fresh-gone.src",
        }
        self.assertEqual(gone & left, set())
        self.assertEqual(set(names) - gone - left, set(), r.stdout)

    def test_a_linked_brief_is_never_followed(self):
        target = self.tmp / "elsewhere.src"
        target.write_text("keep")
        (self.state / "task-link.src").symlink_to(target)
        os.utime(
            self.state / "task-link.src", (NOW - 30 * DAY,) * 2, follow_symlinks=False
        )
        self.tidy("--apply", "briefs")
        self.assertEqual(target.read_text(), "keep")

    # --- archive --------------------------------------------------------------------------

    def test_archive_keeps_what_was_touched_inside_the_week(self):
        arc = self.state / "archive"
        (arc / "old").mkdir(parents=True)
        (arc / "old" / "a.md").write_text("x")
        (arc / "recent").mkdir()
        (arc / "recent" / "b.md").write_text("x")
        (arc / "old.tgz").write_text("x")
        outside = self.tmp / "outside"
        outside.mkdir()
        (outside / "keep.md").write_text("keep")
        (arc / "link").symlink_to(outside)
        for p in (arc / "old" / "a.md", arc / "old", arc / "recent", arc / "old.tgz"):
            age(p, 30 * DAY)
        age(arc / "recent" / "b.md", DAY)
        os.utime(arc / "link", (NOW - 30 * DAY,) * 2, follow_symlinks=False)
        r = self.tidy("--apply", "archive")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(sorted(p.name for p in arc.iterdir()), ["recent"])
        self.assertEqual((outside / "keep.md").read_text(), "keep")

    def test_an_archive_that_is_a_link_is_left_alone(self):
        real = self.tmp / "real-archive"
        real.mkdir()
        (real / "x").write_text("x")
        age(real / "x", 30 * DAY)
        (self.state / "archive").symlink_to(real)
        self.tidy("--apply", "archive")
        self.assertTrue((real / "x").exists())

    # --- the briefing ---------------------------------------------------------------------

    @NEEDS_TECHNE
    def test_queue_drops_done_lines_from_before_this_week(self):
        q = (
            "# Queue\n\n## Running now\n- ✅ **Mon 11-09:** running lines stay\n\n"
            "## Done since 11-09\n"
            "- ✅ **Wed 11-18:** this week stays\n"
            "- ✅ **Sun 11-15:** last week goes\n  its continuation goes too\n"
            "- ✅ undated line stays\n"
            "- ✅ **Mon 11-16:** Monday stays\n"
            "\n## Next\n- 11-01 next items stay\n"
        )
        (self.brief / "queue.md").write_text(q)
        r = self.tidy("--apply", "queue")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        got = (self.brief / "queue.md").read_text()
        self.assertNotIn("last week goes", got)
        self.assertNotIn("its continuation", got)
        for keep in (
            "this week stays",
            "undated line stays",
            "Monday stays",
            "next items stay",
            "running lines stay",
        ):
            self.assertIn(keep, got)
        self.assertIn("## Done since 11-16", got)
        self.assertIn("1 undated lines stay", r.stdout)

    def test_done_files_are_removed_in_one_commit(self):
        (self.brief / "done").mkdir()
        (self.brief / "done" / "2026-W45.md").write_text("x")
        (self.brief / "done" / "README.md").write_text("x")
        git(self.brief, "add", "-A")
        git(self.brief, "commit", "-qm", "done")
        r = self.tidy("--apply", "done")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertFalse((self.brief / "done").exists())
        self.assertIn("Retire done/", git(self.brief, "log", "-1", "--format=%s"))
        self.assertEqual(git(self.brief, "status", "--porcelain"), "")

    def test_done_files_with_edits_are_refused(self):
        (self.brief / "done").mkdir()
        (self.brief / "done" / "2026-W45.md").write_text("x")
        git(self.brief, "add", "-A")
        git(self.brief, "commit", "-qm", "done")
        (self.brief / "done" / "2026-W45.md").write_text("edited")
        r = self.tidy("--apply", "done")
        self.assertEqual(r.returncode, 1)
        self.assertEqual((self.brief / "done" / "2026-W45.md").read_text(), "edited")

    @NEEDS_TECHNE
    def test_expired_removes_what_an_expired_owner_governs(self):
        fm = "---\nowner: heph\nexpires: {}\n---\n"
        files = {
            "review/old/README.md": fm.format("2026-11-01"),
            "review/old/a.png": "x",
            "review/live/README.md": fm.format("2026-12-01"),
            "review/live/b.png": "x",
            "review/note.md": fm.format("2026-11-19"),
            "review/bare.md": "no frontmatter: reported, never deleted",
        }
        for rel, text in files.items():
            (self.brief / rel).parent.mkdir(parents=True, exist_ok=True)
            (self.brief / rel).write_text(text)
        git(self.brief, "add", "-A")
        git(self.brief, "commit", "-qm", "review")
        r = self.tidy("--apply", "expired")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        left = sorted(git(self.brief, "ls-files").split())
        self.assertEqual(
            left,
            [
                "README.md",
                "queue.md",
                "review/bare.md",
                "review/live/README.md",
                "review/live/b.png",
            ],
        )

    @NEEDS_TECHNE
    def test_report_says_what_is_left(self):
        (self.brief / "done").mkdir()
        (self.brief / "done" / "W1.md").write_text("x")
        (self.brief / "review").mkdir()
        (self.brief / "review" / "draft.md").write_text("x")
        git(self.brief, "add", "-A")
        git(self.brief, "commit", "-qm", "x")
        self.heph()
        self.shots.write_text(
            "import sys; print('gh down', file=sys.stderr); raise SystemExit(3)\n"
        )
        out = self.tmp / "report.json"
        r = self.tidy("--report", str(out))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        data = json.loads(out.read_text())
        self.assertEqual(data["shots_rc"], 3)
        self.assertIn("gh down", data["shots_said"])
        self.assertEqual(data["done_files"], 1)
        self.assertIn("review/", data["unowned"])
        self.assertIn("done/", data["unowned"])
        self.assertEqual(data["ts"], int(NOW))
        self.assertGreater(data["heph_bytes"], 0)

    def test_report_without_techne_says_so(self):
        out = self.tmp / "report.json"
        r = self.tidy("--report", str(out), TECHNE_CLEANUP=str(self.tmp / "missing.py"))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(json.loads(out.read_text())["techne"])

    def test_unknown_part_is_refused(self):
        r = self.tidy("everything")
        self.assertEqual(r.returncode, 2)
        self.assertIn("unknown part", r.stderr)


if __name__ == "__main__":
    unittest.main()
