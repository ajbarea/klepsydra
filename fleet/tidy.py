"""tidy.py (`fleet tidy`): delete the finished history the fleet keeps outside git and GitHub.

Usage:
    fleet tidy [--apply] [PART ...]   a dry run without --apply writes every line and path
                                      that would go to tidy-preview.md in the state folder,
                                      and --apply drops only what that list shows (a part
                                      with anything unlisted refuses);
                                      PART is one or more of heph briefs archive queue done
                                      expired (default: all)
    fleet tidy --report FILE          the fleet-cleanup timer: prune the shots (fleet shots
                                      --apply), then write what is still left to FILE for doctor

Finished work is recorded once, in merged PRs, closed issues and git history, so:
  heph     HEPH.md keeps its head, its START HERE block, undated sections, standing rules and
           its last HEPH_KEEP lines (FLEET_HEPH_KEEP, 600 by default): position alone decides,
           so a line goes only once that many newer lines sit below it, whatever any clock
           says. A dated later START HERE block reaching within START_MARGIN lines of the cut
           refuses the tidy. What goes is copied to archive/ for KEEP_DAYS first (HEPH.md is in no repo). Refused while another
           process has it open or wrote it in the last WRITE_QUIET_S seconds. Its time is kept,
           since `fleet recover` reads AJ's messages since HEPH.md was last written. Writers
           take no lock, so a write between the last check and the swap is lost, and the kept
           time hides the rewrite from an editor's modified-since-read check: run it when the
           orchestrator is between turns.
  briefs   a fresh-*.src untouched for KEEP_DAYS, and a task-*.src once its agent finished over
           KEEP_DAYS ago (one with no registry row waits for a launch); never one of an agent
           in panes.tsv or paused.tsv. Each is moved to archive/briefs/ for KEEP_DAYS more.
  archive  entries of the state folder's archive/ untouched for KEEP_DAYS days, and each
           file of archive/briefs/ (brief.sh adds one per rewrite).
  queue    the briefing's Done lines dated before this week's Monday (the Monday sweep);
           a line with no date stays. Harvest lessons from the dry run's list first.
  done     the briefing's retired done/ week files (git rm, one commit).
  expired  briefing files past the `expires` date their frontmatter carries,
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
import collections
import contextlib
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
KEEP_DAYS = 7
WRITE_QUIET_S = 120


def wait_seconds(raw: str | None) -> float:
    """FLEET_REGISTRY_WAIT in seconds; empty, unreadable or out of range falls back to 60."""
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
    r"^(?:task-(?P<t>.+)|fresh-(?P<f>.+?)(?:-\d{8}-\d{4}(?:-recover|-resume)?)?)\.src$"
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
WINDOW_DAYS = 330  # a MM-DD further back than this is a future event named, not a date


# The queue alone reads dates (its Done lines, against this week's Monday); HEPH.md never does.
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


def split_lines(text: str) -> list[str]:
    """TEXT's lines with their endings, split at \n alone: a form feed, U+2028 or a lone \r is
    part of a line, never a break, and \r\n stays as it was."""
    parts = text.split("\n")
    out = [p + "\n" for p in parts[:-1]]
    if parts[-1]:
        out.append(parts[-1])
    return out


STANDING = re.compile(
    r"\b(?:standing|permanent|binding)\b", re.I
)  # a rule AJ set to last


def undated(heading: str) -> bool:
    """Whether a ## heading names no date-shaped text (a regex, never a clock)."""
    return not (FULL_DATE.search(heading) or SHORT_DATE.search(heading))


def keep_lines(raw: str | None) -> int:
    """FLEET_HEPH_KEEP: how many log lines HEPH.md keeps; empty or no positive number is 600."""
    try:
        v = int(raw or "600")
    except ValueError:
        return 600
    return v if v > 0 else 600


HEPH_KEEP = keep_lines(os.environ.get("FLEET_HEPH_KEEP"))
START_MARGIN = 100  # a later START HERE this close above the cut refuses the tidy


