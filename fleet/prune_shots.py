"""prune_shots.py [--apply]: keep fleet-briefing/shots to what still awaits AJ.

Reads the open Review issues in the briefing repo (titled "Review: ...").
Each "## N. title" section, in the body or a comment, is answered once
every checkbox in it is ticked, or once a "Routed" comment names it ("- N "
or "§N"). An answered section's images leave shots/, as do images over
MAX_AGE_DAYS old (by their dated folder, else by when git added them),
since by then they were decided or forgotten. A shots/README.md line goes
when every image it names has gone. A Review issue closes once every
section is answered. Prints what it would do; with --apply it does it
(git rm and one commit, the README edit, the issue close), leaving the push
to the briefing sync. Also prints the repo's size, with an offer to squash
its history past SQUASH_AT_MB.
"""

import argparse
import fcntl
import fnmatch
import json
import logging
import logging.handlers
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
STATE = Path(os.environ.get("FLEET_STATE", HOME / ".local/state/fleet-orchestrator"))
REPO = Path(os.environ.get("BRIEFING_DIR", "/mnt/c/Users/ajbar/fleet-briefing"))
SLUG = os.environ.get("BRIEFING_SLUG", "ajbarea/fleet-briefing")
GH = os.environ.get("FLEET_GH", "gh")
NOW = float(os.environ.get("FLEET_NOW", time.time()))
MAX_AGE_DAYS = 14
SQUASH_AT_MB = 500

log = logging.getLogger("fleet::shots")


class JsonLines(logging.Formatter):
    """The app log's line: ts, level, target, message, then the event's own fields."""

    def format(self, record: logging.LogRecord) -> str:
        line = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created))
            + f".{int(record.msecs):03d}Z",
            "level": record.levelname.replace("WARNING", "WARN"),
            "target": record.name,
            "message": record.getMessage(),
        }
        line |= getattr(record, "fields", {})
        return json.dumps(line)


def setup_log() -> None:
    folder = STATE / "log"
    folder.mkdir(parents=True, exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(
        folder / "shots.log", maxBytes=1 << 20, backupCount=4
    )
    handler.setFormatter(JsonLines())
    log.addHandler(handler)
    term = logging.StreamHandler(sys.stderr)
    term.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(term)
    log.setLevel(logging.INFO)


def event(level: int, message: str, **fields: object) -> None:
    log.log(level, message, extra={"fields": fields})


def gh_json(*args: str) -> object:
    out = subprocess.run([GH, *args], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(REPO), *args], capture_output=True, text=True, check=True
    ).stdout


SECTION = re.compile(r"^## (\d+)\.", re.M)
IMAGE = re.compile(r"shots/([\w./{},-]+?\.(?:png|jpe?g|webp|gif))", re.I)
BOX = re.compile(r"^\s*- \[( |x|X)\]", re.M)


def sections(texts: list[str]) -> dict[int, str]:
    """Each numbered section's text, gathered from the body and the comments."""
    out: dict[int, str] = {}
    for text in texts:
        marks = list(SECTION.finditer(text))
        for i, m in enumerate(marks):
            end = marks[i + 1].start() if i + 1 < len(marks) else len(text)
            out[int(m.group(1))] = out.get(int(m.group(1)), "") + text[m.start() : end]
    return out


def routed(comments: list[str]) -> set[int]:
    """Section numbers a "Routed" comment answers."""
    done: set[int] = set()
    for c in comments:
        if c.lstrip().startswith("Routed"):
            done |= {int(n) for n in re.findall(r"^\s*- (\d+)\b", c, re.M)}
            done |= {int(n) for n in re.findall(r"§(\d+)", c)}
    return done


def answered(text: str) -> bool:
    boxes = BOX.findall(text)
    return bool(boxes) and all(b in "xX" for b in boxes)


def expand(name: str) -> list[str]:
    """A README name with {a,b} alternatives, as the file names it stands for."""
    m = re.search(r"\{([^{}]*)\}", name)
    if not m:
        return [name]
    return [
        x
        for alt in m.group(1).split(",")
        for x in expand(name[: m.start()] + alt + name[m.end() :])
    ]


