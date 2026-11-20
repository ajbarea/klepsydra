# IMPL: klepsydra#384 PR 1 (#493): settings page, design A

Branch `feat/settings-page-384`, worktree `.claude/worktrees/settings-r2`.
Push only with `git push origin feat/settings-page-384:feat/settings-page-384`. Never to main.
Notes from earlier sessions (reviews r1-r5, browser and Windows logs, shots, PR-body draft):
`~/.local/state/fleet-orchestrator/reports/settings-493-r1.md` and `.../reports/settings-493-r2/`.

## Slice
Make PR 1 merge-ready: every review Blocking, Should-fix and Nit fixed, with guards so the
classes cannot return. Opus worker took it over from agy. Do not merge; Athena reviews and
does the live check in the Windows app.

## State (11-20, 2nd Opus replacement)
- Round-4 fixes were uncommitted in the worktree when the last worker stopped, along with the
  hover mutant its killed mutation run had left in settings.css (reverted, not committed).
  The fixes landed in acc37c8: the tray's empty focus keeps the page; leaveSettings keys on the
  page shown; showing the page cancels a portrait, End dialog, session menu or popover;
  Coalesce::serve survives a panicking run; the handler guard catches doc lines and gated mods.
- On acc37c8: node 603/603, browser settings cases 59/59 (both schemes, 1920 + 390), cargo fleet
  448 + clippy clean, biome, ruff check, cargo fmt clean; hover mutant caught.
- Round-4 mutants (scratchpad `mutate_r4.py`, runs on a scratch copy, baseline first), the Windows
  check and the fresh Opus round 5 were running when this was written.

## Next
1. Round 5 findings (`reports/settings-493-r2/review-r5.md`): fix until a round is clean.
2. Shots (fleet-briefing/shots/2026-11-20) + PR body from `settings-493-r2/pr-body.md`; CI green;
   `fleet send` Athena; `fleet done`.

## Verify
`node --test src/*.test.js` · `npm run -s lint` · `uvx ruff check scripts/test_wall_browser.py` ·
`flock -o /tmp/fleet-heavy.lock timeout 900 uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py settings_view settings_rows_show_answers settings_bound_controls settings_by_hash` ·
`KLEPSYDRA_STAGE=klepsydra-build-settings flock -o /tmp/fleet-heavy.lock timeout 2400 bash scripts/build-windows.sh --check` · `cargo test -p klepsydra-fleet` (in src-tauri).
Mutation scripts restore in `finally`, which a killed worker never reaches: check `git diff` for a
leftover mutant before committing.
