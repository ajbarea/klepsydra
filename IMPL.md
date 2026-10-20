# IMPL

Current slice: a kourai forge medallion for every session without a kourai
portrait, replacing the DiceBear faces (branch feat/kourai-faces).

## Done
- ✅ `src/fleet/medallion.js`: one SVG template in a 96-unit viewBox, a dark
  disc lit from the upper left, a laurel ring and one serif initial, in one
  of six metals: kourai's gold (#C9944A, #F1D2A1, #AA771C), bronze, copper,
  rose gold, pale gold, verdigris. The metal is FNV-1a of the voice label,
  else the session id, mod 6. Built once per (initial, metal), at most
  37 x 6, as a `data:image/svg+xml` URL.
- ✅ The initial is the display name's first letter, upper-cased, only when it
  is A-Z or 0-9; anything else gets the laurel alone. No name text reaches
  the markup.
- ✅ `identity()`: a cast voice keeps its portrait; any other voice, a blend
  or no voice gets the medallion as `face` and `face2x`, named as before.
- ✅ Removed the Lorelei and fallback faces, their LICENSES.json entries,
  `cast.json`'s `lorelei` and `fallbacks`, `hash()`, and the DiceBear render
  scripts. `scripts/cut-portraits.py` stays for the portraits.
- ✅ CSP `img-src 'self' data:`; a guard keeps `data:` out of other directives.
- ✅ `many_tabs` says "Rename a tab so only one is titled that."; the `?demo`
  wall has a `bm_fable` session.

## Verified
- ✅ Tests: every metal's initial meets 4.5:1 against every stop of its disc;
  within a metal only the letter differs; `bm_fable` (rose gold) and
  `am_fenrir` (copper) differ; a voice keeps its metal across sessions;
  unsafe names draw no letter.
- ✅ `?demo` wall (1920x1080) and strip in Chromium: medallions load,
  `alt=""`, 66 px and 28 px circles matching the portraits beside them.

## Next
- 📋 #32: an optional split mode for the fleet tab.
- 📋 #22: interrupt and exit from a card; the recorded `tmux.pane` makes it a
  `send-keys` to a known pane.

## Open
- The initial uses a system serif (Palatino Linotype on Windows, P052 or
  DejaVu Serif on Linux), so the letter's shape differs by platform.
- Six metals for 4 uncast pool voices and any number of unnamed sessions:
  `am_fenrir` and `af_alloy` share copper (their initials differ).
- The tray icon still draws a bar in either layout.

## Verify
    node --test src/*.test.js
    bash statusline/test_statusline.sh && bash hooks/test_fleet.sh && bash hooks/test_launch.sh
    bash scripts/test_measure_memory.sh
    (cd src-tauri && cargo test -p klepsydra-fleet && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings)
    bash scripts/build-windows.sh --check
