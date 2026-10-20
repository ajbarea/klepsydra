# IMPL

Current slice: compact card density (#50), branch feat/compact-cards. AJ runs
the wall on half of a 1920x1080 screen (about 960x1000), where five
comfortable cards already scrolled; eight should fit.

## Done
- Density (`src/fleet/density.js`): Auto (default), Comfortable, Compact.
  Auto turns compact when the comfortable grid would scroll and back only
  when it would fit RETURN_SPARE_CARDS (1) more card, so a card leaving and
  arriving at the boundary does not flip the wall. `wall.js` measures an
  unseen comfortable clone of the wall (with that extra card, as tall as the
  tallest) on a card arriving or leaving and on resize (100 ms settle).
- Compact (`wall.css`, tokens on `[data-density="compact"]` set on the bar
  and the wall): the card is one grid, header (56 px portrait with ring and
  waves, name, task, pill, Clear, Open terminal 28 px tall), meta (repo,
  branch, "+N" chip with role img + aria-label + title, crew), ask, then
  prompt 1 line and reply 2 (1 when asking). `grid-auto-rows: 1fr`, so every
  card is 196.6 px. A button note floats over the card corner; `.why` and
  "prompt free" are hidden; `.updated` folds into the pill (`pillWhen`).
- One spacing scale (`--space-1..9`); comfortable values unchanged, compact
  picks 12 px gap and padding. Waves scale with `--wall-face`.
- Pref: `wall_density` in prefs.json via `get_wall_density` /
  `set_wall_density` (`src-tauri/src/fleet.rs`, unknown values read as auto).
- Control: radio fieldset beside + New session, 24 px labels.
- Demo: `?demo=N` takes the first N sessions; two new fixture sessions
  (long names, +2 chip, stale updated) and a long task name on Metis.
- Measured (Playwright, demo): 960x1000 Auto = compact, 8 cards, no scroll,
  bottom at 893 px; 1920x1080 Auto = compact, 16 cards in 4x4, no scroll.
  Comfortable is pixel-identical to main below the bar (reduced motion,
  16 cards, 960 and 1920).
- Ring, option C (round 2): one solid arc per item, agents first from 12
  o'clock; agent thick, shell thin, one colour (`RINGS` in model.js:
  comfortable 7/3 px, compact 5.5/2.5 px, gaps 14/11 px of arc, so 22/25
  degrees); at most RING_MAX (5) arcs plus "+N", a shell keeps one. The model
  returns `rings` per density; wall.js repaints rings on a density change.
  The face insets 9 px (compact 7) so a hairline of card shows inside the arc.
- Ring key (`.ring-key` beside the tally in `.lead`): two neutral arcs at the
  comfortable widths, shown while any card has work (`showsRingKey`); wraps
  to a second line at 945. Screen readers get one sentence; arcs aria-hidden.
- Fit at the real content sizes (work area 1920x1048, so about 1920x1000
  maximised and 945x1000 snapped): `scripts/test_wall_browser.py` checks 16 cards
  at 1920x1000 and 8 at 945x1000 in Auto, compact, no scrollbar, key in view
  (bottom 895 and 916 px).
- Gates: the whole audit list, build-windows --check, the fit test.

- Review round (PR #55), each with a check that failed first: a
  ResizeObserver on the wall re-runs Auto once a frame when a card grows; the
  probe copies the bar as comfortable and rounds up (and the visually hidden
  live region no longer adds a pixel under the wall); compact keeps a one-line
  slot at the card's foot for the note or the off reason (note title = full
  text); an off Open terminal's name ends "unavailable: <reason>". Compact
  cards are 205.6 px; fit bottoms 931 (1920x1000) and 952 (945x1000).

## Next
- AJ merges. #56 Slice 2 (the wall's receipt line, guardrail chip and ledger
  drawer) builds on this branch's wall once it lands; main has #57's receiver
  and ledger merged in (fba8801).
- Live check through UIA on the installed build: switch densities, resize
  across the boundary, confirm the pref survives a restart.

## Verify
- `node --test src/*.test.js`; `cd src-tauri && cargo test -p klepsydra-fleet`.
- Serve the repo root, open `/src/wall.html?demo=8` at 960x1000 and
  `/src/wall.html?demo` at 1920x1000; or run `scripts/test_wall_browser.py`.
