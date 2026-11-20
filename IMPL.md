# IMPL: klepsydra#384 PR 1 (#493): settings page, design A

Branch `feat/settings-page-384`, worktree `.claude/worktrees/settings-r2`.
Push only with `git push origin feat/settings-page-384:feat/settings-page-384`. Never to main.
Notes from earlier sessions (reviews r1-r3, browser and Windows logs, shots, PR-body draft):
`~/.local/state/fleet-orchestrator/reports/settings-493-r1.md` and `.../reports/settings-493-r2/`.

## Slice
Make PR 1 merge-ready: every review Blocking, Should-fix and Nit fixed, with guards so the
classes cannot return. Opus worker took it over from agy. Do not merge; Athena reviews and
does the live check in the Windows app.

## State (11-20, Opus replacement worker)
- Merged origin/main (#487 gauge opacity) into the branch: the slider stays in the gear; a Settings
  "Gauges" row for it is #421 step 3, not this PR. Conflicts were mechanical (main.rs, wall.js,
  wall.html, browser stub).
- r3 Nits all landed in 3032584 except the Ledger losing its session filter across the page:
  fixed (`onShut(forGood)`), browser case in `settings_by_hash`, mutation-checked.
- Node 602/602, cargo fleet 447 pass, lint clean after the merge.

## Next
1. Hover mutant: `flock -o /tmp/fleet-heavy.lock timeout 1200 python3 ~/.local/state/fleet-orchestrator/reports/settings-493-r2/mutate_heavy.py "$PWD"` (must print `caught`).
2. Settings browser cases (both schemes, 1920 + 390) and `build-windows.sh --check` on HEAD.
3. Opus review round 4 (fresh reviewer); fix until clean.
4. Shots (fleet-briefing/shots/2026-11-20) + PR body from `settings-493-r2/pr-body.md`; CI green;
   `fleet send` Athena; `fleet done`.

## Verify
`node --test src/*.test.js` · `npm run -s lint` · `uvx ruff check scripts/test_wall_browser.py` ·
`flock -o /tmp/fleet-heavy.lock timeout 900 uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py settings_view settings_rows_show_answers settings_bound_controls settings_by_hash` ·
`KLEPSYDRA_STAGE=klepsydra-build-settings flock -o /tmp/fleet-heavy.lock timeout 2400 bash scripts/build-windows.sh --check` · `cargo test -p klepsydra-fleet` (in src-tauri).
