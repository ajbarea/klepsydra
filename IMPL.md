# IMPL

Current slice: a kourai forge medallion for every session without a kourai
portrait, replacing the DiceBear faces (branch feat/kourai-faces).

## Done
- ✅ `src/fleet/medallion.js`: one SVG template in a 96-unit viewBox, a
  charcoal-to-bronze disc lit from the upper left, a gold laurel ring in
  kourai's gold (#C9944A, #F1D2A1, #AA771C) and one serif initial. Built
  once per initial and returned as a `data:image/svg+xml` URL.
- ✅ The initial is the display name's first letter, upper-cased, only when it
  is A-Z or 0-9; anything else gets the laurel alone. No name text reaches
  the markup.
- ✅ `identity()`: a cast voice keeps its portrait; any other voice, a blend
  or no voice gets the medallion as `face` and `face2x`, named as before.
  A voice named like an Object property no longer matches the cast.
- ✅ Removed the Lorelei and fallback faces, their LICENSES.json entries,
  `cast.json`'s `lorelei` and `fallbacks`, `hash()`, and the DiceBear render
  scripts. `scripts/cut-portraits.py` stays for the portraits.
- ✅ CSP: `img-src 'self' data:`, so the app shows the data URL; a guard keeps
  `data:` out of every other directive.
- ✅ `many_tabs` now says "Rename a tab so only one is titled that."
- ✅ The `?demo` wall has a `bm_fable` session, shown as a medallion.

## Verified
- ✅ Tests: the initial meets 4.5:1 against every disc stop; only the letter
  differs between medallions; unsafe names draw no letter.
- ✅ The `?demo` wall at 1920x1080 and strip in Chromium (Playwright): the
  medallion loads, `alt=""`, 66 px inside the 80 px portrait and 28 px in
  the strip, the same circle as the portraits beside it.

## Next
- 📋 #32: an optional split mode for the fleet tab.
- 📋 #22: interrupt and exit from a card; the recorded `tmux.pane` makes it a
  `send-keys` to a known pane.

## Open
- The initial uses a system serif (Palatino Linotype on Windows, P052 or
  DejaVu Serif on Linux), so the letter's shape differs by platform.
- The tray icon still draws a bar in either layout.

## Verify
    node --test src/*.test.js
    bash statusline/test_statusline.sh && bash hooks/test_fleet.sh && bash hooks/test_launch.sh
    bash scripts/test_measure_memory.sh
    (cd src-tauri && cargo test -p klepsydra-fleet && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings)
    bash scripts/build-windows.sh --check
