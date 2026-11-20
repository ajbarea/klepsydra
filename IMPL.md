# IMPL: klepsydra#384 PR 1 (#493): settings page, design A

Branch `feat/settings-page-384`, worktree `.claude/worktrees/settings-r2`.
Push only with `git push origin feat/settings-page-384:feat/settings-page-384`. Never to main.
Notes from earlier sessions (reviews r1-r5, browser and Windows logs, shots, PR-body draft):
`~/.local/state/fleet-orchestrator/reports/settings-493-r1.md` and `.../reports/settings-493-r2/`.

## Slice
Make PR 1 merge-ready: every review Blocking, Should-fix and Nit fixed, with guards so the
classes cannot return. Opus worker took it over from agy. Do not merge; Athena reviews and
does the live check in the Windows app.

## State (11-20, 2nd Opus replacement): handed to Athena
- Round-4 fixes landed in acc37c8 (found uncommitted beside a leftover mutant, reverted). Round 5
  (fresh Opus) CLEAN with 2 Nits: guard gaps fixed in fa313c6, PR body rewritten. Verify pass
  CLEAN with 3 Nits, fixed in ceda252 (gated file/block, br/cr raw strings, escaped quote char).
- On ceda252: node 603/603, browser settings cases 59/59 (both schemes, 1920 + 390), cargo fleet
  448 + clippy clean, Windows check clean (115 + 429 + 7), biome, ruff, fmt clean; 15 mutants
  this session all caught (hover; 6 for r4; 8 for the handler guard).
- Shots: fleet-briefing/shots/2026-11-20/klepsydra-384-settings-*. PR body updated.

## Next
1. CI green on the head, then Athena: fresh review + live check in the installed Windows app
   (tray Settings..., file picker, login entry, phone wall port). Do not merge from here.
2. Later PRs of #384: the Gauges row for the background slider is #421 step 3.

## Verify
`node --test src/*.test.js` · `npm run -s lint` · `uvx ruff check scripts/test_wall_browser.py` ·
`flock -o /tmp/fleet-heavy.lock timeout 900 uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py settings_view settings_rows_show_answers settings_bound_controls settings_by_hash` ·
`KLEPSYDRA_STAGE=klepsydra-build-settings flock -o /tmp/fleet-heavy.lock timeout 2400 bash scripts/build-windows.sh --check` · `cargo test -p klepsydra-fleet` (in src-tauri).
Mutation scripts restore in `finally`, which a killed worker never reaches: check `git diff` for a
leftover mutant before committing.
