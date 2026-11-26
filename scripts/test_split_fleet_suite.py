"""Tests for scripts/split_fleet_suite.py against a copy of the real suite.

Run: python3 -I scripts/test_split_fleet_suite.py
"""

from __future__ import annotations

import json
import os
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
    """Every tracked file the selection reads, as a git repo."""
    files = subprocess.run(
        ["git", "-C", str(REPO), "ls-files"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.split()
    files += ["scripts/split_fleet_suite.py", "scripts/split-fleet-suite.sh"]
    for f in set(files):
        src = REPO / f
        if src.is_file() and src.suffix.lower() not in (
            ".png",
            ".webp",
            ".jpg",
            ".ico",
            ".icns",
        ):
            (dst / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst / f)
    subprocess.run(["git", "init", "-q", str(dst)], check=True)
    subprocess.run(["git", "-C", str(dst), "add", "-A"], check=True)
    subprocess.run(
        [
            "git",
            "-C",
            str(dst),
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            "copy",
        ],
        check=True,
    )


def run(repo: Path, *args: str, stdin: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-I", str(repo / "scripts" / "split_fleet_suite.py"), *args],
        input=stdin,
        capture_output=True,
        text=True,
    )


def shards(repo: Path) -> dict[str, str]:
    return {
        p.name: p.read_text()
        for p in sorted((repo / "fleet" / "tests" / "shards").glob("*.sh"))
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
            for ln in a[f"{s}.sh"].split("\n_group_name=tail ")[0].splitlines():
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
                ["bash", "-n", str(repo / "fleet" / "tests" / "shards" / f"{s}.sh")],
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
        check("app art no fleet code names runs none", sel("assets/new-icon.png"), [])
        check("no change runs none", sel(), [])
        check(
            "the README, which the suite reads, runs every shard",
            sel("README.md"),
            every,
        )
        check(
            "an IMPL.md, which the docs sweep reads, runs every shard",
            sel("IMPL.md"),
            every,
        )
        check(
            "the wall's Rust view, which the suite reads, runs every shard",
            sel("src-tauri/fleet/src/view.rs"),
            every,
        )
        check(
            "a file outside the app that nothing names runs every shard",
            sel("notes.txt"),
            every,
        )
        check(
            "launch.sh runs every shard",
            sel("fleet/launch.sh"),
            every,
        )
        subprocess.run(
            ["git", "-C", str(repo), "rm", "-q", "fleet/headless-rules.md"], check=True
        )
        check(
            "a deleted file the suite read still runs every shard",
            sel("fleet/headless-rules.md"),
            every,
        )
        subprocess.run(["git", "-C", str(repo), "reset", "-q", "--hard"], check=True)

        # The prelude's EXIT trap keeps the shard's abort note (one EXIT trap per shell).
        check(
            "the prelude's EXIT trap runs the abort note first",
            "trap 'shard_abort_trap; cleanup' EXIT" in a["prelude.sh"],
            True,
        )
        head = a["misc.sh"].split('. "$shard_dir/prelude.sh"')[0]
        probe = (
            head
            + "cleanup() { :; }\ntrap 'shard_abort_trap; cleanup' EXIT\n_group_name=probe _group_orig_line=7\necho \"$unbound\"\n"
        )
        r = subprocess.run(["bash", "-c", probe], capture_output=True, text=True)
        check(
            "a shard that aborts says where",
            (
                r.returncode != 0,
                "shard misc aborted" in r.stdout + r.stderr,
                "test_fleet.sh:7" in r.stdout + r.stderr,
            ),
            (True, True, True),
        )

        # A function that defines a one-liner inside it ends at its own brace (bash -n decides).
        sys.path.insert(0, str(repo / "scripts"))
        import split_fleet_suite as m

        nested = [
            "outer() { # A\n",
            "  ( inner() { cat; }\n",
            "    inner )\n",
            "}\n",
            "x=1\n",
        ]
        fns = [d for d in m.find_defs(nested, m.heredoc_mask(nested)) if d.kind == "fn"]
        check(
            "a nested one-liner does not end its function",
            [(d.name, d.end) for d in fns],
            [("outer", 3)],
        )

        # A # inside an expansion is no comment: the one-liner ends on its own line, and the
        # line after it (a side effect) is never replayed as part of it.
        hashy = [
            'sid_of() { echo "${1#o}"; }\n',
            'touch "$work/side-effect"\n',
            "after() {\n",
            "  :\n",
            "}\n",
        ]
        fns = [d for d in m.find_defs(hashy, m.heredoc_mask(hashy)) if d.kind == "fn"]
        check(
            "a # inside ${1#o} does not hide a function's end",
            [(d.name, d.start, d.end) for d in fns],
            [("sid_of", 0, 0), ("after", 2, 4)],
        )
        check(
            "a heredoc cut before its delimiter does not parse",
            m.parses("cat <<EOF\nx\n"),
            False,
        )

        # Every function of the real suite ends where bash says: the shortest run of lines
        # from its first that bash -n reads whole, with no warning.
        def bash_end(lines: list[str], i: int) -> int:
            for j in range(i, len(lines)):
                p = subprocess.run(
                    ["bash", "-n"],
                    input="".join(lines[i : j + 1]),
                    text=True,
                    capture_output=True,
                )
                if p.returncode == 0 and not p.stderr.strip():
                    return j
            return -1

        suite = (repo / "fleet" / "test_fleet.sh").read_text().splitlines(keepends=True)
        fns = [d for d in m.find_defs(suite, m.heredoc_mask(suite)) if d.kind == "fn"]
        check(
            "every function in the suite ends where bash -n says",
            [(d.name, d.end) for d in fns if d.end != bash_end(suite, d.start)],
            [],
        )

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
        src.write_text(text.replace("(( fail == 0 ))", "exit 0"))
        r = run(repo)
        check(
            "a suite that no longer ends with its verdict stops the split",
            (r.returncode, "verdict" in r.stderr),
            (1, True),
        )
        src.write_text(
            text.replace(
                "check_keryx_isolation\n",
                'check_keryx_isolation\ncheck "a tail check" a a\n',
            )
        )
        r = run(repo)
        check(
            "a check added to the suite's tail runs in every shard",
            (
                r.returncode,
                all(
                    'check "a tail check" a a' in t
                    for t in shards(repo).values()
                    if "_shard_finished" in t
                ),
            ),
            (0, True),
        )
        src.write_text(text)

        # A make that started a shard passes FLEET_SHARD on; the suite's make -n checks must not see it.
        r = subprocess.run(
            [
                "bash",
                "-c",
                head + 'make -s -n -C "$1" test-fleet FLEET_HEAVY_HELD=1',
                "x",
                str(repo),
            ],
            capture_output=True,
            text=True,
            env={**os.environ, "FLEET_SHARD": "misc", "MAKEFLAGS": "FLEET_SHARD=misc"},
        )
        check(
            "a shard started by make FLEET_SHARD= gives the suite a clean make",
            r.stdout.strip(),
            "bash fleet/test_fleet.sh",
        )

        # Only FLEET_SHARD= given to make picks a shard; one exported in the shell runs it all.
        def make_n(*args: str, **env: str) -> subprocess.CompletedProcess[str]:
            clean = {
                k: v
                for k, v in os.environ.items()
                if k not in ("FLEET_SHARD", "MAKEFLAGS")
            }
            return subprocess.run(
                [
                    "make",
                    "-s",
                    "-n",
                    "-C",
                    str(repo),
                    "test-fleet",
                    "FLEET_HEAVY_HELD=1",
                    *args,
                ],
                capture_output=True,
                text=True,
                env={**clean, **env},
            )

        exported = make_n(FLEET_SHARD="misc")
        check(
            "an exported FLEET_SHARD runs the whole suite, and make says it ignored it",
            (
                exported.stdout.strip(),
                "FLEET_SHARD from the environment is ignored" in exported.stderr,
            ),
            ("bash fleet/test_fleet.sh", True),
        )
        check(
            "make test-fleet FLEET_SHARD=misc runs the misc shard",
            make_n("FLEET_SHARD=misc")
            .stdout.strip()
            .endswith("exec bash fleet/tests/shards/misc.sh'"),
            True,
        )

    print(f"\n{'all passed' if not failures else f'{failures} failed'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
