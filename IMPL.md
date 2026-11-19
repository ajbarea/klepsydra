# IMPL: klepsydra#421 + #438: gauge strip, variant A with docked faces

Branch feat/gauge-strip-a-421 (worktree .claude/worktrees/gauge-421). Decision: PR #459 last comment (AJ 11-18).
Mockups: branch design/mockups-1118, docs/mockups/2026-11-18 (gauge-a.html, strip.js/css, readings.js, wall-header.html, settings-a.html).

## Plan: one PR per step
1. **PR 1 (this branch): floating strip as variant A.**
   - `src/icons.js`: MAKER_ICONS moved out of wall.js, shared by wall and gauge.
   - `src/chips.js` (pure, tested): `toChips(rows, nowMs)` groups toRows' rows into one chip per account;
     lead = tightest non-group window; week at 100% = "out until", session hidden; group windows (agy claude/gpt) never lead;
     stale (> 3 h) dims and names its age; route chip from toRows' isBestRoute (#411 rule, no second source);
     Copilot placeholder until #323; order = route order (agy, copilot, api, claude), then label.
   - `src/chipview.js`: DOM for linear (tray Compact) and stacked (tray Full). Hover detail = native title tooltip
     (escapes the small window); aria-label carries every window.
   - Faces dock to their account's chip (session account.id = usage account id; agy/copilot by engine); the rest after the last chip.
   - Hit area: the whole strip (grip + chips), as the mockup's click-through default is off; the setting comes in PR 3.
   - Double layout: in PR 3 with Settings' layout row (issue filed).
2. **PR 2: #438 opacity** 0-100 step 5 in prefs.json, live; halo below 60% (dark) / 50% (light), full ink below 70%.
3. **PR 3: docked gauges in the wall header** + floating strip hidden while the wall has focus + Settings › Gauges rows.
4. **PR 4: System chip** (off by default), only after 1-3.

## Done
- (nothing pushed yet)

## Next
- Write chips.js + tests, icons.js, chipview.js, main.js/index.html/style.css; strip.js `place` option.

## Verify
- `node --test src/*.test.js`; `npm run lint`; live: serve src/ with real readings (phone server usage), Playwright 1920/390 dark/light.
- CPU: CDP Performance TaskDuration delta / wall time over 120 s, main vs branch, same fixture.
