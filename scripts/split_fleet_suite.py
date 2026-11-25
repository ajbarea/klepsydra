"""Split fleet/test_fleet.sh into shard files CI runs in parallel (#547).

fleet/test_fleet.sh stays the only source: the shards are generated at job
start and never committed. Each shard is the suite's prelude, then the
definitions its groups read from groups it does not hold (the last one of
each name before the group, copied verbatim), then its groups.

Run: python3 -I scripts/split_fleet_suite.py            write fleet/tests/*.sh
     python3 -I scripts/split_fleet_suite.py --select   changed paths on stdin,
                                                         prints the shards to run
     python3 -I scripts/split_fleet_suite.py --list     prints every shard
"""

from __future__ import annotations

import collections
import fnmatch
import json
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "fleet" / "test_fleet.sh"
OUT = ROOT / "fleet" / "tests"
TAIL_HEADER = 'echo "the suite\'s own isolation"'

# A change to any of these reaches every shard.
CORE = (
    "fleet/test_fleet.sh",
    "fleet/lib.sh",
    "fleet/tests/",
    "scripts/split-fleet-suite.sh",
    "scripts/split_fleet_suite.py",
    ".github/workflows/ci.yml",
    "Makefile",
)
# The app's own code, which no fleet script runs: a change here that no shard
# names runs no shard. Any other change no shard names runs every shard.
APP_ONLY = ("src/", "src-tauri/", "assets/")
NOT_APP_ONLY = ("src/fleet/", "src-tauri/fleet/")
# Values a pure assignment may not copy: they differ from run to run.
VOLATILE_RE = re.compile(
    r"\$\{?(?:[!?$#@*0-9-]|RANDOM\b|SECONDS\b|BASHPID\b|LINENO\b|EPOCH)"
)

TABLE = [
    (
        "resume",
        [
            r"^reset times$",
            r"^reading the screen$",
            r"^limits from events",
            r"^resume: limits, resets",
            r"^resume: what AJ typed",
            r"^resume: review round",
            r"^round 4: AJ resumed",
            r"^live_session$",
            r"^registry session ids",
            r"^resume: menus, the orchestrator",
            r"^resume: a fresh session after a long idle",
        ],
    ),
    (
        "launch",
        [
            r"^launch\.sh",
            r"^launch without worker settings",
        ],
    ),
    (
        "brief",
        [
            r"^briefs$",
            r"^#515: the context budget",
            r"^briefing sync",
            r"^briefing mirror to Drive",
            r"^fleet send:",
            r"^#515: a brief naming",
        ],
    ),
    (
        "doctor",
        [
            r"^doctor$",
            r"^install$",
            r"^the running server reads the installed conf",
        ],
    ),
    (
        "accounts",
        [
            r"^cut-over$",
            r"^two accounts: picking one$",
            r"^fresh-now moves every row",
            r"^two accounts: launch$",
            r"^two accounts: the resume service$",
            r"^two accounts: the orchestrator at a limit",
            r"^two accounts: back to the preferred account",
            r"^two accounts: the second folder follows the first$",
        ],
    ),
    (
        "accounts-move",
        [
            r"^two accounts: a worker that keeps background work is asked to move back",
            r"^two accounts: Heph's preferred account is the other end",
            r"^two accounts: Heph's pane watcher never holds his move back",
        ],
    ),
    (
        "accounts-review",
        [
            r"^two accounts: review round 1$",
            r"^two accounts: moves side by side, retried, and before the limit",
            r"^two accounts: review round 3$",
        ],
    ),
    (
        "close",
        [
            r"^a finished agent is never relaunched",
            r"^fleet done reports the finish",
            r"^relaunch never leaves two agents on one row",
        ],
    ),
    (
        "watcher",
        [
            r"^CI reds typed into the agent",
            r"^the watcher",
            r"^fleet pause",
            r"^background stale",
            r"^cell [A-Z]",
            r"^hostile screen",
            r"^the tmux server watchdog",
        ],
    ),
    (
        "recover",
        [
            r"^recover after a hard shutdown",
            r"^the orchestrator's config folder",
            r"^an agent's own IMPL\.md",
            r"^finished agents: one verdict per row",
            r"^recover:",
            r"^resume: Heph's session is recorded",
            r"^the orchestrator's identity across",
        ],
    ),
    (
        "misc",
        [
            r"^fleet voices: keryx follows",
            r"^keryx isolation check",
            r"^the fleet log$",
        ],
    ),
]
SHARDS = [area for area, _ in TABLE]

