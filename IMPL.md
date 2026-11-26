# IMPL: card names keep room in narrow compact walls (#535, PR #538)

Branch fix/card-names-535, worktree .claude/worktrees/agy-535. Opus redesign
(11-25) after the free-engine rounds ran out; spec:
https://github.com/ajbarea/klepsydra/issues/535#issuecomment-7172801378

## Slice
One floor for every engine: `fleet/namewidth.js` measures each compact card's
name (a Range, read all then write all, cached per card by text and loaded
fonts) and sets `--name-w` on the card; `wall.css` gives the name's column
`minmax(min(--name-w, 90px) + gap, 1fr)`. Who gives way: the name to its
floor, then the pill's time, then its label, down to its mark; Open terminal
and Clear never (max-content tracks). No `calc-size()`, no `@supports` fork,
no comfortable block (the app never shows comfortable under 420 px).

## Done
- CSS + JS + node test (`src/fleet-namewidth.test.js`, 6).
- `narrow_window_keeps_cards_inside` runs twice (as is, and with every
  stylesheet's `calc-size()` stripped and `CSS.supports` denying it), at
  360-1920 px incl. 880/900; asserts a time is cut only with its name at the
  floor (one-line headers), a label only once the time is gone and with no
  space left beside it, and no pill content outside its box. 57/57.
- Mutants, each red: no shrink weight (12), rigid label (2), no floor (4),
  no measuring (4), the flex gap back (12).
- Shots: fleet-briefing shots/2026-11-25/klepsydra-535-redesign-*.

## Verify
- `node --test src/fleet-namewidth.test.js`
- `flock -o /tmp/fleet-heavy.lock timeout 1500 uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py narrow_window_keeps_cards_inside`

## Next
1. 📋 Fresh Opus review rounds (elenchus medium) to clean, CI green, merge.
