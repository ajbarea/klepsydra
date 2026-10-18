# IMPL

Current slice: a gauge you can size, park and read from across a desk.

## Done
- Scroll on the grip zooms the whole gauge in 10% integer levels, 75% to
  236%, kept in `prefs.json` in the app data dir; a badge shows the size for
  800ms. Wheel maths in `src/zoom.js`: at most one step per event and per
  80ms, a notch-sized delta steps at once, smaller ones (touchpads)
  accumulate, and a fling cannot bank more than one step. 9 tests.
- Every CSS size is multiplied by `--scale`, and a test fails on any px size,
  or px token, outside the tokens that is not. The panel sets its own width and the window
  follows, as it already did for height. Bars 6px to 10px.
- `set_size` replaces `set_height`. A zoom pins the content under the live
  cursor (read when the resize runs, not when the wheel event fired), and an
  edge flush with the monitor stays flush; other size changes grow away from
  the nearest monitor edges; the first sizing after launch restores the last
  rect by its edges, so a gauge docked on the taskbar stays docked whatever
  its rows; the result is clamped to the monitor's full bounds. Move and
  resize are one SetWindowPos on Windows. On X11, where both land
  asynchronously, the rect last requested stands in for 500ms.
- Tray "Set home here" saves the window rect and its monitor (name, bounds,
  scale). "Reset position" finds that monitor by bounds, then name, then
  nearness; keeps home's corner nearest the edges, rescaled if the resolution
  changed; positions for the size the gauge will have at the destination's
  scale; and clamps. The move keeps the current size, since Windows rescales
  on arrival. A prefs file that exists but cannot be read is never
  overwritten. Placement maths in `src-tauri/src/geometry.rs`, std only. 21
  tests, run in CI.
- The grip rectangle travels with each resize, and the watcher re-reads its
  cached placement at once, so the next wheel notch still lands on the grip.
  It saves the position once moves settle, not per notch.

## Verified, not inferred
- Windows probe (synthetic wheel through the OS input stack, cursor parked
  over a throwaway build): every notch on the grip arrived (deltaY +-100,
  pixel mode); three on the bar passed through to the window beneath; 30-unit
  deltas arrived as 25px; Ctrl+wheel did not trigger WebView2's page zoom.
  Grip armed in 8-30ms (20 of 20), disarmed in 2-33ms.
- Geometry and zoom suites pass locally (`rustc --test`, `node --test`).

## Open
- Mixed-DPI monitors not exercised: a reset across scales relies on Windows
  rescaling the window on arrival.
- Not yet run on X11; scroll there is expected to work (wheel goes to the
  window under the pointer) but unverified.
- Depends on Windows' "Scroll inactive windows" setting (on by default).
- Track #2f2f2f against the panel is 1.3:1; the fill carries the contrast.

## Verify
    node --test src/*.test.js
    (cd src-tauri && cargo test && cargo clippy --all-targets -- -D warnings)
    bash scripts/visual-check.sh