def plan_heph(
    text: str, keep_last: int = 0, guard: bool = True
) -> tuple[list[str], dict]:
    """The lines HEPH.md keeps, and a summary of what goes. Position alone decides, never a
    clock or a date: the last KEEP_LAST lines (HEPH_KEEP) stay, so a line goes only once that
    many newer lines sit below it; above that cut the head, the first START HERE block,
    undated sections and standing rules stay too. Raises ValueError when there is no START
    HERE block, or another one sits within START_MARGIN lines above the cut, where it may be
    a recent handoff written lower down."""
    keep_last = keep_last or HEPH_KEEP
    lines = split_lines(text)
    heads = [i for i, ln in enumerate(lines) if H2.match(ln)]
    if not heads:
        raise ValueError("HEPH.md has no ## sections")
    starts = [i for i in heads if lines[i][3:].upper().startswith("START HERE")]
    if not starts:
        raise ValueError("HEPH.md has no ## START HERE block")
    s0 = starts[0]
    s1 = next((i for i in heads if i > s0), len(lines))
    cut = max(0, len(lines) - keep_last)  # every line from here down stays
    for s in starts[1:] if guard else []:
        # A dated block (an undated one is kept whole anyway) that reaches into the margin
        # above the cut, by any of its lines, may be a recent handoff: refuse.
        end = next((h for h in heads if h > s), len(lines))
        if s < cut and end > cut - START_MARGIN and not undated(lines[s]):
            raise ValueError(
                f"line {s + 1} is a START HERE block just above the kept lines: merge it into "
                "the top one, or keep more lines (FLEET_HEPH_KEEP)"
            )
    kept_whole: set[int] = set()  # lines of undated sections
    for n, h in enumerate(heads):
        if undated(lines[h]):
            kept_whole.update(
                range(h, heads[n + 1] if n + 1 < len(heads) else len(lines))
            )
    keep = set(range(heads[0])) | set(range(s0, s1)) | set(range(cut, len(lines)))
    standing = 0
    losses: list[tuple[str, int]] = []
    for n, h in enumerate(heads):
        if s0 <= h < s1:
            continue
        end = heads[n + 1] if n + 1 < len(heads) else len(lines)
        body = range(h + 1, end)
        # A blank line keeps nothing alive; it stays with the section around it.
        recent = [i for i in body if lines[i].strip() and (i in kept_whole or i >= cut)]
        new = set(recent)
        marked = [i for i in body if i not in new and STANDING.search(lines[i])]
        standing += len(marked)
        recent += marked  # a standing rule stays until someone moves it to its home
        if h in kept_whole or recent:  # a heading below the cut is kept with it
            keep.add(h)
            keep.update(recent)
            keep.update(i for i in body if not lines[i].strip())
            lost = sum(1 for i in body if i not in keep)
            if lost:
                losses.append((lines[h].strip(), lost))
    kept = [ln for i, ln in enumerate(lines) if i in keep]
    dropped_lines = [ln for i, ln in enumerate(lines) if i not in keep]
    return kept, {
        "lines": len(lines),
        "kept": len(kept),
        "bytes": len(text.encode("utf-8", "surrogateescape")),
        "kept_bytes": len("".join(kept).encode("utf-8", "surrogateescape")),
        "sections_dropped": [lines[h].strip() for h in heads if h not in keep],
        "losses": losses,
        "dropped_lines": dropped_lines,
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
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
        text = f.read()  # newline="": every line ending kept byte for byte
    now = dt.datetime.fromtimestamp(NOW)
    try:
        kept, s = plan_heph(text)
    except ValueError as exc:
        print(f"heph: refused: {exc}; nothing dropped")
        return 1
    gone = s["lines"] - s["kept"]
    print(
        f"heph: HEPH.md {s['lines']} lines ({s['bytes'] // 1024} KB) -> {s['kept']} "
        f"({s['kept_bytes'] // 1024} KB): the head, START HERE and the last {HEPH_KEEP} lines; "
        f"{'drops' if apply else 'would drop'} {gone} lines in {len(s['sections_dropped'])} sections"
    )
    if not preview("heph", [ln.rstrip("\r\n") for ln in s["dropped_lines"]], apply):
        return 1
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
    # The clock reads behind the file: no telling whether it is being written.
    if st.st_mtime > NOW:
        print(
            f"heph: refused: HEPH.md's time ({dt.datetime.fromtimestamp(st.st_mtime):%Y-%m-%d %H:%M}) "
            f"is later than the clock ({now:%Y-%m-%d %H:%M}); if the clock is right, "
            "`touch` HEPH.md and run it again"
        )
        return 1
    if NOW - st.st_mtime < WRITE_QUIET_S:
        print(
            f"heph: refused: HEPH.md was written {NOW - st.st_mtime:.0f} s ago; run it again in a few minutes"
        )
        return 1
    pids = open_elsewhere(path)
    if pids:
        print(f"heph: refused: HEPH.md is open in pid {', '.join(map(str, pids))}")
        return 1
    # What goes is kept for KEEP_DAYS in archive/, which the archive part then expires, so
    # anything dropped is recoverable for a week (HEPH.md is in no repo).
    arc = safe_archive(STATE / "archive")
    if arc is None:
        print(
            "heph: refused: archive/ is a link or no folder; the dropped lines need a safe copy first"
        )
        return 1
    copy = arc / f"HEPH-dropped-{dt.datetime.fromtimestamp(NOW):%Y%m%d-%H%M%S}.md"
    with open(copy, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write("".join(s["dropped_lines"]))
        f.flush()
        os.fsync(f.fileno())  # on disk before HEPH.md loses these lines
    fd, tmp = tempfile.mkstemp(dir=STATE, prefix=".HEPH.", suffix=".tmp")
    try:
        with os.fdopen(
            fd, "w", encoding="utf-8", errors="surrogateescape", newline=""
        ) as f:
            f.write("".join(kept))
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, stat.S_IMODE(st.st_mode))
        os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
        now_st = path.lstat()
        if (now_st.st_mtime_ns, now_st.st_size) != (st.st_mtime_ns, st.st_size):
            os.unlink(tmp)
            copy.unlink(missing_ok=True)  # nothing was dropped after all
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


def protected() -> tuple[set[str], set[str], dict[str, float]]:
    """(names, paths) of agents whose briefs stay: every row of panes.tsv and paused.tsv, and
    agents finished or unpaused in the last KEEP_DAYS days; and, for agents finished before
    that, when they last finished: only a task brief older than that may go."""
    names: set[str] = set()
    paths: set[str] = set()
    gone: dict[str, float] = {}
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
            ended = dt.datetime.fromisoformat(when).timestamp()
        except ValueError:
            ended = NOW  # an unreadable time is kept, never guessed old
        if ended >= cutoff:
            names.update(r[1:2])
            paths.update(f for f in r if f.endswith(".src"))
        elif r[1:2]:
            gone[r[1]] = max(gone.get(r[1], 0.0), ended)
    for r in rows(STATE / "unpaused.tsv"):
        names.update(r[:1])
    return names - {""}, paths, gone


def stale_briefs() -> list[Path]:
    """Briefs that may go: a fresh brief (pasted once at launch) untouched for KEEP_DAYS, and a
    task brief only once its agent finished over KEEP_DAYS ago, and only if the brief is no
    newer than that finish. A task brief with no registry row waits for a launch, and one
    written after its agent's last finish is a new brief for a reused name: both stay."""
    names, paths, gone = protected()
    cutoff = NOW - KEEP_DAYS * 86400
    out = []
    with os.scandir(STATE) as it:
        for e in it:
            m = BRIEF.match(e.name)
            if not m or not e.is_file(follow_symlinks=False):
                continue
            name = m["t"] or m["f"]
            mtime = e.stat(follow_symlinks=False).st_mtime
            if (
                (m["t"] is not None and mtime > gone.get(name, -1.0))
                or name in names
                or e.path in paths
                or mtime >= cutoff
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


PREVIEW: dict[str, list[str]] = {}  # this dry run's list, by part
PREVIEW_FILE = "tidy-preview.md"
PREVIEW_HEAD = "# fleet tidy: everything the dry run would drop\n\n"


def read_preview() -> dict[str, list[str]]:
    """The saved dry-run list, by part. Each section names its item count, so an item that
    is blank or looks like a heading is still read as an item. Missing or garbled: empty."""
    try:
        # newline="": no \r is turned into a line break
        with open(
            STATE / PREVIEW_FILE, encoding="utf-8", errors="surrogateescape", newline=""
        ) as f:
            rows = f.read()
    except OSError:
        return {}
    lines = rows.split("\n")  # only \n: an item may hold any other line break
    if lines and lines[-1] == "":
        lines.pop()
    out: dict[str, list[str]] = {}
    i = 2 if lines[:2] == PREVIEW_HEAD.splitlines() else len(lines)
    while i < len(lines):
        m = re.fullmatch(r"## (\w+) \((\d+)\)", lines[i])
        if not m or i + 1 + int(m[2]) > len(lines):
            return {}
        out[m[1]] = lines[i + 1 : i + 1 + int(m[2])]
        i += 1 + int(m[2])
    return out


def preview(part: str, items: list[str], apply: bool) -> bool:
    """A dry run records every line or path PART would drop. With --apply, whether PART may
    go ahead: only when each item it would drop is in the saved dry-run list, so nothing
    goes that no one was shown (a line that crossed the age limit since then included)."""
    if not apply:
        PREVIEW[part] = items
        return True
    if not items:
        return True
    left = collections.Counter(read_preview().get(part, []))
    left.subtract(items)
    unlisted = -sum(n for n in left.values() if n < 0)
    if unlisted:
        print(
            f"{part}: refused: {unlisted} of {len(items)} not in the dry run's list "
            f"({PREVIEW_FILE}); run `fleet tidy {part}`, read it, then --apply again"
        )
        return False
    return True


def save_preview(sections: dict[str, list[str]]) -> Path:
    out = STATE / PREVIEW_FILE
    if not is_state_folder(
        STATE
    ):  # only into the state folder; os.replace swaps a link itself
        raise OSError("not the state folder")
    if not sections:
        out.unlink(missing_ok=True)
        return out
    body = PREVIEW_HEAD + "".join(
        f"## {part} ({len(items)})\n" + "".join(f"{x}\n" for x in items)
        for part, items in sections.items()
    )
    fd, tmp = tempfile.mkstemp(dir=STATE, prefix=".tidy-preview.", suffix=".tmp")
    try:
        with os.fdopen(
            fd, "w", encoding="utf-8", errors="surrogateescape", newline=""
        ) as f:
            f.write(body)
        os.replace(tmp, out)
    except OSError:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise
    return out


def write_preview(ran: list[str]) -> str:
    """Merge this dry run's list into the saved one: the parts it ran are replaced (a part
    with nothing to drop leaves no section), the others kept. Printed when it cannot be saved."""
    sections = {k: v for k, v in read_preview().items() if k not in ran}
    sections |= {k: v for k, v in PREVIEW.items() if v}
    try:
        out = save_preview(sections)
    except OSError:
        sys.stdout.write(
            "".join(
                f"## {k} ({len(v)})\n" + "".join(f"{x}\n" for x in v)
                for k, v in PREVIEW.items()
                if v
            )
        )
        return "the full list is above"
    if not any(PREVIEW.values()):
        return "nothing would go"
    return f"the full list is in {out}"


def forget_preview(applied: list[str]) -> None:
    """After --apply, the applied parts' lists are out of date; the others stay."""
    sections = read_preview()
    if any(k in sections for k in applied):
        with contextlib.suppress(OSError):
            save_preview({k: v for k, v in sections.items() if k not in applied})


def safe_archive(arc: Path) -> Path | None:
    """ARC, made if missing, or None when it is a link or not a folder."""
    if arc.is_symlink():
        return None
    try:
        arc.mkdir(exist_ok=True)
    except OSError:
        return None
    return arc  # mkdir raised above when ARC is a file


def shelve(paths: list[Path], under: Path) -> int:
    """Move each brief, which must sit directly in UNDER, to archive/briefs/ stamped now, so the
    archive part keeps it KEEP_DAYS more: a brief removed in error comes back from there."""
    arc = safe_archive(STATE / "archive")
    dest = safe_archive(arc / "briefs") if arc else None
    if dest is None:
        print(
            "  refused: archive/ or archive/briefs/ is a link or no folder; nothing moved"
        )
        return 1
    stamp = f"{dt.datetime.fromtimestamp(NOW):%Y%m%d-%H%M%S}"
    failed = 0
    for p in paths:
        if p.parent != under:
            print(f"  refused: {p} is not in {under}")
            failed = 1
            continue
        to = dest / f"{p.name}.tidy-{stamp}"
        try:
            os.replace(p, to)
            os.utime(to, follow_symlinks=False)
        except OSError as exc:
            print(f"  could not move {p.name}: {exc.strerror or exc}")
            failed = 1
    return failed


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
    listed = [
        str(p.relative_to(STATE)) if p.is_relative_to(STATE) else str(p) for p in found
    ]
    if not preview(part, listed, apply):
        return 1
    if not apply or not found:
        return 0
    failed = 0
    for parent in sorted({p.parent for p in found}):
        if parent not in (under, under / "briefs"):
            print(f"  refused: {parent} is not {under}")
            failed = 1
            continue
        mine = [p for p in found if p.parent == parent]
        failed |= shelve(mine, parent) if part == "briefs" else remove(mine, parent)
    event(logging.INFO, f"{part} tidied", removed=len(found), failed=failed)
    return failed


# --- the briefing --------------------------------------------------------------------------

DAY = re.compile(r"(?<![\d-])(\d{1,2})-(\d{2})(?![\d-])")
HOUSE_DAY = re.compile(
    r"\*\*[A-Z][a-z]{2} (\d{1,2})-(\d{2})\b"
)  # the queue's own "**Fri 11-20"


def week_start(now: dt.datetime) -> dt.date:
    return now.date() - dt.timedelta(days=now.weekday())


def plan_queue(
    text: str, now: dt.datetime, done_sections
) -> tuple[str, list[str], int]:
    """(new text, every dropped line, undated items kept) for queue.md: each Done section's
    list items dated before this week's Monday go, with their continuation lines."""
    lines = split_lines(text)
    if len(lines) != len(text.splitlines()):
        # techne numbers lines with str.splitlines; a break it splits on and \n does not
        # (U+2028, a form feed, a lone \r) would point its spans at the wrong lines.
        raise ValueError(
            "queue.md holds a line break other than \\n; edit that line by hand"
        )
    monday = week_start(now)
    drop: set[int] = set()
    undated_items = 0
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
            m = HOUSE_DAY.search(ln) or DAY.search(ln)  # **Fri 11-20 first
            day = (
                month_day(int(m[1]), int(m[2]), now)
                if m and 1 <= int(m[1]) <= 12
                else None
            )
            if day is None:
                undated_items += 1
            elif day < monday:
                drop.update(range(i, j))
            i = j
    dropped = [lines[i].rstrip("\r\n") for i in sorted(drop)]
    if drop:
        for h in heads:
            lines[h] = re.sub(
                r"(Done since )\d{1,2}-\d{2}", rf"\g<1>{monday:%m-%d}", lines[h]
            )
    new = "".join(ln for i, ln in enumerate(lines) if i not in drop)
    return new, dropped, undated_items


def read_exact(path: Path) -> str:
    """PATH's text with every line ending as written (no \r\n turned into \n)."""
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
        return f.read()


def done_items(dropped: list[str]) -> int:
    return sum(1 for ln in dropped if ln.startswith("- "))


def tidy_queue(apply: bool, mod) -> int:
    path = BRIEFING / "queue.md"
    if mod is None:
        print("queue: skipped: techne's cleanup.py not found (set TECHNE_CLEANUP)")
        return 1
    try:
        text = read_exact(path)
    except OSError as exc:
        print(f"queue: no queue.md ({exc.strerror or exc})")
        return 1
    now = dt.datetime.fromtimestamp(NOW)
    try:
        new, dropped, undated = plan_queue(text, now, mod.done_sections)
    except ValueError as exc:
        print(f"queue: refused: {exc}; nothing dropped")
        return 1
    print(
        f"queue: {'drops' if apply else 'would drop'} {done_items(dropped)} Done items "
        f"({len(dropped)} lines) dated before "
        f"{week_start(now):%a %m-%d} (harvest lessons from them first; GitHub holds the rest)"
        + (f"; {undated} undated lines stay" if undated else "")
    )
    for ln in dropped:
        print(f"  {ln[:140]}")
    if not preview("queue", dropped, apply):
        return 1
    if not apply or not dropped:
        return 0
    try:
        with BriefingLock():
            if read_exact(path) != text:
                print(
                    "queue: refused: queue.md changed during the tidy; nothing written"
                )
                return 1
            fd, tmp = tempfile.mkstemp(dir=BRIEFING, prefix=".queue.", suffix=".tmp")
            try:
                with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
                    f.write(new)
                    f.flush()
                    os.fsync(f.fileno())
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
    if not preview("done", files, apply):
        return 1
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
    if not preview("expired", files, apply):
        return 1
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
            # The same briefing and state this tidy reads, never the defaults.
            env=os.environ | {"BRIEFING_DIR": str(BRIEFING), "FLEET_STATE": str(STATE)},
        )
        data["shots_rc"] = shots.returncode
        if shots.returncode:
            said = (shots.stderr or shots.stdout).strip().splitlines()
            data["shots_said"] = (
                said[-1][-300:] if said else ""
            )  # the last line: the error
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
                text = read_exact(BRIEFING / "queue.md")
                data["queue_old"] = done_items(
                    plan_queue(text, dt.datetime.fromtimestamp(NOW), mod.done_sections)[
                        1
                    ]
                )
            except OSError:
                data["queue_old"] = 0
            except ValueError as exc:
                data["queue_old"] = 0
                data["queue_refused"] = str(exc)[:200]
        data["done_files"] = len(done_files()) if data["briefing"] else 0
        try:
            data["heph_bytes"] = (STATE / "HEPH.md").stat().st_size
        except OSError:
            data["heph_bytes"] = 0
        if is_state_folder(STATE):
            heph = STATE / "HEPH.md"
            if heph.is_file() and not heph.is_symlink():
                text = read_exact(heph)
                try:
                    plan_heph(text)
                    why = None
                except ValueError as exc:  # doctor names why a tidy would refuse
                    why = str(exc)[:200]
                try:
                    _, s = plan_heph(text, guard=False)  # what a tidy would drop
                    data["heph_drop"] = s["lines"] - s["kept"]
                    # A tidy is due once a batch of half the kept lines would go, so the
                    # warning does not come back with every line appended after a tidy.
                    data["heph_due"] = data["heph_drop"] >= max(1, HEPH_KEEP // 2)
                    if why and data["heph_due"]:
                        data["heph_refused"] = why
                except ValueError:  # no START HERE at all: nothing can be planned
                    data["heph_refused"] = why
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
    # Every run that may write the saved list holds the lock, briefing-only runs too.
    lock = open(STATE / ".tidy.lock", "a") if is_state_folder(STATE) else None
    if lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("refused: another fleet tidy is running")
            return 1
    mod = techne_cleanup() if {"queue", "expired"} & set(parts) else None
    failed = 0
    done: list[str] = []
    for part in parts:
        if part == "heph":
            rc = tidy_heph(a.apply)
        elif part in ("briefs", "archive"):
            rc = tidy_files(part, a.apply)
        elif part == "queue":
            rc = tidy_queue(a.apply, mod)
        elif part == "done":
            rc = tidy_done(a.apply)
        else:
            rc = tidy_expired(a.apply, mod)
        failed |= rc
        if rc == 0:
            done.append(part)
    if not a.apply:
        print(f"dry run: nothing changed; {write_preview(parts)}; add --apply to do it")
    elif is_state_folder(STATE):
        forget_preview(done)  # a refused part keeps its list for the next try
    return failed


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