def age_days(rel: str) -> float:
    """Days since the image's dated folder, else since git added it."""
    m = re.match(r"(\d{4}-\d{2}-\d{2})/", rel)
    if m:
        added = time.mktime(time.strptime(m.group(1), "%Y-%m-%d"))
    else:
        out = git(
            "log", "--diff-filter=A", "--format=%ct", "-1", "--", f"shots/{rel}"
        ).strip()
        added = float(out) if out else NOW
    return (NOW - added) / 86400


LINK = re.compile(r"\((\d{4}-\d{2}-\d{2}/[\w.,-]+?\.(?:png|jpe?g|webp|gif))\)", re.I)
STEM = re.compile(r"^- \*{0,2}([\w.{},*-]+?)\*{0,2}:")


def readme_names(line: str, date: str | None, have: set[str]) -> set[str]:
    """The images a README line names: its shots/ paths and dated links, and
    a leading `- name-{a,b}-x:` stem (a * is any text) under the date heading
    above it, as the files in shots/ it matches."""
    names = {x for n in IMAGE.findall(line) for x in expand(n)} | set(
        LINK.findall(line)
    )
    if date and (m := STEM.match(line)):
        for stem in expand(m.group(1)):
            names |= {h for h in have if fnmatch.fnmatch(h, f"{date}/{stem}*")}
    return names


IMAGE_FILE = re.compile(r"\.(?:png|jpe?g|webp|gif)$", re.I)


