"""What an orchestrator's Bash command may do, for orch-guard.sh (#264).

Reads the command on stdin and prints one line per finding, tab-separated:
  BYPASS <how>           a tmux call that would skip orch-tmux.sh (the guard
                         on the orchestrator's PATH that checks every send at
                         run time): tmux named by a path, or PATH changed
  REGISTRY <why>         a command that names panes.tsv and may write it
  CLAUDE <mode> <signal> claude started (interactive or headless) with an
                         API key; SIGNAL names how the key reaches it

It never models bash's grammar, which a parser that is not bash gets wrong
on some corner. Sends are checked at run time by orch-tmux.sh, on tmux's real
arguments. What is left here is decided by shape, and every doubt lands on
refusing: a command naming panes.tsv is a write unless each of its pieces
starts with a program that cannot write a file and its only redirects are to
/dev/null or between descriptors; a launch is interactive unless the piece
that runs claude says -p; a settings file or config folder that cannot be
read counts as a key. ORCH_ACCOUNTS (space-separated config folders) is where
launch.sh may start a session. tests/orch_parse_differential.py runs
generated commands in bash and fails on any registry write this misses.
Run: python3 -I orch_guard_parse.py < command
"""

import json
import os
import re
import sys

TMUX_PATH = re.compile(
    r"(?:^|[\s;&|(`'\"=])(?:\\|/)[^\s;&|()`'\"]*tmux(?=$|[\s;&|)`'\"])"
)
TMUX_WORD = re.compile(r"(?<![\w.-])tmux(?![\w-])")
PATH_SET = re.compile(
    r"(?<![\w-])(PATH=|env\s+(?:-\S+\s+)*-i\b|env\s+(?:-\S+\s+)*--ignore-environment)"
)

REGISTRY = re.compile(r"(?:panes\.tsv|\$\{?REGISTRY\b)")
# Programs that cannot write a file, whatever their flags.
CANNOT_WRITE = {
    "cat", "grep", "egrep", "fgrep", "cut", "head", "tail", "column", "wc", "jq", "diff", "cmp",
    "stat", "ls", "test", "[", "[[", "echo", "printf", "true", "false", "nl", "tr", "file",
    "md5sum", "sha256sum", "date", "basename", "dirname", "realpath", "readlink",
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
# Redirects that write no file: to /dev/null, and descriptor copies (2>&1, >&2).
SAFE_REDIRECT = re.compile(
    r"[0-9]*>>?\|?\s*/dev/null(?![\w/.-])|[0-9]*[<>]&[0-9]+-?|[0-9]*>&-"
)
SPLIT = re.compile(r"[;&|\n()`]+|\$\(|<\(|>\(")

KEY_ENV = re.compile(
    r"(?<!\w)(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN)=(?!['\"]{2}|\s|$|;)"
)
CLAUDE_WORD = re.compile(r"(?:^|[\s;&|(/'\"`])claude(?=$|[\s;&|)'\"`])")
LAUNCHER = re.compile(
    r"(?:^|[\s/'\"])(launch|fresh-now|relaunch-fresh)\.sh(?=$|[\s'\";&|)])"
)
SETTINGS = re.compile(r"--settings[=\s]+(['\"]?)([^\s'\";&|)]+)")
CONFIG = re.compile(r"(?<!\w)(CLAUDE_CONFIG_DIR|FLEET_ACCOUNT)=(['\"]?)([^\s'\";&|)]*)")


def bypass(cmd, out):
    if TMUX_PATH.search(cmd):
        print("BYPASS\ttmux called by a path", file=out)
    elif TMUX_WORD.search(cmd) and PATH_SET.search(cmd):
        print("BYPASS\tPATH changed in a command that calls tmux", file=out)


def program(piece):
    """The first word of a piece of a command, past keywords and assignments."""
    words = piece.split()
    i = 0
    while i < len(words) and (
        words[i] in KEYWORDS or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[i])
    ):
        i += 1
    return os.path.basename(words[i].strip("'\"\\")) if i < len(words) else None


def registry(cmd, out):
    if not REGISTRY.search(cmd):
        return
    plain = SAFE_REDIRECT.sub(" ", cmd.replace("\\\n", " "))
    if ">" in plain:
        print("REGISTRY\tredirect", file=out)
        return
    for piece in SPLIT.split(plain):
        word = program(piece)
        if word is not None and word not in CANNOT_WRITE:
            print(f"REGISTRY\t{word}", file=out)
            return


def expand(path):
    home = os.path.expanduser("~")
    return os.path.expanduser(path.replace("${HOME}", home).replace("$HOME", home))


def holds_helper(path, missing_is_key):
    """Whether a settings file names an apiKeyHelper; None when it cannot be read."""
    try:
        with open(path, encoding="utf-8") as f:
            return "apiKeyHelper" in json.dumps(json.load(f))
    except FileNotFoundError:
        return None if missing_is_key else False
    except (OSError, ValueError):
        return None


def headless(cmd):
    """Whether the piece that runs claude asks for -p or --print."""
    for piece in SPLIT.split(cmd.replace("\\\n", " ")):
        if program(piece) == "claude" and re.search(
            r"(?:^|\s)(-p|--print)(?=$|\s)", piece
        ):
            return True
    return False


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
        # A file the command makes first is not there yet: unknown, so a key.
        held = None if "$" in path else holds_helper(path, missing_is_key=True)
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
            dirs.extend(
                x for x in os.environ.get("ORCH_ACCOUNTS", "").split() if x not in dirs
            )
            continue
        held = holds_helper(
            os.path.join(expand(d), "settings.json"), missing_is_key=False
        )
        if held is None:
            signal = f"a settings.json the guard cannot read in {d}"
        elif held:
            signal = f"apiKeyHelper in {d}/settings.json"
    if signal:
        mode = "headless" if headless(cmd) and not launcher else "interactive"
        print(f"CLAUDE\t{mode}\t{signal}", file=out)


def main():
    cmd = sys.stdin.read()
    bypass(cmd, sys.stdout)
    registry(cmd, sys.stdout)
    claude(cmd, sys.stdout)


if __name__ == "__main__":
    main()
