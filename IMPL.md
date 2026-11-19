# IMPL: klepsydra#461 gauge strip shows the resting keeper with no sessions

Issue: https://github.com/ajbarea/klepsydra/issues/461 · PR #463 · branch `fix/strip-keeper-461`

## Slice
- `src/fleet/cast.js` `keeperBase` (one keeper lookup); `strip.js` draws one `.face.rest` button with no sessions (after the reader's first snapshot): keeper face, or a plain wall-mark button; click calls `open()` with no id.
- Review fix (Opus, 11-18): `.face img { display:block }` beat `[hidden]`, so the plain button drew a broken-image sliver and a keeper switch left the old face. Fixed with `.face img[hidden] { display:none }` in `src/fleet/badge.css`, and `strip.js` clears the img `src`/`srcset` when no keeper.

## Done
- Code, unit tests (15 pass), lint clean; full `node --test` 514 pass.
- Browser case `strip_keeper_states`: 3 pass with the fix, 2 fail with the CSS rule removed. Shots in fleet-briefing/shots/2026-11-18/keeper-strip-browser-*.png.

## Next
One CI round on #463, then report to Heph (inbox/hermes-463.md if `fleet send` says not-pasted). Do not merge.

## Verify
`node --test src/fleet-strip.test.js`; `npm run lint`; `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py strip_keeper_states`.