# Setup every shard needs that no definition carries: folders, the tmux server
# and fixture files that earlier groups write as a side effect of a longer
# line. Each fixture line must appear verbatim in the suite (checked below).
PLUMBING = [
    "export work FLEET_LOG",
    'mkdir -p "$work/bin" "$work/cfg-a" "$FLEET_STATE/log"',
    "t start-server 2>/dev/null || true",
]
FIXTURES = [
    "printf 'the brief body\\n' >\"$work/brief.src\"",
    "printf 'handoff\\n' >\"$work/HEPH.md\"",
    ': >"$work/rec.log"',
    ': >"$work/launcher-bg"',
    "printf 'Do the thing.\\nThen the other thing.\\n' >\"$work/task.src\"",
    "printf 'one\\ntwo\\nthree\\n' >\"$work/three.txt\"",
]
ACCOUNT_FIXTURES = [
    'mkdir -p "$work/cfg-b"',
    "login a; login b",
    "reading a Personal 10 5000; reading b RIT 10 4000",
]
# The one place a shard runs a line the suite does not: the recover group
# removes a file an earlier group left behind in the full run.
PATCHES = [
    (
        'rm -f "$KLEPSYDRA_DIR/fleet/$SNEW.json"',
        'rm -f "$KLEPSYDRA_DIR/fleet/$SW.json" "$KLEPSYDRA_DIR/fleet/$SNEW.json"',
    ),
]

