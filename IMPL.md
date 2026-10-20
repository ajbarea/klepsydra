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
- Gates: the whole audit list, build-windows --check.

## Next
- Independent review, then AJ merges.
- Live check through UIA on the installed build: switch densities, resize
  across the boundary, confirm the pref survives a restart.

## Verify
- `node --test src/*.test.js`; `cd src-tauri && cargo test -p klepsydra-fleet`.
- Serve the repo root, open `/src/wall.html?demo=8` at 960x1000 and
  `/src/wall.html?demo` at 1920x1080.
