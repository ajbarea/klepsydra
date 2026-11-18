# IMPL: klepsydra#461 gauge strip shows the resting keeper with no sessions

Issue: https://github.com/ajbarea/klepsydra/issues/461 · PR #463 · branch `fix/strip-keeper-461`

## Slice
- `src/fleet/cast.js` `keeperBase` (one keeper lookup); `strip.js` draws one `.face.rest` button with no sessions (after the reader's first snapshot): keeper face, or a plain wall-mark button; click calls `open()` with no id.
- Review fix (Opus, 11-18): `.face img { display:block }` beat `[hidden]`, so the plain button drew a broken-image sliver and a keeper switch left the old face. Fixed with `.face img[hidden] { display:none }` in `src/fleet/badge.css`, and `strip.js` clears the img `src`/`srcset` when no keeper.

## Done
- Code, unit tests (`src/fleet-strip.test.js`, 15 pass), lint clean; earlier full `node --test` 514 pass.
- New browser case `strip_keeper_states` in `scripts/test_wall_browser.py` (keeper face; switch keeper -> none; fresh plain button; asserts display none, no src, glyph centred).

## Next (not run: stopped at the 5h limit)
1. Run `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py strip_keeper_states` under `flock -o /tmp/fleet-heavy.lock`, with `STRIP_SHOTS=/mnt/c/Users/ajbar/fleet-briefing/shots/2026-11-18` for the three `keeper-strip-browser-*.png`; fix the case if it fails. Optionally confirm it fails with the CSS rule removed.
2. Add a shots/README.md line for the new shots; update the PR body (what was checked live).
3. One CI round on #463 (the "Gauge logic" job was pending earlier), then report to Heph. Do not merge.

## Verify
`node --test src/fleet-strip.test.js`; `npm run lint`; the browser case above.
