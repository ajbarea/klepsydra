"""A stand-in for Claude Code in a tmux pane, for the fleet script tests.

It draws the screen shapes the fleet scripts read, as Claude Code 2.1 draws
them (captured 2026-10-28): the transcript, the spinner, the input box between
two rules with its dim placeholder, the status lines, the limit banners and
the Remote Control menu. It takes keys as a terminal would and appends what
happened to a log, one event per line (SUBMIT <text>, INTERRUPTED, RC ...).

A test steers it through a JSON state file, re-read on every tick:
  above      transcript lines above the input box
  below      status lines below it
  busy       a turn is running (the spinner shows)
  input      text to put in the input box now (then removed from the file)
  clear      empty the input box now (then removed from the file)
  on_submit  what a submitted line starts: "busy" (default), "limit" or "none"
  rc         "off" (default) or "on": Remote Control already connected
  rc_delay   seconds before /remote-control's answer shows
  busy_delay seconds before a submitted turn's spinner shows
  menu       "limit" shows Claude Code's limit menu

Run: python3 -I fake_pane.py STATE LOG
"""

import json
import os
import select
import sys
import termios
import time
import tty

RULE = "─" * 60
PROMPT = "\x1b[39m❯ "
PLACEHOLDER = '\x1b[2mTry\x1b[0m \x1b[2m"edit\x1b[0m \x1b[2m<filepath>\x1b[0m \x1b[2mto..."\x1b[0m'
SPINNER = "✢ Churning… (12s · ↓ 1.2k tokens · esc to interrupt)"
RC_ACTIVE = [
    "  /remote-control is active · Continue here, on your phone, or at",
    "  https://claude.ai/code/session_01FakeFakeFakeFakeFake",
]
RC_MENU = [
    "  Remote Control",
    "  This session is available in the Claude mobile app and at https://claude.ai/code/session_01FakeFakeFakeFakeFake.",
    "    Disconnect this session",
    "    Show QR code   Scan with your phone to open this session",
    "  ❯ Continue",
    "  Enter to select · Esc to continue",
]
LIMIT_MENU = [
    "  You've hit your session limit · resets 1:10pm (America/New_York)",
    "  ❯ 1. Stop and wait for limit to reset",
    "    2. Upgrade your plan",
    "  Enter to confirm · Esc to cancel",
]


