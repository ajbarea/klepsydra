"""What an orchestrator's Bash command may do, for orch-guard.sh (#264).

Reads the command on stdin and prints one line per finding, tab-separated:
  SOCKET <socket>        a tmux server a send may reach, in the order to try:
                         "-L NAME", "-S PATH", "t" (lib.sh's t, the fleet
                         socket), then "env" (the tmux the session runs in)
  SEND <target>          a pane a send may reach
  UNRESOLVED <raw>       a send target this command does not spell out
  REGISTRY <why>         a command that names panes.tsv and is not read-only
  CLAUDE <mode> <signal> claude started (interactive or headless) with an
                         API key; SIGNAL names how the key reaches it

It never models bash's grammar (a parser of bash that is not bash disagrees
with it on some corner: comments, continuations, subshells, quotes). It
over-approximates instead, so every doubt lands on the refusing side: a
command that sends keys at all has every pane it mentions checked (echoed or
commented ones too), a -t it cannot resolve is UNRESOLVED, a command naming
panes.tsv is a write unless each of its pieces starts with a read-only
program, and a launch is interactive unless it says -p. The differential test
(tests/orch_parse_differential.py) runs generated commands in bash and fails
on any send or write bash makes that this misses.
Run: python3 -I orch_guard_parse.py < command
"""

import json
import os
import re
import sys

SEND_WORD = re.compile(r"(?<![\w-])(send-keys|send|paste-buffer|pasteb)(?![\w-])")
TMUX_WORD = re.compile(r"(?<![\w.-])tmux(?![\w-])")
# lib.sh's t as a program: at a command's start or after a keyword.
T_FUNC = re.compile(
    r"(?:^|[;&|(\n`]|\b(?:then|do|else)\b)\s*t\s+(?:send-keys|send|paste-buffer|pasteb)\b"
)
SOCK = re.compile(r"(?<![\w-])-([LS])\s*['\"]?([^\s'\";&|)]+)")
PANE = re.compile(r"(?<![\w%])%[0-9]+(?!\w)")
TARGET = re.compile(r"(?<![\w-])-t\s*(['\"]?)([^\s'\";&|)]+)")
VAR = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")
PANE_LIKE = re.compile(r"^[%@]?[A-Za-z0-9_.:=+-]+$")

REGISTRY = re.compile(r"(?:^|[\s/'\"=<>])panes\.tsv(?=$|[\s'\";|&)<>])")
READ_ONLY = {
    "cat", "grep", "egrep", "fgrep", "rg", "cut", "head", "tail", "column", "wc", "less", "more", "sort",
    "jq", "diff", "cmp", "stat", "ls", "test", "[", "[[", "echo", "printf", "true", "false", "nl",
    "awk", "gawk", "mawk", "sed", "tr", "file", "md5sum", "sha256sum", "date",
}  # fmt: skip
KEYWORDS = {
    "then",
    "do",
    "else",
    "elif",
    "if",
    "while",
    "until",
    "!",
    "{",
    "}",
    "time",
    "fi",
    "done",
}
SPLIT = re.compile(r"[;&|\n()`]+|\$\(")

KEY_ENV = re.compile(r"(?<!\w)(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN)=")
CLAUDE_WORD = re.compile(r"(?:^|[\s;&|(/'\"`])claude(?=$|[\s;&|)'\"`])")
LAUNCHER = re.compile(
    r"(?:^|[\s/'\"])(launch|fresh-now|relaunch-fresh)\.sh(?=$|[\s'\";&|)])"
)
HEADLESS = re.compile(r"(?:^|\s)(-p|--print)(?=$|\s)")
SETTINGS = re.compile(r"--settings[=\s]+(['\"]?)([^\s'\";&|)]+)")


def values(cmd, name):
    """NAME's values as this command sets them: NAME=VALUE, for NAME in WORDS."""
    got = [
        m.group(2)
        for m in re.finditer(rf"(?:^|[\s;&|(`]){name}=(['\"]?)([^\s'\";&|)`]*)", cmd)
    ]
    for m in re.finditer(rf"\bfor\s+{name}\s+in\s+(.*?)\s*(?:;|\n|\bdo\b)", cmd):
        got.extend(m.group(1).split())
    return got


