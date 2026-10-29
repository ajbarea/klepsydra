#!/usr/bin/env python3
"""Watch the fleet repos' GitHub Actions runs and keep klepsydra's ci.json.

    python3 ci_watch.py [--once]

Every repo in ~/.claude/techne.toml with status "active" is polled every 2
minutes (longer when GitHub's x-poll-interval asks) with conditional requests:
an unchanged answer is a 304, which costs no rate limit. A run counts when it is
on the repo's default branch or at the head of an open pull request. The newest
completed run per workflow and branch decides: failure, timed_out or
startup_failure is red; a later green run clears it. Each new red run that is
not Dependabot's is triaged once by techne ci-audit's report mode (read-only),
and gets one line under "Needs you" in the queue file. Dependabot's reds are
listed for the morning instead. Once a day the latest green run on each default
branch is read for warnings. Nothing is pushed, merged or re-run.

ci.json (in klepsydra's data folder) is what the wall and the phone show. The
log is JSON lines in the fleet log folder, one per decision.
"""

import json
import logging
import logging.handlers
import os
import re
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.github.com"
RED = ("failure", "timed_out", "startup_failure")
POLL_S = 120
DEPENDABOT = "dependabot[bot]"
HOME = Path.home()
STATE = Path(os.environ.get("FLEET_STATE", HOME / ".local/state/fleet-orchestrator"))
KLEPSYDRA_DIR = Path(
    os.environ.get(
        "KLEPSYDRA_DIR", "/mnt/c/Users/ajbar/AppData/Local/dev.ajsoftworks.klepsydra"
    )
)
TECHNE_TOML = Path(os.environ.get("TECHNE_TOML", HOME / ".claude/techne.toml"))
QUEUE = Path(
    os.environ.get("FLEET_QUEUE", "/mnt/c/Users/ajbar/fleet-briefing/claude-queue.md")
)
SWEEP_HOUR = int(os.environ.get("CI_SWEEP_HOUR", "6"))

log = logging.getLogger("fleet::ci")


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
        folder / "ci.log", maxBytes=1 << 20, backupCount=4
    )
    handler.setFormatter(JsonLines())
    log.addHandler(handler)
    term = logging.StreamHandler(sys.stderr)
    term.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    log.addHandler(term)
    log.setLevel(logging.INFO)


def event(level: int, message: str, **fields: object) -> None:
    log.log(level, message, extra={"fields": fields})


def sisters(toml: Path) -> tuple[str, list[str]]:
    """The GitHub user and the names of the active sister repos."""
    data = tomllib.loads(toml.read_text())
    return data["github_user"], [
        s["name"] for s in data.get("sisters", []) if s.get("status") == "active"
    ]


class GitHub:
    """Conditional GETs: each path's ETag is kept, and a 304 answers with the last body."""

    def __init__(self, token: str, cache: Path):
        self.token = token
        self.cache_path = cache
        try:
            self.cache = json.loads(cache.read_text())
        except (OSError, ValueError):
            self.cache = {}
        self.poll_s = POLL_S

    def get(self, path: str):
        held = self.cache.get(path)
        req = urllib.request.Request(API + path)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("Authorization", f"Bearer {self.token}")
        if held:
            req.add_header("If-None-Match", held["etag"])
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = json.loads(r.read())
                if r.headers.get("ETag"):
                    self.cache[path] = {"etag": r.headers["ETag"], "body": body}
                self.poll_s = max(POLL_S, int(r.headers.get("X-Poll-Interval") or 0))
                return body
        except urllib.error.HTTPError as e:
            if e.code == 304 and held:
                return held["body"]
            raise

    def save(self) -> None:
        tmp = self.cache_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.cache))
        tmp.replace(self.cache_path)


