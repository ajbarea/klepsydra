# IMPL: klepsydra#384 PR 1 (#493): settings page, design A

Branch `feat/settings-page-384`, worktree `.claude/worktrees/settings-r2`.
Push only with `git push origin feat/settings-page-384:feat/settings-page-384`. Never to main.
Notes from earlier sessions (reviews r1-r3, browser and Windows logs, shots, PR-body draft):
`~/.local/state/fleet-orchestrator/reports/settings-493-r1.md` and `.../reports/settings-493-r2/`.

## Slice
Make PR 1 merge-ready: every review Blocking, Should-fix and Nit fixed, with guards so the
classes cannot return. Opus worker took it over from agy. Do not merge; Athena reviews and
does the live check in the Windows app.

## Stopped here (11-19 night, paused at AJ's word to save Personal capacity)
- Pushed through 943d5c8. Round 1 and 2 fixed; round 3's three Should-fix fixed in 3032584
  (hold without saving, one `fleet voices` at a time, card focus, refused reads hide rows).
  Whether every r3 Nit landed is unchecked: verify in round 4 (`settings-493-r2/review-r3.md`).
- Browser `settings_view` passes 24/24 on 943d5c8's test with the real CSS (both schemes
  emulated, 1920 + 390; `settings-493-r2/logs/br5.log`).
- Was mid mutation check: mutant `.settings-view .tog[aria-checked="true"]` ->
  `.tog[aria-checked="true"]` (loses to wall.css `button:hover:not(...)`, 0,2,1). The run was
  killed by the limit before it finished; the mutant has been reverted in the tree.
- Windows check last passed at 20:48, before the r3 fixes: rerun.

## Next
1. Mutation check: `flock -o /tmp/fleet-heavy.lock timeout 1200 python3 ~/.local/state/fleet-orchestrator/reports/settings-493-r2/mutate_heavy.py "$PWD"` (must print `caught`).
2. Full settings browser cases, both schemes, 1920 + 390, and `build-windows.sh --check` on HEAD.
3. Independent Opus review round 4 (fresh reviewer: diff + open r3 Nits); fix until clean.
4. Shots to fleet-briefing/shots/2026-11-19 (+ README line); PR body from `settings-493-r2/pr-body.md`
   (short top, live vs tested); CI green; `fleet send` Athena; `fleet done`.

## Verify
`node --test src/*.test.js` · `npm run -s lint` · `uvx ruff check scripts/test_wall_browser.py` ·
`flock -o /tmp/fleet-heavy.lock timeout 900 uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py settings_view settings_rows_show_answers settings_bound_controls settings_by_hash` ·
`KLEPSYDRA_STAGE=klepsydra-build-settings flock -o /tmp/fleet-heavy.lock timeout 2400 bash scripts/build-windows.sh --check` · `cargo test -p klepsydra-fleet` (in src-tauri).
