"""tidy.py (`fleet tidy`): delete the finished history the fleet keeps outside git and GitHub.

Usage:
    fleet tidy [--apply] [PART ...]   a dry run without --apply; PART is one or more of
                                      heph briefs archive queue done expired (default: all)
    fleet tidy --report FILE          the fleet-cleanup timer: prune the shots (fleet shots
                                      --apply), then write what is still left to FILE for doctor

Finished work is recorded once, in merged PRs, closed issues and git history, so:
  heph     HEPH.md keeps its head, its START HERE block and the log lines of the last
           HEPH_HOURS hours; older lines go (outcomes live in GitHub and queue.md). Every date
           guess errs toward keeping: an undated section stays whole, an earlier time means
           midnight passed, and dates that go backwards refuse the tidy. What goes is copied
           to archive/ for KEEP_DAYS first (HEPH.md is in no repo). Refused while another
           process has it open or wrote it in the last WRITE_QUIET_S seconds. Its time is kept,
           since `fleet recover` reads AJ's messages since HEPH.md was last written.
  briefs   task-*.src and fresh-*.src of agents in no row of panes.tsv or paused.tsv and not
           finished in the last KEEP_DAYS days, and older than KEEP_DAYS themselves.
  archive  entries of the state folder's archive/ untouched for KEEP_DAYS days, and each
           file of archive/briefs/ (brief.sh adds one per rewrite).
  queue    the briefing's Done lines dated before this week's Monday (the Monday sweep);
           a line with no date stays. Harvest lessons from the dry run's list first.
  done     the briefing's retired done/ week files (git rm, one commit).
  expired  briefing files past the `expires` (or `reviewed`) date their frontmatter carries,
           or a README.md above them carries (git rm, one commit). Harvest them first.
Briefing deletions are committed under the lock the briefing sync holds; git keeps them.
"""

# research(2026-11): one history in git and GitHub, generated changelogs over kept lists
# (https://rufuspollock.com/2026-02-25-changelogs-lightweight-best-practice); owner + expiry
# frontmatter with a scheduled check (https://microsoft.github.io/hve-core/docs/contributing/
# documentation-maintenance); a cleanup unit at low priority with Persistent= and a randomized
# delay (https://wiki.archlinux.org/title/Systemd/Timers).

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import importlib.util
import json
import logging
import logging.handlers
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HOME = Path.home()
STATE = Path(os.environ.get("FLEET_STATE", HOME / ".local/state/fleet-orchestrator"))
BRIEFING = Path(os.environ.get("BRIEFING_DIR", "/mnt/c/Users/ajbar/fleet-briefing"))
NOW = float(os.environ.get("FLEET_NOW", time.time()))
HERE = Path(__file__).resolve().parent
HEPH_HOURS = 48
KEEP_DAYS = 7
WRITE_QUIET_S = 120


def wait_seconds(raw: str | None) -> float:
    """FLEET_REGISTRY_WAIT as lib.sh's with_registry reads it: empty or unreadable is 60."""
    try:
        v = float(raw or "60")
    except ValueError:
        return 60.0
    return v if 0 <= v < 86400 else 60.0  # also rejects nan and inf


REGISTRY_WAIT_S = wait_seconds(os.environ.get("FLEET_REGISTRY_WAIT"))
PARTS = ("heph", "briefs", "archive", "queue", "done", "expired")
# The briefing's permanent files, and what other tools own: everything else is transient.
BRIEFING_KEEP = [
    "README.md",
    "needs-you.md",
    "queue.md",
    "shots/**",
    ".gitignore",
    ".gitattributes",
]
BRIEF = re.compile(
    r"^(?:task-(?P<t>.+)|fresh-(?P<f>.+?)(?:-\d{8}-\d{4}(?:-recover)?)?)\.src$"
)

log = logging.getLogger("fleet::tidy")


