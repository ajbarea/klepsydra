"""What an orchestrator's Bash command does, for orch-guard.sh (#264).

Reads the command on stdin and prints one line per finding, tab-separated:
  SEND <socket> <target>   tmux send-keys or paste-buffer to a pane; socket is
                           "-L NAME", "-S PATH", "t" (lib.sh's t: the fleet
                           socket) or "env" (the tmux the session runs in)
  UNRESOLVED <raw>         a send whose target is a variable this command does
                           not set
  REGISTRY <word>          a command that can write panes.tsv (WORD: what writes)
  CLAUDE <mode> <signal>   claude started (interactive or headless) with an
                           API key; SIGNAL names how the key reaches it
  UNPARSED                 the command does not split (an unclosed quote)

Tokens come from shlex in POSIX mode, which reads quotes, comments and the
;|&<>() operators as bash does. A newline separates commands in bash but not
in shlex, so each line is split on its own unless a quote spans it.
Run: python3 -I orch_guard_parse.py < command
"""

import json
import os
import re
import shlex
import sys

SENDS = {"send-keys", "send", "paste-buffer", "pasteb"}
OPS = {";", "&&", "||", "|", "&", ";;", "(", ")", "|&", "\n"}
# send-keys and paste-buffer options that take a value.
VALUED = {"-N", "-c", "-b", "-s", "-T"}
WRITERS = {
    "tee",
    "rm",
    "truncate",
    "python",
    "python3",
    "perl",
    "ed",
    "ex",
    "vi",
    "vim",
    "sponge",
    "dd",
}
COPIERS = {"mv", "cp", "install", "rsync", "ln"}
PREFIX = {"sudo", "env", "command", "exec", "nohup", "time", "timeout", "flock"}
KEY_ENV = re.compile(r"^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN)=")
VAR = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")
LAUNCHERS = ("launch.sh", "fresh-now.sh", "relaunch-fresh.sh")


