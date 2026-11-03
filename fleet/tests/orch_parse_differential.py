"""Differential test of orch_guard_parse.py against bash (#264).

Sends: generates commands from shell pieces the orchestrator writes (tmux
sends with literal, assigned, looped and piped targets, tmux's abbreviations
and combined flags, quotes holding separators, comments, echoed look-alikes,
line breaks, continuations, subshells, if/then, { }, !, time), runs each in
bash against a real private tmux server whose panes record every byte they
receive, and compares the panes that got keys with the panes the parser
names (resolved on that server).
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

# Each pane records the bytes it receives, unbuffered, in raw mode.
RECORDER = (
    "import os,sys,tty;tty.setraw(0);f=open(sys.argv[1],'ab',0)\n"
    "while True:\n b=os.read(0,4096)\n if not b: break\n f.write(b)"
)
PANES = 8


def pane(r):
    return f"%{r.randint(1, PANES - 1)}"


def target(r):
    return pane(r) if r.random() < 0.8 else f"rec:{r.randint(1, PANES - 1)}"


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
    """One send to a pane of the private server."""
    prog = r.choice(["tmux", "tmux -L {sock}", "t", "/usr/bin/tmux", "command tmux"])
    sub = r.choice(
        [
            "send-keys",
            "send-keys",
            "send",
            "send-k",
            "paste-buffer -b b1",
            "pasteb",
            "paste",
        ]
    )
    shape = r.randrange(10)
    t = target(r)
    if shape == 0:
        return f"{prog} {sub} -t {t} {text(r)}"
    if shape == 1:
        return f"{prog} {sub} -t{t} {text(r)}"
    if shape == 2:
        return f'p={t}; {prog} {sub} -t "$p" {text(r)}'
    if shape == 3:
        return f"for q in {t} {target(r)}; do {prog} {sub} -t $q {text(r)}; done"
    if shape == 4:
        return (
            f"{prog} {sub} -N 2 -t {t} Enter"
            if "send" in sub
            else f"{prog} {sub} -t {t}"
        )
    if shape == 5:
        flags = "-lt" if "send" in sub else "-dt"
        return f"{prog} {sub} {flags} {t} go"
    if shape == 6:
        return f"echo {t} | xargs -I{{}} {prog.replace('t', 'tmux') if prog == 't' else prog} {sub} -t {{}} go"
    if shape == 7:
        return (
            f"printf '%s\\n' {t} | while read -r w; do {prog} {sub} -t \"$w\" go; done"
        )
    if shape == 8:
        inner = f"{prog} {sub} -t {t} go"
        w = r.choice(["brace", "! ", "time "])
        return "{ " + inner + "; }" if w == "brace" else w + inner
    return f"{prog} {sub} \\\n  -t {t} {text(r)}"


def piece(r):
    k = r.randrange(10)
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
    if k == 8:
        return "{ " + send(r) + "; }"
    return r.choice(["true", "echo done", "ls >/dev/null"])


def command(r):
    parts = [piece(r) for _ in range(r.randint(1, 3))]
    out = parts[0]
    for p in parts[1:]:
        out += r.choice(["; ", " && ", "\n", " || true; "]) + p
    return out


class Server:
    """A private tmux server with PANES windows, each pane a byte recorder."""

    def __init__(self, work):
        self.work = work
        self.sock = f"orch-diff-{os.getpid()}"
        self.tm = ["tmux", "-L", self.sock]
        self.logs = {}
        subprocess.run(
            [
                *self.tm,
                "-f",
                "/dev/null",
                "new-session",
                "-d",
                "-s",
                "rec",
                "-x",
                "80",
                "-y",
                "20",
                "sleep 100000",
            ],
            check=True,
        )
        for i in range(1, PANES):
            log = os.path.join(work, f"p{i}.log")
            pid = subprocess.run(
                [
                    *self.tm,
                    "new-window",
                    "-d",
                    "-P",
                    "-F",
                    "#{pane_id}",
                    "-t",
                    f"rec:{i}",
                    sys.executable,
                    "-I",
                    "-c",
                    RECORDER,
                    log,
                ],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()
            self.logs[pid] = log
        subprocess.run([*self.tm, "set-buffer", "-b", "b1", "x"], check=True)
        subprocess.run([*self.tm, "set-buffer", "x"], check=True)
        self.path = subprocess.run(
            [*self.tm, "display-message", "-p", "#{socket_path}"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def pane_of(self, t):
        got = subprocess.run(
            [*self.tm, "display-message", "-p", "-t", t, "#{pane_id}"],
            capture_output=True,
            text=True,
        )
        return got.stdout.strip() if got.returncode == 0 else None

    def run(self, cmd):
        """The panes that received bytes while bash ran CMD."""
        for log in self.logs.values():
            open(log, "wb").close()
        env = {"PATH": "/usr/bin:/bin", "HOME": self.work, "TMUX": f"{self.path},0,0"}
        script = f't() {{ tmux -L {self.sock} "$@"; }}\n' + cmd + "\n"
        subprocess.run(
            ["bash", "-c", script],
            env=env,
            capture_output=True,
            timeout=10,
            check=False,
            cwd=self.work,
        )
        subprocess.run(["sleep", "0.15"], check=False)
        return sorted(p for p, log in self.logs.items() if os.path.getsize(log) > 0)

    def close(self):
        subprocess.run([*self.tm, "kill-server"], capture_output=True, check=False)


def by_parser(cmd, server):
    out = subprocess.run(
        [sys.executable, "-I", PARSER],
        input=cmd,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    sends, unresolved = set(), 0
    for line in out.splitlines():
        f = line.split("\t")
        if f[0] == "SEND":
            p = server.pane_of(f[1])
            if p:
                sends.add(p)
        elif f[0] == "UNRESOLVED":
            unresolved += 1
    return sorted(sends), unresolved


REG_PIECES = [
    'reg=panes.tsv; grep -v x "$reg" > p.new && cat p.new > "$reg"',
    'reg=./panes.tsv; cp bak "$reg"',
    'r=panes.tsv; sed -n 1p "$r" >/dev/null',
    "grep x panes.tsv >/dev/null 2>&1",
    'f=panes.tsv; printf "x\\n" >> "$f"',
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
    with tempfile.TemporaryDirectory() as work:
        server = Server(work)
        try:
            for i in range(n):
                cmd = command(r).replace("{sock}", server.sock)
                want = server.run(cmd)
                got, unresolved = by_parser(cmd, server)
                missed = sorted(set(want) - set(got))
                if missed and not unresolved:
                    bad += 1
                    print(
                        f"SEND MISSED #{i}: keys reached {want}, parser named {got}\n{cmd}\n"
                    )
                over += bool(set(got) - set(want))
        finally:
            server.close()
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
