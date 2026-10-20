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
- 📋 Installed build: toggle from the tray, the gauge stays on the taskbar
  edge, the layout survives a restart.

## Open
- The tray icon still draws a bar in either layout.
