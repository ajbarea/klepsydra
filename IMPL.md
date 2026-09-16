# IMPL

Current slice: first working overlay.

## Done
- statusLine producer publishing one file per account, 27 fixture tests green.
- Gauge logic (`src/gauge.js`): ramp, countdown, staleness, multi-account rows. 21 unit tests green.
- Overlay frontend renders a row per account window, verified by screenshot across 9 states.
- Ramp set to `bands` (blue <60%, yellow 60-85%, red >85%).
- Tauri shell: transparent click-through window, tray, `read_usage` + `set_height` commands.
- Screenshot harness (`scripts/visual-check.sh`), deterministic via `?still=1`.

## Open
- `cargo tauri build` has never run. Blocked on MSVC Build Tools (VCTools workload).
- Window x/y in `tauri.conf.json` are placeholders for a 1920-wide display.
- `set_height` auto-sizing is written but unexercised until the first build.
- Autostart not wired; currently a Startup-folder shortcut.

## Verify
    bash statusline/test_statusline.sh
    node --test src/*.test.js
    bash scripts/visual-check.sh
