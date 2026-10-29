#!/usr/bin/env python3
"""Watch the fleet repos' GitHub Actions runs and keep klepsydra's ci.json.

    python3 ci_watch.py [--once]

Every repo in ~/.claude/techne.toml with status "active" is polled every 2
minutes (longer when GitHub's x-poll-interval asks) with conditional requests:
an unchanged answer is a 304, which costs no rate limit. A run counts when it is
on the repo's default branch or at the head of an open pull request. The newest
completed run per workflow and branch that succeeded or failed decides
(a cancelled, skipped or neutral run decides nothing): failure, timed_out or
startup_failure is red; a later green run clears it. Each new red run that is
not Dependabot's is triaged once by techne ci-audit's report mode (read-only),
and gets one line under "Needs you" in the queue file. Dependabot's reds are
listed for the morning instead. Once a day the latest green run on each default
branch is read for warnings. Nothing is pushed, merged or re-run.

ci.json (in klepsydra's data folder) is what the wall and the phone show. The
log is JSON lines in the fleet log folder, one per decision. No error stops
the watch: a repo that cannot be read is skipped for the pass and logged, and
what it has triaged is saved as soon as it is, so a restart triages nothing twice.
"""

import json
import logging
import logging.handlers
import os
import re
import subprocess
import sys
import time
import threading
import tomllib
import urllib.error
import urllib.request
from pathlib import Path

API = "https://api.github.com"
RED = ("failure", "timed_out", "startup_failure")
DECISIVE = RED + ("success",)
KEEP_REPORTS_S = 14 * 86400
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

    def get(self, path: str, keep=None):
        """GET PATH; with KEEP (the body cut to what is read), its ETag and that cut are kept."""
        held = self.cache.get(path) if keep else None
        req = urllib.request.Request(API + path)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        req.add_header("Authorization", f"Bearer {self.token}")
        if held:
            req.add_header("If-None-Match", held["etag"])
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                body = json.loads(r.read())
                if keep:
                    body = keep(body)
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


RUN_FIELDS = (
    "id",
    "name",
    "workflow_id",
    "head_branch",
    "head_sha",
    "status",
    "conclusion",
    "created_at",
    "updated_at",
    "html_url",
)


def slim_runs(body: dict) -> list[dict]:
    return [
        {k: r.get(k) for k in RUN_FIELDS}
        | {
            "actor": (r.get("actor") or {}).get("login"),
            "repo": (r.get("head_repository") or {}).get("full_name"),
        }
        for r in body.get("workflow_runs", [])
    ]


def slim_pulls(body: list) -> list[dict]:
    return [
        {"number": p["number"], "sha": p["head"]["sha"], "user": p["user"]["login"]}
        for p in body
    ]


def runs_that_count(
    user: str, repo: str, gh: GitHub
) -> tuple[list[dict], str, set[int]]:
    """The decisive run (succeeded or failed) newest per workflow and branch, on
    the default branch or at an open PR's head, and the default branch. Each is
    asked for by branch or by head, so a busy repo cannot page one out."""
    meta = gh.get(
        f"/repos/{user}/{repo}",
        keep=lambda b: {
            "default_branch": b["default_branch"],
            "full_name": b["full_name"],
        },
    )
    # A transferred repo answers under its new owner; compared without case.
    default, own = meta["default_branch"], meta["full_name"].lower()
    pulls = gh.get(
        f"/repos/{user}/{repo}/pulls?state=open&per_page=100", keep=slim_pulls
    )
    runs = gh.get(
        f"/repos/{user}/{repo}/actions/runs?branch={default}&status=completed&per_page=100",
        keep=slim_runs,
    )
    for p in pulls:
        runs = runs + [
            r | {"_pr": p}
            for r in gh.get(
                f"/repos/{user}/{repo}/actions/runs?head_sha={p['sha']}&per_page=50",
                keep=slim_runs,
            )
        ]
    newest: dict[tuple, dict] = {}
    for r in runs:
        if r.get("status") != "completed" or r.get("conclusion") not in DECISIVE:
            continue
        pr = r.get("_pr")
        r["fork"] = (r.get("repo") or own).lower() != own
        if not pr and (r["head_branch"] != default or r["fork"]):
            continue
        key = (r["workflow_id"], pr["number"] if pr else default)
        if key not in newest or r["created_at"] > newest[key]["created_at"]:
            newest[key] = r | {"_pr": pr}
    return list(newest.values()), default, {p["number"] for p in pulls}


