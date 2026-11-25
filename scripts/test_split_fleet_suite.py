"""Tests for scripts/split_fleet_suite.py against a copy of the real suite.

Run: python3 -I scripts/test_split_fleet_suite.py
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
failures = 0


def check(name: str, got: object, want: object) -> None:
    global failures
    if got == want:
        print(f"ok   {name}")
    else:
        failures += 1
        print(f"FAIL {name}\n  got:  {got!r}\n  want: {want!r}")


def copy_repo(dst: Path) -> None:
    """The generator, the suite and the files it can reach, as a git repo."""
    files = subprocess.run(
        ["git", "-C", str(REPO), "ls-files", "fleet", "hooks", "statusline", "scripts"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    files += ["scripts/split_fleet_suite.py", "scripts/split-fleet-suite.sh"]
    for f in set(files):
        src = REPO / f
        if src.is_file():
            (dst / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst / f)
    subprocess.run(["git", "init", "-q", str(dst)], check=True)
    subprocess.run(["git", "-C", str(dst), "add", "-A"], check=True)


def run(repo: Path, *args: str, stdin: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-I", str(repo / "scripts" / "split_fleet_suite.py"), *args],
        input=stdin,
        capture_output=True,
        text=True,
    )


def shards(repo: Path) -> dict[str, str]:
    return {
        p.name: p.read_text() for p in sorted((repo / "fleet" / "tests").glob("*.sh"))
    }


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        copy_repo(repo)
        every = json.loads(run(repo, "--list").stdout)
        check("--list names eleven shards", len(every), 11)

        first = run(repo)
        check("a split of the real suite succeeds", first.returncode, 0)
        a = shards(repo)
        run(repo)
        check("the split is deterministic", shards(repo), a)
        check(
            "one file per shard plus the prelude",
            sorted(a),
            sorted([f"{s}.sh" for s in every] + ["prelude.sh"]),
        )

        # Every check line of the suite lands in exactly one shard (the tail in all).
        suite = (repo / "fleet" / "test_fleet.sh").read_text().splitlines()
        tail = suite.index('echo "the suite\'s own isolation"')
        group_checks = sum(1 for ln in suite[:tail] if ln.strip().startswith("check "))
        prelude_checks = sum(
            1 for ln in a["prelude.sh"].splitlines() if ln.strip().startswith("check ")
        )
        in_bodies = 0
        for s in every:
            inside = False
            for ln in a[f"{s}.sh"].splitlines():
                if ln.startswith("_group_shard_line="):
                    inside = True
                elif ln.startswith("printf '%sgroup"):
                    inside = False
                elif inside and ln.strip().startswith("check "):
                    in_bodies += 1
        check(
            "the groups across shards hold every check line of the suite once",
            in_bodies,
            group_checks - prelude_checks,
        )

        # A definition another shard makes is replayed, from the suite, verbatim.
        check(
            "a later group sees the clock the full run has",
            "# replayed from fleet/test_fleet.sh:" in a["misc.sh"],
            True,
        )

        for s in every:
            r = subprocess.run(
                ["bash", "-n", str(repo / "fleet" / "tests" / f"{s}.sh")],
                capture_output=True,
                text=True,
            )
            check(f"{s}.sh parses", r.returncode, 0)

        def sel(*paths: str) -> list[str]:
            return json.loads(
                run(repo, "--select", stdin="\n".join(paths) + "\n").stdout
            )

        check("the suite itself runs every shard", sel("fleet/test_fleet.sh"), every)
        check("lib.sh runs every shard", sel("fleet/lib.sh"), every)
        check(
            "the fake pane under fleet/tests runs every shard",
            sel("fleet/tests/fake_pane.py"),
            every,
        )
        check("the workflow runs every shard", sel(".github/workflows/ci.yml"), every)
        check(
            "the generator runs every shard", sel("scripts/split_fleet_suite.py"), every
        )
        check("a page of the app runs none", sel("src/wall.js"), [])
        check("the README runs none", sel("README.md"), [])
        check("no change runs none", sel(), [])
        launch = sel("fleet/launch.sh")
        check("launch.sh reaches the launch shard", "launch" in launch, True)

        # Drift fails loudly instead of running a stale copy.
        src = repo / "fleet" / "test_fleet.sh"
        text = src.read_text()
        src.write_text(
            text.replace(
                "printf 'the brief body\\n' >\"$work/brief.src\"",
                "printf 'x\\n' >\"$work/brief.src\"",
            )
        )
        r = run(repo)
        check(
            "a fixture the suite no longer writes stops the split",
            (r.returncode, "fixture line" in r.stderr),
            (1, True),
        )
        src.write_text(text.replace("check_keryx_isolation\n\necho\n", "\necho\n"))
        r = run(repo)
        check(
            "a tail the shards no longer mirror stops the split",
            (r.returncode, "tail" in r.stderr),
            (1, True),
        )
        src.write_text(text + '\ncheck "after the summary" a a\n')
        r = run(repo)
        check("a check added to the suite needs no edit here", r.returncode, 0)
        src.write_text(text)

    print(f"\n{'all passed' if not failures else f'{failures} failed'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
