# IMPL

Current slice: first working overlay.

## Done
- statusLine producer publishing one file per account, 27 fixture tests green.
- Gauge logic (`src/gauge.js`): ramp, countdown, staleness, multi-account rows. 21 unit tests green.
- Overlay frontend renders a row per account window, verified by screenshot across 9 states.
- Ramp set to `bands` (blue <60%, yellow 60-85%, red >85%).
- Tauri shell: transparent click-through window, tray, `read_usage` + `set_height` commands.
- Screenshot harness (`scripts/visual-check.sh`), deterministic via `?still=1`.

- Built and run on Windows. Verified at the OS level: WS_EX_TRANSPARENT
  (click-through), WS_EX_TOPMOST, WS_EX_LAYERED, no taskbar button, and
  `set_height` sizing the window to the measured panel (64 configured -> 56 actual).
- Live end-to-end: overlay reading matched the account file exactly (86%, 2 hr 14 min).

## Open
- Window x/y (1480,12) overlap the browser tab strip; needs a real position.
- The tray menu is untested: it builds without panicking, but no item has been
  clicked, so the interactive/click-through toggle is unexercised.
- Tray icon lands in the notification-area overflow by default.
- Autostart not wired.

## Verify
    bash statusline/test_statusline.sh
    node --test src/*.test.js
    bash scripts/visual-check.sh