def workflow_ids(user: str, repo: str, gh) -> list[int]:
    """The ids of the repo's workflows that are still active."""
    return gh.get(
        f"/repos/{user}/{repo}/actions/workflows?per_page=100",
        keep=lambda b: [
            w["id"] for w in b.get("workflows", []) if w.get("state") == "active"
        ],
    )


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
    try:
        got = subprocess.run(
            ["bash", str(script), f"{user}/{repo}", str(run_id), str(out)],
            capture_output=True,
            text=True,
            timeout=900,
        )
        if got.returncode:
            return {
                "state": "failed",
                "why": (got.stderr.strip().splitlines() or ["exit"])[-1][:300],
            }
        r = json.loads((out / "report.json").read_text())
    except (subprocess.TimeoutExpired, OSError, ValueError) as e:
        return {"state": "failed", "why": f"{type(e).__name__}: {e}"[:300]}
    f = r.get("failing_step") or {}
    return {
        "state": "done",
        "verdict": r["verdict"],
        "cause": f.get("root_cause") or r["summary"],
        "location": f.get("location"),
        "summary": r["summary"],
        "report": str(out / "report.md"),
    }


def one_line(text: str, cap: int = 200) -> str:
    """TEXT as one plain line for the queue file: no newline, control character or leading #."""
    flat = re.sub(r"[\x00-\x1f\x7f]+", " ", text).strip().lstrip("#").strip()
    return flat[:cap]


def needs_you(run: dict) -> bool:
    """One line under the queue file's "Needs you" for a new red run, once.
    True when the line is there (written now or before)."""
    if not QUEUE.exists():
        event(logging.WARNING, "queue line not written: no queue file", path=str(QUEUE))
        return False
    mark = f"<!-- ci:{run['repo']}:{run['run_id']} -->"
    tmp = QUEUE.with_name(f".{QUEUE.name}.{os.getpid()}.tmp")
    try:
        return add_queue_line(run, mark, tmp)
    except (OSError, ValueError) as e:
        tmp.unlink(missing_ok=True)
        event(
            logging.WARNING,
            "queue line not written: the file could not be changed",
            error=str(e)[:200],
        )
        return False


def add_queue_line(run: dict, mark: str, tmp: Path) -> bool:
    for _ in range(3):
        before = QUEUE.stat().st_mtime_ns
        text = QUEUE.read_text(encoding="utf-8")
        if mark in text:
            return True
        m = re.search(r"^## Needs you[^\n]*\n", text, re.M)
        if not m:
            event(
                logging.WARNING,
                "queue line not written: no Needs you heading",
                path=str(QUEUE),
            )
            return False
        t = run.get("triage", {})
        cause = one_line(t.get("cause") or "triage pending")
        where = f" ({one_line(t['location'], 120)})" if t.get("location") else ""
        what = one_line(f"{run['workflow']} failed on {run['branch']}", 160)
        line = f"- 🔴 **CI {one_line(run['repo'], 60)}**: {what}: {cause}{where}. {run['url']} {mark}\n"
        tmp.write_text(text[: m.end()] + line + text[m.end() :], encoding="utf-8")
        if (
            QUEUE.stat().st_mtime_ns != before
        ):  # someone saved it meanwhile: read it again
            tmp.unlink(missing_ok=True)
            continue
        tmp.replace(QUEUE)
        event(logging.INFO, "queue line added", repo=run["repo"], run_id=run["run_id"])
        return True
    event(
        logging.WARNING,
        "queue line not written: the file kept changing",
        repo=run["repo"],
    )
    return False


