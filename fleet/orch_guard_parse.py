"""What an orchestrator's Bash command may do, for orch-guard.sh (#264).

Reads the command on stdin and prints one line per finding, tab-separated:
  SOCKET <socket>        a tmux server a send may reach, in the order to try:
                         "-L NAME", "-S PATH", "t" (lib.sh's t, the fleet
                         socket), then "env" (the tmux the session runs in)
  SEND <target>          a pane a send may reach
  UNRESOLVED <raw>       a send target this command does not spell out
  DELAY <word>           the command waits before it acts (sleep, a loop, ...)
  REGISTRY <why>         a command that names panes.tsv and may write it
  CLAUDE <mode> <signal> claude started (interactive or headless) with an
                         API key; SIGNAL names how the key reaches it

It never models bash's or tmux's grammar (a parser that is neither
disagrees with them on some corner: comments, continuations, subshells,
quotes, tmux's abbreviations and combined flags). It over-approximates
instead, so every doubt lands on the refusing side: any word tmux could read
as a send (send..., paste...) or lib.sh's senders make a command a send, and
every pane it names is checked, echoed or commented ones too; a target it
cannot resolve is UNRESOLVED; a command naming panes.tsv is a write if it
redirects anywhere, edits in place, or runs anything but a read-only program;
a launch is interactive unless it says -p, and a settings file or config
folder it cannot read counts as a key. ORCH_ACCOUNTS (space-separated config
folders) is where launch.sh may start a session. The differential test
(tests/orch_parse_differential.py) runs generated commands against real tmux
and bash and fails on any send or write this misses.
Run: python3 -I orch_guard_parse.py < command
"""

import json
import os
import re
import sys

# Any word tmux may read as send-keys or paste-buffer: it takes unique
# prefixes and aliases (send, send-k, paste, pasteb).
SEND_WORD = re.compile(r"(?<![\w-])(send|paste)[\w-]*(?![\w-])")
TMUX_WORD = re.compile(r"(?<![\w.-])tmux(?![\w-])")
T_WORD = re.compile(r"(?<![\w.$%/-])t(?![\w.-])")
# lib.sh's own senders, each with its pane first.
LIB_SEND = re.compile(
    r"(?<![\w-])(type_exactly|deliver|inbox_deliver|submit|remote_control|retire)\s+(['\"]?)([^\s'\";&|)]+)"
)
PANE = re.compile(r"(?<![\w%])%[0-9]+(?!\w)")
# -t alone or last in a flag cluster (-lt %5).
TARGET = re.compile(r"(?<![\w-])-[A-Za-z]*t\s*(['\"]?)([^\s'\";&|)]+)")
VAR = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")
PANE_LIKE = re.compile(r"^[%@]?[A-Za-z0-9_.:=+-]+$")
DELAY = re.compile(
    r"(?<![\w-])(sleep|until|while|timeout|watch|at|systemd-run|wait_for)(?![\w-])"
)

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
# A redirect that writes a file: not 2>&1 and not to /dev/null.
REDIRECT = re.compile(r"(?<![<>&])(?:[0-9]*|&)>>?\|?(?!&)\s*(?!/dev/null(?![\w/.-]))\S")

KEY_ENV = re.compile(
    r"(?<!\w)(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN)=(?!['\"]{2}|\s|$|;)"
)
CLAUDE_WORD = re.compile(r"(?:^|[\s;&|(/'\"`])claude(?=$|[\s;&|)'\"`])")
LAUNCHER = re.compile(
    r"(?:^|[\s/'\"])(launch|fresh-now|relaunch-fresh)\.sh(?=$|[\s'\";&|)])"
)
HEADLESS = re.compile(r"(?:^|\s)(-p|--print)(?=$|\s)")
SETTINGS = re.compile(r"--settings[=\s]+(['\"]?)([^\s'\";&|)]+)")
CONFIG = re.compile(r"(?<!\w)(CLAUDE_CONFIG_DIR|FLEET_ACCOUNT)=(['\"]?)([^\s'\";&|)]*)")


def values(cmd, name):
    """NAME's values as this command sets them: NAME=VALUE, for NAME in WORDS."""
    got = [
        m.group(2)
        for m in re.finditer(rf"(?:^|[\s;&|(`]){name}=(['\"]?)([^\s'\";&|)`]*)", cmd)
    ]
    for m in re.finditer(rf"\bfor\s+{name}\s+in\s+(.*?)\s*(?:;|\n|\bdo\b)", cmd):
        got.extend(m.group(1).split())
    return got