def sends(cmd, out):
    if not SEND_WORD.search(cmd):
        return
    t_func = bool(T_FUNC.search(cmd))
    if not (TMUX_WORD.search(cmd) or t_func):
        return
    socks = [f"-{m.group(1)} {m.group(2)}" for m in SOCK.finditer(cmd)]
    if t_func:
        socks.append("t")
    socks.append("env")
    for s in dict.fromkeys(socks):
        print(f"SOCKET\t{s}", file=out)
    targets = [m.group(0) for m in PANE.finditer(cmd)]
    for m in TARGET.finditer(cmd):
        raw = m.group(2)
        v = VAR.match(raw)
        if v:
            vals = values(cmd, v.group(1))
            good = [x for x in vals if PANE_LIKE.match(x)]
            if not good or len(good) < len(vals):
                print(f"UNRESOLVED\t{raw}", file=out)
            targets.extend(good)
        elif "$" in raw or "`" in raw:
            print(f"UNRESOLVED\t{raw}", file=out)
        else:
            targets.append(raw)
    for target in dict.fromkeys(targets):
        print(f"SEND\t{target}", file=out)


def program(piece):
    """The first word of a piece of a command, past keywords and assignments."""
    words = piece.split()
    i = 0
    while i < len(words) and (
        words[i] in KEYWORDS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[i])
    ):
        i += 1
    return os.path.basename(words[i].strip("'\"")) if i < len(words) else None


def copies_onto_registry(piece):
    """Whether a cp piece may write panes.tsv: its last word is panes.tsv, or it
    names a target folder (-t), which may hold one."""
    words = piece.split()
    if any(
        w in ("-t", "-T") or w.startswith(("--target-directory", "-t"))
        for w in words[1:]
    ):
        return True
    return not words or os.path.basename(words[-1].strip("'\"")) == "panes.tsv"


def registry(cmd, out):
    if not REGISTRY.search(cmd):
        return
    if re.search(r">\|?\s*['\"]?[^\s'\";&|]*panes\.tsv", cmd):
        print("REGISTRY\tredirect", file=out)
        return
    # In-place edits and the read-only programs' own ways to write: sort -o, sed's w.
    if re.search(
        r"(?<![\w-])(-i|--in-place|-o|--output)\b|\binplace\b|\bw\s*['\"]?[^\s'\"]*panes\.tsv",
        cmd,
    ):
        print("REGISTRY\tin-place", file=out)
        return
    for piece in SPLIT.split(cmd.replace("\\\n", " ")):
        word = program(piece)
        if word == "cp" and not copies_onto_registry(piece):
            continue  # a backup: panes.tsv is only read
        if word is not None and word not in READ_ONLY:
            print(f"REGISTRY\t{word}", file=out)
            return


def claude(cmd, out):
    launcher = LAUNCHER.search(cmd)
    if not (CLAUDE_WORD.search(cmd) or launcher):
        return
    signal = None
    m = KEY_ENV.search(cmd)
    if m:
        signal = m.group(1)
    elif "apiKeyHelper" in cmd:
        signal = "apiKeyHelper"
    for m in SETTINGS.finditer(cmd):
        path = os.path.expanduser(m.group(2))
        try:
            with open(path, encoding="utf-8") as f:
                if "apiKeyHelper" in json.dumps(json.load(f)):
                    signal = f"apiKeyHelper in {m.group(2)}"
        except (OSError, ValueError):
            pass
    if signal:
        headless = bool(HEADLESS.search(cmd)) and not launcher
        print(
            f"CLAUDE\t{'headless' if headless else 'interactive'}\t{signal}", file=out
        )


def main():
    cmd = sys.stdin.read()
    sends(cmd, sys.stdout)
    registry(cmd, sys.stdout)
    claude(cmd, sys.stdout)


if __name__ == "__main__":
    main()