def write_json(path: Path, data: dict) -> None:
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=1))
    tmp.replace(path)


def poll(
    user: str, repos: list[str], gh: GitHub, known: dict, save_known=lambda: None
) -> dict:
    """One pass: the red runs that count, triaged once each, and the Dependabot reds.
    A repo that fails anywhere is skipped for this pass and logged."""
    red, dependabot, errors = [], [], []
    for repo in repos:
        try:
            red_here, dep_here = repo_pass(user, repo, gh, known, save_known)
        except Exception as e:  # noqa: BLE001 — one repo never stops the watch
            errors.append({"repo": repo, "error": f"{type(e).__name__}: {e}"[:200]})
            event(
                logging.WARNING,
                "repo not read",
                repo=repo,
                error=f"{type(e).__name__}: {e}"[:200],
            )
            continue
        red += red_here
        dependabot += dep_here
    return {"red": red, "dependabot": dependabot, "errors": errors}


def repo_pass(
    user: str, repo: str, gh: GitHub, known: dict, save_known
) -> tuple[list, list]:
    red, dependabot = [], []
    # Read before anything is triaged, so a failed read changes nothing.
    runs, _, open_prs = runs_that_count(user, repo, gh)
    workflows = set(workflow_ids(user, repo, gh))
    for r in runs:
        place = (r["workflow_id"], r["_pr"]["number"] if r["_pr"] else "default")
        if r.get("conclusion") not in RED:
            for k in known.values():
                held = k.get("item")
                if (
                    held
                    and held["repo"] == repo
                    and (held["workflow_id"], held["place"]) == place
                ):
                    k.pop("item")
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
        if (pr and pr["user"] == DEPENDABOT) or r.get("actor") == DEPENDABOT:
            dependabot.append(item)
            continue
        key = f"{repo}:{r['id']}"
        if key not in known and r["fork"]:
            known[key] = {
                "failing": {},
                "triage": {
                    "state": "skipped",
                    "why": "a fork's PR: its logs are not triaged",
                },
                "queued": True,
            }
            save_known()
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
            known[key] = {
                "failing": item["failing"],
                "triage": item["triage"],
                "queued": False,
            }
            save_known()
        known[key]["item"] = item | {
            "workflow_id": r["workflow_id"],
            "place": pr["number"] if pr else "default",
        }
        if not known[key].get("queued"):
            known[key]["queued"] = needs_you(item | known[key])
            save_known()
        known[key]["seen"] = int(time.time())
        item |= {k: known[key][k] for k in ("failing", "triage")}
        red.append(item)
    # 2. A red run whose workflow ran no newer decisive run stays red even when it has
    # paged out of the newest runs: only a newer run of the same workflow and place clears it.
    # A held red goes when its PR is no longer open, its workflow is gone, a newer
    # red took its place, or it is a month old.
    places = {
        (r["workflow_id"], r["_pr"]["number"] if r["_pr"] else "default"): r["id"]
        for r in runs
    }
    month = time.time() - 30 * 86400
    for key, k in known.items():
        held = k.get("item")
        if not (key.startswith(f"{repo}:") and held):
            continue
        place = (held["workflow_id"], held["place"])
        newer = places.get(place) not in (None, held["run_id"])
        gone = (held["place"] != "default" and held["place"] not in open_prs) or held[
            "workflow_id"
        ] not in workflows
        if newer or gone or k.get("seen", 0) < month:
            k.pop("item")
            continue
        if place not in places:
            red.append(
                {x: v for x, v in held.items() if x not in ("workflow_id", "place")}
                | {"failing": k["failing"], "triage": k["triage"]}
            )
    return red, dependabot


