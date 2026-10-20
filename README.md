<p align="center">
  <img src="assets/hero.png" alt="klepsydra sitting over the Windows taskbar, showing 3% of the five-hour window used" width="520">
</p>

<h1 align="center">klepsydra</h1>

<p align="center">Your Claude Code usage limit, always on screen.</p>

<p align="center">
  <a href="https://github.com/ajbarea/klepsydra/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/ajbarea/klepsydra/ci.yml?branch=main&label=CI" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-Windows%20%7C%20Linux-0078D4" alt="Platform: Windows | Linux">
</p>

A thin always-on-top bar showing how much of your Claude Code limit you have
used, so you can see it without running `/usage` in whichever terminal happens
to be in front. The bar fills blue to yellow to red as the window is consumed.
With several Claude Code sessions open, a portrait for each sits beside the
bar, and the ones waiting on you come first.

## Why "klepsydra"

A *klepsydra* is the Athenian water clock: a vessel that drains to time a
speech in court. A visible, depleting allotment.

## How it gets the number

Claude Code pipes a JSON blob to your `statusLine` command on every render.
That blob carries the same rate-limit figures `/usage` displays:

```json
"rate_limits": {
  "five_hour": { "used_percentage": 73, "resets_at": 1746540000 },
  "seven_day": { "used_percentage": 12, "resets_at": 1746799200 }
}
```

So the status line does double duty: it prints a compact readout to your
terminal, and publishes the figures to a small JSON file. The overlay polls
those files. No API calls, no credentials, no second background process.

```
Claude Code (every session)
  │ statusLine JSON on stdin
  ▼
klepsydra-statusline.sh ──► <app data dir>/accounts/<account>/<session>.json
  │                                          │
  └─► "Opus 5 · ctx 21% · 5h 73% · 7d 12%"   └──► klepsydra overlay
```

The app data dir is `%LOCALAPPDATA%\dev.ajsoftworks.klepsydra` on Windows and
`$XDG_DATA_HOME/dev.ajsoftworks.klepsydra` on Linux (`~/.local/share` when
`XDG_DATA_HOME` is unset or relative).

### Reconciling several terminals

Each session holds whatever *its own* last API response said, and Claude Code
re-runs the status line with that same response on `refreshInterval`, at a
window's reset time and on mode changes. So the hook publishes a session's
reading only for a new response (the session's API time grew, or its windows
changed), each session to its own file, stamped `observed_at`. The overlay
reconciles them per account and window:

- the reading observed last is current, because it came from the latest API
  response;
- readings observed in the same second fall back to the later `resets_at`,
  then the higher number.

Files without `observed_at` come from an older hook, which restamped every
session on every re-render. Observed readings newer than all of them make
them obsolete, and they are ignored. Until then, or while one is newer than
every observed reading (an old hook still writing), the overlay takes the
newest window and its highest reading, as before. Upgrade the hook with the
overlay.

Taking the highest reading is not safe even within one window: a reset granted
mid-week or a plan upgrade lowers usage under the same `resets_at`.

### Old readings

A reading whose every window has ended is never published, since a real
response always reports the window it counts against. Once an hour, in the
background, the hook deletes readings the overlay can never draw again: a
session's file whose every window ended over a day ago, unless it is its
account's newest, and that one too once the overlay drops the account after
30 days without a reading. An account with an older hook's files keeps every
reading until it is dropped, since the overlay weighs all of them there.
Anything it cannot read stays. A reading rewritten while the prune decides
stays too, and one rewritten in the instant before the delete comes back on
its session's next render. An account takes its name from its newest
reading.

## Two accounts at once

The statusLine payload carries no account identity, so the hook reads it from
the global config, which `CLAUDE_CONFIG_DIR` relocates per login:

```bash
CLAUDE_CONFIG_DIR=~/.claude-personal claude   # one account
claude                                         # the other
```

Each account publishes to its own file, so terminals on different logins never
overwrite each other, and the overlay draws a labelled row for each:

<p align="center">
  <img src="assets/two-accounts.png" alt="Three rows: a personal session and week window, and a team session window, each separately labelled" width="450">
</p>

With one account the rows drop the prefix and read "Current session" and "This
week". A separate config dir is a separate *everything* though, so the second
profile starts without your settings, plugins or skills until you copy them.

## Install

**1. Publish the numbers and the sessions.** Copy the hooks, the launcher and
its tmux settings, and point Claude Code at the hooks. Starting sessions from
the wall needs tmux 3.3 or later (`remain-on-exit failed`); Ubuntu 24.04's 3.4
is the tested version.

```bash
cp statusline/klepsydra-statusline.sh hooks/klepsydra-fleet.sh hooks/klepsydra-launch.sh hooks/klepsydra-tmux.conf ~/.claude/
chmod +x ~/.claude/klepsydra-statusline.sh ~/.claude/klepsydra-fleet.sh ~/.claude/klepsydra-launch.sh
```

Then merge this into `~/.claude/settings.json` (into each config dir's
`settings.json` if you run two logins):

<!-- fleet-settings:start -->
```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/klepsydra-statusline.sh",
    "refreshInterval": 30
  },
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "PreToolUse": [{ "matcher": "AskUserQuestion|ExitPlanMode", "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "Notification": [{ "matcher": "elicitation_dialog|elicitation_url_dialog|idle_prompt", "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "PostToolUse": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "PostToolUseFailure": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "StopFailure": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command", "command": "~/.claude/klepsydra-fleet.sh", "async": true }] }]
  }
}
```
<!-- fleet-settings:end -->

Every fleet hook is `async`, so Claude Code never waits for it, and none
prints anything, so the permission hook never answers a prompt. The
`Notification` matcher catches an MCP server's request for input (a dialog or
a URL) and the idle notice that corrects a session still marked as working
after its turn ended. `PostToolUseFailure` ends a wait whose approved command
then failed.
For the gauge alone, keep `statusLine` and leave out `hooks`.

The hook picks the overlay's data dir for the platform it runs on: on Linux,
the XDG data dir; under WSL, the Windows side, since the overlay there is a
Windows app.

Set `KLEPSYDRA_DIR` if your Windows user differs from your WSL user. It
configures both hook scripts, which want a WSL path (`/mnt/c/...`); the overlay
reads the same setting as a Windows path (`C:\...`), so exporting one value
to both sides gives the overlay a path it cannot resolve. The hooks prune
their old files only when the last folder of that path is
`dev.ajsoftworks.klepsydra`; any other name leaves them in place.

**2. Build the overlay.** Windows and Linux differ here; see the Linux
section below. On Windows it requires Rust (MSVC toolchain), Node, and the
Microsoft C++ Build Tools:

```powershell
winget install Rustlang.Rustup OpenJS.NodeJS
winget install Microsoft.VisualStudio.2022.BuildTools --override `
  "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

```bash
bash scripts/build-windows.sh
```

`KLEPSYDRA_STAGE=klepsydra-build-<name>` builds in a staging folder of its own,
so a branch can build beside the main one.

**3. Start it with Windows.** Put a shortcut to `klepsydra.exe` in
`shell:startup`.

Published readings live in `%LOCALAPPDATA%\dev.ajsoftworks.klepsydra`, so
uninstalling with *Delete application data* ticked takes them with it. Leaving
it unticked keeps them for a reinstall; they are rewritten within seconds of
the next Claude Code render by any terminal signed into that account.

### Linux