def setup_log() -> None:
    sys.path.insert(0, str(HERE))
    try:
        import prune_shots  # the app log's JSON line format, one place
    finally:
        sys.path.pop(0)
    folder = STATE / "log"
    folder.mkdir(parents=True, exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(
        folder / "tidy.log", maxBytes=1 << 20, backupCount=4
    )
    handler.setFormatter(prune_shots.JsonLines())
    log.addHandler(handler)
    log.setLevel(logging.INFO)


def event(level: int, message: str, **fields: object) -> None:
    log.log(level, message, extra={"fields": fields})


def techne_cleanup():
    """techne's cleanup check module (_shared/cleanup.py): TECHNE_CLEANUP, else the newest
    installed copy, else techne's main checkout. None when there is none."""
    found = (
        [Path(os.environ["TECHNE_CLEANUP"])] if os.environ.get("TECHNE_CLEANUP") else []
    )
    if not found:
        found = sorted(
            HOME.glob(".claude/plugins/cache/techne/techne/*/_shared/cleanup.py"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        found.append(HOME / "ajsoftworks/techne/plugins/techne/_shared/cleanup.py")
    for path in found:
        if not path.is_file():
            continue
        spec = importlib.util.spec_from_file_location("techne_cleanup", path)
        if not (spec and spec.loader):
            continue
        mod = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(mod)
        except Exception as exc:  # a broken copy is skipped, and the next one tried
            event(
                logging.WARNING,
                "techne cleanup.py did not load",
                path=str(path),
                said=str(exc)[:200],
            )
            continue
        if all(
            hasattr(mod, f) for f in ("transient_status", "done_sections", "Config")
        ):
            mod.LOADED_FROM = str(path)
            return mod
    return None


def is_state_folder(p: Path) -> bool:
    """Only the fleet's own state folder is tidied: a FLEET_STATE that names / or $HOME by
    mistake holds no panes.tsv, so nothing in it is touched."""
    return p.is_dir() and not p.is_symlink() and (p / "panes.tsv").is_file()


def ago(seconds: float) -> str:
    return f"{seconds / 86400:.0f} d" if seconds >= 86400 else f"{seconds / 3600:.0f} h"


# --- HEPH.md -------------------------------------------------------------------------------

H2 = re.compile(r"^## ")
FULL_DATE = re.compile(r"\b(20\d\d)-(\d\d)-(\d\d)\b")
SHORT_DATE = re.compile(r"(?<![\d-])(\d\d)-(\d\d)(?![\d-])")
LINE_DATE = re.compile(r"^- (?:\*\*)?(?:(20\d\d)-)?(\d\d)-(\d\d)\b")
LINE_TIME = re.compile(r"^- (?:\*\*)?(?:(?:20\d\d-)?\d\d-\d\d )?(\d{1,2}):(\d)(\d|x)\b")
HEAD_TIME = re.compile(r"\b(\d{1,2}):(\d)(\d|x)\b")
KEEP = dt.datetime.max  # the stamp of a line under an undated section: always kept
WINDOW_DAYS = 330  # a MM-DD further back than this is a future event named, not a date


def month_day(month: int, day: int, now: dt.datetime) -> dt.date | None:
    """MM-DD as the latest date at or before tomorrow, or None when that is over WINDOW_DAYS
    old: "- 11-25 RIT resets", written on 11-20, names a future day, not last year's."""
    try:
        d = dt.date(now.year, month, day)
        if d > now.date() + dt.timedelta(days=1):
            d = dt.date(now.year - 1, month, day)
    except ValueError:
        return None
    return d if (now.date() - d).days <= WINDOW_DAYS else None


def minutes_of(m: re.Match[str]) -> int:
    return int(m[1]) * 60 + int(m[2]) * 10 + (0 if m[3] == "x" else int(m[3]))


def stamp_lines(
    lines: list[str], now: dt.datetime
) -> tuple[list[dt.datetime | None], list[tuple[int, dt.date]]]:
    """A time for each line, and the explicit dates in file order as (line, date). The date
    comes from the nearest heading or dated line above, the time of day from the line's own
    `- HH:MM` (or the line above). Every guess errs toward keeping: a time earlier than the one
    before it with no new date means midnight passed, and a line under a `## ` heading that
    carries no date is stamped KEEP. None only before the first heading."""
    out: list[dt.datetime | None] = []
    marks: list[tuple[int, dt.date]] = []
    day: dt.date | None = None
    minutes: int | None = None
    undated = False
    for n, line in enumerate(lines):
        if line.startswith("#"):
            new_day = None
            m = FULL_DATE.search(line)
            if m:
                try:
                    new_day = dt.date(int(m[1]), int(m[2]), int(m[3]))
                except ValueError:
                    new_day = None
            else:
                m = SHORT_DATE.search(line)
                new_day = month_day(int(m[1]), int(m[2]), now) if m else None
            if new_day is not None:
                day, undated = new_day, False
                t = HEAD_TIME.search(line)
                minutes = minutes_of(t) if t else None
                marks.append((n, new_day))
            elif line.startswith("## "):
                undated = True  # an undated section is kept whole
        else:
            m = LINE_DATE.match(line)
            got = None
            if m and 1 <= int(m[2]) <= 12:
                try:
                    got = (
                        dt.date(int(m[1]), int(m[2]), int(m[3]))
                        if m[1]
                        else month_day(int(m[2]), int(m[3]), now)
                    )
                except ValueError:
                    got = None
            if got is not None and not undated:
                day, minutes = got, None
                marks.append((n, got))
            t = LINE_TIME.match(line)
            if t and day and int(t[1]) < 24 and not undated:
                mins = minutes_of(t)
                if minutes is not None and mins < minutes:
                    day += dt.timedelta(
                        days=1
                    )  # midnight passed, or an earlier note: keep
                minutes = mins
        if undated:
            out.append(KEEP)
        elif day is None:
            out.append(None)
        else:
            out.append(
                dt.datetime.combine(day, dt.time()) + dt.timedelta(minutes=minutes or 0)
            )
    return out, marks


STANDING = re.compile(
    r"\b(?:standing|permanent|binding)\b", re.I
)  # a rule AJ set to last


def plan_heph(text: str, now: dt.datetime) -> tuple[list[str], dict]:
    """The lines HEPH.md keeps, and a summary of what goes. Raises ValueError when the log
    cannot be dated, has no START HERE block, or names dates out of order after it, so a
    misread never drops a line."""
    lines = text.splitlines(keepends=True)
    heads = [i for i, ln in enumerate(lines) if H2.match(ln)]
    if not heads:
        raise ValueError("HEPH.md has no ## sections")
    starts = [i for i in heads if lines[i].startswith("## START HERE")]
    if not starts:
        raise ValueError("HEPH.md has no ## START HERE block")
    s0 = starts[0]
    s1 = next((i for i in heads if i > s0), len(lines))
    stamps, marks = stamp_lines(lines, now)
    log_marks = [(n, d) for n, d in marks if n >= s1]
    if not log_marks:
        raise ValueError("no line after START HERE carries a date")
    for (_, a), (n, b) in zip(log_marks, log_marks[1:]):
        if b < a - dt.timedelta(days=1):
            raise ValueError(
                f"line {n + 1} dates to {b}, before {a} above it: the dates misread"
            )
    if log_marks[-1][1] > now.date() + dt.timedelta(days=1):
        raise ValueError(
            f"line {log_marks[-1][0] + 1} dates after today: the dates misread"
        )
    for s in starts[1:]:
        a, b = stamps[s0], stamps[s]
        if not (
            isinstance(a, dt.datetime) and isinstance(b, dt.datetime) and b <= a < KEEP
        ):
            raise ValueError(
                f"line {s + 1} is a START HERE block newer than the first, or undated: "
                "merge it into the top one first"
            )
    cutoff = now - dt.timedelta(hours=HEPH_HOURS)
    keep = set(range(heads[0])) | set(range(s0, s1))
    standing = 0
    losses: list[tuple[str, int]] = []
    for n, h in enumerate(heads):
        if s0 <= h < s1:
            continue
        end = heads[n + 1] if n + 1 < len(heads) else len(lines)
        body = range(h + 1, end)
        recent = [i for i in body if stamps[i] is not None and stamps[i] >= cutoff]
        new = set(recent)
        marked = [i for i in body if i not in new and STANDING.search(lines[i])]
        standing += len(marked)
        recent += marked  # a standing rule stays until someone moves it to its home
        if (stamps[h] is not None and stamps[h] >= cutoff) or recent:
            keep.add(h)
            keep.update(recent)
            lost = len(body) - len(recent)
            if lost:
                losses.append((lines[h].strip(), lost))
    kept = [ln for i, ln in enumerate(lines) if i in keep]
    dropped_lines = [ln for i, ln in enumerate(lines) if i not in keep]
    return kept, {
        "lines": len(lines),
        "kept": len(kept),
        "bytes": len(text.encode()),
        "kept_bytes": len("".join(kept).encode()),
        "sections_dropped": [lines[h].strip() for h in heads if h not in keep],
        "losses": losses,
        "dropped_lines": dropped_lines,
        "since": cutoff.strftime("%m-%d %H:%M"),
        "standing": standing,
    }


def open_elsewhere(path: Path) -> list[int]:
    """Pids of other processes that have PATH open, from /proc (Linux)."""
    want = os.path.realpath(path)
    pids = []
    try:
        procs = os.scandir("/proc")
    except OSError:
        return []
    with procs:
        for p in procs:
            if not p.name.isdigit() or int(p.name) == os.getpid():
                continue
            try:
                for fd in os.scandir(f"/proc/{p.name}/fd"):
                    if os.readlink(fd.path) == want:
                        pids.append(int(p.name))
                        break
            except OSError:
                continue
    return pids


def tidy_heph(apply: bool) -> int:
    path = STATE / "HEPH.md"
    try:
        st = path.lstat()
    except FileNotFoundError:
        print("heph: no HEPH.md")
        return 0
    if not stat.S_ISREG(st.st_mode):
        print("heph: refused: HEPH.md is not a regular file")
        return 1
    text = path.read_text(encoding="utf-8", errors="surrogateescape")
    now = dt.datetime.fromtimestamp(NOW)
    try:
        kept, s = plan_heph(text, now)
    except ValueError as exc:
        print(f"heph: refused: {exc}; nothing dropped")
        return 1
    gone = s["lines"] - s["kept"]
    print(
        f"heph: HEPH.md {s['lines']} lines ({s['bytes'] // 1024} KB) -> {s['kept']} "
        f"({s['kept_bytes'] // 1024} KB): the head, START HERE and the log since {s['since']}; "
        f"{'drops' if apply else 'would drop'} {gone} lines in {len(s['sections_dropped'])} sections"
    )
    secs = s["sections_dropped"]
    for h in secs if len(secs) <= 6 else [*secs[:3], "...", *secs[-3:]]:
        print(f"  {h[:110]}")
    for h, lost in s["losses"]:
        print(f"  {h[:90]}: keeps its recent lines, loses {lost} older")
    if s["standing"]:
        print(
            f"  keeps {s['standing']} older lines marked STANDING, PERMANENT or binding: move "
            "each to memory, START HERE or its repo, then tidy again"
        )
    if not apply or not gone:
        return 0
    if NOW - st.st_mtime < WRITE_QUIET_S:
        print(
            f"heph: refused: HEPH.md was written {NOW - st.st_mtime:.0f} s ago; run it again in a few minutes"
        )
        return 1
    pids = open_elsewhere(path)
    if pids:
        print(f"heph: refused: HEPH.md is open in pid {', '.join(map(str, pids))}")
        return 1
    # What goes is kept for KEEP_DAYS in archive/, which the archive part then expires, so a
    # misread date is recoverable for a week (HEPH.md is in no repo).
    arc = STATE / "archive"
    if arc.is_symlink():
        print(
            "heph: refused: archive/ is a link; the dropped lines need a safe copy first"
        )
        return 1
    arc.mkdir(exist_ok=True)
    copy = arc / f"HEPH-dropped-{dt.datetime.fromtimestamp(NOW):%Y%m%d-%H%M%S}.md"
    copy.write_text(
        "".join(s["dropped_lines"]), encoding="utf-8", errors="surrogateescape"
    )
    fd, tmp = tempfile.mkstemp(dir=STATE, prefix=".HEPH.", suffix=".tmp")
    try:
        with os.fdopen(
            fd, "w", encoding="utf-8", errors="surrogateescape", newline=""
        ) as f:
            f.write("".join(kept))
        os.chmod(tmp, stat.S_IMODE(st.st_mode))
        os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
        now_st = path.lstat()
        if (now_st.st_mtime_ns, now_st.st_size) != (st.st_mtime_ns, st.st_size):
            os.unlink(tmp)
            print("heph: refused: HEPH.md changed during the tidy; nothing written")
            return 1
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    event(
        logging.INFO,
        "HEPH.md tidied",
        lines=s["lines"],
        kept=s["kept"],
        sections=len(s["sections_dropped"]),
    )
    return 0


# --- briefs and archive --------------------------------------------------------------------


class RegistryUnreadable(Exception):
    pass


def rows(path: Path) -> list[list[str]]:
    """PATH's tab-separated rows; a missing file has none. Any other read error is raised, so
    an unreadable registry never protects nothing."""
    try:
        text = path.read_text(errors="replace")
    except FileNotFoundError:
        return []
    except OSError as exc:
        raise RegistryUnreadable(f"{path.name}: {exc.strerror or exc}") from None
    return [ln.split("\t") for ln in text.splitlines() if ln.strip()]


def protected() -> tuple[set[str], set[str]]:
    """(names, paths) of agents whose briefs stay: every row of panes.tsv and paused.tsv, and
    agents finished or unpaused in the last KEEP_DAYS days."""
    names: set[str] = set()
    paths: set[str] = set()
    for r in rows(STATE / "panes.tsv"):
        names.update(r[1:2])
        paths.update(f for f in r if f.endswith(".src"))
    for r in rows(STATE / "paused.tsv"):
        names.update(r[:1])  # name, note, then the panes.tsv row itself
        names.update(r[3:4])
        paths.update(f for f in r if f.endswith(".src"))
    cutoff = NOW - KEEP_DAYS * 86400
    for r in rows(STATE / "finished.tsv"):
        when = r[6] if len(r) > 6 else ""
        try:
            recent = dt.datetime.fromisoformat(when).timestamp() >= cutoff
        except ValueError:
            recent = True  # an unreadable time is kept, never guessed old
        if recent:
            names.update(r[1:2])
            paths.update(f for f in r if f.endswith(".src"))
    for r in rows(STATE / "unpaused.tsv"):
        names.update(r[:1])
    return names - {""}, paths


def stale_briefs() -> list[Path]:
    names, paths = protected()
    cutoff = NOW - KEEP_DAYS * 86400
    out = []
    with os.scandir(STATE) as it:
        for e in it:
            m = BRIEF.match(e.name)
            if not m or not e.is_file(follow_symlinks=False):
                continue
            name = m["t"] or m["f"]
            if (
                name in names
                or e.path in paths
                or e.stat(follow_symlinks=False).st_mtime >= cutoff
            ):
                continue
            out.append(Path(e.path))
    return sorted(out)


def newest_mtime(p: Path) -> float:
    """The newest time anywhere in P (a folder's own time misses edits to files inside)."""
    newest = p.lstat().st_mtime
    if p.is_dir() and not p.is_symlink():
        for dirpath, dirnames, filenames in os.walk(p):
            for n in dirnames + filenames:
                try:
                    newest = max(newest, os.lstat(os.path.join(dirpath, n)).st_mtime)
                except OSError:
                    continue
    return newest


def stale_archive() -> list[Path]:
    """Entries of archive/ untouched for KEEP_DAYS. archive/briefs/, which brief.sh adds to on
    every rewrite, is aged file by file, since its own newest time never grows old."""
    arc = STATE / "archive"
    if not arc.is_dir() or arc.is_symlink():
        return []
    cutoff = NOW - KEEP_DAYS * 86400
    out = []
    with os.scandir(arc) as it:
        for e in it:
            p = Path(e.path)
            if e.name == "briefs" and e.is_dir(follow_symlinks=False):
                with os.scandir(p) as inner:
                    out += [
                        Path(x.path)
                        for x in inner
                        if newest_mtime(Path(x.path)) < cutoff
                    ]
            elif newest_mtime(p) < cutoff:
                out.append(p)
    return sorted(out)


def remove(paths: list[Path], under: Path) -> int:
    """Delete each path, which must sit directly in UNDER; a link is unlinked, never followed."""
    failed = 0
    for p in paths:
        if p.parent != under:
            print(f"  refused: {p} is not in {under}")
            failed = 1
            continue
        try:
            if p.is_dir() and not p.is_symlink():
                shutil.rmtree(p)
            else:
                p.unlink()
        except OSError as exc:
            print(f"  could not remove {p.name}: {exc.strerror or exc}")
            failed = 1
    return failed


class FileLock:
    """An exclusive flock on PATH, waited for up to WAIT seconds; False from __enter__ when
    another holder kept it that long."""

    def __init__(self, path: Path, wait: float) -> None:
        self.path, self.wait = path, wait

    def __enter__(self) -> bool:
        self.f = open(self.path, "a")
        end = time.monotonic() + self.wait
        while True:
            try:
                fcntl.flock(self.f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except BlockingIOError:
                if time.monotonic() >= end:
                    return False
                time.sleep(0.2)

    def __exit__(self, *exc: object) -> None:
        self.f.close()


def tidy_files(part: str, apply: bool) -> int:
    if part != "briefs":
        return tidy_found(part, stale_archive(), apply)
    # Under the registry lock, as launch, done and pause write panes.tsv and the briefs.
    with FileLock(STATE / ".registry.lock", REGISTRY_WAIT_S) as held:
        if not held:
            print(
                f"briefs: refused: the registry lock was held for {REGISTRY_WAIT_S} s"
            )
            return 1
        try:
            found = stale_briefs()
        except RegistryUnreadable as exc:
            print(f"briefs: refused: {exc} → make it readable; nothing removed")
            return 1
        return tidy_found(part, found, apply)


def tidy_found(part: str, found: list[Path], apply: bool) -> int:
    under = STATE if part == "briefs" else STATE / "archive"
    what = (
        "briefs of agents gone over 7 days"
        if part == "briefs"
        else "archive entries untouched for 7 days"
    )
    print(f"{part}: {'removes' if apply else 'would remove'} {len(found)} {what}")
    for p in found[:5]:
        print(f"  {p.name}")
    if len(found) > 5:
        print(f"  ... and {len(found) - 5} more")
    if not apply or not found:
        return 0
    failed = 0
    for parent in sorted({p.parent for p in found}):
        if parent not in (under, under / "briefs"):
            print(f"  refused: {parent} is not {under}")
            failed = 1
            continue
        failed |= remove([p for p in found if p.parent == parent], parent)
    event(logging.INFO, f"{part} tidied", removed=len(found), failed=failed)
    return failed


# --- the briefing --------------------------------------------------------------------------

DAY = re.compile(r"(?<![\d-])(\d{1,2})-(\d{2})(?![\d-])")


def week_start(now: dt.datetime) -> dt.date:
    return now.date() - dt.timedelta(days=now.weekday())


def plan_queue(
    text: str, now: dt.datetime, done_sections
) -> tuple[str, list[str], int]:
    """(new text, dropped lines, undated lines kept) for queue.md: each Done section's list
    items dated before this week's Monday go, with their continuation lines."""
    lines = text.splitlines(keepends=True)
    monday = week_start(now)
    drop: set[int] = set()
    undated = 0
    heads = []
    for a, b, title in done_sections(text):
        heads.append(a - 1)
        i = a  # the line after the heading (0-based a)
        while i < b:
            ln = lines[i]
            if not ln.startswith("- "):
                i += 1
                continue
            j = i + 1
            while j < b and lines[j].strip() and not lines[j].startswith(("- ", "#")):
                j += 1
            m = DAY.search(ln)
            day = (
                month_day(int(m[1]), int(m[2]), now)
                if m and 1 <= int(m[1]) <= 12
                else None
            )
            if day is None:
                undated += 1
            elif day < monday:
                drop.update(range(i, j))
            i = j
    dropped = [lines[i].rstrip("\n") for i in sorted(drop) if lines[i].startswith("- ")]
    if drop:
        for h in heads:
            lines[h] = re.sub(
                r"(Done since )\d{1,2}-\d{2}", rf"\g<1>{monday:%m-%d}", lines[h]
            )
    new = "".join(ln for i, ln in enumerate(lines) if i not in drop)
    return new, dropped, undated


def tidy_queue(apply: bool, mod) -> int:
    path = BRIEFING / "queue.md"
    if mod is None:
        print("queue: skipped: techne's cleanup.py not found (set TECHNE_CLEANUP)")
        return 1
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"queue: no queue.md ({exc.strerror or exc})")
        return 1
    now = dt.datetime.fromtimestamp(NOW)
    new, dropped, undated = plan_queue(text, now, mod.done_sections)
    print(
        f"queue: {'drops' if apply else 'would drop'} {len(dropped)} Done lines dated before "
        f"{week_start(now):%a %m-%d} (harvest lessons from them first; GitHub holds the rest)"
        + (f"; {undated} undated lines stay" if undated else "")
    )
    for ln in dropped:
        print(f"  {ln[:140]}")
    if not apply or not dropped:
        return 0
    try:
        with BriefingLock():
            if path.read_text(encoding="utf-8") != text:
                print(
                    "queue: refused: queue.md changed during the tidy; nothing written"
                )
                return 1
            fd, tmp = tempfile.mkstemp(dir=BRIEFING, prefix=".queue.", suffix=".tmp")
            try:
                with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
                    f.write(new)
                os.replace(tmp, path)
            except BaseException:
                if os.path.exists(tmp):
                    os.unlink(tmp)
                raise
    except (OSError, subprocess.CalledProcessError) as exc:
        print(f"queue: failed, nothing written: {exc}")
        return 1
    event(logging.INFO, "queue Done lines dropped", dropped=len(dropped))
    return 0


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(BRIEFING), *args], capture_output=True, text=True, check=True
    ).stdout


class BriefingLock:
    """The lock the briefing sync and `fleet shots --apply` take (.git/fleet-sync.lock), so a
    sync never commits or rebases over half a change."""

    def __enter__(self):
        self.f = open(
            Path(git("rev-parse", "--absolute-git-dir").strip()) / "fleet-sync.lock",
            "w",
        )
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc: object) -> None:
        self.f.close()


