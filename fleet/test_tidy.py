"""Tests for tidy.py (`fleet tidy`) in a scratch state folder and a scratch briefing repo.
Run: python3 -I fleet/test_tidy.py

The queue, expired and report cases need techne's cleanup.py: TECHNE_CLEANUP, else
~/ajsoftworks/techne. Without it they fail, unless KLEPSYDRA_NO_TECHNE=1 declares its absence."""

import atexit
import contextlib
import datetime as dt
import fcntl
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
NOW = time.mktime(time.strptime("2026-11-20 12:00", "%Y-%m-%d %H:%M"))  # a Friday
DAY = 86400
TECHNE = os.environ.get("TECHNE_CLEANUP") or str(
    Path.home() / "ajsoftworks/techne/plugins/techne/_shared/cleanup.py"
)
HAVE_TECHNE = Path(TECHNE).is_file()

# Nothing this suite starts may reach the live fleet: every child, in-process or not, sees a
# gh that records its call and fails, a briefing slug that names no repo, and a shots prune
# that does nothing (a test that needs another sets its own).
SANDBOX = Path(tempfile.mkdtemp(prefix="test-tidy-"))
atexit.register(shutil.rmtree, SANDBOX, ignore_errors=True)
(SANDBOX / "gh").write_text(
    '#!/bin/sh\necho "$@" >> "$(dirname "$0")/gh-calls"\nexit 1\n'
)
(SANDBOX / "gh").chmod(0o755)
(SANDBOX / "shots.py").write_text("raise SystemExit(0)\n")
SAFE_ENV = {
    "FLEET_GH": str(SANDBOX / "gh"),
    "BRIEFING_SLUG": "test/no-such-briefing",
    "FLEET_PRUNE_SHOTS": str(SANDBOX / "shots.py"),
}
os.environ.update(SAFE_ENV)
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

## 2026-11-14 06:00 RECOVERY
- 06:10 six days ago, with a later date below it: dropped
- 22:00 still the 14th: dropped

## 2026-11-15 day
- 06:10 five days ago, but only the 11-18 date sits below it: kept

## 2026-11-18 06:00 RECOVERY
- 06:10 two days and six hours ago: kept, nothing below proves it older
- 23:50 late on the 18th: kept
- 00:10 the 19th, after midnight: kept
  a continuation line of it
- 13:00 the 19th: kept

