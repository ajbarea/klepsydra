# IMPL

Current slice: the compact layout (#21). "Compact" in the tray redraws the
gauge as a ring per window in one row, low enough to sit inside the taskbar,
so every account fits there instead of one row with the rest below the edge.

## Done
- ✅ `gauge.js`: short countdowns ("4h 58m", "3d 11h", "<1m") and ages ("15m")
  from the same parts as the long ones, so the two cannot drift; each reading
  carries `short`, which keeps "· 15m old" and "· age unknown". `ringDash`
  leaves the round caps out of the dash, so 97% reads short of a full ring.
- ✅ `index.html` and `style.css`: one row template for both layouts. The
  ring (an SVG circle with `pathLength` 100) is hidden in the full layout; in
  compact a grid places the same label, percent and countdown. Floors under
  the percent and countdown, measured in the gauge's font, hold the width.
- ✅ `main.js`: each layout keeps its own zoom (`zoom`, `zoom_compact`), read
  before the switch so it draws once; a later layout message cancels one
  still loading; the first draw waits up to 500 ms for the saved layout.
- ✅ `main.rs`: the layout has a `Hub` of its own (the fleet's type, its own
  state), which holds its lock across publish and subscribe, so no tray
  change is lost at startup. A test builds the managed state, since a type
  managed twice panics at launch. The tray sends
  the layout read back from `prefs.json` and sets its check from it.
- ✅ `ipc.js`: one channel helper for the fleet feed and the layout.
- ✅ README (Compact, resizing, Restyling) and compact shots in
  `scripts/visual-check.sh`, including over 100%, a reset, waiting, three
  widths and zooms -3, +1, +2 and +4.

## Verified, not inferred
- ✅ Node, statusline, hook and fleet-crate suites pass in WSL; fleet clippy
  is clean.
- ✅ Chrome headless: 42px tall at 100%, 46px at 110%, 50px at 121%; one
  window is 149px wide at 9%, 10%, 97% and 118%.
- ✅ Independent review, two rounds. Round 2 found the launch crash (fixed,
  with its test) and three timing risks: two fixed, and a first layout whose
  zoom read outlasts 500 ms still draws the bars once.
- ✅ Clippy clean and 97 Rust tests pass on Windows (`build-windows.sh --check`),
  after the managed-state test tripped on the alias that crashed launch.
- 📋 Installed build: tray toggle both ways, each layout's zoom, restart.

## Open
- The tray icon still draws a bar in either layout.
- The visual check's first shot can miss on a cold Chrome start; a rerun
  writes all of them.
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