class Pane:
    def __init__(self, state_path, log_path):
        self.state_path = state_path
        self.log_path = log_path
        self.state = {}
        self.input = ""
        self.pastes = 0
        self.menu = None
        self.rc_at = None  # when /remote-control's answer shows
        self.rc_was_on = False
        self.busy_at = None
        self.buf = b""
        self.shown = None

    def log(self, line):
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(line + "\n")

    def load(self):
        try:
            with open(self.state_path, encoding="utf-8") as f:
                state = json.load(f)
        except (OSError, ValueError):
            return
        changed = False
        if "input" in state:
            self.input = state.pop("input")
            changed = True
        if state.pop("clear", False):
            self.input = ""
            changed = True
        if changed:
            with open(self.state_path, "w", encoding="utf-8") as f:
                json.dump(state, f)
        self.state = state
        if state.get("menu") == "limit":
            self.menu = "limit"

    def save(self):
        with open(self.state_path, "w", encoding="utf-8") as f:
            json.dump(self.state, f)

    def submit(self):
        text = self.input
        self.input = ""
        if text.strip() == "/remote-control":
            self.rc_was_on = self.state.get("rc") == "on"
            self.rc_at = time.time() + float(self.state.get("rc_delay", 0))
            self.log("RC REQUESTED")
            return
        self.log("SUBMIT " + text.replace("\n", "\\n"))
        self.state.setdefault("above", []).append(
            "❯ " + text.splitlines()[0] if text else "❯"
        )
        then = self.state.get("on_submit", "busy")
        if then == "busy":
            self.busy_at = time.time() + float(self.state.get("busy_delay", 0))
        elif then == "limit":
            self.state["above"].append(
                "  ⎿  You've hit your session limit · resets 1:10pm (America/New_York)"
            )
        self.save()

    def key(self, data):
        self.buf += data
        while self.buf:
            b = self.buf
            if b.startswith(b"\x1b[200~"):
                end = b.find(b"\x1b[201~")
                if end < 0:
                    return
                text = b[6:end].decode("utf-8", "replace").replace("\r", "\n")
                self.buf = b[end + 6 :]
                self.pastes += 1
                self.input += text
                self.log("PASTE " + str(len(text)))
                continue
            if b.startswith(b"\x1b["):  # an arrow or other CSI key
                i = 2
                while i < len(b) and not (0x40 <= b[i] <= 0x7E):
                    i += 1
                if i >= len(b):
                    return
                self.buf = b[i + 1 :]
                continue
            self.buf = b[1:]
            c = b[:1]
            if c == b"\x1b":
                if self.state.get("busy") or self.busy_at is not None:
                    self.busy_at = None
                    self.state["busy"] = False
                    self.save()
                    self.log("INTERRUPTED")
                elif self.menu:
                    self.log("MENU ESC " + self.menu)
                    self.menu = None
                else:
                    self.log("ESC")
            elif c in (b"\r", b"\n"):
                if self.menu == "rc":
                    self.log("RC CONTINUE")
                    self.menu = None
                elif self.menu == "limit":
                    self.log("LIMIT MENU STOP")
                    self.menu = None
                    self.state.pop("menu", None)
                    self.state.setdefault("above", []).append(LIMIT_MENU[0])
                    self.save()
                elif self.rc_at is not None:
                    self.log("KEY ENTER (while /remote-control answers)")
                else:
                    self.submit()
            elif c == b"\x15":  # C-u
                self.input = ""
            elif c in (b"\x7f", b"\x08"):  # Backspace
                self.input = self.input[:-1]
            elif c >= b" ":
                rest = c
                while self.buf and self.buf[:1] >= b" " and self.buf[:1] != b"\x7f":
                    rest += self.buf[:1]
                    self.buf = self.buf[1:]
                self.input += rest.decode("utf-8", "replace")

    def tick(self):
        if self.busy_at is not None and time.time() >= self.busy_at:
            self.busy_at = None
            self.state["busy"] = True
            self.save()
        if self.rc_at is not None and time.time() >= self.rc_at:
            self.rc_at = None
            if self.rc_was_on:
                self.menu = "rc"
            else:
                self.state["rc"] = "on"
                self.state.setdefault("above", []).extend(RC_ACTIVE)
                self.save()
                self.log("RC ON")

    def lines(self):
        above = list(self.state.get("above", []))
        if self.state.get("busy"):
            above.append(SPINNER)
        if self.menu == "limit":
            return above + [RULE] + LIMIT_MENU
        if self.menu == "rc":
            return above + [RULE] + RC_MENU
        if self.pastes and "\n" in self.input:
            shown = f"[Pasted text #{self.pastes} +{self.input.count(chr(10))} lines]"
            box = [PROMPT + shown]
        elif self.input:
            first, *more = self.input.split("\n")
            box = [PROMPT + first] + ["  " + m for m in more]
        else:
            box = [PROMPT + PLACEHOLDER]
        below = self.state.get("below", ["  ⏵⏵ bypass permissions on · 1 shell"])
        return above + [RULE] + box + [RULE] + below

    def draw(self):
        lines = self.lines()
        if lines == self.shown:
            return
        self.shown = lines
        sys.stdout.write("\x1b[H\x1b[2J" + "\r\n".join(lines))
        sys.stdout.flush()


def main():
    pane = Pane(sys.argv[1], sys.argv[2])
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    # Claude Code asks for bracketed paste, so tmux's paste-buffer -p marks a paste.
    sys.stdout.write("\x1b[?2004h")
    try:
        while True:
            pane.load()
            pane.tick()
            pane.draw()
            ready, _, _ = select.select([fd], [], [], 0.05)
            if ready:
                data = os.read(fd, 4096)
                if not data:
                    break
                pane.key(data)
                pane.draw()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    main()
