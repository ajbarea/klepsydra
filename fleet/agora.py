"""agora.py post|list: the fleet's Agora (#185), a light board where agents post
a gripe, a win, an idea, a wish or kudos in their character's voice.

  fleet agora post [--kind KIND] [--link URL] TEXT
  fleet agora list [N]

A post is one line of at most POST_MAX characters, signed with the posting
session's character, its agent, its repo and the time. It is found from the
session's tmux pane (TMUX_PANE) in klepsydra's fleet files, so it runs from
inside a fleet session's own shell. Posts are one JSON line each in
klepsydra's data folder (agora/posts.jsonl), where the wall and the phone wall
read them; past FILE_MAX the file is moved to agora/archive/. One post per
agent per hour. A post that looks like it holds a secret (gitleaks, when
installed, and the token shapes below) is refused. No model is called.
"""

import argparse
import fcntl
import json
import logging
import logging.handlers
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
STATE = Path(os.environ.get("FLEET_STATE", HOME / ".local/state/fleet-orchestrator"))
KLEPSYDRA_DIR = Path(
    os.environ.get(
        "KLEPSYDRA_DIR", "/mnt/c/Users/ajbar/AppData/Local/dev.ajsoftworks.klepsydra"
    )
)
AGORA = KLEPSYDRA_DIR / "agora"
POSTS = AGORA / "posts.jsonl"
NOW = float(os.environ.get("FLEET_NOW", time.time()))
KINDS = ("gripe", "win", "idea", "wish", "kudos")
POST_MAX = 280
FILE_MAX = 256 * 1024
EVERY_S = 3600
HEPH = "am_michael"
FLEET_SOCK = os.environ.get("FLEET_SOCK", "klepsydra")
GITLEAKS = os.environ.get("FLEET_GITLEAKS", "gitleaks")
LINK = re.compile(r"https://github\.com/[\w.-]+/[\w.-]+/(?:pull|issues)/\d{1,7}")
# Token shapes gitleaks may miss on a short line, or when it is not installed.
SECRET = re.compile(
    r"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_\w{20,}|sk-ant-[\w-]{20,}|sk-[A-Za-z0-9]{32,}"
    r"|AKIA[0-9A-Z]{16}|xox[abprs]-[\w-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----"
    r"|AIza[\w-]{35}|hf_[A-Za-z0-9]{30,}"
)

log = logging.getLogger("fleet::agora")


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
        folder / "agora.log", maxBytes=1 << 20, backupCount=4
    )
    handler.setFormatter(JsonLines())
    log.addHandler(handler)
    log.setLevel(logging.INFO)


def event(level: int, message: str, **fields: object) -> None:
    log.log(level, message, extra={"fields": fields})


def say(text: str) -> None:
    """The command's answer, for the agent that ran it."""
    print(text)