def sockets(cmd):
    """The servers each tmux word in CMD names with -L or -S, in order."""
    socks = []
    for m in TMUX_WORD.finditer(cmd):
        words = cmd[m.end() :].split()
        i = 0
        while i < len(words) and words[i].startswith("-"):
            w = words[i]
            if w in ("-L", "-S") and i + 1 < len(words):
                socks.append(f"{w} {words[i + 1].strip(chr(39) + chr(34))}")
                i += 2
            elif w[:2] in ("-L", "-S") and len(w) > 2:
                socks.append(f"{w[:2]} {w[2:].strip(chr(39) + chr(34))}")
                i += 1
            elif w in ("-f", "-c", "-T"):
                i += 2
            else:
                i += 1
    return socks


def target(cmd, raw, targets, out):
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


def sends(cmd, out):
    lib = list(LIB_SEND.finditer(cmd))
    tmux = TMUX_WORD.search(cmd) or T_WORD.search(cmd)
    if not (lib or (tmux and SEND_WORD.search(cmd))):
        return
    socks = sockets(cmd)
    if T_WORD.search(cmd) or lib:
        socks.append("t")
    socks.append("env")
    for s in dict.fromkeys(socks):
        print(f"SOCKET\t{s}", file=out)
    m = DELAY.search(cmd)
    if m:
        print(f"DELAY\t{m.group(1)}", file=out)
    targets = [m.group(0) for m in PANE.finditer(cmd)]
    # Targets fed in at run time (xargs, parallel) cannot be read beforehand.
    m = re.search(r"(?<![\w-])(xargs|parallel)(?![\w-])", cmd)
    if m:
        print(f"UNRESOLVED\ttargets from {m.group(1)}", file=out)
    for m in TARGET.finditer(cmd):
        target(cmd, m.group(2), targets, out)
    for m in lib:
        target(cmd, m.group(3), targets, out)
    for t in dict.fromkeys(targets):
        print(f"SEND\t{t}", file=out)


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
    """Whether a cp piece may write panes.tsv: its last word is panes.tsv or a
    variable, or it names a target folder (-t), which may hold one."""
    words = piece.split()
    if any(
        w in ("-t", "-T") or w.startswith(("--target-directory", "-t"))
        for w in words[1:]
    ):
        return True
    last = words[-1].strip("'\"") if words else ""
    return not words or "$" in last or os.path.basename(last) == "panes.tsv"


def registry(cmd, out):
    if not REGISTRY.search(cmd):
        return
    if REDIRECT.search(cmd):
        print("REGISTRY\tredirect", file=out)
        return
    # In-place edits and the read-only programs' own ways to write: sort -o, sed's w.
    if re.search(
        r"(?<![\w-])(-i|--in-place|-o|--output)\b|\binplace\b|\bw\s*['\"]?[^\s'\"]*panes\.tsv",
        cmd,
    ):
        print("REGISTRY\tin-place", file=out)
        return
    # fd duplications (2>&1, >&2, &>) are no separators.
    plain = re.sub(r"[0-9]*[<>]&[0-9-]+|&>>?", " ", cmd.replace("\\\n", " "))
    for piece in SPLIT.split(plain):
        word = program(piece)
        if word == "cp" and not copies_onto_registry(piece):
            continue  # a backup: panes.tsv is only read
        if word is not None and word not in READ_ONLY:
            print(f"REGISTRY\t{word}", file=out)
            return


def expand(path):
    home = os.path.expanduser("~")
    return os.path.expanduser(path.replace("${HOME}", home).replace("$HOME", home))


def holds_helper(path):
    """Whether a settings file names an apiKeyHelper; None when it cannot be read."""
    try:
        with open(path, encoding="utf-8") as f:
            return "apiKeyHelper" in json.dumps(json.load(f))
    except FileNotFoundError:
        return False
    except (OSError, ValueError):
        return None


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
        path = expand(m.group(2))
        held = None if "$" in path else holds_helper(path)
        if held is None:
            signal = f"a --settings file the guard cannot read: {m.group(2)}"
        elif held:
            signal = f"apiKeyHelper in {m.group(2)}"
    # The config folder the session starts on: named, or where launch.sh may pick.
    dirs = [m.group(3) for m in CONFIG.finditer(cmd)]
    if not dirs:
        if launcher:
            dirs = os.environ.get("ORCH_ACCOUNTS", "").split()
        dirs = dirs or [os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude"]
    for d in dirs:
        if "$" in expand(d):
            dirs.extend(os.environ.get("ORCH_ACCOUNTS", "").split())
            continue
        if holds_helper(os.path.join(expand(d), "settings.json")):
            signal = f"apiKeyHelper in {d}/settings.json"
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
