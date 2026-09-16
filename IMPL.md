# IMPL

Current slice: first working overlay, installed and running.

## Done
- statusLine producer publishing one file per account. 27 fixture tests.
- Gauge logic (`src/gauge.js`): ramp, countdown, staleness, multi-account rows.
  23 unit tests.
- Overlay renders a row per account window and sizes its window to fit.
  Screenshot-verified across 9 states; ramp set to `bands`.
- Tauri shell: transparent, click-through, topmost, tray, autostart, persisted
  position. Installed to `%LOCALAPPDATA%\klepsydra` from the NSIS bundle.
- Screenshot harness (`scripts/visual-check.sh`), deterministic via `?still=1`.

## Verified against the running window, not inferred
- `WS_EX_TRANSPARENT`, `WS_EX_TOPMOST`, `WS_EX_LAYERED` set; no taskbar button.
- `set_height` sized the window to the measured panel (64 configured -> 56 actual).
- Grip hit testing: cursor over the handle flips click-through off, everywhere
  else leaves it on.
- Dragging, driven by a synthesised press-move-release: moved exactly the
  commanded delta, a press starting off the handle moved nothing, and the
  position survived a restart.
- Taskbar burial reproduced (gauge hidden 120ms after the taskbar takes
  foreground) and recovery confirmed (visible again at 700ms).
- Reading on screen matched the published file exactly.
- Autostart registry entry points at the installed path.

## Open
- Tray menu is unexercised: it builds and the registry side checks out, but no
  item has been clicked, so the autostart toggle and "Reset position" have
  never run.
- Tray icon lands in the notification-area overflow by default.
- Default position (1280,1022) assumes 1920x1080; window-state overrides it
  once the handle is dragged.

## Verify
    bash statusline/test_statusline.sh
    node --test src/*.test.js
    bash scripts/visual-check.sh
