# IMPL: klepsydra#461 gauge strip shows the resting keeper with no sessions

Issue: https://github.com/ajbarea/klepsydra/issues/461 (branch `fix/strip-keeper-461`)

## Slice
- `src/fleet/cast.js`: `keeperBase(cast)`, the one keeper lookup; `theme.js` `keeperOf` (the wall's empty state) uses it.
- `src/fleet/strip.js`: with no sessions, once the reader has spoken (`heard`), draw one `.face.rest` button: the keeper's 96/192 face, label "Open the fleet wall", no badge or pulse; a theme with no keeper gets a plain four-card glyph button. Click calls `open()` with no id. Before the first snapshot the strip stays hidden (no flash of the keeper).
- `src/main.js`: `open_wall` gets `focus: ""` when no id (the wall ignores an empty focus).
- `src/style.css`: `.face.rest` layout. `stripRect` already reads the strip's rect, so the window sizing needs no change.
- Tests: `src/fleet-strip.test.js` (keeper button, click, sessions replace it, no keeper, pre-snapshot hidden).

## Done
Code, unit tests.

## Next
Full `node --test src/*.test.js`, `npm run lint`, screenshots in `fleet-briefing/shots/2026-11-18/keeper-strip-*.png`, PR (label bug, assignee ajbarea, Closes #461), CI wait, report to Heph, `fleet done`. Do not merge.

## Verify
`node --test src/fleet-strip.test.js`; `npm run lint`; render with the real themes at 1920 (scratch script `shoot.py`).