Tested on Debian 13 with XFCE on X11. Install Rust with
[rustup](https://rustup.rs), then the WebKitGTK, tray and build packages:

```bash
sudo apt install libwebkit2gtk-4.1-dev build-essential curl wget file libxdo-dev \
  libssl-dev libayatana-appindicator3-dev librsvg2-dev nodejs npm
bash scripts/build-linux.sh
sudo apt install ./src-tauri/target/release/bundle/deb/klepsydra_0.1.0_amd64.deb
```

Run `klepsydra` once. It registers itself in `~/.config/autostart`, so it starts
with every later login.

The tray icon needs a StatusNotifierItem host. On XFCE that is the Status Tray
panel plugin (`xfce4-panel --add=systray`). Stock GNOME has none and needs an
AppIndicator extension. Without a host the gauge still runs, but the tray menu,
and with it Quit, is unreachable: `pkill klepsydra` stops it.

Tauri's X11 click-through leaves one input pixel at the window's top-left
corner, which sits in the panel's transparent rounded corner.

The gauge needs an X11 session. A Wayland compositor shows clients no global
pointer, so under Wayland the drag handle stays inert.

`sudo apt remove klepsydra` leaves the published readings in the data dir; they
are small, and rewritten on the next render.

**Upgrading from a build older than this one:** step 1 again. The hook is a
copy in your `~/.claude`, so an upgraded overlay meets a hook still publishing
to the previous location, `%LOCALAPPDATA%\klepsydra`. The overlay reads both, so
the gauge keeps working either way; once the hook is re-copied, that folder
holds nothing current and can be deleted.

## Using it

Grab the dotted handle on the left edge to drag the gauge anywhere; it
remembers where you put it. Everything except that handle and the fleet
strip is click-through, so the gauge never intercepts a click meant for the
window underneath.

Scroll on the handle to resize the whole gauge, text and bars together, from
75% to 236% in 10% steps; the new size shows briefly and is remembered,
for each layout apart. The point under the pointer stays put, so the handle
stays under it. When rows come or go, the gauge grows away from the screen
edges it sits nearest: parked over the taskbar, it grows upward. Either way it
stays wholly on its monitor. Scrolling relies on Windows' "Scroll inactive
windows when I hover over them", which is on by default.

Dragging is handled in the backend rather than by `data-tauri-drag-region`,
which needs a focused window -- this one is deliberately unfocused and
click-through, so webview drag events never arrive. The pointer watcher reads
the mouse button straight from the OS instead, and a drag only begins on a
press that starts on the handle.

Neither Windows nor Tauri's X11 backend offers per-region hit testing for a
click-through window -- ignoring cursor events is all or nothing. So a
background thread watches the pointer and makes the window interactive only
while it is over the handle or the fleet strip. The frontend reports both
rectangles rather than the backend hard-coding them, so restyling cannot
desync the two.

The tray icon is itself a miniature of the bar, redrawn as the reading changes,
so the level stays readable when the overlay is covered or a fullscreen app is
in front. "Set home here" saves where the gauge sits now, and "Reset position"
returns it there, keeping the corner nearest the screen edges: a gauge homed
on the taskbar returns to the taskbar at any size. Its monitor is found by
position, then by name, then by nearness, and a changed resolution moves
home to the same relative spot. With no home saved, it goes over the primary
monitor's taskbar, 220px in from the right. The menu also toggles "Compact"
(below) and "Start with Windows" ("Start at login" on Linux), and quits.
Autostart is on by default; the icon may start in the notification-area
overflow.

### Compact

"Compact" in the tray menu redraws the gauge to fit inside the taskbar. Each
window becomes a ring, filled clockwise from 12 o'clock in the bar's colours,
beside its percentage and countdown over its label, all in one row with the
fleet strip beside it. Countdowns shorten ("4h 58m", "3d 11h"), and a
reading more than 15 minutes old still says how old it is ("2h · 20m old").

<p align="center">
  <img src="assets/compact-taskbar.png" alt="The compact gauge inside the Windows taskbar: three rings with 12% and 4h 37m for the personal session, 20% and 6d 15h for the personal week, an empty ring with 0% and reset 2h ago for the team session, and five session portraits beside them" width="614">
</p>

Each layout keeps its own size from the handle, since compact is sized to the
taskbar and the bars to the desk. Compact opens at 100%, where three windows
stand 42px tall against 142px for the bars, and it fits inside a 48px taskbar
up to 110%. The choice is remembered, and switching keeps the gauge on the
screen edges it sits nearest, so a gauge on the taskbar stays there.

### Staying in front of the taskbar

The taskbar is itself a topmost window, and within that band z-order goes to
whichever window was raised last -- so clicking the taskbar buries a gauge
sitting over it, and takes the drag handle out of reach. Tauri's
`set_always_on_top` diffs against the flag it already holds and does nothing,
so klepsydra calls `SetWindowPos` with `HWND_TOPMOST` twice a second instead.
`NOMOVE`/`NOSIZE` preserve your position and `NOACTIVATE` keeps focus where it
was.

On Linux the gauge sets `_NET_WM_STATE_ABOVE` and the window manager keeps it
there, so no re-assert runs. On XFCE it stays above the panel when the panel
is revealed.

## The fleet strip

<p align="center">
  <img src="assets/fleet-strip.png" alt="The gauge's three account rows, and beside them fifteen session portraits: three with orange needs-you diamonds first, then a vermillion error square, three blue working circles, four green done checks, and grey rings for sessions not started or ended" width="670">
</p>

With several Claude Code sessions open, klepsydra shows a portrait for each to
the right of the gauge, with a badge for its status. Each badge has its own
shape, symbol and colour, from the Okabe-Ito palette:

| Badge | Status | Means |
|---|---|---|
| orange diamond `!` | needs you | a permission, a question, a plan or an MCP server's request is waiting |
| vermillion square `×` | error | the last turn ended on an API error |
| blue circle `…` | working | a prompt is being answered |
| blue circle `?` | working? | working, but nothing has happened for 10 minutes; the turn may have been interrupted |
| orange diamond `?` | needs you? | waiting on you with no word for 30 minutes; the session may be gone |
| green circle `✓` | done | the last turn finished |
| grey ring `○` | not started | no prompt yet |
| grey ring `?` | silent | no heartbeat and no event for 90 seconds; the session may be gone (never shown for a session waiting on you, since an open prompt hides the status line and stops the heartbeat) |
| grey ring `–` | ended | the session ended; it leaves after 10 minutes |
| grey ring `–` | ended · gone | the session's Claude process is gone (a reboot or `wsl --shutdown`); it leaves after 10 minutes |

On a card, an ended or error pill names its reason: "ended · exited",
"ended · gone", "error · rate limit".

Sessions that need you come first, the longest wait leading, then errors,
work in progress, finished work, and the rest. A session that starts needing
you pulses once, unless the system asks for reduced motion. Every status
shows its age, in the portrait's tooltip and on its card. A ring around each
badge keeps it at 3:1 contrast against the strip's backdrop.

Click a portrait to open the card wall at that session. It is an ordinary
window, made on the first click and only hidden after that. A summary bar
counts the sessions that need you, work, are done, and are idle or ended, with
an error count only when one exists. Each card shows:

- the session's face in a ring that fills, while it works, with the time since
  its last activity (its file's last change) over 600 seconds, and while it
  needs you with the time since it asked over 1800 seconds: the same limits
  that turn a card to "working?" and "needs you?";
- a status pill, top right, with the badge, label and age, and the reason on
  an ended or error card;
- the session's name, where it works now (repo, worktree, branch chip) and the
  other repos it touched;
- for a session that needs you, a line saying what it waits for;
- the last prompt in a quoted block and the full reply under it.

A left edge in the status tone marks each card, and a needs-you card adds an
amber border. Ended, silent and not-started cards are dimmer. The grid uses
columns at least 420 px wide: four at 1920 px, two at 1280, one at 800.

**Open terminal** (Jump) brings the session's terminal to the front. For a
session started with **+ New session**, it finds the session's tmux window by
pane id and checks the Claude process is still in that pane, selects the
window, then selects the Windows Terminal tab titled exactly "klepsydra
sessions", the fixed title of the fleet tab; a hand-opened session of that name,
whose title starts with a status glyph, is not it. If the pane now holds
another session, or a launch is already running, the card says so and no tab
is selected. If no tab matches, the window is still selected and the card
says "Selected the session's tmux window."; hidden tabs, two matching tabs and
a UI Automation failure are reported as they are. If Windows keeps the focus,
the tab's taskbar button flashes instead. A session in tmux opens this way
before it has a name.

When Open terminal is off, its reason ("session ended", "no session name
yet") shows as small text beside it.

For a tab opened by hand, Jump selects the tab whose title, after its status
glyph, is exactly the session's name. With no such tab, or more than one, it
says so and does nothing. When Windows Terminal hides its tabs (full screen or
focus mode), it says that instead. A tab renamed in Windows Terminal (Rename
tab) keeps that name and ignores Claude Code's title, so Jump cannot find it.
Rename the tab by hand to exactly the session's name (right-click the tab,
Rename tab), or start the session from **+ New session**, which needs no tab
title.

**Clear** on an ended or silent card removes it now. A session that is still
running brings its card back at its next event, without its start time or the
repos it touched.

### Starting sessions

**+ New session**, in the wall's summary bar, starts `claude` in `launch_dir`
as a window of the tmux session `fleet` on the socket `klepsydra`. The first
click opens a Windows Terminal window named `fleet` with one tab. Each later
click adds a tmux window to that tab. Closing the tab leaves the sessions
running, and the next **+** or Jump reattaches. The tab attaches to the tmux
server by its socket path.

On a cold WSL the tab can take longer than the 5 seconds the launcher waits
for it. The note then says "Started a session in DIR. The terminal tab has not
attached yet.", and for 30 seconds another **+** or Jump opens no second tab.
A click waits up to 45 seconds for WSL. Past that the note says "WSL did not
answer within 45 seconds. The session may still be starting; check the
terminal before clicking again."

`launch_dir` and `launch_distro` are keys in `prefs.json`, in the app data dir.
`launch_dir` defaults to `~`. `launch_distro` defaults to WSL's default
distro. tmux loads `~/.tmux.conf` first, then `~/.claude/klepsydra-tmux.conf`,
which names each window after its Claude session and keeps a window open when
`claude` exits with an error. This is the one place the overlay starts a
process: `wsl.exe`, from a click, one call at a time.

To see the wall without sessions, serve the repo root (for example
`python3 -m http.server`) and open `/src/wall.html?demo`.

A session's face follows its keryx voice, so it stays the same while the
session moves between repos. Ten voices are cast as the kourai-khryseai
characters and show their portraits. Any other voice shows the voice's name
and a forge medallion: a gold laurel ring on a dark bronze disc around the
name's initial. A session without keryx is named by its session, else its
folder, and shows the medallion with that initial.

While keryx is muted (`/keryx off`) it holds no new terminal, so a new session
takes the voice keryx remembers for its repo and the cast stays on screen. The
session keeps that voice as it moves between repos.

Sessions sharing a voice show its face by claim: a session that has not ended
before one that has, then a voice keryx held before a repo's, then the first
started. The others show a medallion and their own name until the keeper leaves;
two running sessions that keryx itself gave one voice both keep it. So a face
changes with the status only once, when its session ends beside a running one
with the same voice (after `/clear`, the new session keeps the portrait).

The portraits are files in `src/fleet/faces`, each listed in `LICENSES.json`,
and `scripts/cut-portraits.py` cuts them from kourai-khryseai. The medallion is
an SVG drawn in `src/fleet/medallion.js`. The overlay loads no library and
fetches nothing.

The fleet hook writes `<app data dir>/fleet/<session>.json`: the state, where
the session works, the first 300 characters of your last prompt and of the
last reply, and the error text of a failed turn. It records no tool input
beyond the tool's name and an edited file's path. The status line adds
`<session>.beat`, the session's name, at most once per 10 seconds. At a
session start, at most once an hour, the hook deletes a session's file when
its Claude Code process is gone and its newest time field (including
`written_at`) is more than a day old, along with the session's beat file. A
session with a fresh heartbeat survives, whatever its file says. A
beat file with no session file, and leftover temp files, go when their own
modification time is more than a day old.

The overlay starts no process and asks WSL for nothing: it watches the folder
and re-reads it every 5 seconds. A file it cannot read is skipped and logged
once to `fleet.log` in the app data dir, and the rest of the fleet still
shows. keryx does the speaking; the strip makes no sound.

## How often it refreshes

The status line is event-driven: Claude Code runs it as you work, and the hook
publishes whenever a render carries a new reading. `refreshInterval: 30` also
re-runs it every 30 seconds, idle or not. The usage reading ignores those
re-runs, since each repeats the session's last API response, but each writes
the session's heartbeat for the fleet strip, at most once per 10 seconds. The
overlay re-reads the files every 5 seconds, and the countdown ticks every 15
seconds off `resets_at`, so it stays right even when nothing is publishing.

## Switching accounts

A running session moves to a new login at its next request, so its next reading
publishes under the new account. A re-render before then repeats the old
account's reading, which stays filed under the old account.

The account you switched away from keeps its rows, since they tell you whether
switching back would help. A window that has reset reads `0% used` with when it
reset. An account's rows go only after 30 days without a reading.

Rows are ordered by when each account last published, so the account you are
signed into now leads and the one you switched away from sits under it. The
tray icon follows the same order, and so tracks the account you are on.

## Restyling

Every visual token lives at the top of `src/style.css`: bar height (10px, read
from across a desk) and radius, the three ramp colours and their thresholds,
panel background, padding and width, fonts and sizes. Each size is multiplied
by the zoom set from the handle. `--ramp-mode` picks between `blend` (continuous
interpolation) and `bands` (flat colours that switch at thresholds). Edit,
rebuild, done.

The fleet strip's sizes and the compact layout's ring sit in the same block,
followed by the few tokens the compact layout changes. The strip's badge colours are in
`src/fleet/badge.css`, where a test holds each to 3:1 contrast, and the card
wall's tokens open `src/fleet/wall.css`.

## When it does not know

A gauge showing a confident wrong number is worse than one admitting
ignorance, so every reading says how old it is once that matters:

| Condition | Shown |
|---|---|
| No file yet | `waiting for Claude Code`, panel dimmed |
| Reading older than 15 minutes | number kept, `updated 2 hr ago` after the countdown |
| The window's own reset time has passed | `0% used`, `Reset 2 hr ago` |
| Unreadable or malformed file | skipped; the account's other sessions still count |

Readings are per machine. Usage on another machine, or since a window reset,
shows up here only once a terminal on this machine makes a request.

`rate_limits` is absent before the first API response of a session and when no
window is active. The hook treats that as "nothing to say" and leaves the
previous file alone rather than overwriting it with blanks.

## Tests

```bash
bash statusline/test_statusline.sh       # usage hook and heartbeat, against recorded payloads
bash hooks/test_fleet.sh                 # fleet hook: states, where, identity, pruning, gone, settings
bash hooks/test_launch.sh                # launcher: new, jump, tab reuse, against a private tmux socket
bash scripts/test_measure_memory.sh      # the release memory check
node --test src/*.test.js                # ramp, countdown, reconciliation, fleet model, faces, guards
(cd src-tauri && cargo test -p klepsydra-fleet)   # fleet reader
bash scripts/build-windows.sh --check    # clippy and every Rust test, on Windows
bash scripts/visual-check.sh             # screenshots every state, the strip and wall included
```

The app crate needs WebKitGTK headers to compile on Linux, so in WSL only the
fleet crate's tests run locally; `--check` and CI cover the rest.

## Releasing

A release ships only when all three hold:

1. Every command under Tests passes, and CI is green on both platforms.
2. The live check, in order:
   1. Back up your Claude Code settings:
      `cp ~/.claude/settings.json ~/.claude/settings.json.bak-fleet`
   2. Merge the fleet settings block from Install, the JSON between the
      `<!-- fleet-settings:start -->` and `<!-- fleet-settings:end -->`
      markers, into `~/.claude/settings.json`. It registers the fleet hooks
      with `async: true` and sets `statusLine.refreshInterval` to 30.
   3. With the new build running, open eight Claude Code sessions in Windows
      Terminal tabs and bring each to one state:
      - **not started:** start `claude` and type nothing.
      - **working:** ask for something long, such as running `sleep 300` in
        Bash.
      - **needs you, approve Bash:** in the default permission mode, ask for a
        command that prompts, and leave the prompt open.
      - **needs you, question:** ask Claude to ask you a multiple-choice
        question, and leave it open.
      - **done:** a prompt that finishes, such as "say hi".
      - **error:** a turn that ends on an API error, such as a prompt in a
        session started with `--model` naming a model the account cannot use.
      - **silent:** `kill -STOP <pid>` on one session's Claude Code process
        (the `claude.pid` in its session file). `kill -CONT <pid>` brings it
        back.
      - **ended:** `/exit` in one session. It leaves after 10 minutes.
   4. Exercise what the status rests on:
      - **Held prompts:** leave a permission prompt and a multiple-choice
        question open for 3 minutes each. Each stays needs you with its age
        growing, never silent and never done (the status line hides while a
        dialog is open, so no heartbeat arrives, and `idle_prompt` must not
        fire).
      - **Failed command:** approve a command that fails, such as
        `grep nomatch /etc/hostname`. The need clears, back to working then
        done.
      - **Subagent ask:** have a subagent ask for a permission and answer it.
        The need clears after the answer.
      - **Exits:** close one tab with its X and `/exit` another. Both read
        ended within 10 minutes, not silent.
   5. Read `bash scripts/fleet-status.sh` against the strip and the wall, one
      line per session. Its `state` column is the portrait's badge and the
      card's status; `reason` is the card's text under it (the tool for
      approve Bash, the question for a question); `beat age` over 90 seconds
      is silent, which the card shows with its age, except for a session that
      needs you: it keeps needing you while its prompt is open (step 4) and
      reads "needs you?" after 30 minutes with no word.
   6. Click each portrait: the wall opens on that session's card. Press
      **Open terminal** on the approve-Bash card: its tab comes to the
      front, or its taskbar button flashes. Rename a hand-opened session to
      another session's name and press Jump again: it says two tabs match and
      does nothing. Move the wall, quit klepsydra from the tray, start it again and
      open the wall: it opens where you left it.
   7. Starting sessions, with `klepsydra-launch.sh` and `klepsydra-tmux.conf`
      in `~/.claude/`:
      - Press **+ New session** three times: one tab, three windows.
      - Press **Open terminal** on each card: each hops to its own window.
      - Close the tab, then press **+**: the tab reattaches and adds a window.
      - Press **Clear** on an ended card: it goes.
      - Run `wsl --shutdown` and start klepsydra and a session again: the old
        cards read "ended · gone".
   8. Restore your settings:
      `mv ~/.claude/settings.json.bak-fleet ~/.claude/settings.json`
3. Memory. Right after starting klepsydra, run
   `bash scripts/measure-memory.sh run /tmp/klepsydra-memory.log` in a WSL
   terminal and leave both running for 8 hours with the fleet in use. It
   samples klepsydra's working set in MiB, WebView2 processes included, at 5
   minutes and at 8 hours. It refuses to run with more than one klepsydra.exe,
   and the check fails if klepsydra restarted between the readings. The release
   is blocked if the second reading is more than 10% above the first. Record
   both readings in the release's ROADMAP entry.
