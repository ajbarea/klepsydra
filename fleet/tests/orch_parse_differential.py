"""Differential test of orch_guard_parse.py against bash (#264).

Sends: generates commands from shell pieces the orchestrator writes (tmux
sends with literal, assigned and looped targets, quotes holding separators,
comments, echoed look-alikes, line breaks, continuations, subshells,
if/then), runs each in real bash with a stub tmux on PATH that records every
send's target, and compares that with the targets the parser reports.
Registry: generates commands that read or write panes.tsv and runs each in
bash in a scratch folder holding one. A send bash makes that the parser
neither reports nor marks unresolved, or a write to panes.tsv it does not
report, is a guard bypass: printed, and the run exits 1. A pane the parser
checks that bash never sends to (it only mentions it) is the parser's chosen
over-approximation, counted but allowed.
Run: python3 -I orch_parse_differential.py [N] [SEED]
"""

import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PARSER = os.path.join(HERE, "..", "orch_guard_parse.py")

STUB = r"""#!/usr/bin/env bash
# Records the target of each send-keys/send/paste-buffer/pasteb it is given.
while (( $# )); do
  case $1 in -L | -S | -f) shift 2 ;; -*) shift ;; *) break ;; esac
done
case ${1:-} in send-keys | send | paste-buffer | pasteb) ;; *) exit 0 ;; esac
shift
while (( $# )); do
  case $1 in
    -t) printf '%s\n' "$2" >>"$TMUX_LOG"; exit 0 ;;
    -t*) printf '%s\n' "${1#-t}" >>"$TMUX_LOG"; exit 0 ;;
    -N | -c | -b | -s | -T) shift 2 ;;
    -*) shift ;;
    *) exit 0 ;;
  esac
done
"""


def pane(r):
    return f"%{r.randint(1, 30)}"


def text(r):
    return r.choice(
        [
            "hi",
            '"a; b"',
            "'x && y'",
            '"keep # this"',
            '"two\nlines"',
            "'it'\"'\"'s'",
            "Enter",
            '"$(date)"',
            "-l go",
        ]
    )


def send(r):
    """One send and the prelude it needs; returns (code, var-free targets wanted)."""
    prog = r.choice(["tmux", "tmux -L s", "t", "/usr/bin/tmux"])
    sub = r.choice(["send-keys", "send-keys", "send", "paste-buffer -b b1", "pasteb"])
    shape = r.randrange(6)
    if shape == 0:
        p = pane(r)
        return f"{prog} {sub} -t {p} {text(r)}"
    if shape == 1:
        p = pane(r)
        return f"{prog} {sub} -t{p} {text(r)}"
    if shape == 2:
        p = pane(r)
        return f'p={p}; {prog} {sub} -t "$p" {text(r)}'
    if shape == 3:
        a, b = pane(r), pane(r)
        return f"for q in {a} {b}; do {prog} {sub} -t $q {text(r)}; done"
    if shape == 4:
        p = pane(r)
        return f"{prog} {sub} -N 2 -t {p} Enter"
    p = pane(r)
    return f"{prog} {sub} \\\n  -t {p} {text(r)}"


def piece(r):
    k = r.randrange(9)
    if k < 4:
        return send(r)
    if k == 4:
        return f"# {send(r)}"
    if k == 5:
        return f'echo "{send(r).replace(chr(34), "")}"'
    if k == 6:
        return f"if true; then {send(r)}; fi"
    if k == 7:
        return f"x=$({send(r)})"
    return r.choice(["true", "echo done", "ls >/dev/null"])


def command(r):
    parts = [piece(r) for _ in range(r.randint(1, 3))]
    out = parts[0]
    for p in parts[1:]:
        out += r.choice(["; ", " && ", "\n", " || true; "]) + p
    return out


def by_bash(cmd, stubdir):
    with tempfile.NamedTemporaryFile("r", delete=False) as log:
        path = log.name
    env = {"PATH": f"{stubdir}:/usr/bin:/bin", "TMUX_LOG": path, "HOME": stubdir}
    script = 't() { tmux -L fleet "$@"; }\n' + cmd + "\n"
    subprocess.run(
        ["bash", "-c", script], env=env, capture_output=True, timeout=10, check=False
    )
    with open(path) as f:
        got = sorted(line.strip() for line in f if line.strip())
    os.unlink(path)
    return got


