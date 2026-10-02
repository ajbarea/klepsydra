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
`${XDG_DATA_HOME:-~/.local/share}/dev.ajsoftworks.klepsydra` on Linux.

### Reconciling several terminals

Each session reports whatever *its own* last API response said, so an idle
terminal keeps publishing a stale, lower number forever -- and with several
terminals sharing one file the reading flips between them. So every session
writes its own file and the overlay reconciles them per account and window:

- a later `resets_at` means a newer window, and wins outright;
- within one window usage only ever grows, so the highest reading is current.

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

**1. Publish the numbers.** Copy the hook and point Claude Code at it:

```bash
cp statusline/klepsydra-statusline.sh ~/.claude/
chmod +x ~/.claude/klepsydra-statusline.sh
```

Then in `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "~/.claude/klepsydra-statusline.sh" }
```

The hook picks the overlay's data dir for the platform it runs on: on Linux,
the XDG data dir; under WSL, the Windows side, since the overlay there is a
Windows app.

Set `KLEPSYDRA_DIR` if your Windows user differs from your WSL user. It
configures the hook, which wants a WSL path (`/mnt/c/...`); the overlay
reads the same setting as a Windows path (`C:\...`), so exporting one value
to both sides gives the overlay a path it cannot resolve.

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

The gauge needs an X11 session. Under native Wayland, Tauri cannot read the
global pointer position, so the drag handle never responds.

`sudo apt remove klepsydra` leaves the published readings in the data dir; they
are small, and rewritten on the next render.

**Upgrading from a build older than this one:** step 1 again. The hook is a
copy in your `~/.claude`, so an upgraded overlay meets a hook still publishing
to the previous location, `%LOCALAPPDATA%\klepsydra`. The overlay reads both, so
the gauge keeps working either way; once the hook is re-copied, that folder
holds nothing current and can be deleted.

## Using it

Grab the dotted handle on the left edge to drag the gauge anywhere; it
remembers where you put it. Everything except that handle is click-through, so
the gauge never intercepts a click meant for the window underneath.

Dragging is handled in the backend rather than by `data-tauri-drag-region`,
which needs a focused window -- this one is deliberately unfocused and
click-through, so webview drag events never arrive. The pointer watcher reads
the mouse button straight from the OS instead, and a drag only begins on a
press that starts on the handle.

Neither Windows nor Tauri's X11 backend offers per-region hit testing for a
click-through window -- ignoring cursor events is all or nothing. So a
background thread watches the pointer and makes the window interactive only
while it is over the handle. The frontend
reports the handle's rectangle rather than the backend hard-coding it, so
restyling cannot desync the two.

The tray icon is itself a miniature of the bar, redrawn as the reading changes,
so the level stays readable when the overlay is covered or a fullscreen app is
in front. It offers "Reset position" (for when the gauge has been dragged
off-screen or onto a monitor that is no longer attached), toggles "Start with
Windows" ("Start at login" on Linux), and quits. Autostart is on by default; the icon may start in the
notification-area overflow.

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

## How often it refreshes

The status line is event-driven: Claude Code runs it as you work, and the hook
publishes on every render. `refreshInterval` adds a periodic re-run so the
reading stays fresh in an idle terminal:

```json
"statusLine": {
  "type": "command",
  "command": "~/.claude/klepsydra-statusline.sh",
  "refreshInterval": 30
}
```

Idle sessions republishing stale numbers are harmless, because reconciliation
takes the highest reading rather than the latest writer. That refreshes the
timestamp, not the number. The percentage only moves when a
new API response arrives, which is correct -- usage does not grow while you are
idle. The overlay re-reads the files every 5 seconds, and the countdown ticks
every 15 seconds off `resets_at`, so it stays right even when nothing is
publishing.

## Switching accounts

Signing into a different account is picked up on the next render, and publishes
under the new account's file. The previous account keeps its row, because its
5-hour window carries on burning down whether or not you are signed into it.
That row drops once the window actually resets.

Rows are ordered by when each account last published, so the account you are
signed into now leads and the one you switched away from sits under it. The
tray icon follows the same order, and so tracks the account you are on.

## Restyling

Every visual token lives at the top of `src/style.css`: bar height and radius,
the three ramp colours and their thresholds, panel background and padding,
fonts and sizes. `--ramp-mode` picks between `blend` (continuous
interpolation) and `bands` (flat colours that switch at thresholds). Edit,
rebuild, done.

## When it does not know

A gauge showing a confident wrong number is worse than one admitting
ignorance, so the panel dims whenever it cannot establish a live reading:

| Condition | Shown |
|---|---|
| No file yet | `waiting for Claude Code` |
| File older than 15 minutes | number kept, panel dimmed |
| The window's own reset time has passed | `window reset`, no number |
| Unreadable or malformed file | last good reading, dimmed |

`rate_limits` is absent before the first API response of a session and when no
window is active. The hook treats that as "nothing to say" and leaves the
previous file alone rather than overwriting it with blanks.

## Tests

```bash
bash statusline/test_statusline.sh   # hook, against recorded payload shapes
node --test src/*.test.js            # ramp, countdown, staleness rules
bash scripts/visual-check.sh         # screenshots every state
```