def git_remove(paths: list[str], message: str) -> int:
    """git rm PATHS and commit only them, under the briefing lock, as `fleet shots --apply`
    does. A path changed or untracked since the scan stops it. On a failure only the files it
    removed come back: an edit someone saved meanwhile is never checked out over."""
    try:
        with BriefingLock():
            tracked = set(
                git("--literal-pathspecs", "ls-files", "-z", "--", *paths).split("\0")
            )
            dirty = [
                ln[3:]
                for ln in git(
                    "--literal-pathspecs", "status", "--porcelain", "-z", "--", *paths
                ).split("\0")
                if ln
            ]
            untracked = [p for p in paths if p not in tracked]
            if dirty or untracked:
                shown = ", ".join((dirty + untracked)[:3])
                print(f"  refused: changed or untracked since the scan: {shown}")
                return 1
            try:
                git("--literal-pathspecs", "rm", "-q", "--", *paths)
                git(
                    "-c",
                    "core.autocrlf=false",
                    "--literal-pathspecs",
                    "commit",
                    "-q",
                    "-m",
                    message,
                    "--",
                    *paths,
                )
            except subprocess.CalledProcessError:
                subprocess.run(
                    ["git", "-C", str(BRIEFING), "reset", "-q", "--", *paths],
                    check=False,
                    capture_output=True,
                )
                missing = [p for p in paths if not os.path.lexists(BRIEFING / p)]
                if missing:
                    subprocess.run(
                        ["git", "-C", str(BRIEFING), "checkout", "--", *missing],
                        check=False,
                        capture_output=True,
                    )
                raise
    except (OSError, subprocess.CalledProcessError) as exc:
        said = (getattr(exc, "stderr", "") or str(exc)).strip()
        print(f"  failed, nothing removed: {said[-200:]}")
        event(logging.ERROR, "briefing removal failed", said=said[-300:])
        return 1
    event(logging.INFO, "briefing files removed", files=len(paths), commit=message)
    return 0


