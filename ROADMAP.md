# ROADMAP

A Claude Code usage gauge that is always on screen, so the limit is readable at
a glance instead of by running `/usage` in whichever terminal is in front.

## Design constraint

The gauge must never show a confident wrong number. Every path that cannot
establish a live reading dims the panel instead of drawing a stale bar.

## Next
- Exercise the tray menu.

## Later
- Optional: flash or notify when crossing a threshold.
- Optional: compact mode that drops the label and countdown to a bare bar.

## Completed
- 2026-09-16 — Added a drag handle, autostart and position persistence. Windows
  has no per-region hit testing for click-through windows, so a pointer-watching
  thread makes the window interactive only over the handle. Installed via the
  NSIS bundle; registering autostart from the build directory would have broken
  on the next rebuild.
- 2026-09-16 — Built and ran on Windows. Transparency, click-through,
  always-on-top, taskbar suppression and window auto-sizing all confirmed
  against the live window rather than inferred; the rendered reading matched
  the published file exactly.
- 2026-09-16 — Made the gauge account-aware. A team seat and a personal account
  report different windows and are used from different terminals, so a single
  shared file would have let two unrelated numbers overwrite each other. The
  hook now takes account identity from the global config (which
  `CLAUDE_CONFIG_DIR` relocates per login) and writes one file per account.
- 2026-09-16 — Established the data source: Claude Code's statusLine JSON input
  carries `rate_limits.five_hour` / `seven_day` / `spend_limit`, each with
  `used_percentage` and `resets_at`. This is the same number `/usage` shows.
- 2026-09-16 — Ruled out the Xbox Game Bar widget store: Game Bar widgets are
  UWP XAML apps, UWP is deprecated as a forward-looking framework, and the
  "widget store" is the Microsoft Store, requiring Partner Center and
  certification. The Windows 11 Widgets Board is Adaptive Cards only, which
  cannot express a custom bar. An always-on-top overlay does what was wanted.
- 2026-09-16 — Producer, gauge logic, frontend and Tauri shell written and
  tested; build pending toolchain.