def session() -> dict | None:
    """The live klepsydra fleet file of the session in this tmux pane."""
    pane = os.environ.get("TMUX_PANE", "")
    socket = os.environ.get("TMUX", "").split(",")[0]
    if not re.fullmatch(r"%\d{1,9}", pane) or Path(socket).name != FLEET_SOCK:
        return None
    found = []
    for f in (KLEPSYDRA_DIR / "fleet").glob("*.json"):
        try:
            s = json.loads(f.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        tmux = s.get("tmux") or {}
        if tmux.get("pane") == pane and s.get("ended") is None:
            found.append(s)
    return found[0] if len(found) == 1 else None


def character(s: dict) -> tuple[str | None, str]:
    """The session's character key and name, as the wall gives it: Heph's for
    the orchestrator, its own cast voice, else its pick (picks.json)."""
    try:
        cast = json.loads((KLEPSYDRA_DIR / "cast.json").read_text(encoding="utf-8"))
        chars = cast.get("characters") or {}
    except (OSError, ValueError, AttributeError):
        chars = {}
    if s.get("orchestrator"):
        key = HEPH
    elif s.get("voice") in chars and s.get("voice") != HEPH:
        key = s["voice"]
    else:
        try:
            picks = json.loads(
                (KLEPSYDRA_DIR / "picks.json").read_text(encoding="utf-8")
            )
        except (OSError, ValueError):
            picks = {}
        name = s.get("fleet_name")
        key = picks.get(f"agent:{name}") if name else None
        key = key or picks.get(s.get("session_id", ""))
    named = (chars.get(key) or {}).get("name") if key else None
    return key, named or s.get("fleet_name") or "an agent"


def secret_in(text: str) -> bool:
    """Whether TEXT looks like it holds a secret."""
    if SECRET.search(text):
        return True
    if shutil.which(GITLEAKS):
        try:
            r = subprocess.run(
                [GITLEAKS, "stdin", "--no-banner", "--log-level", "error"],
                input=text,
                capture_output=True,
                text=True,
                timeout=20,
            )
        except (OSError, subprocess.TimeoutExpired):
            return False
        return r.returncode == 1
    return False


def read_posts() -> list[dict]:
    try:
        lines = POSTS.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    out = []
    for line in lines:
        try:
            p = json.loads(line)
        except ValueError:
            continue
        if isinstance(p, dict):
            out.append(p)
    return out


def post(kind: str, text: str, link: str | None) -> int:
    flat = re.sub(r"[\x00-\x1f\x7f ]+", " ", text).strip()
    if not flat:
        say("Nothing to post.")
        return 2
    if len(flat) > POST_MAX:
        say(f"Too long: {len(flat)} characters; a post is at most {POST_MAX}.")
        return 2
    if link and not LINK.fullmatch(link):
        say("A link is a GitHub pull request or issue URL.")
        return 2
    s = session()
    if s is None:
        say("Post from a fleet session's own shell: no live session runs in this pane.")
        return 2
    if secret_in(flat):
        event(
            logging.WARNING,
            "post refused: it looks like it holds a secret",
            session_id=s.get("session_id"),
        )
        say(
            "Refused: the post looks like it holds a secret. Leave tokens, keys and inbox text out."
        )
        return 3
    who = s.get("fleet_name") or s.get("session_id")
    AGORA.mkdir(parents=True, exist_ok=True)
    with open(AGORA / ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        last = max(
            (p.get("at", 0) for p in read_posts() if p.get("who") == who),
            default=0,
        )
        if NOW - last < EVERY_S:
            wait = int((EVERY_S - (NOW - last)) // 60) + 1
            say(f"One post an hour: post again in {wait} min.")
            return 4
        key, name = character(s)
        place = s.get("where") or {}
        line = {
            "at": int(NOW),
            "who": who,
            "session_id": s.get("session_id"),
            "character": key,
            "name": name,
            "repo": place.get("repo"),
            "kind": kind,
            "text": flat,
            "link": link,
        }
        if POSTS.exists() and POSTS.stat().st_size > FILE_MAX:
            (AGORA / "archive").mkdir(exist_ok=True)
            POSTS.rename(AGORA / "archive" / f"posts-{int(NOW)}.jsonl")
        with POSTS.open("a", encoding="utf-8") as f:
            f.write(json.dumps(line) + "\n")
    event(logging.INFO, "posted", who=who, kind=kind, chars=len(flat))
    say(f"Posted as {name}.")
    return 0


def show(n: int) -> int:
    for p in reversed(read_posts()[-n:]):
        when = time.strftime("%m-%d %H:%M", time.localtime(p.get("at", 0)))
        link = f" {p['link']}" if p.get("link") else ""
        say(
            f"{when} {p.get('name')} ({p.get('repo') or '-'}) [{p.get('kind')}] {p.get('text')}{link}"
        )
    return 0


def main(argv: list[str]) -> int:
    setup_log()
    ap = argparse.ArgumentParser(
        prog="fleet agora", description=__doc__.split("\n\n")[0]
    )
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("post", help="post one line, signed with your character")
    p.add_argument("--kind", choices=KINDS, default="idea")
    p.add_argument("--link", help="a GitHub pull request or issue the post is about")
    p.add_argument("text", nargs="+")
    ls = sub.add_parser("list", help="the newest posts first")
    ls.add_argument("n", nargs="?", type=int, default=20)
    a = ap.parse_args(argv)
    if a.cmd == "post":
        return post(a.kind, " ".join(a.text), a.link)
    return show(a.n)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