def done_files() -> list[str]:
    try:
        return sorted(p for p in git("ls-files", "-z", "--", "done").split("\0") if p)
    except (OSError, subprocess.CalledProcessError):
        return []


def tidy_done(apply: bool) -> int:
    files = done_files()
    print(
        f"done: {'removes' if apply else 'would remove'} {len(files)} retired done/ files (GitHub holds the work; harvest lessons first)"
    )
    if not apply or not files:
        return 0
    return git_remove(files, "Retire done/: finished work lives in GitHub")


def briefing_status(mod):
    cfg = mod.Config()
    cfg.transient, cfg.keep = ["**"], list(BRIEFING_KEEP)
    return mod.transient_status(BRIEFING, cfg, dt.datetime.fromtimestamp(NOW).date())


def tidy_expired(apply: bool, mod) -> int:
    if mod is None:
        print("expired: skipped: techne's cleanup.py not found (set TECHNE_CLEANUP)")
        return 1
    status = briefing_status(mod)
    expired = getattr(
        status, "expired", None
    )  # techne's structured set; older copies lack it
    if expired is None:
        expired = {g for g, why in status.stale.items() if why.startswith("expired")}
    gone = {g: why for g, why in status.stale.items() if g in expired}
    files = sorted({f for g in gone for f in status.governs.get(g, [])})
    print(
        f"expired: {'removes' if apply else 'would remove'} {len(files)} files under {len(gone)} expired owners (harvest them first)"
    )
    for g, why in sorted(gone.items()):
        print(f"  {g}: {why}")
    if not apply or not files:
        return 0
    return git_remove(files, f"Remove {len(files)} expired briefing files")


