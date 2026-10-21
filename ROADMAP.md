# ROADMAP

A Claude Code usage gauge that is always on screen, so the limit is readable at
a glance instead of by running `/usage` in whichever terminal is in front.

## Design constraint

The gauge must never show a confident wrong number. A reading more than 15
minutes old says how old it is, an ended window says when it reset, and the
panel dims only while it has nothing to show. Dimming was dropped because
the account you are not on is always hours old, and it has to stay legible.
The fleet strip holds to the same rule: every status shows its age, and a
session that stops answering reads as silent, never as working.

## Next
- Take the fleet's 8-hour memory reading (README, Releasing).
- Interrupt and exit buttons on a card (#22), which need Jump's tab match.

## Later
- Optional: flash or notify when crossing a threshold.
- A product version of the fleet strip (heuresis verdict `later`, 2026-10-18).
- Clear a card's state on an interrupted turn (Esc on a need, an interrupt)
  once Claude Code fires a hook for it; until then the card keeps its state
  until the next prompt, or reads "working?" at 10 minutes.
- Name a session that keeps Claude Code's default display name (`my-app-3f`),
  which reaches no hook; it is named by its folder for now.

## Completed
- 2026-10-21: Comfortable cards wear their character (#62): a header band lit in
  their colour with their cut-out figure breaking its top edge, a nameplate
  with their epithet, crew marks on a plaque at the figure's foot, and the
  whole portrait one click away (#44). Compact's face grew to 64 px.
- 2026-10-20: Launch sessions as tmux windows from the wall, stable jump,
  Clear, gone, redesigned wall (#31, merged as #35).
- 2026-10-20: Exercised every tray item live on Windows, by real mouse
  clicks: "Set home here" saved the docked rect, "Reset position" brought
  the gauge back to it from mid-screen, and "Start with Windows" removed and
  restored the Run key, its check mark following.
- 2026-10-20: The statusline hook prunes readings the overlay can never draw
  again, hourly and in the background, and never publishes a reading whose
  every window has ended. On a copy of the WSL station's readings it removed
  191 of 265 files and the gauge drew the same rows.
- 2026-10-19: Kept the kourai cast on screen while keryx is muted (#19). A
  session with no keryx hold takes the voice keryx remembers for its repo,
  and the reader keeps any two sessions from sharing a face.
- 2026-10-19: Added the compact layout ("Compact" in the tray, #21): a ring
  per window in one row, 42px tall with three windows where the bars stand
  142px, so the gauge fits inside a 48px taskbar up to 110%. Each layout
  keeps its own zoom, and short countdowns keep the age of an old reading.
- 2026-10-19: Ran the fleet live check against the installed Windows build;
  every README step held over two runs (#17). Opening eleven sessions at once
  jammed WSL's NAT to Anthropic's API for every session, so later checks
  start sessions a few at a time.
- 2026-10-19: Added the fleet strip and card wall. A hook writes one file per
  Claude Code session and the status line adds a heartbeat; the overlay
  shows a portrait per session beside the gauge, whoever needs AJ first,
  with a card wall a click away and a jump back to the session's terminal.
  Every status shows its age, and a session that stops answering reads as
  silent. Polling `claude agents --json` was ruled out: 0.38 to 0.57 s and
  about 170 MB per call (measured 2026-10-18).
- 2026-10-18: Made the gauge resizable and homeable. Scrolling on the grip
  zooms everything around the pointer, so the grip stays under it; a probe
  confirmed the click-through window receives the wheel there and passes it
  through elsewhere. Rows coming or going grow the window away from the
  nearest screen edges. A tray "Set home here" gives "Reset position" a
  target that survives monitor changes. Bars went from 6px to 10px.
- 2026-10-18: Made readings trustworthy across two accounts. Re-renders were
  republishing a session's last reading as fresh and under whichever login was
  current, which filed Personal's weekly under the RIT seat; highest-wins kept
  a weekly at 100% after a mid-week reset dropped it to 1%; and the other
  account vanished once its window reset, the moment it was worth switching
  to. The hook now publishes only changed readings, the newest one wins, and
  the other account stays with its age shown.
- 2026-10-02: Ported to Linux (X11), so the gauge also runs on the Debian/XFCE
  workstation. The hook writes to the XDG data dir, the drag handle reads the
  pointer from the X server, and CI lints the Rust shell on both platforms.
  GTK's 200x200 floor for non-resizable windows was the one Linux-only fix;
  the WebKitGTK/NVIDIA blank-window bug did not reproduce.
- 2026-09-16: Kept the gauge in front of the taskbar. Both are topmost, so the
  last one raised wins; clicking the taskbar buried the gauge and took its drag
  handle with it. Re-asserting HWND_TOPMOST twice a second fixes it, and a tray
  "Reset position" covers the cases z-order cannot fix.
- 2026-09-16: Added a drag handle, autostart and position persistence. Windows
  has no per-region hit testing for click-through windows, so a pointer-watching
  thread makes the window interactive only over the handle. Installed via the
  NSIS bundle; registering autostart from the build directory would have broken
  on the next rebuild.
- 2026-09-16: Built and ran on Windows. Transparency, click-through,
  always-on-top, taskbar suppression and window auto-sizing all confirmed
  against the live window rather than inferred; the rendered reading matched
  the published file exactly.
- 2026-09-16: Made the gauge account-aware. A team seat and a personal account
  report different windows and are used from different terminals, so a single
  shared file would have let two unrelated numbers overwrite each other. The
  hook now takes account identity from the global config (which
  `CLAUDE_CONFIG_DIR` relocates per login) and writes one file per account.
- 2026-09-16: Established the data source: Claude Code's statusLine JSON input
  carries `rate_limits.five_hour` / `seven_day` / `spend_limit`, each with
  `used_percentage` and `resets_at`. This is the same number `/usage` shows.
- 2026-09-16: Ruled out the Xbox Game Bar widget store: Game Bar widgets are
  UWP XAML apps, UWP is deprecated as a forward-looking framework, and the
  "widget store" is the Microsoft Store, requiring Partner Center and
  certification. The Windows 11 Widgets Board is Adaptive Cards only, which
  cannot express a custom bar. An always-on-top overlay does what was wanted.
- 2026-09-16: Producer, gauge logic, frontend and Tauri shell written and
  tested; build pending toolchain.