def runs_that_count(user: str, repo: str, gh: GitHub) -> tuple[list[dict], str]:
    """The newest completed run per workflow and branch that is on the default
    branch or at an open PR's head, and the default branch."""
    meta = gh.get(f"/repos/{user}/{repo}")
    default = meta["default_branch"]
    pulls = gh.get(f"/repos/{user}/{repo}/pulls?state=open&per_page=50")
    heads = {p["head"]["sha"]: p for p in pulls}
    runs = gh.get(f"/repos/{user}/{repo}/actions/runs?per_page=50")["workflow_runs"]
    newest: dict[tuple, dict] = {}
    for r in runs:
        if r.get("status") != "completed":
            continue
        pr = heads.get(r["head_sha"])
        if r["head_branch"] != default and not pr:
            continue
        key = (r["workflow_id"], r["head_branch"])
        if key not in newest or r["created_at"] > newest[key]["created_at"]:
            newest[key] = r | {"_pr": pr}
    return list(newest.values()), default


def failing_step(user: str, repo: str, run_id: int, gh: GitHub) -> dict:
    jobs = gh.get(f"/repos/{user}/{repo}/actions/runs/{run_id}/jobs?per_page=100")[
        "jobs"
    ]
    for j in jobs:
        if j.get("conclusion") in RED:
            step = next(
                (s["name"] for s in j.get("steps") or [] if s.get("conclusion") in RED),
                None,
            )
            return {"job": j["name"], "step": step}
    return {}


def report_script() -> Path | None:
    """techne ci-audit's report.sh: TECHNE_CI_REPORT, else the newest installed copy."""
    if os.environ.get("TECHNE_CI_REPORT"):
        return Path(os.environ["TECHNE_CI_REPORT"])
    found = sorted(
        HOME.glob(
            ".claude/plugins/cache/techne/techne/*/skills/ci-audit/scripts/report.sh"
        ),
        key=lambda p: p.stat().st_mtime,
    )
    return found[-1] if found else None


def triage(user: str, repo: str, run_id: int) -> dict:
    """ci-audit's read-only report for one run, or why there is none."""
    script = report_script()
    if not script or not script.exists():
        return {
            "state": "unavailable",
            "why": "techne's ci-audit report mode is not installed",
        }
    out = STATE / "ci" / f"{repo}-{run_id}"
    got = subprocess.run(
        ["bash", str(script), f"{user}/{repo}", str(run_id), str(out)],
        capture_output=True,
        text=True,
        timeout=900,
    )
    if got.returncode:
        return {
            "state": "failed",
            "why": got.stderr.strip().splitlines()[-1:] or ["exit"],
        }
    r = json.loads((out / "report.json").read_text())
    f = r.get("failing_step") or {}
    return {
        "state": "done",
        "verdict": r["verdict"],
        "cause": f.get("root_cause") or r["summary"],
        "location": f.get("location"),
        "summary": r["summary"],
        "report": str(out / "report.md"),
    }


def needs_you(run: dict) -> None:
    """One line under the queue file's "Needs you" for a new red run, once."""
    if not QUEUE.exists():
        return
    mark = f"<!-- ci:{run['repo']}:{run['run_id']} -->"
    text = QUEUE.read_text()
    if mark in text:
        return
    t = run.get("triage", {})
    cause = t.get("cause") or "triage pending"
    where = f" ({t['location']})" if t.get("location") else ""
    line = f"- 🔴 **CI {run['repo']}**: {run['workflow']} failed on {run['branch']}: {cause}{where}. {run['url']} {mark}\n"
    m = re.search(r"^## Needs you[^\n]*\n", text, re.M)
    if not m:
        return
    QUEUE.write_text(text[: m.end()] + line + text[m.end() :])
    event(logging.INFO, "queue line added", repo=run["repo"], run_id=run["run_id"])


def write_json(path: Path, data: dict) -> None:
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=1))
    tmp.replace(path)