ASSIGN_RE = re.compile(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=")
FN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{")
HEREDOC_RE = re.compile(r"<<-?\s*(['\"]?)([A-Za-z0-9_]+)\1")
FILE_HEREDOC_RE = re.compile(
    r'^cat >"\$work/([\w.-]+)" <<-?\s*([\'"]?)([A-Za-z0-9_]+)\2\s*$'
)
VAR_USE_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")
WORK_FILE_RE = re.compile(r"\$work/([\w.-]+)")
WORD_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
# Command substitutions a pure assignment may hold: a clock reading.
DATE_SUB_RE = re.compile(r"\$\((?:TZ=\S+ )?date(?: -d '[^']*')? \+%s\)")


def fail(msg: str) -> None:
    print(f"split-fleet-suite: {msg}", file=sys.stderr)
    sys.exit(1)


@dataclass
class Def:
    kind: str  # "var", "fn" or "file"
    name: str
    start: int  # first line index
    end: int  # last line index, inclusive
    text: str


@dataclass
class Group:
    title: str
    start: int  # index of the header line
    end: int  # index after the last line
    checks: int
    area: str = ""
    lines: list[str] = field(default_factory=list)


def heredoc_mask(lines: list[str]) -> list[bool]:
    """True for each line inside a heredoc body or on its terminator."""
    mask = [False] * len(lines)
    tag = ""
    for i, line in enumerate(lines):
        s = line.strip()
        if tag:
            mask[i] = True
            if s == tag:
                tag = ""
            continue
        m = HEREDOC_RE.search(line)
        if (
            m
            and "<<<" not in line
            and not s.startswith("check ")
            and "command" not in line
        ):
            tag = m.group(2)
    if tag:
        fail(f"heredoc {tag} never closes")
    return mask


def find_groups(lines: list[str], mask: list[bool]) -> tuple[list[Group], int, int]:
    try:
        tail = next(i for i, ln in enumerate(lines) if ln.rstrip("\n") == TAIL_HEADER)
    except StopIteration:
        fail(f"no tail header {TAIL_HEADER!r} in {SRC.name}")
    headers = [
        i
        for i, ln in enumerate(lines[:tail])
        if not mask[i] and re.match(r'^echo "[^"$]+"$', ln.rstrip("\n"))
    ]
    if not headers:
        fail("no group headers found")
    groups = []
    for n, start in enumerate(headers):
        end = headers[n + 1] if n + 1 < len(headers) else tail
        body = lines[start:end]
        title = re.match(r'^echo "([^"]+)"', lines[start]).group(1)
        groups.append(Group(title, start, end, count_checks(body), lines=body))
    return groups, headers[0], tail


def count_checks(lines: list[str]) -> int:
    return sum(1 for ln in lines if ln.strip().startswith("check "))


def pure_assignment(line: str) -> list[str] | None:
    """Names a line assigns when it only assigns literals or clock readings."""
    s = line.rstrip("\n")
    if not ASSIGN_RE.match(s):
        return None
    stripped = DATE_SUB_RE.sub("0", s)
    if VOLATILE_RE.search(stripped) or any(
        tok in stripped for tok in ("$(", "`", ";", "&&", "||", "|", ">", "<")
    ):
        return None
    try:
        words = shlex.split(stripped, comments=True)
    except ValueError:
        return None
    if words and words[0] == "export":
        words = words[1:]
    names = []
    for w in words:
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", w)
        if not m:
            return None
        names.append(m.group(1))
    return names or None


def find_defs(lines: list[str], mask: list[bool]) -> list[Def]:
    defs: list[Def] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if mask[i]:
            i += 1
            continue
        if m := FN_RE.match(line):
            end = i
            if not re.sub(r"#.*$", "", line[m.end() :]).strip().endswith("}"):
                for j in range(i + 1, len(lines)):
                    if mask[j]:
                        continue
                    s = re.sub(r"#.*$", "", lines[j]).strip()
                    if s == "}" or s.endswith("; }") or s.endswith(";}"):
                        end = j
                        break
                else:
                    fail(f"function {m.group(1)} at line {i + 1} never closes")
            defs.append(Def("fn", m.group(1), i, end, "".join(lines[i : end + 1])))
            i = end + 1
            continue
        if m := FILE_HEREDOC_RE.match(line.rstrip("\n")):
            name, tag = m.group(1), m.group(3)
            end = next(
                (j for j in range(i + 1, len(lines)) if lines[j].strip() == tag), None
            )
            if end is None:
                fail(f"heredoc for $work/{name} at line {i + 1} never closes")
            # The chmod that makes a fixture script runnable belongs to it.
            while (
                end + 1 < len(lines)
                and lines[end + 1].strip() == f'chmod +x "$work/{name}"'
            ):
                end += 1
            defs.append(Def("file", name, i, end, "".join(lines[i : end + 1])))
            i = end + 1
            continue
        if names := pure_assignment(line):
            for n in names:
                defs.append(Def("var", n, i, i, line))
        i += 1
    return defs


def uses(text: str) -> tuple[set[str], set[str], set[str]]:
    """Variables, words (function calls) and $work files a text reads."""
    code = "\n".join(ln for ln in text.splitlines() if not ln.lstrip().startswith("#"))
    # \$x in a heredoc body is text the heredoc writes, not a read of x.
    code = code.replace("\\$", "")
    return (
        set(VAR_USE_RE.findall(code)),
        set(WORD_RE.findall(code)),
        set(WORK_FILE_RE.findall(code)),
    )


def replays(group: Group, defs: list[Def], first_group: int) -> list[Def]:
    """The definitions a group reads that it does not make itself.

    For each name the group (or a definition it pulls in) reads, the last
    definition before the group's header, unless that sits in the prelude,
    which every shard runs. Re-running one the shard also holds is harmless:
    it sets the value the full run has at that point.
    """
    last: dict[tuple[str, str], Def] = {}
    for d in defs:
        if d.start < group.start:
            last[(d.kind, d.name)] = d
    picked: dict[int, Def] = {}
    todo = [group_text(group)]
    while todo:
        vars_, words, files = uses(todo.pop())
        wanted = (
            [("var", n) for n in vars_]
            + [("fn", n) for n in words]
            + [("file", n) for n in files]
        )
        for key in wanted:
            d = last.get(key)
            if d is None or d.start < first_group or d.start in picked:
                continue
            picked[d.start] = d
            todo.append(d.text)
    return [picked[k] for k in sorted(picked)]


def group_text(group: Group) -> str:
    return "".join(group.lines)


def assign(groups: list[Group]) -> None:
    for g in groups:
        for area, pats in TABLE:
            if any(re.search(p, g.title) for p in pats):
                g.area = area
                break
        else:
            print(
                f"split-fleet-suite: group {g.title!r} matches no area; it runs in misc",
                file=sys.stderr,
            )
            g.area = "misc"


def adjust_prelude(prelude: list[str]) -> list[str]:
    out = []
    anno = "printf '::error file=fleet/test_fleet.sh,line=%s,title=fleet test failed::%s\\n' \"${BASH_LINENO[0]}\""
    here_line = 'here=$(cd "$(dirname "$0")" && pwd)'
    trap_line = "trap cleanup EXIT"
    seen_here = seen_anno = seen_trap = False
    for n, ln in enumerate(prelude):
        if n == 0 and ln.startswith("#!"):
            out.append(ln)
            out.append("# shellcheck disable=SC2034 # the shards read these\n")
        elif ln.startswith(here_line):
            out.append('here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)\n')
            seen_here = True
        elif ln.strip() == trap_line:
            # One EXIT trap per shell: the shard's abort note runs before the cleanup.
            out.append(ln.replace(trap_line, "trap 'shard_abort_trap; cleanup' EXIT"))
            seen_trap = True
        elif anno in ln:
            indent = ln[: len(ln) - len(ln.lstrip())]
            out.append(
                f"{indent}local orig_line=${{BASH_LINENO[0]}}\n"
                f"{indent}if [[ -n ${{_group_orig_line:-}} && -n ${{_group_shard_line:-}} ]]; then\n"
                f"{indent}  orig_line=$(( _group_orig_line + BASH_LINENO[0] - _group_shard_line ))\n"
                f"{indent}fi\n" + ln.replace('"${BASH_LINENO[0]}"', '"$orig_line"')
            )
            seen_anno = True
        else:
            out.append(ln)
    if not seen_here:
        fail(f"the prelude no longer sets here with {here_line!r}")
    if not seen_trap:
        fail(
            f"the prelude no longer sets {trap_line!r}, which the shard's abort note joins"
        )
    if not seen_anno:
        fail(
            "check() no longer prints the ::error annotation this script maps to suite lines"
        )
    return out


SHARD_HEAD = """#!/usr/bin/env bash
# Fleet suite shard: {area}. Generated by scripts/split-fleet-suite.sh from
# fleet/test_fleet.sh, which is the source; never edit or commit this file.
set -uo pipefail
shard_name={area}
shard_abort_trap() {{
  local rc=$?
  if (( rc != 0 )) && [[ -z ${{_shard_finished:-}} ]]; then
    printf '%sshard %s aborted (exit %d) at fleet/test_fleet.sh:%s in group "%s"\\n' \\
      "${{GITHUB_ACTIONS:+::error file=fleet/test_fleet.sh,line=${{_group_orig_line:-1}},title=shard aborted::}}" \\
      "$shard_name" "$rc" "${{_group_orig_line:-1}}" "${{_group_name:-setup}}"
  fi
}}
shard_dir=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=fleet/tests/prelude.sh
. "$shard_dir/prelude.sh"

"""


def render(
    area: str, groups: list[Group], defs: list[Def], first_group: int, tail: list[str]
) -> str:
    out = [SHARD_HEAD.format(area=area)]
    out += [ln + "\n" for ln in PLUMBING + FIXTURES]
    if area.startswith("accounts-"):
        out += [ln + "\n" for ln in ACCOUNT_FIXTURES]
    for g in groups:
        out.append(f"\n_group_name={shlex.quote(g.title)}\n")
        for d in replays(g, defs, first_group):
            out.append(f"# replayed from fleet/test_fleet.sh:{d.start + 1}\n{d.text}")
            if not d.text.endswith("\n"):
                out.append("\n")
        out.append(f"_group_t0=$SECONDS _group_orig_line={g.start + 1}\n")
        out.append("_group_shard_line=$((LINENO + 1))\n")
        body = "".join(g.lines)
        for old, new in PATCHES:
            body = body.replace(old, new)
        out.append(body)
        out.append(
            'printf \'%sgroup %s %ds\\n\' "${GITHUB_ACTIONS:+::notice::}" "$_group_name" '
            '"$(( SECONDS - _group_t0 ))"\n'
        )
    # The suite's own tail, verbatim, marked finished before its verdict.
    out.append("\n")
    out += tail[:-1]
    out.append("_shard_finished=1\n")
    out.append(tail[-1])
    return "".join(out)


def split() -> dict[str, str]:
    lines = SRC.read_text(encoding="utf-8").splitlines(keepends=True)
    mask = heredoc_mask(lines)
    groups, first_group, tail = find_groups(lines, mask)
    assign(groups)
    defs = find_defs(lines, mask)

    src_lines = {ln.strip() for ln in lines}
    src_text = "".join(lines)
    for fx in FIXTURES + ACCOUNT_FIXTURES:
        if fx not in src_text:
            fail(
                f"fixture line {fx!r} is no longer in {SRC.name}; update scripts/split_fleet_suite.py"
            )
    for old, _ in PATCHES:
        if src_text.count(old) != 1:
            fail(
                f"patch target {old!r} occurs {src_text.count(old)} times in {SRC.name}, not once"
            )
    if TAIL_HEADER not in src_lines:
        fail("tail header missing")
    tail_lines = lines[tail:]
    while tail_lines and not tail_lines[-1].strip():
        tail_lines.pop()
    if not tail_lines or tail_lines[-1].strip() != "(( fail == 0 ))":
        fail("the suite no longer ends with its verdict, (( fail == 0 ))")

    # Coverage: the groups tile the lines between the prelude and the tail,
    # each lands in exactly one shard, and every check line is in one place.
    if [g.start for g in groups][0] != first_group or groups[-1].end != tail:
        fail("groups do not cover the suite between the prelude and the tail")
    for a, b in zip(groups, groups[1:]):
        if a.end != b.start:
            fail(f"gap or overlap between groups {a.title!r} and {b.title!r}")
    prelude_checks = count_checks(lines[:first_group])
    tail_checks = count_checks(lines[tail:])
    group_checks = sum(g.checks for g in groups)
    total = count_checks(lines)
    if prelude_checks + group_checks + tail_checks != total:
        fail(
            f"check count mismatch: {prelude_checks}+{group_checks}+{tail_checks} != {total}"
        )

    files = {"prelude.sh": "".join(adjust_prelude(lines[:first_group]))}
    print(
        f"{SRC.name}: {len(groups)} groups, {group_checks} checks in groups, "
        f"{prelude_checks} in the prelude, {tail_checks} in the tail (each shard runs the tail)",
        file=sys.stderr,
    )
    for area in SHARDS:
        mine = [g for g in groups if g.area == area]
        files[f"{area}.sh"] = render(area, mine, defs, first_group, tail_lines)
        print(
            f"  {area:16s} {len(mine):3d} groups {sum(g.checks for g in mine):4d} checks",
            file=sys.stderr,
        )
    return files


def write(files: dict[str, str]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (OUT / name).write_text(text, encoding="utf-8")


BINARY = (
    ".png",
    ".webp",
    ".jpg",
    ".jpeg",
    ".gif",
    ".ico",
    ".icns",
    ".pdf",
    ".woff",
    ".woff2",
)
BINARY += (".ttf", ".mp3", ".wav", ".zip", ".gz")


def tracked() -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True, check=True
    )
    return [p for p in out.stdout.splitlines() if not p.lower().endswith(BINARY)]


def mentions(
    text: str, path: str, here: str = "", shared: frozenset[str] = frozenset()
) -> bool:
    """Whether TEXT, a file in folder HERE, names PATH. A name SHARED by several
    tracked files counts only with its folder, or beside the file that names it."""
    folder, _, name = path.rpartition("/")
    if name in shared:
        if f"{folder}/{name}" in text or (folder == here and name in text):
            return True
    elif name in text:
        return True
    stem = name.rsplit(".", 1)[0]
    # A Python module is named without its .py when imported.
    return (
        path.endswith(".py")
        and re.search(rf"\b(?:import|from)\s+{re.escape(stem)}\b", text) is not None
    )


CODE = (".sh", ".py", ".js", ".mjs", ".rs")


def runs_others(path: str) -> bool:
    """Whether a file is code, which can run or load the files it names."""
    name = path.rsplit("/", 1)[-1]
    return (
        name.endswith(CODE)
        or name == "Makefile"
        or (path.startswith("fleet/") and "." not in name)
    )


LS_GLOB_RE = re.compile(r"ls-files\b[^\n]*?'(\*\.[A-Za-z0-9]+)'")


def select(changed: list[str], files: dict[str, str]) -> list[str]:
    """The shards a change can reach, failing closed.

    A shard reaches what its text names, then what each of those files names,
    transitively, and whatever a `git ls-files '*.ext'` in it lists. A path
    the prelude reaches runs every shard. A path no shard reaches runs none
    only when it is the app's own code (APP_ONLY); anything else runs every
    shard. Paths are matched by name, so a deleted or renamed file is found
    in the texts that still name it.
    """
    changed = [c for c in changed if c]
    if any(
        c == core or (core.endswith("/") and c.startswith(core))
        for c in changed
        for core in CORE
    ):
        return list(SHARDS)
    paths = tracked()
    counts = collections.Counter(p.rpartition("/")[2] for p in paths)
    shared = frozenset(n for n, k in counts.items() if k > 1)

    def names(t: str, path: str, here: str) -> bool:
        return mentions(t, path, here, shared)

    text_of: dict[str, str] = {}
    named: dict[str, list[str]] = {}

    def text(p: str) -> str:
        if p not in text_of:
            try:
                text_of[p] = (ROOT / p).read_text(encoding="utf-8", errors="replace")
            except OSError:
                text_of[p] = ""
        return text_of[p]

    def reach(seed: str) -> list[tuple[str, str]]:
        """(folder, text) of the seed, a shard of fleet/test_fleet.sh, and of
        every code file it reaches. A file read as data is reached, but the
        files it names are not run, so it passes nothing on."""
        seen: set[str] = set()
        todo = [p for p in paths if names(seed, p, "fleet")]
        while todo:
            p = todo.pop()
            if p in seen:
                continue
            seen.add(p)
            if runs_others(p):
                if p not in named:
                    here = p.rpartition("/")[0]
                    named[p] = [q for q in paths if q != p and names(text(p), q, here)]
                todo += named[p]
        code = [(p.rpartition("/")[0], text(p)) for p in sorted(seen) if runs_others(p)]
        return [("fleet", seed)] + code + [("", p) for p in sorted(seen)]

    def hits(reached: list[tuple[str, str]], path: str) -> bool:
        """Whether a reached file is PATH (the last entries hold the reached
        paths themselves), or a reached code file names it or lists it."""
        name = path.rpartition("/")[2]
        for here, t in reached:
            if here == "" and t == path:
                return True
            if here == "":
                continue
            if names(t, path, here) or any(
                fnmatch.fnmatch(name, g) for g in LS_GLOB_RE.findall(t)
            ):
                return True
        return False

    prelude = reach(files["prelude.sh"])
    shard_texts = {a: reach(files[f"{a}.sh"]) for a in SHARDS}
    chosen: set[str] = set()
    for c in changed:
        if hits(prelude, c):
            return list(SHARDS)
        hit = {a for a in SHARDS if hits(shard_texts[a], c)}
        if not hit and not (c.startswith(APP_ONLY) and not c.startswith(NOT_APP_ONLY)):
            return list(SHARDS)
        chosen |= hit
    return [a for a in SHARDS if a in chosen]


def main(argv: list[str]) -> None:
    if argv[1:] == ["--list"]:
        print(json.dumps(SHARDS))
        return
    files = split()
    write(files)
    if argv[1:2] == ["--select"]:
        print(json.dumps(select([ln.strip() for ln in sys.stdin], files)))
    elif argv[1:]:
        fail(f"unknown argument {argv[1]!r}")


if __name__ == "__main__":
    main(sys.argv)
