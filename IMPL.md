# IMPL

Current slice: first working overlay.

## Done
- statusLine producer (`statusline/klepsydra-statusline.sh`) publishing `usage.json`, 19 fixture tests green.
- Gauge logic (`src/gauge.js`) with ramp, countdown and staleness rules, 13 unit tests green.
- Overlay frontend (`src/`), verified by screenshot across 9 states plus a ramp comparison.
- Ramp set to `bands` (blue <60%, yellow 60-85%, red >85%).
- Tauri shell (`src-tauri/`): transparent click-through window, tray menu, `read_usage` command.
- Screenshot harness (`scripts/visual-check.sh`), deterministic via `?still=1`.

## Open
- `cargo tauri build` has never run. Blocked on MSVC Build Tools (VCTools workload).
- Window x/y in `tauri.conf.json` are placeholders for a 1920-wide display.
- Autostart not wired; currently a Startup-folder shortcut.

## Verify
    bash statusline/test_statusline.sh
    node --test src/*.test.js
    bash scripts/visual-check.sh