def tokens(cmd):
    """The command's tokens, with "\\n" for each line break outside quotes."""
    out = []
    pending = ""
    for line in cmd.split("\n"):
        pending = f"{pending}\n{line}" if pending else line
        lex = shlex.shlex(pending, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        try:
            out.extend(lex)
        except ValueError:  # a quote still open: it spans the next line
            continue
        out.append("\n")
        pending = ""
    if pending:
        raise ValueError("unclosed quote")
    return out


def segments(toks):
    seg = []
    for tok in toks:
        if tok in OPS:
            if seg:
                yield seg
            seg = []
        else:
            seg.append(tok)
    if seg:
        yield seg


def values(toks):
    """Each variable's values: from NAME=VALUE and from for NAME in WORDS."""
    vals = {}
    for i, tok in enumerate(toks):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", tok)
        if m:
            vals.setdefault(m.group(1), []).append(m.group(2))
        if tok == "for" and i + 2 < len(toks) and toks[i + 2] == "in":
            words = []
            for w in toks[i + 3 :]:
                if w in OPS or w == "do":
                    break
                words.append(w)
            vals.setdefault(toks[i + 1], []).extend(words)
    return vals


def command_word(seg):
    """The index of the program a segment runs, past assignments and
    wrappers (sudo, env, timeout DURATION, flock LOCKFILE, ...)."""
    i = 0
    while i < len(seg):
        tok = seg[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tok):
            i += 1
        elif tok in PREFIX:
            i += 1
            while i < len(seg) and seg[i].startswith("-"):
                i += 1
            if tok in ("timeout", "flock") and i < len(seg):
                i += 1  # the duration or the lock file
        else:
            return i
    return None


def sends(seg, vals, out):
    for i, tok in enumerate(seg):
        if tok not in SENDS:
            continue
        # The program before it: tmux (with -L/-S) or lib.sh's t.
        sock = None
        for j in range(i - 1, -1, -1):
            if seg[j] == "t" and j == command_word(seg):
                sock = "t"
                break
            if os.path.basename(seg[j]) == "tmux":
                sock = "env"
                k = j + 1
                while k < i:
                    if seg[k] in ("-L", "-S") and k + 1 < i:
                        sock = f"{seg[k]} {seg[k + 1]}"
                        k += 2
                    elif seg[k].startswith(("-L", "-S")) and len(seg[k]) > 2:
                        sock = f"{seg[k][:2]} {seg[k][2:]}"
                        k += 1
                    else:
                        k += 1
                break
        if sock is None:
            continue
        target = None
        k = i + 1
        while k < len(seg) and seg[k].startswith("-") and seg[k] != "-":
            opt = seg[k]
            if opt == "-t" and k + 1 < len(seg):
                target = seg[k + 1]
                k += 2
            elif opt.startswith("-t") and len(opt) > 2:
                target = opt[2:]
                k += 1
            elif opt in VALUED:
                k += 2
            else:
                k += 1
        if target is None:
            continue  # no -t: the session's own pane
        m = VAR.match(target)
        if m:
            got = [v for v in vals.get(m.group(1), []) if not v.startswith("$")]
            if not got:
                print(f"UNRESOLVED\t{target}", file=out)
                continue
            for v in got:
                print(f"SEND\t{sock}\t{v}", file=out)
        elif "$" in target or "`" in target:
            print(f"UNRESOLVED\t{target}", file=out)
        else:
            print(f"SEND\t{sock}\t{target}", file=out)


def is_registry(tok):
    return os.path.basename(tok) == "panes.tsv"


def registry(seg, out):
    if not any(is_registry(tok) for tok in seg):
        return
    for i, tok in enumerate(seg[:-1]):
        if tok in (">", ">>", ">|", "<>") and is_registry(seg[i + 1]):
            print(f"REGISTRY\t{tok}", file=out)
            return
    c = command_word(seg)
    if c is None:
        return
    word = os.path.basename(seg[c])
    args = [a for a in seg[c + 1 :] if not a.startswith("-")]
    if word in COPIERS:
        # A copy writes only its destination; a move also takes its source away.
        hit = (
            bool(args)
            and is_registry(args[-1])
            or (word == "mv" and any(is_registry(a) for a in args))
        )
    elif word == "sed":
        hit = any(a.startswith(("-i", "--in-place")) for a in seg[c + 1 :])
    elif word in ("awk", "gawk"):
        hit = "inplace" in seg[c + 1 :]
    else:
        hit = word in WRITERS
    if hit:
        print(f"REGISTRY\t{word}", file=out)


def claude(seg, toks, out):
    c = command_word(seg)
    if c is None:
        return
    word = os.path.basename(seg[c])
    if (
        word != "claude"
        and not (
            word in ("bash", "sh")
            and c + 1 < len(seg)
            and os.path.basename(seg[c + 1]) in LAUNCHERS
        )
        and word not in LAUNCHERS
    ):
        return
    args = seg[c + 1 :]
    headless = word == "claude" and any(a in ("-p", "--print") for a in args)
    signal = None
    for tok in toks:  # an export earlier in the command reaches it too
        if KEY_ENV.match(tok):
            signal = tok.split("=", 1)[0]
        elif "apiKeyHelper" in tok:
            signal = "apiKeyHelper"
    for k, tok in enumerate(args[:-1]):
        if tok == "--settings":
            path = os.path.expanduser(args[k + 1])
            try:
                with open(path, encoding="utf-8") as f:
                    if "apiKeyHelper" in json.dumps(json.load(f)):
                        signal = f"apiKeyHelper in {args[k + 1]}"
            except (OSError, ValueError):
                pass
    if signal:
        print(
            f"CLAUDE\t{'headless' if headless else 'interactive'}\t{signal}", file=out
        )


def main():
    cmd = sys.stdin.read()
    try:
        toks = tokens(cmd)
    except ValueError:
        print("UNPARSED")
        return
    vals = values(toks)
    for seg in segments(toks):
        sends(seg, vals, sys.stdout)
        registry(seg, sys.stdout)
        claude(seg, toks, sys.stdout)


if __name__ == "__main__":
    main()
