"""Tests for tidy.py (`fleet tidy`) in a scratch state folder and a scratch briefing repo.
Run: python3 -I fleet/test_tidy.py

The queue, expired and report cases need techne's cleanup.py: TECHNE_CLEANUP, else
~/ajsoftworks/techne. Without it they fail, unless KLEPSYDRA_NO_TECHNE=1 declares its absence."""

import contextlib
import datetime as dt
import fcntl
import io
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

    def test_heph_refuses_an_undated_log(self):
        self.refused(
            "# H\n## START HERE\n- x\n## Notes\n- y\n",
            "no line after START HERE carries a date",
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

    def plan(self, text: str):
        mod = load_tidy(self.state, self.brief)
        return mod.plan_heph(text, dt.datetime.fromtimestamp(NOW))

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
            doc(" (11-19 08:00)", " (11-12 10:00)", "## 11-13 09:00\n- z\n")
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
            + "## 2026-11-11 day\n- 09:00 z\n## 2026-11-20 day\n- 09:00 x\n"
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

    def test_the_newest_lines_stay_whatever_their_shape(self):
        """Heph's review, B1: a line with no date the parser reads took the last date above it,
        so after a gap the newest lines were dropped. Each shape below is the newest line."""
        for shape in (
            "- 10:00 NEWEST",
            "- Fri 11-20 10:00 NEWEST",
            "- **Fri 11-20:** NEWEST",
            "- Heph 11-20 10:00: NEWEST",
            "10:00 NEWEST as a paragraph",
            "### Fri 11-20\n- 10:00 NEWEST",
        ):
            text = self.HEAD.replace("2026-11-15", "2026-11-17") + shape + "\n"
            kept, _ = self.plan(text)
            self.assertIn("NEWEST", "".join(kept), shape)

    def test_a_stop_order_written_after_a_gap_survives_apply(self):
        text = (
            "# H\n## START HERE (11-19 06:00)\n- now\n## 2026-11-17 06:50\n- 06:55 a\n"
            "- 07:30 Heph: written Thu 11-19 07:30\n- 07:45 AJ: STOP merging #601 until Ben replies\n"
        )
        p = self.heph(text, written=14 * 60)
        r = self.tidy("--apply", "heph", now=NOW - DAY + 8 * 3600)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertIn("STOP merging #601", p.read_text())

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
        with contextlib.redirect_stdout(out):
            self.assertEqual(mod.tidy_found("archive", [stray], True), 1)
        self.assertIn(
            f"refused: {self.tmp} is not {self.state / 'archive'}", out.getvalue()
        )
        self.assertTrue(stray.exists())

    def test_a_line_is_bounded_by_every_date_below_it(self):
        # cutoff 11-18 12:00. X sits above 11-17 (alone: kept to 11-19) and 11-16, a date that
        # slipped back a day: written by the end of the 16th, plus a day, so it goes.
        text = "# H\n## START HERE\n- now\n## 2026-11-10\n- X\n## 2026-11-17\n- a\n## 2026-11-16\n- b\n"
        kept, _ = self.plan(text)
        self.assertNotIn("- X\n", kept)

    def test_a_date_keeps_the_lines_above_it_two_days(self):
        # Above an 11-17 date only: the 17th plus two days of slack reaches past the cutoff.
        text = "# H\n## START HERE\n- now\n## 2026-11-10\n- X\n## 2026-11-17\n- a\n"
        kept, _ = self.plan(text)
        self.assertIn("- X\n", kept)
        text = text.replace("2026-11-17", "2026-11-16")
        kept, _ = self.plan(text)
        self.assertNotIn("- X\n", kept)

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
                kept, _ = self.plan(self.HEAD + tail)
                self.assertIn("newest work", "".join(kept))

    def test_dates_that_go_backwards_refuse(self):
        text = self.HEAD + "## 2026-11-19 day\n- 10:00 x\n## 10-12 slices\n- 11:00 y\n"
        with self.assertRaisesRegex(ValueError, "before 2026-11-19 above it"):
            self.plan(text)

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