# --- the timer's report --------------------------------------------------------------------


def report(out: Path) -> int:
    """Prune the shots, then write what the next tidy would do, for doctor. Never ends without
    a report: a timeout or a crash is written into it as `error`, so doctor names the cause."""
    data: dict = {
        "ts": int(NOW),
        "briefing": str(BRIEFING) if BRIEFING.is_dir() else None,
    }
    try:
        shots = subprocess.run(
            [
                sys.executable,
                "-I",
                os.environ.get("FLEET_PRUNE_SHOTS", str(HERE / "prune_shots.py")),
                "--apply",
            ],
            capture_output=True,
            text=True,
            timeout=540,
            check=False,
        )
        data["shots_rc"] = shots.returncode
        if shots.returncode:
            data["shots_said"] = (shots.stderr or shots.stdout).strip()[-300:]
    except subprocess.TimeoutExpired:
        data["shots_rc"], data["shots_said"] = 124, "timed out after 540 s"
    try:
        mod = techne_cleanup()
        data["techne"] = getattr(mod, "LOADED_FROM", None)
        if mod is not None and data["briefing"]:
            status = briefing_status(mod)
            data["unowned"] = sorted(
                u
                for k, names in status.bare.items()
                for u in ([f"{k}/"] if k else names)
            )
            data["stale"] = sorted(f"{g}: {why}" for g, why in status.stale.items())
            try:
                text = (BRIEFING / "queue.md").read_text(encoding="utf-8")
                data["queue_old"] = len(
                    plan_queue(text, dt.datetime.fromtimestamp(NOW), mod.done_sections)[
                        1
                    ]
                )
            except OSError:
                data["queue_old"] = 0
        data["done_files"] = len(done_files()) if data["briefing"] else 0
        try:
            data["heph_bytes"] = (STATE / "HEPH.md").stat().st_size
        except OSError:
            data["heph_bytes"] = 0
        if is_state_folder(STATE):
            data["briefs_stale"] = len(stale_briefs())
            data["archive_stale"] = len(stale_archive())
    except Exception as exc:  # the report is written whatever failed, naming it
        data["error"] = f"{type(exc).__name__}: {exc}"[:300]
    fd, tmp = tempfile.mkstemp(dir=out.parent, prefix=f".{out.name}.", suffix=".tmp")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)
    os.replace(tmp, out)
    event(
        logging.INFO,
        "cleanup report written",
        **{k: v for k, v in data.items() if isinstance(v, int)},
    )
    return 0


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="fleet tidy", description=__doc__.split("\n\n")[0]
    )
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--report", type=Path)
    ap.add_argument("parts", nargs="*", metavar="PART")
    a = ap.parse_args(argv)
    bad = [p for p in a.parts if p not in PARTS]
    if bad:
        ap.error(f"unknown part {bad[0]!r}; choose from {', '.join(PARTS)}")
    setup_log()
    if a.report:
        return report(a.report)
    parts = a.parts or list(PARTS)
    state_parts = {"heph", "briefs", "archive"} & set(parts)
    if state_parts and not is_state_folder(STATE):
        print(
            f"refused: {STATE} holds no panes.tsv, so it is not the fleet's state folder"
        )
        return 1
    lock = open(STATE / ".tidy.lock", "w") if state_parts else None
    if lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("refused: another fleet tidy is running")
            return 1
    mod = techne_cleanup() if {"queue", "expired"} & set(parts) else None
    failed = 0
    for part in parts:
        if part == "heph":
            failed |= tidy_heph(a.apply)
        elif part in ("briefs", "archive"):
            failed |= tidy_files(part, a.apply)
        elif part == "queue":
            failed |= tidy_queue(a.apply, mod)
        elif part == "done":
            failed |= tidy_done(a.apply)
        elif part == "expired":
            failed |= tidy_expired(a.apply, mod)
    if not a.apply:
        print("dry run: nothing changed; add --apply to do it")
    return failed


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