def sweep(user: str, repos: list[str], gh: GitHub, swept: set) -> list[dict]:
    """Warnings on the latest green run of each default branch, each run read once."""
    found = []
    for repo in repos:
        try:
            runs, default, _ = runs_that_count(user, repo, gh)
        except Exception as e:  # noqa: BLE001 — the sweep skips what it cannot read
            event(
                logging.WARNING,
                "sweep: repo not read",
                repo=repo,
                error=f"{type(e).__name__}: {e}"[:200],
            )
            continue
        green = [
            r
            for r in runs
            if r["head_branch"] == default
            and r["conclusion"] == "success"
            and not r["_pr"]
            and r["id"] not in swept
        ]
        for r in green:
            swept.add(r["id"])
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


def prune_reports(folder: Path, now: float) -> None:
    """Remove the triage folders report.sh made (it marks each run/ folder) once
    older than two weeks. Never follows a symlink: a link is removed as a link."""
    for d in folder.glob("*-*"):
        mark = d / "run" / ".ci-report-run"
        if (
            d.is_symlink()
            or not d.is_dir()
            or (d / "run").is_symlink()
            or not mark.is_file()
        ):
            continue
        if now - d.stat().st_mtime <= KEEP_REPORTS_S:
            continue
        for top, dirs, files in os.walk(d, topdown=False, followlinks=False):
            for name in files:
                (Path(top) / name).unlink()
            for name in dirs:
                p = Path(top) / name
                p.unlink() if p.is_symlink() else p.rmdir()
        d.rmdir()
        event(logging.INFO, "old triage removed", folder=d.name)


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
    for v in known.values():
        v.setdefault("seen", int(time.time()))
    user, repos = sisters(TECHNE_TOML)
    event(logging.INFO, "ci watch started", repos=len(repos), poll_s=POLL_S)
    sweep_path = STATE / "ci" / "sweep.json"
    try:
        last_sweep = json.loads(sweep_path.read_text())
    except (OSError, ValueError):
        last_sweep = {}
    sweeping: threading.Thread | None = None

    def save_known() -> None:
        write_json(known_path, known)

    def run_sweep(today: str) -> None:
        nonlocal last_sweep
        try:
            sweep_gh = GitHub(token, STATE / "ci" / "sweep-etags.json")
            swept = set(last_sweep.get("swept", []))
            items = sweep(user, repos, sweep_gh, swept)
            sweep_gh.save()
            last_sweep = {"date": today, "items": items, "swept": sorted(swept)[-2000:]}
            write_json(sweep_path, last_sweep)
            event(logging.INFO, "daily sweep", items=len(items))
        except Exception:  # noqa: BLE001 — logged; tomorrow's sweep tries again
            log.exception("daily sweep failed")

    while True:
        try:
            state = poll(user, repos, gh, known, save_known)
            today = time.strftime("%F")
            due = (
                last_sweep.get("date") != today
                and time.localtime().tm_hour >= SWEEP_HOUR
            )
            if (
                due
                and (sweeping is None or not sweeping.is_alive())
                and "--once" not in argv
            ):
                sweeping = threading.Thread(
                    target=run_sweep, args=(today,), daemon=True
                )
                sweeping.start()
            state |= {
                "sweep": {k: v for k, v in last_sweep.items() if k != "swept"},
                "v": 1,
                "observed_at": int(time.time()),
                "repos": len(repos),
            }
            try:
                write_json(KLEPSYDRA_DIR / "ci.json", state)
            except OSError:
                log.exception("ci.json not written")
            month = time.time() - 30 * 86400
            for key in [
                k
                for k, v in known.items()
                if v.get("seen", month + 1) < month and "item" not in v
            ]:
                del known[key]
            save_known()
            gh.save()
            prune_reports(STATE / "ci", time.time())
        except Exception:  # noqa: BLE001 — logged; the next pass tries again
            log.exception("a pass failed")
        if "--once" in argv:
            return 0
        time.sleep(gh.poll_s)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
