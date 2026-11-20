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


# The fixture's lines a tidy first saw 30 days ago; every other line it saw a minute ago.
HEPH_OLD = {
    "## 10-28 00:40",
    "- 00:41 old work",
    "- 09:00 more old work",
    "## 2026-11-14 06:00 RECOVERY",
    "- 06:10 six days ago, with a later date below it: dropped",
    "- 22:00 still the 14th: dropped",
}


def seen_times(text: str, old) -> list[float]:
    return [
        NOW - 30 * DAY if ln.rstrip("\r\n") in old else NOW - 60
        for ln in text.splitlines(True)
    ]


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

    def heph(self, text: str = HEPH, written: float = 3600, old=HEPH_OLD) -> Path:
        p = self.state / "HEPH.md"
        p.write_text(text)
        age(p, written)
        self.seed(text, old)
        return p

    def seed(self, text: str, old) -> None:
        """The first-seen record a tidy would have kept: OLD lines 30 days ago, the rest now."""
        mod = load_tidy(self.state, self.brief)
        keys = mod.line_keys(text.splitlines(True))
        mod.save_seen(keys, seen_times(text, old))

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

    old = {k: os.environ.get(k) for k in ("FLEET_STATE", "BRIEFING_DIR", "FLEET_NOW")}
    os.environ |= {
        "FLEET_STATE": str(state),
        "BRIEFING_DIR": str(brief),
        "FLEET_NOW": str(now),
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
    seed = Tidy.seed

    def plan(self, text: str, old=()):
        mod = load_tidy(self.state, self.brief)
        return mod.plan_heph(
            text, dt.datetime.fromtimestamp(NOW), seen_times(text, old)
        )

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

    def test_a_later_start_here_newer_than_the_first_is_refused(self):
        def doc(top: str, later: str, mid: str = "") -> str:
            return (
                f"# H\n## START HERE{top}\n- top\n## 11-12 09:00 log\n- 09:30 x\n"
                f"## START HERE{later}\n- later\n{mid}## 11-20 09:00\n- 09:30 y\n"
            )

        for top, later in (
            (" (11-10 08:00)", " (11-17 08:00, rotation)"),
            (" (11-10 08:00)", ""),
            ("", " (11-17 08:00)"),
        ):
            with self.assertRaisesRegex(
                ValueError, "START HERE block newer than the first"
            ):
                self.plan(doc(top, later))
        kept, _ = self.plan(
            doc(" (11-19 08:00)", " (11-12 10:00)"),
            old={"## START HERE (11-12 10:00)", "- later"},
        )
        self.assertIn("- top\n", kept)
        self.assertNotIn("- later\n", kept)

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
        kept, s = self.plan(text, old={"## 2026-11-10 day", *rules, *noise})
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

    def test_a_line_seen_lately_stays_whatever_date_it_names(self):
        """Heph's review B1 and its verify pass: any date in the log may name another day (a
        gap, a recap, a reference), so only when a tidy first saw a line decides its age."""
        old = {"## 2026-11-17 RECOVERY", "- 09:00 old"}
        for shape in (
            "- 10:00 NEWEST",
            "- Fri 11-20 10:00 NEWEST",
            "- **Fri 11-20:** NEWEST",
            "- Heph 11-20 10:00: NEWEST",
            "10:00 NEWEST as a paragraph",
            "### Fri 11-20\n- 10:00 NEWEST",
            "- 10:30 NEWEST\n- 11-16 decision recap",
            "- 10:30 NEWEST\n- 11-17 recap",
            "- 10:30 NEWEST\n### 11-16 lessons",
            "- 10:30 NEWEST\n- **11-16:** recap",
            "- 10:30 NEWEST\n## 11-16 lessons\n- x",
            "- 10:30 NEWEST\n## 2026-10-28 retro\n- x",
        ):
            text = (
                "# H\n## START HERE\n- now\n## 2026-11-17 RECOVERY\n- 09:00 old\n"
                + shape
                + "\n"
            )
            kept, _ = self.plan(text, old)
            self.assertIn("NEWEST", "".join(kept), shape)
            self.assertNotIn("- 09:00 old\n", kept, shape)

    def test_a_heading_just_opened_stays_before_its_first_line(self):
        text = "# H\n## START HERE\n- now\n## 2026-11-17 old\n- 09:00 x\n## 2026-11-20 just opened\n"
        kept, _ = self.plan(text, {"## 2026-11-17 old", "- 09:00 x"})
        self.assertIn("## 2026-11-20 just opened\n", kept)
        self.assertNotIn("- 09:00 x\n", kept)

    def test_an_old_line_goes_even_when_it_names_today(self):
        text = "# H\n## START HERE\n- now\n## Fri 11-20 log\n- 09:00 11-20 noted\n## 11-20 b\n- y\n"
        kept, _ = self.plan(text, old={"## Fri 11-20 log", "- 09:00 11-20 noted"})
        self.assertNotIn("- 09:00 11-20 noted\n", kept)

    def test_a_stop_order_written_after_a_gap_survives_apply(self):
        text = (
            "# H\n## START HERE (11-19 06:00)\n- now\n## 2026-11-17 06:50\n- 06:55 a\n"
            "- 07:30 Heph: written Thu 11-19 07:30\n- 07:45 AJ: STOP merging #601 until Ben replies\n"
        )
        p = self.heph(text, written=14 * 60, old={"## 2026-11-17 06:50", "- 06:55 a"})
        r = self.tidy("--apply", "heph")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("STOP merging #601", p.read_text())
        self.assertNotIn("06:55 a", p.read_text())

    def test_with_no_record_nothing_goes_and_the_record_starts(self):
        for record in (None, "garbage\nnot\ta number\n", b"\xff\xfe"):
            with self.subTest(record=record):
                p = self.state / "HEPH.md"
                p.write_text(HEPH)
                age(p, 3600)
                rec = self.state / ".heph-seen.tsv"
                rec.unlink(missing_ok=True)
                if isinstance(record, str):
                    rec.write_text(record)
                elif record is not None:
                    rec.write_bytes(record)
                r = self.tidy("--apply", "heph")
                self.assertEqual(r.returncode, 0, r.stdout)
                self.assertEqual(p.read_text(), HEPH)
                self.assertEqual(
                    rec.read_text().splitlines()[-1], f"#end\t{len(HEPH.splitlines())}"
                )

    def test_the_age_boundary_is_heph_hours(self):
        mod = load_tidy(self.state, self.brief)
        text = (
            "# H\n## START HERE\n- now\n## 2026-11-01 a\n- x\n"  # dated: not kept whole
        )
        cut = NOW - mod.HEPH_HOURS * 3600
        for seen, kept in ((cut - 1, False), (cut, True)):
            times = [NOW] * 3 + [seen, seen]
            got, _ = mod.plan_heph(text, dt.datetime.fromtimestamp(NOW), times)
            self.assertEqual("- x\n" in got, kept, seen)

    def test_apply_rewrites_the_record_for_the_kept_lines(self):
        text = "# H\n## START HERE\n- now\n## 2026-11-01 a\n- ok\n- new\n- ok\n"
        p = self.heph(text, old={"## 2026-11-01 a"})
        mod = load_tidy(self.state, self.brief)
        rec = self.state / ".heph-seen.tsv"
        keys = mod.line_keys(text.splitlines(True))
        lines = text.splitlines(True)
        rows = [NOW - 60] * len(lines)
        rows[4] = NOW - 30 * DAY  # the first "- ok" is old, the second new
        mod.save_seen(keys, rows)
        r = self.tidy("--apply", "heph")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(
            p.read_text(), "# H\n## START HERE\n- now\n## 2026-11-01 a\n- new\n- ok\n"
        )
        got = dict(row.split("\t") for row in rec.read_text().splitlines()[:-1])
        kept_keys = mod.line_keys(p.read_text().splitlines(True))
        self.assertEqual(set(got), set(kept_keys))
        self.assertEqual(
            float(got[kept_keys[5]]),
            round(NOW - 60),
            "the kept copy keeps its own time",
        )

    def test_a_record_loads_only_whole_and_sane(self):
        mod = load_tidy(self.state, self.brief)
        rec = self.state / ".heph-seen.tsv"
        good = f"k\t{NOW + 10 * DAY:.0f}\nj\t{NOW - DAY:.0f}\nk\t{NOW - 2 * DAY:.0f}\n"
        rec.write_text(good + "#end\t3\n")
        self.assertEqual(
            mod.load_seen(), {"k": [NOW + 10 * DAY, NOW - 2 * DAY], "j": [NOW - DAY]}
        )
        for bad in (
            good,  # cut off before its end row
            good + "#end\t2\n",  # an end row naming another count
            good[:-4] + "\n#end\t3\n",  # a time cut short reads as 1970
            good + "#end\t3\nx\t1\n",  # rows after the end
            good.replace("j\t", "j\tsoon", 1) + "#end\t3\n",  # one bad row among good
            "k\tnan\n#end\t1\n",
            "k\tinf\n#end\t1\n",
            "k\t0\n#end\t1\n",
            "k\t-5\n#end\t1\n",
            f"k\t{NOW + 31 * DAY:.0f}\n#end\t1\n",
            "k\n#end\t1\n",
            f"\t{NOW:.0f}\n#end\t1\n",
            "",
        ):
            with self.subTest(bad=bad[-30:]):
                rec.write_text(bad)
                self.assertEqual(mod.load_seen(), {})

    def test_a_clock_stepped_back_never_ages_a_line(self):
        """Heph's review r2, S1: a stored time is never moved earlier, and a line first seen
        while the clock runs behind is stamped no earlier than any time already held."""
        mod = load_tidy(self.state, self.brief)
        a = ["# H\n", "## START HERE\n", "- now\n", "## 2026-11-01 log\n", "- a\n"]
        mod.NOW = NOW - 3600
        mod.first_seen(a)
        mod.NOW = NOW - 3 * DAY  # the clock steps back three days
        seen = mod.first_seen(a + ["- b\n"])
        self.assertEqual(seen[4:], [NOW - 3600, NOW - 3600])
        mod.NOW = NOW  # and is set right
        seen = mod.first_seen(a + ["- b\n"])
        kept, _ = mod.plan_heph(
            "".join(a) + "- b\n", dt.datetime.fromtimestamp(NOW), seen
        )
        self.assertIn("- a\n", kept)
        self.assertIn("- b\n", kept)

    def test_a_truncated_record_drops_nothing(self):
        """Heph's review r2, S2: a record cut off mid-write is no record."""
        p = self.heph()
        rec = self.state / ".heph-seen.tsv"
        rec.write_bytes(rec.read_bytes()[:-12])
        r = self.tidy("--apply", "heph")
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertEqual(p.read_text(), HEPH)

    def test_an_edited_or_deleted_copy_never_passes_its_age_on(self):
        """A text written twice, days apart: when the older copy is edited or deleted, the
        copy left keeps the newer time."""
        mod = load_tidy(self.state, self.brief)
        head = "# H\n## START HERE\n- now\n## 2026-11-01 log\n"
        mod.NOW = NOW - 3 * DAY
        mod.first_seen((head + "- watch CI\n").splitlines(True))
        mod.NOW = NOW - 3600
        mod.first_seen((head + "- watch CI\n- other\n- watch CI\n").splitlines(True))
        mod.NOW = NOW
        for later in (
            head + "- watch CI ✅\n- other\n- watch CI\n",
            head + "- other\n- watch CI\n",
        ):
            with self.subTest(later=later):
                seen = mod.first_seen(later.splitlines(True))
                kept, _ = mod.plan_heph(later, dt.datetime.fromtimestamp(NOW), seen)
                self.assertIn("- watch CI\n", kept)
                mod.save_seen(  # back to the state before this edit
                    mod.line_keys(
                        (head + "- watch CI\n- other\n- watch CI\n").splitlines(True)
                    ),
                    [NOW - 3600] * 4 + [NOW - 3 * DAY, NOW - 3600, NOW - 3600],
                )

    def test_first_seen_takes_a_key_s_newest_time(self):
        mod = load_tidy(self.state, self.brief)
        lines = ["# H\n", "- x\n"]
        k = mod.line_keys(lines)[1]
        mod.save_seen([k, k], [NOW - 9 * DAY, NOW - DAY])
        self.assertEqual(mod.first_seen(lines)[1], NOW - DAY)

    def test_a_blank_line_above_does_not_reset_a_line_s_age(self):
        mod = load_tidy(self.state, self.brief)
        mod.NOW = NOW - 9 * DAY
        mod.first_seen(["# H\n", "- a\n", "\n", "- b\n"])
        mod.NOW = NOW
        self.assertEqual(mod.first_seen(["# H\n", "- a\n", "- b\n"])[2], NOW - 9 * DAY)

    def test_a_text_moved_after_another_line_is_new(self):
        mod = load_tidy(self.state, self.brief)
        mod.NOW = NOW - 9 * DAY
        mod.first_seen(["# H\n", "- a\n", "- ok\n", "- b\n"])
        mod.NOW = NOW
        self.assertEqual(mod.first_seen(["# H\n", "- a\n", "- b\n", "- ok\n"])[3], NOW)

    def test_no_line_under_48_hours_ever_goes(self):
        """Random appends (some texts repeated), edits and deletes, seen every 6 hours, with an
        applied tidy now and then: a line whose text was written only once is kept while it is
        under HEPH_HOURS old, and a text found twice after the same line is never dropped. (The
        same text written again after the same line is the same note: no new text is lost.)"""
        import random

        mod = load_tidy(self.state, self.brief)
        rng = random.Random(514)
        head = ["# H\n", "## START HERE\n", "- now\n", "## 2026-11-01 log\n"]
        checked = 0
        for trial in range(40):
            (self.state / ".heph-seen.tsv").unlink(missing_ok=True)
            body: list[
                tuple[str, float, bool]
            ] = []  # line, when written, written only once
            written: set[str] = set()

            def put(ln: str, when: float) -> tuple[str, float, bool]:
                once = ln not in written
                written.add(ln)
                return ln, when, once

            t0 = NOW - 20 * DAY
            for step in range(60):
                now = t0 + step * 6 * 3600
                for i in range(rng.randint(0, 3)):
                    op = rng.random()
                    if op < 0.6 or not body:
                        text = rng.choice(["- ok", "", f"- note {trial}.{step}.{i}"])
                        body.append(put(text + "\n", now))
                    elif op < 0.8:
                        k = rng.randrange(len(body))
                        body[k] = put(body[k][0].rstrip("\n") + f" ✅{step}\n", now)
                    else:
                        del body[rng.randrange(len(body))]
                mod.NOW = now
                lines = head + [ln for ln, _, _ in body]
                seen = mod.first_seen(lines)
                if step % 5 != 4:
                    continue
                text = "".join(lines)
                kept, s = mod.plan_heph(text, dt.datetime.fromtimestamp(now), seen)
                keep = set(s["kept_index"])
                cut = now - mod.HEPH_HOURS * 3600
                keys = mod.line_keys(lines)
                for n, (ln, w, once) in enumerate(body, start=len(head)):
                    if not ln.strip():
                        continue
                    if keys.count(keys[n]) > 1 or (w >= cut and once):
                        checked += 1
                        self.assertIn(n, keep, (trial, step, ln))
                body = [b for n, b in enumerate(body, start=len(head)) if n in keep]
                mod.save_seen(mod.line_keys(kept), [seen[i] for i in s["kept_index"]])
        mod.NOW = NOW
        self.assertGreater(checked, 500)

    def test_the_report_skips_the_record_while_a_tidy_runs(self):
        (self.state / "HEPH.md").write_text(HEPH)
        mod = load_tidy(self.state, self.brief)
        stub = mock.patch.dict(os.environ, {"FLEET_PRUNE_SHOTS": str(self.shots)})
        with stub, open(self.state / ".tidy.lock", "a") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            with contextlib.redirect_stdout(io.StringIO()):
                mod.report(self.tmp / "report.json")
            self.assertFalse((self.state / ".heph-seen.tsv").exists())
        with stub, contextlib.redirect_stdout(io.StringIO()):
            mod.report(self.tmp / "report.json")
        self.assertTrue((self.state / ".heph-seen.tsv").exists())

    def test_a_record_that_cannot_be_saved_is_logged(self):
        mod = load_tidy(self.state, self.brief)
        got = []
        with mock.patch.object(mod, "event", lambda level, msg, **kw: got.append(msg)):
            with mock.patch.object(
                mod.os, "replace", mock.Mock(side_effect=OSError("full"))
            ):
                mod.save_seen(["k"], [NOW])
        self.assertEqual(
            got, ["first-seen record not saved; lines it lacks count as new"]
        )
        self.assertEqual(list(self.state.glob(".heph-seen.*")), [])

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

    def test_the_report_records_first_sight(self):
        (self.state / "HEPH.md").write_text(HEPH)
        r = self.tidy("--report", str(self.tmp / "report.json"))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        rec = (self.state / ".heph-seen.tsv").read_text().splitlines()
        self.assertEqual(rec[-1], f"#end\t{len(HEPH.splitlines())}")

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
                kept, _ = self.plan(
                    self.HEAD + tail, {"## 2026-11-15 RECOVERY", "- 09:00 old"}
                )
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
