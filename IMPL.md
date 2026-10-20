# IMPL

Current slice: the compact layout (#21). "Compact" in the tray redraws the
gauge as a ring per window in one row, low enough to sit inside the taskbar,
so every account fits there instead of one row with the rest below the edge.

## Done
- ✅ `gauge.js`: short countdowns ("4h 58m", "3d 11h", "<1m") and ages ("15m")
  from the same parts as the long ones, so the two cannot drift; each reading
  carries `short`, which keeps "· 15m old" and "· age unknown".
- ✅ `index.html` and `style.css`: one row template for both layouts. The
  ring (an SVG circle with `pathLength` 100, so the dash is the percentage)
  is hidden in the full layout; in compact a grid places the same label,
  percent and countdown, and the bar is hidden. Compact tokens sit in the
  restyling block, and every size still follows the zoom.
- ✅ `main.js`: `applyLayout`, a layout channel from the backend, and a first
  draw that waits up to 500 ms for the saved layout so a compact gauge does
  not open tall.
- ✅ `main.rs`: `layout` in `prefs.json`, `layout_subscribe`, and a "Compact"
  check item in the tray menu.
- ✅ README (Compact, Restyling) and compact shots in `scripts/visual-check.sh`.

## Verified, not inferred
- ✅ 118 node tests pass, including long and short countdowns agreeing at
  every unit boundary.
- ✅ Rendered in Chrome headless: 42px tall with three windows, against 142px
  for the bars.
- ✅ Clippy clean and 96 Rust tests pass on Windows (`build-windows.sh --check`).
- ✅ Installed build in compact sits inside the taskbar (32px at zoom -3,
  docked at y=1048). 📋 Tray toggle and restart not yet exercised.

## Next: review round 1 (independent review, 2026-10-19), not yet fixed
- Zoom per layout (`zoom`, `zoom_compact`; compact starts at 0), since a
  shared zoom leaves compact at -3 unreadable (about 8px labels, seen live).
- Rust: `layout_subscribe` stores the channel and sends under one lock;
  the tray handler re-reads the saved layout and sets the check from it.
- DRY: reuse the fleet `Hub` and `feed.js` channel setup for the layout.
- Ring: subtract the round caps (stroke / 2πr of the path) from the dash so
  97% does not read full; transition `visibility` so a reset animates down.
- Width: give `.pct` a floor that fits "100%" and `.sub` one for "23h 59m".
- Drop the redundant `--size-pct`/`--size-sub` compact overrides; add
  compact shots for over 100%, reset at 0% and waiting; README states the
  zoom at which compact fits 48px.

## Open
- The tray icon still draws a bar in either layout.
- The default display name (`my-app-3f`) reaches no hook and no status line,
  so a session with no voice and no name is named by its launch folder.
- A denied permission dismissed with Esc keeps "needs you" until the next
  prompt, its age showing.

## Verify
    node --test src/*.test.js
    bash statusline/test_statusline.sh && bash hooks/test_fleet.sh
    bash scripts/test_measure_memory.sh
    (cd src-tauri && cargo test -p klepsydra-fleet && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings)
    bash scripts/build-windows.sh --check
    bash scripts/visual-check.sh