def by_parser(cmd):
    out = subprocess.run(
        [sys.executable, "-I", PARSER],
        input=cmd,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    sends, unresolved = [], 0
    for line in out.splitlines():
        f = line.split("\t")
        if f[0] == "SEND":
            sends.append(f[1])
        elif f[0] == "UNRESOLVED":
            unresolved += 1
    return sorted(sends), unresolved


REG_PIECES = [
    "sed -i '/old/d' panes.tsv",
    "cat panes.tsv",
    "grep x panes.tsv > out",
    "cut -f1 panes.tsv | sort",
    "grep -v old panes.tsv > panes.tsv.new && mv panes.tsv.new panes.tsv",
    "cp panes.tsv bak",
    "cp -p panes.tsv panes.tsv.bak-0655",
    "cp bak 'panes.tsv'",
    "echo a >> panes.tsv",
    "printf 'x\\n' | tee -a panes.tsv",
    "awk 1 panes.tsv | sort -u",
    "sed -n 1p panes.tsv",
    "python3 -c \"open('panes.tsv','a').write('x')\"",
    "# sed -i '/x/d' panes.tsv",
    'echo "sed -i x panes.tsv"',
    "if true; then echo b >> panes.tsv; fi",
    "x=$(sed -i '/a/d' panes.tsv)",
    "wc -l panes.tsv",
    "rm -f panes.tsv",
    "mv panes.tsv panes.tsv.bak",
    "cp bak panes.tsv",
    "truncate -s 0 panes.tsv",
    "jq -R . panes.tsv",
    "cat > panes.tsv <<'X'\nnew\nX",
    "sort -o panes.tsv panes.tsv",
    "dd if=bak of=panes.tsv status=none",
    "perl -pi -e 's/a/b/' panes.tsv",
    "sort -u panes.tsv -o panes.tsv",
    "uniq bak panes.tsv",
    "sed -n 'w panes.tsv' bak",
    "awk '{print > \"panes.tsv\"}' bak",
    "sort --output=panes.tsv bak",
    "head -1 panes.tsv \\\n  | tail -1",
    "ln -sf bak panes.tsv",
]


def reg_command(r):
    parts = [r.choice(REG_PIECES) for _ in range(r.randint(1, 3))]
    out = parts[0]
    for p in parts[1:]:
        out += r.choice(["; ", " && ", "\n", " || true; "]) + p
    return out


def wrote(cmd):
    with tempfile.TemporaryDirectory() as d:
        reg = os.path.join(d, "panes.tsv")
        for name in ("panes.tsv", "bak"):
            with open(os.path.join(d, name), "w") as f:
                f.write("%1\told\n%2\tkeep\n")
        before = os.lstat(reg)
        subprocess.run(
            ["bash", "-c", cmd],
            cwd=d,
            capture_output=True,
            timeout=10,
            check=False,
            env={"PATH": "/usr/bin:/bin", "HOME": d},
        )
        try:
            after = os.lstat(reg)
        except FileNotFoundError:
            return True
        with open(reg, "rb") as f:
            data = f.read()
        return (after.st_ino, after.st_mtime_ns, after.st_mode) != (
            before.st_ino,
            before.st_mtime_ns,
            before.st_mode,
        ) or data != b"%1\told\n%2\tkeep\n"


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 300
    r = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 264)
    bad = over = 0
    with tempfile.TemporaryDirectory() as stubdir:
        stub = os.path.join(stubdir, "tmux")
        with open(stub, "w") as f:
            f.write(STUB)
        os.chmod(stub, 0o755)
        for i in range(n):
            cmd = command(r)
            # /usr/bin/tmux in a generated command must reach the stub too.
            want = by_bash(cmd.replace("/usr/bin/tmux", "tmux"), stubdir)
            got, unresolved = by_parser(cmd)
            missed = sorted(set(want) - set(got))
            if missed and not unresolved:
                bad += 1
                print(f"SEND MISSED #{i}: bash sent {want}, parser {got}\n{cmd}\n")
            over += bool(set(got) - set(want))
    reg_bad = reg_over = 0
    for i in range(n):
        cmd = reg_command(r)
        flagged = (
            "REGISTRY"
            in subprocess.run(
                [sys.executable, "-I", PARSER],
                input=cmd,
                capture_output=True,
                text=True,
                check=True,
            ).stdout
        )
        if wrote(cmd) and not flagged:
            reg_bad += 1
            print(f"WRITE MISSED #{i}:\n{cmd}\n")
        reg_over += flagged and not wrote(cmd)
    print(
        f"differential: {n} send commands, {bad} missed, {over} over-checked; "
        f"{n} registry commands, {reg_bad} missed, {reg_over} over-flagged"
    )
    return 1 if bad or reg_bad else 0


if __name__ == "__main__":
    sys.exit(main())
