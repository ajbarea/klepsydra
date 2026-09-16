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

- Grab handle with pointer-watched hit testing, autostart, and persisted window
  position. Hit testing verified by moving the cursor and watching
  WS_EX_TRANSPARENT flip: interactive over the handle, click-through elsewhere.
- Installed to `%LOCALAPPDATA%\klepsydra` via the NSIS bundle, so the autostart
  entry points at a stable path rather than the scratch build directory.

## Open
- The tray menu is untested: it builds without panicking, but no item has been
  clicked, so the autostart toggle is unexercised. Its handler is the only path
  that calls `disable()`.
- Tray icon lands in the notification-area overflow by default.
- Default position (1280,1022) assumes 1920x1080; the window-state plugin
  overrides it once the handle is dragged.


## Verify
    bash statusline/test_statusline.sh
    node --test src/*.test.js
    bash scripts/visual-check.sh