### Sub-section with no date
- 14:00 still the 19th: kept
"""


# The fixture's cut: its last lines from "## 2026-11-15 day" down stay; above that, only the
# head, START HERE and the undated Role section do.
HEPH_KEEP = len(HEPH.splitlines()) - HEPH.splitlines().index("## 2026-11-15 day")


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
        self, *args: str, now: float = NOW, dry_first: bool = True, **env: str
    ) -> subprocess.CompletedProcess:
        """Run tidy as the fleet does. --apply goes only after a dry run of the same parts
        (the guard tested in test_apply_drops_only_what_the_dry_run_listed)."""
        if "--apply" in args and dry_first:
            self.tidy(
                *(a for a in args if a != "--apply"), now=now, dry_first=False, **env
            )
        e = {
            k: v
            for k, v in os.environ.items()
            if not k.startswith(("GIT_", "FLEET_", "BRIEFING_", "TECHNE_"))
        }
        e |= SAFE_ENV | {
            "FLEET_HEPH_KEEP": str(HEPH_KEEP),
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

    def test_heph_keeps_the_head_start_here_and_its_last_lines(self):
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
            "five days ago",
            "06:10 two days",
        ):
            self.assertIn(line, kept)
        for line in (
            "old work",
            "six days ago",
            "still the 14th",
            "## 10-28",
            "## 2026-11-14",
        ):
            self.assertNotIn(line, kept)
        self.assertIn("## Role", kept)  # an undated section is kept whole
        self.assertIn("Heph runs the fleet (undated, from 10-27).", kept)
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
        r = self.tidy(
            "--apply", "heph"
        )  # its dry run first, so the list gate is passed
        self.assertEqual(r.returncode, 1)
        self.assertIn("heph: refused: HEPH.md is not a regular file", r.stdout)
        self.assertEqual(real.read_text(), HEPH)
        self.assertTrue((self.state / "HEPH.md").is_symlink())

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
            "fresh-paused2-20261101-0900.src": old,  # same agent; the row lists only task-
            "task-recent-finish.src": old,  # finished 2 days ago
            "task-old-finish.src": old,  # finished 9 days ago: goes
            "fresh-gone-20261101-0900-recover.src": old,  # goes
            "fresh-gone.src": old,  # goes
            "task-new.src": 2 * DAY,  # no registry row: waits for a launch
            "fresh-new-20261118-0900.src": 2 * DAY,  # written lately: stays
            "task-mentioned.src": old,  # its path is a panes.tsv field
            "task-unpaused.src": old,  # unpaused.tsv names it
            "fresh-unpaused-20261101-0900.src": old,  # and its fresh brief
            "task-oddtime.src": old,  # finished, with a time that cannot be read
            "fresh-oddtime-20261101-0900.src": old,  # and its fresh brief: kept as recent
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
            "%5\toddtime\tb\ts\tw\tc\tyesterday-ish\n"
            # Each protected agent also finished long ago, so only its protection keeps it.
            + "".join(
                f"%6\t{n}\tb\ts\tw\tc\t{older}\n"
                for n in ("live", "paused", "paused2", "mentioned", "unpaused")
            )
        )
        (s / "unpaused.tsv").write_text("unpaused\tsid\t2026-11-01T00:00:00\n")
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
        (self.state / "fresh-link.src").symlink_to(target)
        os.utime(
            self.state / "fresh-link.src", (NOW - 30 * DAY,) * 2, follow_symlinks=False
        )
        self.tidy("--apply", "briefs")
        self.assertEqual(target.read_text(), "keep")
        self.assertTrue(
            (self.state / "fresh-link.src").is_symlink(), "a link is skipped"
        )

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


def load_tidy(state: Path, brief: Path, now: float = NOW):
    """tidy.py imported in this process, reading STATE, BRIEFING and NOW from the environment."""
    import importlib.util

    keys = ("FLEET_STATE", "BRIEFING_DIR", "FLEET_NOW", "FLEET_HEPH_KEEP")
    old = {k: os.environ.get(k) for k in keys}
    os.environ |= {
        "FLEET_STATE": str(state),
        "BRIEFING_DIR": str(brief),
        "FLEET_NOW": str(now),
        "FLEET_HEPH_KEEP": str(HEPH_KEEP),
    }
    try:
        spec = importlib.util.spec_from_file_location("tidy_t", HERE / "tidy.py")
        assert spec and spec.loader
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    return mod


class ReviewRound1(unittest.TestCase):
    """The shapes and guards the first review found untested (Tidy's fixtures, not its tests)."""

    setUp = Tidy.setUp
    tidy = Tidy.tidy
    heph = Tidy.heph

    def plan(self, text: str, keep_last: int = 2):
        mod = load_tidy(self.state, self.brief)
        return mod.plan_heph(text, keep_last)

    HEAD = "# H\n## START HERE\n- now\n## 2026-11-15 RECOVERY\n- 09:00 old\n"

    def test_an_unreadable_registry_protects_by_refusing(self):
        old = 30 * DAY
        (self.state / "task-parked.src").write_text("x")
        age(self.state / "task-parked.src", old)
        (self.state / "paused.tsv").write_text("parked\tPAUSED: why\n")
        os.chmod(self.state / "paused.tsv", 0)
        try:
            r = self.tidy("--apply", "briefs")
        finally:
            os.chmod(self.state / "paused.tsv", 0o600)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("briefs: refused: paused.tsv:", r.stdout)
        self.assertTrue((self.state / "task-parked.src").exists())
        (self.state / "paused.tsv").unlink()
        (
            self.state / "paused.tsv"
        ).mkdir()  # a folder by that name is no registry either
        r = self.tidy("--apply", "briefs")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertTrue((self.state / "task-parked.src").exists())

    def test_a_held_registry_lock_refuses_the_briefs(self):
        (self.state / "fresh-gone.src").write_text("x")
        age(self.state / "fresh-gone.src", 30 * DAY)
        with open(self.state / ".registry.lock", "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            r = self.tidy("--apply", "briefs", FLEET_REGISTRY_WAIT="0.3")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("the registry lock was held", r.stdout)
        self.assertTrue((self.state / "fresh-gone.src").exists())
        r = self.tidy("--apply", "briefs", FLEET_REGISTRY_WAIT="0.3")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertFalse((self.state / "fresh-gone.src").exists())

    def test_a_later_start_here_is_judged_by_position_alone(self):
        """No date decides: a later START HERE among the kept lines stays, one far above the cut
        goes like any old section, and one just above the cut (START_MARGIN) refuses."""
        mod = load_tidy(self.state, self.brief)

        def doc(gap: int) -> str:  # GAP lines between the later START HERE and the cut
            return (
                "# H\n## START HERE (11-20)\n- top\n## 2026-01-01 log\n"
                + "".join(f"- a {k}\n" for k in range(150 - gap))
                + "## START HERE (12-30 handoff)\n- later\n## 2026-01-02 log\n"
                + "".join(f"- b {k}\n" for k in range(gap))
                + "".join(f"- kept {k}\n" for k in range(5))
            )

        kept, _ = mod.plan_heph(doc(140), 5)  # far above the cut: an old section
        self.assertNotIn("- later\n", kept)
        self.assertIn("- top\n", kept)
        with self.assertRaisesRegex(
            ValueError, "START HERE block just above the kept lines"
        ):
            mod.plan_heph(doc(20), 5)
        # doc(g)'s later block (heading, one line) ends g + 1 lines above the cut: the
        # margin's far edge is where that end first reaches into the START_MARGIN lines.
        with self.assertRaisesRegex(
            ValueError, "START HERE block just above the kept lines"
        ):
            mod.plan_heph(doc(mod.START_MARGIN - 2), 5)
        mod.plan_heph(doc(mod.START_MARGIN - 1), 5)  # one line further up: no refusal
        kept, _ = mod.plan_heph(doc(20), 40)  # among the kept lines: it stays
        self.assertIn("- later\n", kept)
        kept, _ = mod.plan_heph(doc(20), 28)  # it is the first kept line: no refusal
        undated_later = doc(20).replace(
            "## START HERE (12-30 handoff)", "## START HERE"
        )
        kept, _ = mod.plan_heph(undated_later, 5)  # undated: kept whole, so no refusal
        self.assertIn("- later\n", kept)
        self.assertIn("- later\n", kept)

    def test_standing_rules_in_old_sections_stay(self):
        # Shapes from the live HEPH.md, in every case it uses.
        rules = [
            "- 10:00 AJ (STANDING ROUTING): free capacity first",
            "- 10:05 AJ GRANT (10-28, standing until he says otherwise)",
            "- 10:10 AJ RULE (11-01, permanent): the two orchestrators are equal",
            "- 10:15 AJ standing rule: perf #1",
            "- 10:20 (standing for MSR Stage 1)",
            "- 10:25 AJ (BINDING): trust order",
            "- 10:30 binding from 10-28",
        ]
        noise = [
            "- 09:00 old work",
            "- 11:00 a standingdesk note",
            "- 11:05 two outstanding PRs",
        ]
        text = (
            "# H\n## START HERE\n- now\n## 2026-11-10 day\n"
            + "".join(f"{ln}\n" for ln in noise[:1] + rules + noise[1:])
            + "## 2026-11-20 day\n- 09:00 x\n"
        )
        kept, s = self.plan(text)
        for ln in rules:
            self.assertIn(ln + "\n", kept)
        for ln in noise:
            self.assertNotIn(ln + "\n", kept)
        self.assertIn("## 2026-11-10 day\n", kept)
        self.assertEqual(s["standing"], len(rules))

    def test_the_registry_wait_reads_like_lib_sh(self):
        mod = load_tidy(self.state, self.brief)
        for raw, want in (
            (None, 60.0),
            ("", 60.0),
            ("x", 60.0),
            ("nan", 60.0),
            ("inf", 60.0),
            ("-1", 60.0),
            ("0", 0.0),
            ("2.5", 2.5),
        ):
            self.assertEqual(mod.wait_seconds(raw), want, raw)

    def test_heph_keeps_exactly_its_last_lines(self):
        mod = load_tidy(self.state, self.brief)
        head = "# H\n## START HERE\n- now\n## 2026-11-01 log\n"
        body = [f"- line {k}\n" for k in range(10)]
        for keep in (1, 4, 10, 50):
            kept, _ = mod.plan_heph(head + "".join(body), keep)
            got = [ln for ln in body if ln in kept]
            self.assertEqual(
                got, body[max(0, len(body) + 4 - keep - 4) :][-keep:], keep
            )
        self.assertEqual(mod.keep_lines(None), 600)
        for raw, want in (("", 600), ("x", 600), ("0", 600), ("-3", 600), ("25", 25)):
            self.assertEqual(mod.keep_lines(raw), want, raw)

    def test_a_section_cut_in_two_keeps_its_heading(self):
        text = "# H\n## START HERE\n- now\n## 2026-11-01 log\n- a\n- b\n- c\n"
        kept, _ = self.plan(text, keep_last=2)
        self.assertEqual(
            "".join(kept), "# H\n## START HERE\n- now\n## 2026-11-01 log\n- b\n- c\n"
        )

    def test_the_last_lines_stay_even_above_start_here(self):
        text = "# H\n## 2026-11-20 09:00 note above\n- AJ: newest order\n## START HERE\n- now\n"
        kept, _ = self.plan(text, keep_last=600)
        self.assertEqual("".join(kept), text)

    def test_an_undated_section_is_read_from_its_heading_alone(self):
        """Only a ## heading opens or ends a kept-whole section, by its text, never a clock."""
        mod = load_tidy(self.state, self.brief)
        text = (
            "# H\n## START HERE\n- now\n## Rules\n- r1\n### 11-15 additions\n- r2\n"
            "## Limits: at most 10-12 PRs\n- l1\n## Typo 2026-02-30 notes\n- t1\n## 2026-11-19 log\n- x\n"
        )
        got = "".join(mod.plan_heph(text, 1)[0])  # no clock is read at all
        self.assertIn("- r1\n### 11-15 additions\n- r2\n", got)
        self.assertNotIn("- l1\n", got)  # a date-shaped heading: by position
        self.assertNotIn("- t1\n", got)  # even one that is no real date

    def test_odd_line_breaks_never_shift_the_kept_lines(self):
        """Heph's review r4: split at \\n alone, so a form feed, U+2028 or a lone \\r inside a
        line never turns one line into two and pushes a newest line past the cut."""
        mod = load_tidy(self.state, self.brief)
        head = "# H\n## START HERE\n- now\n## 2026-11-01 log\n"
        for odd in ("\x0c", "\u2028", "\x85", "\r", "\v"):
            with self.subTest(odd=repr(odd)):
                text = head + "- old\n" + f"- a{odd}b{odd}c\n" + "- newest order\n"
                kept, _ = mod.plan_heph(text, 2)
                self.assertEqual(kept[-2:], [f"- a{odd}b{odd}c\n", "- newest order\n"])
                self.assertNotIn("- old\n", kept)

    def test_crlf_lines_are_kept_byte_for_byte(self):
        text = HEPH.replace("\n", "\r\n")
        p = self.state / "HEPH.md"
        p.write_bytes(text.encode())
        age(p, 3600)
        r = self.tidy("--apply", "heph")
        self.assertEqual(r.returncode, 0, r.stdout)
        out = p.read_bytes()
        self.assertTrue(out.endswith(text.encode()[-200:]))
        self.assertNotIn(b"\n", out.replace(b"\r\n", b""))

    def test_the_report_counts_what_a_tidy_would_drop(self):
        self.heph()
        r = self.tidy("--report", str(self.tmp / "r.json"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        got = json.loads((self.tmp / "r.json").read_text())
        _, s = load_tidy(self.state, self.brief).plan_heph(HEPH)
        self.assertEqual(got["heph_drop"], s["lines"] - s["kept"])
        self.assertGreater(got["heph_drop"], 0)
        self.assertTrue(got["heph_due"])  # the fixture drops more than half its keep
        self.tidy("--apply", "heph")
        self.tidy("--report", str(self.tmp / "r.json"))
        self.assertEqual(json.loads((self.tmp / "r.json").read_text())["heph_drop"], 0)

    def test_a_tidy_is_due_only_for_a_batch(self):
        """Heph's review r4 verify: a file that only grows would warn again after one line."""
        head = "# H\n## START HERE\n- now\n## 2026-11-01 log\n"
        for extra, due in ((1, False), (4, False), (5, True)):
            with self.subTest(extra=extra):
                self.heph(head + "".join(f"- l{k}\n" for k in range(10 + extra)))
                r = self.tidy(
                    "--report", str(self.tmp / "r.json"), FLEET_HEPH_KEEP="10"
                )
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                got = json.loads((self.tmp / "r.json").read_text())
                # The section's heading stays with its kept lines.
                self.assertEqual(got["heph_drop"], extra, got)
                self.assertIs(got["heph_due"], due, got)

    def test_the_report_names_a_margin_refusal_only_when_a_batch_is_due(self):
        head = "# H\n## START HERE (11-20)\n- top\n## START HERE (11-10)\n- later\n## 2026-11-01 log\n"
        for extra, due in ((3, False), (30, True)):
            with self.subTest(extra=extra):
                self.heph(head + "".join(f"- l{k}\n" for k in range(extra + 20)))
                self.tidy("--report", str(self.tmp / "r.json"), FLEET_HEPH_KEEP="20")
                got = json.loads((self.tmp / "r.json").read_text())
                self.assertIs(got["heph_due"], due, got)
                self.assertEqual("heph_refused" in got, due, got)

    def test_the_report_names_why_a_tidy_would_refuse(self):
        self.heph("# H\n## Notes\n- x\n")
        self.tidy("--report", str(self.tmp / "r.json"))
        got = json.loads((self.tmp / "r.json").read_text())
        self.assertEqual(got.get("heph_refused"), "HEPH.md has no ## START HERE block")

    def test_an_empty_heading_just_below_the_cut_stays(self):
        text = "# H\n## START HERE\n- now\n## 2026-11-17 old\n- 09:00 x\n## 2026-11-20 just opened\n"
        kept, _ = self.plan(text, keep_last=1)
        self.assertIn("## 2026-11-20 just opened\n", kept)
        self.assertNotIn("- 09:00 x\n", kept)

    def test_start_here_is_found_in_any_case(self):
        """Heph's review r5, S1: the words count in any case, at the top and lower down."""
        for top in ("## Start Here", "## start here", "## START HERE"):
            with self.subTest(top=top):
                kept, _ = self.plan(
                    f"# H\n{top}\n- now\n## 2026-11-01 log\n- a\n- b\n", 1
                )
                self.assertIn("- now\n", kept)

    def test_a_dated_start_here_block_reaching_the_margin_refuses(self):
        """Heph's review r5, N1: the whole block counts, not only its heading."""
        mod = load_tidy(self.state, self.brief)
        body = "".join(f"- old {k}\n" for k in range(200))
        text = (
            "# H\n## START HERE (11-20)\n- top\n## START HERE (11-10)\n"
            + body
            + "".join(f"- new {k}\n" for k in range(50))
        )
        cut = len(text.split("\n")) - 1 - 120  # keep 120: the block straddles the cut
        self.assertLess(
            3, cut - mod.START_MARGIN
        )  # its heading is far above the margin
        with self.assertRaisesRegex(ValueError, "line 4 is a START HERE block"):
            mod.plan_heph(text, 120)

    def test_heph_with_bytes_that_are_no_utf8_plans(self):
        p = self.state / "HEPH.md"
        p.write_bytes(HEPH.encode() + b"- a stray \xff\xfe byte\n")
        age(p, 3600)
        r = self.tidy("heph")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("would drop", r.stdout)
        self.tidy("--report", str(self.tmp / "r.json"))
        got = json.loads((self.tmp / "r.json").read_text())
        self.assertIsNone(got.get("error"), got)
        self.assertGreater(got["heph_drop"], 0, got)

    def test_no_clock_can_drop_the_newest_line(self):
        """Heph's review r3: position alone decides. Whatever FLEET_NOW reads, the last lines
        stay and only lines with that many newer ones below them go."""
        text = (
            "# H\n## START HERE (11-19 06:00)\n- now\n## 2026-11-17 06:50\n- 06:55 a\n"
            "- 07:30 Heph: written Thu 11-19 07:30\n- 07:45 AJ: STOP merging #601 until Ben replies\n"
        )
        for now in (NOW, NOW + 400 * DAY, NOW - 400 * DAY):
            with self.subTest(now=now):
                p = self.heph(text)
                r = self.tidy("--apply", "heph", now=now, FLEET_HEPH_KEEP="2")
                self.assertIn("STOP merging #601", p.read_text())
                if now < NOW:  # the clock behind the file's time: refused, nothing lost
                    self.assertIn("is later than the clock (2025-", r.stdout)
                    self.assertIn("`touch` HEPH.md and run it again", r.stdout)
                    continue
                self.assertEqual(r.returncode, 0, r.stdout)
                self.assertIn("07:30 Heph", p.read_text())
                self.assertNotIn("06:55 a", p.read_text())

    def test_the_report_prunes_the_shots_of_its_own_briefing(self):
        mod = load_tidy(self.state, self.brief)
        seen = self.tmp / "env.txt"
        self.shots.write_text(
            "import os, pathlib\n"
            f"pathlib.Path({str(seen)!r}).write_text(os.environ['BRIEFING_DIR'] + '|' + os.environ['FLEET_STATE'])\n"
        )
        with mock.patch.dict(os.environ, {"FLEET_PRUNE_SHOTS": str(self.shots)}):
            os.environ.pop("BRIEFING_DIR", None)
            with contextlib.redirect_stdout(io.StringIO()):
                mod.report(self.tmp / "report.json")
        self.assertEqual(seen.read_text(), f"{self.brief}|{self.state}")

    def test_the_real_shots_prune_under_the_suite_reaches_no_live_repo(self):
        mod = load_tidy(self.state, self.brief)
        calls = SANDBOX / "gh-calls"
        calls.unlink(missing_ok=True)
        with mock.patch.dict(
            os.environ, {"FLEET_PRUNE_SHOTS": str(HERE / "prune_shots.py")}
        ):
            with contextlib.redirect_stdout(io.StringIO()):
                mod.report(self.tmp / "report.json")
        made = calls.read_text() if calls.exists() else ""
        self.assertIn(
            "issue list -R test/no-such-briefing", made
        )  # it did ask gh, the stub
        self.assertNotIn("ajbarea/fleet-briefing", made)
        self.assertTrue(
            all("test/no-such-briefing" in c for c in made.splitlines()), made
        )

    def test_the_report_keeps_the_last_line_of_a_failed_prune(self):
        mod = load_tidy(self.state, self.brief)
        self.shots.write_text(
            "import sys\nsys.stderr.write('Traceback\\n  ' + 'x' * 400 + '\\nCalledProcessError: gh failed\\n')\nsys.exit(1)\n"
        )
        out = self.tmp / "report.json"
        with (
            mock.patch.dict(os.environ, {"FLEET_PRUNE_SHOTS": str(self.shots)}),
            contextlib.redirect_stdout(io.StringIO()),
        ):
            mod.report(out)
        self.assertEqual(
            json.loads(out.read_text())["shots_said"], "CalledProcessError: gh failed"
        )

    def test_a_queued_task_brief_stays_and_a_finished_one_is_shelved(self):
        s = self.state
        for n in ("task-queued.src", "task-done.src"):
            (s / n).write_text("x")
            age(s / n, 30 * DAY)
        older = dt.datetime.fromtimestamp(NOW - 9 * DAY).isoformat()
        (s / "finished.tsv").write_text(f"%4\tdone\tb\ts\tw\tc\t{older}\n")
        r = self.tidy("--apply", "briefs")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertTrue(
            (s / "task-queued.src").exists(), "a brief waiting to launch stays"
        )
        self.assertFalse((s / "task-done.src").exists())
        shelved = list((s / "archive" / "briefs").glob("task-done.src.tidy-*"))
        self.assertEqual(len(shelved), 1)
        self.assertGreaterEqual(shelved[0].stat().st_mtime, time.time() - 60)
        r = self.tidy("--apply", "archive")
        self.assertTrue(shelved[0].exists(), "the archive keeps it 7 more days")

    def test_a_rebriefed_name_keeps_its_new_task_brief(self):
        s = self.state
        (s / "task-reused.src").write_text("x")
        age(s / "task-reused.src", 8 * DAY)  # written after the old run finished
        older = dt.datetime.fromtimestamp(NOW - 9 * DAY).isoformat()
        oldest = dt.datetime.fromtimestamp(NOW - 20 * DAY).isoformat()
        (s / "finished.tsv").write_text(
            # The newer run first: the last finish counts, not the last row.
            f"%5\treused\tb\ts\tw\tc\t{older}\n%4\treused\tb\ts\tw\tc\t{oldest}\n"
        )
        self.assertEqual(self.tidy("--apply", "briefs").returncode, 0)
        self.assertTrue((s / "task-reused.src").exists())
        age(
            s / "task-reused.src", 10 * DAY
        )  # the brief of the run that finished 9 days ago
        self.assertEqual(self.tidy("--apply", "briefs").returncode, 0)
        self.assertFalse((s / "task-reused.src").exists())

    def test_a_resume_brief_of_a_live_agent_stays(self):
        s = self.state
        (s / "fresh-live-20261101-0900-resume.src").write_text("x")
        age(s / "fresh-live-20261101-0900-resume.src", 30 * DAY)
        (s / "panes.tsv").write_text(f"%1\tlive\t{s}/task-live.src\tsid1\n")
        self.assertEqual(self.tidy("--apply", "briefs").returncode, 0)
        self.assertTrue((s / "fresh-live-20261101-0900-resume.src").exists())

    def test_the_dry_run_lists_everything_it_would_drop(self):
        s = self.state
        names = [f"fresh-gone{i}.src" for i in range(7)]
        for n in names:
            (s / n).write_text("x")
            age(s / n, 30 * DAY)
        self.heph()
        r = self.tidy("heph", "briefs")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("... and 2 more", r.stdout)
        listed = (s / "tidy-preview.md").read_text()
        self.assertIn(f"the full list is in {s / 'tidy-preview.md'}", r.stdout)
        for n in names:
            self.assertIn(f"\n{n}\n", listed)
        for line in ("- 00:41 old work", "- 22:00 still the 14th: dropped"):
            self.assertIn(f"\n{line}\n", listed)
        self.assertTrue(
            all((s / n).exists() for n in names), "a dry run removes nothing"
        )
        self.assertEqual(self.tidy("--apply", "briefs", dry_first=False).returncode, 0)
        left = (s / "tidy-preview.md").read_text()
        self.assertNotIn("## briefs", left, "an applied part clears its own list")
        self.assertIn("## heph", left, "and leaves the others")

    def test_a_preview_that_cannot_be_written_leaves_no_temp_file(self):
        mod = load_tidy(self.state, self.brief)
        mod.PREVIEW["briefs"] = ["fresh-x.src"]

        def fail(src, dst):
            raise OSError("disk full")

        out = io.StringIO()
        with (
            mock.patch.object(mod.os, "replace", fail),
            contextlib.redirect_stdout(out),
        ):
            self.assertEqual(mod.write_preview(["briefs"]), "the full list is above")
        self.assertIn("fresh-x.src", out.getvalue())
        self.assertEqual(list(self.state.glob(".tidy-preview.*")), [])

    def test_apply_drops_only_what_the_dry_run_listed(self):
        """Heph's review r2, N5: --apply goes only when each thing it would drop was shown."""
        s = self.state
        (s / "fresh-a.src").write_text("x")
        age(s / "fresh-a.src", 30 * DAY)
        r = self.tidy("--apply", "briefs", dry_first=False)  # no dry run at all
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("briefs: refused: 1 of 1 not in the dry run's list", r.stdout)
        self.assertTrue((s / "fresh-a.src").exists())
        self.tidy("briefs")
        (s / "fresh-b.src").write_text("x")  # eligible after the dry run
        age(s / "fresh-b.src", 30 * DAY)
        r = self.tidy("--apply", "briefs", dry_first=False)
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("1 of 2 not in the dry run's list", r.stdout)
        self.assertTrue((s / "fresh-a.src").exists() and (s / "fresh-b.src").exists())
        self.tidy("briefs")
        self.heph()
        self.tidy("heph")  # another part's dry run keeps the briefs list
        r = self.tidy("--apply", "briefs", dry_first=False)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertFalse((s / "fresh-a.src").exists() or (s / "fresh-b.src").exists())

    def test_the_saved_list_round_trips_any_line(self):
        import random

        mod = load_tidy(self.state, self.brief)
        rng = random.Random(5141)
        alphabet = [
            "a",
            " ",
            "#",
            "## x (3)",
            "\r",
            "\u2028",
            "\x0c",
            "\x85",
            "\x1c",
            "\v",
            "é",
            "\udcff",
        ]
        for _ in range(200):
            items = [
                "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 6)))
                for _ in range(rng.randint(1, 6))
            ]
            mod.PREVIEW.clear()
            mod.PREVIEW["heph"] = items
            mod.write_preview(["heph"])
            self.assertEqual(mod.read_preview(), {"heph": items}, items)

    def test_the_queue_list_holds_every_line_it_drops(self):
        q = (
            "# Queue\n\n## Done since 11-09\n- ✅ **Sun 11-15:** last week\n"
            "  LESSON: keep the continuation\n- ✅ **Fri 11-20:** this week\n"
        )
        (self.brief / "queue.md").write_text(q)
        git(self.brief, "add", "-A")
        git(self.brief, "commit", "-qm", "q")
        r = self.tidy("queue")
        self.assertIn("would drop 1 Done items (2 lines)", r.stdout)
        listed = (self.state / "tidy-preview.md").read_text()
        self.assertIn("  LESSON: keep the continuation\n", listed)

    def test_the_saved_list_reads_blank_and_heading_items(self):
        mod = load_tidy(self.state, self.brief)
        mod.PREVIEW["heph"] = ["## 10-28 00:40", "", "- 00:41 old work"]
        mod.write_preview(["heph"])
        self.assertEqual(
            mod.read_preview(), {"heph": ["## 10-28 00:40", "", "- 00:41 old work"]}
        )
        (self.state / "tidy-preview.md").write_text(
            mod.PREVIEW_HEAD + "## heph (5)\nx\n"
        )
        self.assertEqual(mod.read_preview(), {}, "a list cut short is no list")

    def test_a_refused_apply_keeps_its_list(self):
        p = self.heph()
        self.tidy("heph")
        age(p, 30)  # written just now: the apply waits
        r = self.tidy("--apply", "heph", dry_first=False)
        self.assertIn("was written 30 s ago", r.stdout)
        self.assertIn("## heph", (self.state / "tidy-preview.md").read_text())
        age(p, 3600)
        r = self.tidy("--apply", "heph", dry_first=False)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_apply_without_a_listed_dry_run_refuses_every_part(self):
        """Heph's review r3, S2: each part's --apply refuses without a saved list."""
        p = self.heph()
        (self.brief / "queue.md").write_text(
            "# Queue\n\n## Done since 11-09\n- ✅ **Sun 11-15:** x\n"
        )
        (self.brief / "done").mkdir()
        (self.brief / "done" / "W1.md").write_text("x")
        (self.brief / "review").mkdir()
        (self.brief / "review" / "old.md").write_text(
            "---\nowner: heph\nexpires: 2026-01-01\n---\n"
        )
        git(self.brief, "add", "-A")
        git(self.brief, "commit", "-qm", "parts")
        head = git(self.brief, "rev-parse", "HEAD")
        queue = (self.brief / "queue.md").read_text()
        for part in ("heph", "queue", "done", "expired"):
            with self.subTest(part=part):
                r = self.tidy("--apply", part, dry_first=False)
                self.assertEqual(r.returncode, 1, r.stdout)
                self.assertIn(f"{part}: refused: ", r.stdout)
                self.assertIn("not in the dry run's list", r.stdout)
        self.assertEqual(p.read_text(), HEPH)
        self.assertEqual((self.brief / "queue.md").read_text(), queue)
        self.assertEqual(git(self.brief, "rev-parse", "HEAD"), head)
        self.assertTrue((self.brief / "done" / "W1.md").exists())
        self.assertTrue((self.brief / "review" / "old.md").exists())

    def test_the_list_counts_copies_of_one_text(self):
        text = HEPH.replace("- 00:41 old work\n", "- none\n").replace(
            "- 09:00 more old work\n", "- none\n"
        )
        p = self.heph(text)
        self.tidy("heph")
        listed = (self.state / "tidy-preview.md").read_text()
        self.assertEqual(listed.splitlines().count("- none"), 2)
        mod = load_tidy(self.state, self.brief)
        got = mod.read_preview()
        got["heph"].remove("- none")  # the list shows one copy; the tidy would drop two
        mod.save_preview(got)
        r = self.tidy("--apply", "heph", dry_first=False)
        self.assertIn("heph: refused: 1 of", r.stdout)
        self.assertEqual(p.read_text(), text)

    def test_a_list_without_its_header_is_no_list(self):
        mod = load_tidy(self.state, self.brief)
        (self.state / "tidy-preview.md").write_text("x\ny\n## heph (1)\n- z\n")
        self.assertEqual(mod.read_preview(), {})

    def test_a_briefing_only_run_takes_the_tidy_lock(self):
        with open(self.state / ".tidy.lock", "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            r = self.tidy("done")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("refused: another fleet tidy is running", r.stdout)

    def test_a_queue_line_is_dated_by_its_own_house_date(self):
        q = (
            "# Queue\n\n## Done since 11-09\n- ✅ v1-20 schema shipped **Thu 11-19**\n"
            "- ✅ **Sun 11-15:** last week\n"
        )
        (self.brief / "queue.md").write_text(q)
        r = self.tidy("queue")
        self.assertIn("would drop 1 Done items (1 lines)", r.stdout)
        self.assertNotIn("v1-20 schema", (self.state / "tidy-preview.md").read_text())

    def test_the_queue_keeps_its_line_endings(self):
        q = (
            "# Queue\r\n\r\n## Done since 11-09\r\n- ✅ **Fri 11-20:** keep\r\n"
            "- ✅ **Sun 11-15:** last week\r\n"
        )
        path = self.brief / "queue.md"
        path.write_bytes(q.encode())
        r = self.tidy("--apply", "queue")
        self.assertEqual(r.returncode, 0, r.stdout)
        out = path.read_bytes().decode()
        self.assertIn("- ✅ **Fri 11-20:** keep\r\n", out)
        self.assertNotIn("last week", out)
        self.assertNotIn("\n", out.replace("\r\n", ""))

    def test_a_queue_with_a_stray_byte_applies_byte_for_byte(self):
        q = b"# Queue\n\n## Done since 11-09\n- \xe2\x9c\x85 **Fri 11-20:** keep \xff\n- \xe2\x9c\x85 **Sun 11-15:** old\n"
        path = self.brief / "queue.md"
        path.write_bytes(q)
        r = self.tidy("--apply", "queue")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        want = q.replace(b"- \xe2\x9c\x85 **Sun 11-15:** old\n", b"").replace(
            b"since 11-09", b"since 11-16"
        )
        self.assertEqual(path.read_bytes(), want)  # the stray byte back as it was

    def test_a_queue_line_break_other_than_newline_refuses(self):
        q = "# Queue\n\n## Done since 11-09\n- ✅ **Fri 11-20:** keep\u2028- ✅ **Sun 11-15:** tail\n"
        path = self.brief / "queue.md"
        path.write_text(q)
        r = self.tidy("--apply", "queue")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn(
            "queue: refused: queue.md holds a line break other than", r.stdout
        )
        self.assertEqual(path.read_text(), q)
        r = self.tidy("--report", str(self.tmp / "r.json"))
        got = json.loads((self.tmp / "r.json").read_text())
        self.assertEqual(got.get("queue_old"), 0, got)
        self.assertIsNone(got.get("error"), got)
        self.assertIn("holds a line break other than", got.get("queue_refused", ""))

    def test_an_ignored_untracked_path_is_never_removed(self):
        mod = load_tidy(self.state, self.brief)
        (self.brief / ".gitignore").write_text("done/W9.md\n")
        (self.brief / "done").mkdir()
        (self.brief / "done" / "W9.md").write_text("x")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(mod.git_remove(["done/W9.md"], "m"), 1)
        self.assertIn(
            "refused: changed or untracked since the scan: done/W9.md", out.getvalue()
        )
        self.assertTrue((self.brief / "done" / "W9.md").exists())

    def test_a_second_tidy_is_refused(self):
        self.heph()
        with open(self.state / ".tidy.lock", "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            r = self.tidy("--apply", "heph")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("refused: another fleet tidy is running", r.stdout)
        self.assertEqual((self.state / "HEPH.md").read_text(), HEPH)

    def test_heph_refuses_an_archive_that_is_a_link_or_a_file(self):
        p = self.heph()
        outside = self.tmp / "outside"
        outside.mkdir()
        (self.state / "archive").symlink_to(outside)
        r = self.tidy("--apply", "heph")
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("archive/ is a link or no folder", r.stdout)
        self.assertEqual(p.read_text(), HEPH)
        self.assertEqual(list(outside.iterdir()), [])
        (self.state / "archive").unlink()
        (self.state / "archive").write_text("a file")
        r = self.tidy("--apply", "heph")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertNotIn("Traceback", r.stderr)
        self.assertEqual(p.read_text(), HEPH)

    def test_found_paths_outside_the_part_s_folder_are_refused(self):
        mod = load_tidy(self.state, self.brief)
        stray = self.tmp / "stray.src"
        stray.write_text("x")
        out = io.StringIO()
        with (
            mock.patch.object(
                mod, "preview", return_value=True
            ),  # past the list's gate
            contextlib.redirect_stdout(out),
        ):
            self.assertEqual(mod.tidy_found("archive", [stray], True), 1)
        self.assertIn(
            f"refused: {self.tmp} is not {self.state / 'archive'}", out.getvalue()
        )
        self.assertTrue(stray.exists())

    def test_shelve_refuses_a_path_outside_its_folder(self):
        mod = load_tidy(self.state, self.brief)
        stray = self.tmp / "stray.src"
        stray.write_text("x")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(mod.shelve([stray], self.state), 1)
        self.assertIn(f"refused: {stray} is not in {self.state}", out.getvalue())
        self.assertTrue(stray.exists())

    def test_the_preview_is_printed_when_state_is_no_state_folder(self):
        (self.brief / "done").mkdir()
        (self.brief / "done" / "W1.md").write_text("x")
        git(self.brief, "add", "-A")
        git(self.brief, "commit", "-qm", "d")
        (self.state / "panes.tsv").unlink()
        r = self.tidy("done")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("## done (1)\ndone/W1.md\n", r.stdout)
        self.assertIn("the full list is above", r.stdout)
        self.assertFalse((self.state / "tidy-preview.md").exists())

    def test_shapes_that_must_never_lose_recent_lines(self):
        cases = {
            "undated newest section": "## Heph takeover (after shutdown)\n- 16:30 newest work\n",
            "a heading with only a time": "## 16:2x Heph takeover\n- 16:30 newest work\n",
            "a number range in a heading": "## Slices 1-3 plan\n- 11:00 newest work\n",
            "a future date named in a line": "## 2026-11-20 RECOVERY\n- 11-25 13:00 RIT resets\n- 09:00 newest work\n",
            "a long gap with no new date": "## 2026-11-19 day\n- 20:00 late\n- 16:00 newest work\n",
        }
        for name, tail in cases.items():
            with self.subTest(name):
                kept, _ = self.plan(self.HEAD + tail, keep_last=len(tail.splitlines()))
                self.assertIn("newest work", "".join(kept))

    def test_heph_keeps_what_it_drops_for_a_week(self):
        p = self.heph()
        r = self.tidy("--apply", "heph")
        self.assertEqual(r.returncode, 0, r.stdout)
        copies = list((self.state / "archive").glob("HEPH-dropped-*.md"))
        self.assertEqual(len(copies), 1)
        self.assertIn("00:41 old work", copies[0].read_text())
        self.assertNotIn("00:41 old work", p.read_text())

    def test_heph_changed_mid_tidy_is_refused(self):
        p = self.heph()
        self.tidy("heph")  # the dry run --apply needs
        mod = load_tidy(self.state, self.brief)
        real = mod.open_elsewhere

        def touch(path):
            p.write_text(HEPH + "- 11:59 a new line\n")
            return real(path)

        mod.open_elsewhere = touch
        self.assertEqual(mod.tidy_heph(True), 1)
        self.assertIn("a new line", p.read_text())
        arc = self.state / "archive"
        self.assertEqual(list(arc.glob("HEPH-dropped-*")) if arc.exists() else [], [])

    def test_remove_refuses_a_path_outside_its_folder(self):
        mod = load_tidy(self.state, self.brief)
        outside = self.tmp / "keep.src"
        outside.write_text("x")
        self.assertEqual(mod.remove([outside], self.state), 1)
        self.assertTrue(outside.exists())

    def test_a_folder_named_like_a_brief_is_left_alone(self):
        d = self.state / "task-folder.src"
        d.mkdir()
        (d / "x").write_text("x")
        os.utime(d, (NOW - 30 * DAY,) * 2)
        self.tidy("--apply", "briefs")
        self.assertTrue((d / "x").exists())

    def test_archive_briefs_age_one_by_one(self):
        b = self.state / "archive" / "briefs"
        b.mkdir(parents=True)
        (b / "old.src").write_text("x")
        (b / "new.src").write_text("x")
        age(b / "old.src", 30 * DAY)
        r = self.tidy("--apply", "archive")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(sorted(p.name for p in b.iterdir()), ["new.src"])

    def test_an_untracked_path_is_never_removed(self):
        mod = load_tidy(self.state, self.brief)
        (self.brief / "done").mkdir()
        (self.brief / "done" / "W1.md").write_text("x")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(mod.git_remove(["done/W1.md"], "m"), 1)
        self.assertTrue((self.brief / "done" / "W1.md").exists())
        self.assertIn(
            "refused: changed or untracked since the scan: done/W1.md", out.getvalue()
        )

    def test_a_path_changed_since_the_scan_is_refused_before_git_rm(self):
        (self.brief / "done").mkdir()
        f = self.brief / "done" / "W1.md"
        f.write_text("orig")
        git(self.brief, "add", "-A")
        git(self.brief, "commit", "-qm", "d")
        f.write_text("edited after the scan")
        mod = load_tidy(self.state, self.brief)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(mod.git_remove(["done/W1.md"], "m"), 1)
        self.assertEqual(f.read_text(), "edited after the scan")
        self.assertIn(
            "refused: changed or untracked since the scan: done/W1.md", out.getvalue()
        )

    def test_a_failed_git_rm_keeps_an_edit_saved_meanwhile(self):
        (self.brief / "done").mkdir()
        f = self.brief / "done" / "W1.md"
        f.write_text("orig")
        git(self.brief, "add", "-A")
        git(self.brief, "commit", "-qm", "d")
        mod = load_tidy(self.state, self.brief)
        real = mod.git

        def racing(*args):
            if "rm" in args:
                f.write_text("edited meanwhile")
            return real(*args)

        mod.git = racing
        self.assertEqual(mod.git_remove(["done/W1.md"], "m"), 1)
        self.assertEqual(f.read_text(), "edited meanwhile")

    @NEEDS_TECHNE
    def test_queue_changed_mid_tidy_is_refused(self):
        q = "# Queue\n\n## Done since 11-09\n- ✅ **Sun 11-15:** last week\n"
        path = self.brief / "queue.md"
        path.write_text(q)
        self.tidy("queue")  # the dry run --apply needs
        mod = load_tidy(self.state, self.brief)
        real = mod.BriefingLock.__enter__

        def enter(lock):
            got = real(lock)
            path.write_text(q + "- a line added meanwhile\n")
            return got

        mod.BriefingLock.__enter__ = enter
        self.assertEqual(mod.tidy_queue(True, mod.techne_cleanup()), 1)
        self.assertIn("added meanwhile", path.read_text())

    @NEEDS_TECHNE
    def test_expired_never_removes_what_is_only_stale(self):
        fm = "---\nowner: heph\nreviewed: 2020-01-01\n---\n"
        (self.brief / "review").mkdir()
        (self.brief / "review" / "README.md").write_text(fm)
        (self.brief / "review" / "a.png").write_text("x")
        git(self.brief, "add", "-A")
        git(self.brief, "commit", "-qm", "r")
        r = self.tidy("--apply", "expired")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertTrue((self.brief / "review" / "a.png").exists())

    def test_report_survives_a_prune_that_hangs_and_a_missing_briefing(self):
        mod = load_tidy(self.state, self.tmp / "no-briefing")
        real = mod.subprocess.run

        def hang(cmd, *a, **k):
            if "--apply" in cmd:
                raise mod.subprocess.TimeoutExpired(cmd, 540)
            return real(cmd, *a, **k)

        mod.subprocess.run = hang
        out = self.tmp / "r.json"
        try:
            self.assertEqual(mod.report(out), 0)
        finally:
            mod.subprocess.run = real
        data = json.loads(out.read_text())
        self.assertEqual((data["shots_rc"], data["briefing"]), (124, None))
        self.assertIn("timed out", data["shots_said"])

    def test_report_names_a_crash(self):
        mod = load_tidy(self.state, self.brief)

        def boom():
            raise RuntimeError("roster broke")

        mod.stale_briefs = boom
        out = self.tmp / "r.json"
        self.assertEqual(mod.report(out), 0)
        self.assertIn("roster broke", json.loads(out.read_text())["error"])


if __name__ == "__main__":
    unittest.main()