def poll(user: str, repos: list[str], gh: GitHub, known: dict) -> dict:
    """One pass: the red runs that count, triaged once each, and the Dependabot reds."""
    red, dependabot, errors = [], [], []
    for repo in repos:
        try:
            runs, _ = runs_that_count(user, repo, gh)
        except (urllib.error.URLError, KeyError, ValueError) as e:
            errors.append({"repo": repo, "error": str(e)[:200]})
            event(logging.WARNING, "repo not read", repo=repo, error=str(e)[:200])
            continue
        for r in runs:
            if r.get("conclusion") not in RED:
                continue
            pr = r["_pr"]
            item = {
                "repo": repo,
                "workflow": r["name"],
                "branch": r["head_branch"],
                "pr": pr["number"] if pr else None,
                "run_id": r["id"],
                "url": r["html_url"],
                "conclusion": r["conclusion"],
                "at": r["updated_at"],
            }
            if (pr and pr["user"]["login"] == DEPENDABOT) or r.get("actor", {}).get(
                "login"
            ) == DEPENDABOT:
                dependabot.append(item)
                continue
            key = f"{repo}:{r['id']}"
            if key not in known:
                item["failing"] = failing_step(user, repo, r["id"], gh)
                event(
                    logging.WARNING,
                    "red run",
                    repo=repo,
                    run_id=r["id"],
                    workflow=r["name"],
                    branch=r["head_branch"],
                    **{f"failing_{k}": v for k, v in item["failing"].items()},
                )
                item["triage"] = triage(user, repo, r["id"])
                event(
                    logging.INFO,
                    "triaged",
                    repo=repo,
                    run_id=r["id"],
                    **{
                        k: v
                        for k, v in item["triage"].items()
                        if k in ("state", "verdict", "location", "why")
                    },
                )
                known[key] = {k: item[k] for k in ("failing", "triage")}
                needs_you(item)
            item |= known[key]
            red.append(item)
    return {"red": red, "dependabot": dependabot, "errors": errors}


def sweep(user: str, repos: list[str], gh: GitHub) -> list[dict]:
    """Warnings on the latest green run of each default branch."""
    found = []
    for repo in repos:
        try:
            runs, default = runs_that_count(user, repo, gh)
        except (urllib.error.URLError, KeyError, ValueError):
            continue
        green = [
            r
            for r in runs
            if r["head_branch"] == default and r["conclusion"] == "success"
        ]
        for r in green:
            t = triage(user, repo, r["id"])
            if t.get("state") == "done" and t["verdict"] != "clean":
                found.append(
                    {
                        "repo": repo,
                        "workflow": r["name"],
                        "run_id": r["id"],
                        "url": r["html_url"],
                        "summary": t["summary"],
                        "report": t["report"],
                    }
                )
    return found


def main(argv: list[str]) -> int:
    setup_log()
    token = subprocess.run(
        ["gh", "auth", "token"], capture_output=True, text=True
    ).stdout.strip()
    if not token:
        event(logging.ERROR, "no GitHub login: run gh auth login")
        return 1
    (STATE / "ci").mkdir(parents=True, exist_ok=True)
    gh = GitHub(token, STATE / "ci" / "etags.json")
    known_path = STATE / "ci" / "known.json"
    try:
        known = json.loads(known_path.read_text())
    except (OSError, ValueError):
        known = {}
    user, repos = sisters(TECHNE_TOML)
    event(logging.INFO, "ci watch started", repos=len(repos), poll_s=POLL_S)
    last_sweep: dict = {}
    while True:
        state = poll(user, repos, gh, known)
        today = time.strftime("%F")
        if last_sweep.get("date") != today and time.localtime().tm_hour >= SWEEP_HOUR:
            last_sweep = {"date": today, "items": sweep(user, repos, gh)}
            event(logging.INFO, "daily sweep", items=len(last_sweep["items"]))
        state |= {
            "sweep": last_sweep,
            "v": 1,
            "observed_at": int(time.time()),
            "repos": len(repos),
        }
        write_json(KLEPSYDRA_DIR / "ci.json", state)
        write_json(known_path, known)
        gh.save()
        if "--once" in argv:
            return 0
        time.sleep(gh.poll_s)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