def apply(readme: Path, dropped: set[str], gone: dict[str, str]) -> bool:
    """Remove the images and README lines in one commit of only those paths, under the lock the
    briefing sync takes, so a sync never commits half of it. Under the lock it checks again: an
    image changed since the scan stops the prune (the next run decides), and the README is
    re-read so lines added meanwhile stay. On any failure the removals are unstaged, only the
    files it removed come back, and the error is logged."""
    paths = [f"shots/{img}" for img in sorted(gone)]
    before = readme.read_text() if readme.exists() else ""
    lock = None
    try:
        lock = open(REPO / ".git" / "fleet-sync.lock", "w")
        fcntl.flock(lock, fcntl.LOCK_EX)
        changed = [
            ln[3:]
            for ln in git("status", "--porcelain", "--", *paths).splitlines()
            if ln[3:] in paths
        ]
        if changed:
            event(
                logging.WARNING,
                "shots prune skipped: images changed",
                paths=changed[:5],
            )
            print(f"prune skipped: {', '.join(changed[:3])} changed since the scan")
            return True
        before = readme.read_text() if readme.exists() else ""
        keep = [ln for ln in before.splitlines(keepends=True) if ln not in dropped]
        git("--literal-pathspecs", "rm", "-q", "--ignore-unmatch", "--", *paths)
        readme.write_text("".join(keep))
        git("add", "--", "shots/README.md")
        message = (
            f"Shots: remove {len(gone)} images decided or over {MAX_AGE_DAYS} days old"
        )
        git(
            "-c",
            "core.autocrlf=false",
            "--literal-pathspecs",
            "commit",
            "-q",
            "-m",
            message,
            "--",
            "shots/README.md",
            *paths,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        said = getattr(exc, "stderr", "") or str(exc)
        subprocess.run(
            ["git", "-C", str(REPO), "reset", "-q", "--", "shots"], check=False
        )
        missing = [x for x in paths if not (REPO / x).exists()]
        if missing:
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(REPO),
                    "--literal-pathspecs",
                    "checkout",
                    "-q",
                    "--",
                    *missing,
                ],
                check=False,
            )
        if readme.exists() or before:
            readme.write_text(before)
        event(
            logging.ERROR, "shots prune failed; nothing removed", said=str(said)[-300:]
        )
        print(f"prune failed, nothing removed: {str(said).strip()[-200:]}")
        return False
    finally:
        if lock is not None:
            lock.close()
    event(logging.INFO, "shots pruned", removed=len(gone), readme_lines=len(dropped))
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--apply", action="store_true", help="remove, edit, commit and close for real"
    )
    args = ap.parse_args()
    setup_log()
    failed = 0
    shots = REPO / "shots"
    # Tracked images only: an untracked or edited file is not the sync's yet, and never removed.
    tracked = git("ls-files", "-z", "--", "shots").split("\0")
    dirty = set(git("status", "--porcelain", "-z", "--", "shots").split("\0"))
    have = {
        t[len("shots/") :]
        for t in tracked
        if IMAGE_FILE.search(t) and not any(d.endswith(t) for d in dirty if d)
    }

    gone: dict[str, str] = {}  # image -> why it goes
    shown: set[str] = set()  # images an open section still shows, in any Review issue
    closing: list[int] = []
    issues = gh_json(
        "issue",
        "list",
        "-R",
        SLUG,
        "--state",
        "open",
        "--search",
        "Review: in:title",
        "--json",
        "number,title,body,comments",
    )
    for issue in issues:
        if not issue["title"].startswith("Review:"):
            continue
        comments = [c["body"] for c in issue.get("comments", [])]
        secs = sections([issue["body"], *comments])
        done = routed(comments)
        open_secs = []
        for n, text in sorted(secs.items()):
            if n in done or answered(text):
                for img in IMAGE.findall(text):
                    for x in expand(img):
                        if x in have:
                            gone.setdefault(
                                x, f"answered in Review #{issue['number']} §{n}"
                            )
            else:
                open_secs.append(n)
                shown |= {x for img in IMAGE.findall(text) for x in expand(img)}
        if secs and not open_secs:
            closing.append(issue["number"])
        print(
            f"Review #{issue['number']}: {len(secs) - len(open_secs)} of {len(secs)} sections answered"
        )
    for img in sorted(have):
        if img not in gone and age_days(img) > MAX_AGE_DAYS:
            gone[img] = f"over {MAX_AGE_DAYS} days old"
    for img in shown & gone.keys():
        del gone[img]

    readme = shots / "README.md"
    lines = readme.read_text().splitlines(keepends=True) if readme.exists() else []
    keep, date = [], None
    for ln in lines:
        if m := re.match(r"## (\d{4}-\d{2}-\d{2})", ln):
            date = m.group(1)
        names = readme_names(ln, date, have)
        if not (names and names <= gone.keys()):
            keep.append(ln)

    verb = "removed" if args.apply else "would remove"
    for img, why in sorted(gone.items()):
        print(f"{verb}: shots/{img} ({why})")
    print(
        f"{'' if args.apply else 'would '}drop {len(lines) - len(keep)} README lines; "
        f"{'closed' if args.apply else 'would close'}: {', '.join(f'#{n}' for n in closing) or 'none'}"
    )

    pruned = True
    if args.apply and (gone or len(keep) != len(lines)):
        pruned = apply(readme, {ln for ln in lines if ln not in keep}, gone)
        failed |= not pruned
    if args.apply and pruned:
        for n in closing:
            r = subprocess.run(
                [
                    GH,
                    "issue",
                    "close",
                    str(n),
                    "-R",
                    SLUG,
                    "--comment",
                    "Every section is answered and its images are removed from shots/ "
                    "(git history keeps them). New shots go in the next Review issue.",
                ],
                capture_output=True,
                text=True,
            )
            if r.returncode:
                failed = 1
                event(
                    logging.ERROR,
                    "review issue not closed",
                    issue=n,
                    said=r.stderr[-300:],
                )
            else:
                event(logging.INFO, "review issue closed", issue=n)

    size_mb = 0.0
    for ln in git("count-objects", "-v").splitlines():
        k, _, v = ln.partition(": ")
        if k in ("size", "size-pack"):
            size_mb += int(v) / 1024
    note = (
        f"; past {SQUASH_AT_MB} MB, offer AJ a history squash"
        if size_mb > SQUASH_AT_MB
        else ""
    )
    print(f"briefing repo: {size_mb:.0f} MB{note}")
    event(
        logging.INFO,
        "shots checked",
        remove=len(gone),
        close=len(closing),
        size_mb=round(size_mb),
        applied=args.apply,
    )
    return failed


if __name__ == "__main__":
    sys.exit(main())
