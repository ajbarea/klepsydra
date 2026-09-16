# klepsydra

A thin always-on-top bar showing how much of your Claude Code limit you have
used, so you can see it without running `/usage` in whichever terminal happens
to be in front.

```
Current session   ●──────────────────────   1% used
Resets in 4 hr 58 min
```

The bar fills blue to yellow to red as the window is consumed.

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
that file. No API calls, no credentials, no second background process.

```
Claude Code (any terminal)
  │ statusLine JSON on stdin
  ▼
klepsydra-statusline.sh ──► %LOCALAPPDATA%\Klepsydra\usage.json ──► klepsydra.exe
  │
  └─► "Opus 5 · ctx 21% · 5h 73% · 7d 12%"
```

Run several terminals and they all publish to the same file. The limits are
account-wide, so the most recent writer is the correct one.

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

Set `KLEPSYDRA_OUT` if your Windows user differs from your WSL user.

**2. Build the overlay.** Requires Rust (MSVC toolchain), Node, and the
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

## Using it

The bar is click-through, so it never intercepts a click meant for the window
underneath. The tray icon switches between the 5-hour and 7-day windows, shows
both at once, toggles interactivity so you can drag the panel, and quits.

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
