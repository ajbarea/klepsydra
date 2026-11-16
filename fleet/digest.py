"""digest.py: generate fleet-briefing/today.md daily digest for Claude Duet.

Reads:
- Shipped/merged work from sister repos today (git log over the last 24h).
- Active jobs from fleet-briefing/queue.md (## Running now).
- High-priority tasks from fleet-briefing/needs-you.md (## Needs you).

Outputs a concise, 1-minute read markdown digest into fleet-briefing/today.md,
which mirrors to Google Drive for Claude Duet to read on session start.
"""

from __future__ import annotations

import argparse
import datetime
import os
import pathlib
import subprocess
import tempfile
import tomllib
from typing import NamedTuple

HOME = pathlib.Path.home()
BRIEFING_DIR = pathlib.Path(os.environ.get("BRIEFING_DIR", "/mnt/c/Users/ajbar/fleet-briefing"))
WORKSPACE_ROOT = pathlib.Path(os.environ.get("WORKSPACE_ROOT", "/home/ajbar/ajsoftworks"))
TECHNE_TOML = pathlib.Path(os.environ.get("TECHNE_TOML", HOME / ".claude/techne.toml"))


class CommitInfo(NamedTuple):
    repo: str
    sha: str
    subject: str
    committed_at: str


def get_sister_repos(root: pathlib.Path = WORKSPACE_ROOT) -> list[pathlib.Path]:
    """Return active sister repository paths."""
    sister_names: list[str] = []
    if TECHNE_TOML.is_file():
        try:
            data = tomllib.loads(TECHNE_TOML.read_text(encoding="utf-8"))
            for item in data.get("sisters", []):
                if item.get("status") == "active":
                    sister_names.append(item.get("name"))
        except Exception:
            pass

    if not sister_names:
        sister_names = [
            "keryx",
            "klepsydra",
            "talks",
            "techne",
            "askesis",
            "ajbarea.github.io",
            "classes/csci739-quantum-machine-learning",
            "sphragis",
            "papers",
            "phalanx-fl",
        ]

    repos: list[pathlib.Path] = []
    for name in sister_names:
        repo_dir = root / name
        if (repo_dir / ".git").is_dir() or (repo_dir / ".git").is_file():
            repos.append(repo_dir)
    return repos


def get_recent_commits(repo: pathlib.Path, since_hours: int = 24) -> list[CommitInfo]:
    """Get commits on main within the given time window."""
    since_arg = f"--since={since_hours} hours ago"
    try:
        cmd = [
            "git",
            "-C",
            str(repo),
            "log",
            "main",
            "-n",
            "10",
            since_arg,
            "--format=%h%x09%s%x09%cI",
        ]
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        commits: list[CommitInfo] = []
        for line in res.stdout.strip().splitlines():
            parts = line.split("\t")
            if len(parts) >= 3:
                sha, subj, ts = parts[0], parts[1], parts[2]
                commits.append(CommitInfo(repo=repo.name, sha=sha, subject=subj, committed_at=ts))
        return commits
    except Exception:
        return []


def parse_needs_you(briefing_dir: pathlib.Path = BRIEFING_DIR, max_items: int = 5) -> list[str]:
    """Extract top actionable lines from needs-you.md."""
    file_path = briefing_dir / "needs-you.md"
    if not file_path.is_file():
        return []

    content = file_path.read_text(encoding="utf-8")
    lines: list[str] = []
    in_section = False

    for raw in content.splitlines():
        line = raw.strip()
        if line.startswith("## Needs you") or line.startswith("## Waiting on your yes"):
            in_section = True
            continue
        elif line.startswith("## "):
            in_section = False

        if in_section and line.startswith("- "):
            # Strip markdown badges or simplify
            clean = line[2:].strip()
            # Drop finished items
            if clean.startswith("✅"):
                continue
            lines.append(clean)
            if len(lines) >= max_items:
                break

    return lines


def parse_running_now(briefing_dir: pathlib.Path = BRIEFING_DIR) -> list[str]:
    """Extract active jobs from queue.md ## Running now."""
    file_path = briefing_dir / "queue.md"
    if not file_path.is_file():
        return []

    content = file_path.read_text(encoding="utf-8")
    items: list[str] = []
    in_running = False

    for raw in content.splitlines():
        line = raw.strip()
        if line.startswith("## Running now"):
            in_running = True
            continue
        elif line.startswith("## "):
            in_running = False

        if in_running and (line.startswith("- 🔄") or line.startswith("- ⚡")):
            items.append(line[2:].strip())

    return items


def build_digest(
    briefing_dir: pathlib.Path = BRIEFING_DIR,
    workspace_root: pathlib.Path = WORKSPACE_ROOT,
    now: datetime.datetime | None = None,
) -> str:
    """Build the markdown body of today.md."""
    if now is None:
        now = datetime.datetime.now()

    date_str = now.strftime("%Y-%m-%d")
    time_str = now.strftime("%I:%M %p")

    # Collect commits
    all_commits: list[CommitInfo] = []
    for r in get_sister_repos(workspace_root):
        all_commits.extend(get_recent_commits(r, since_hours=24))

    # Parse queues
    needs_you = parse_needs_you(briefing_dir, max_items=5)
    running_now = parse_running_now(briefing_dir)

    lines: list[str] = [
        f"# Fleet Digest: {date_str}",
        f"*Updated {time_str} ET · Generated for Claude Duet & Fleet State*",
        "",
        "## Shipped & Merged (Last 24h)",
    ]

    if all_commits:
        lines.append("| Repo | Commit | Summary |")
        lines.append("| :--- | :--- | :--- |")
        for c in all_commits:
            # Clean subject if too long
            subj = c.subject if len(c.subject) <= 80 else c.subject[:77] + "..."
            lines.append(f"| `{c.repo}` | `{c.sha}` | {subj} |")
    else:
        lines.append("No new commits on main in the last 24 hours.")

    lines.append("")
    lines.append("## Running Now")
    if running_now:
        for item in running_now:
            lines.append(f"- {item}")
    else:
        lines.append("- All fleet queues clear; awaiting new tasks.")

    lines.append("")
    lines.append("## What Needs AJ")
    if needs_you:
        for item in needs_you:
            lines.append(f"- {item}")
    else:
        lines.append("- All clear; no blocking decisions or unreviewed items.")

    lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        help="Destination markdown file (default: $BRIEFING_DIR/today.md)",
    )
    parser.add_argument("--stdout", action="store_true", help="Print digest to stdout")
    args = parser.parse_args(argv)

    dest = pathlib.Path(args.out) if args.out else BRIEFING_DIR / "today.md"
    digest_text = build_digest(BRIEFING_DIR, WORKSPACE_ROOT)

    if args.stdout:
        print(digest_text)
        return 0

    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=dest.parent, delete=False, encoding="utf-8") as tmp:
        tmp.write(digest_text)
        tmp_path = pathlib.Path(tmp.name)

    tmp_path.replace(dest)
    print(f"✓ Wrote fleet digest to {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
