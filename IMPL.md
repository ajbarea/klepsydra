# IMPL: klepsydra#384 PR 1 (#493): settings page, design A, round 2

Branch `feat/settings-page-384`, worktree `.claude/worktrees/settings-r2`.
Push only with `git push origin feat/settings-page-384:feat/settings-page-384`. Never to main.
Round-1 review: `~/.local/state/fleet-orchestrator/reports/settings-493-r1.md` (NOT CLEAN; agy built PR 1).

## Slice
Make PR 1 merge-ready: every round-1 Blocking, Should-fix and Nit fixed, with guards
so the classes cannot return. Opus worker (settings-r2) took it over from agy.

## Done
- Tray Settings... opens `wall.html#settings` on a new wall, sets the hash on an open one (fleet.rs `show_wall`); the hash is the only switch (wall.js `showView`), Back clears it.
- Rows show what the command returned (settings.js `apply`/`viewOf`, registry `view`): autostart {on, held, label}, ping and phone read back, Voices reads keryx live (voices.rs `get_voices_mode`, bounded Reader), pickers return both paths (async, `blocking_pick_file` in spawn_blocking).
- Split, density, Characters and New session's default are bound rows: the page calls the wall's own function (`split.set`, `pickDensity`, `chooseTheme`, `setDefault`) and each control syncs the page.
- New session lists the + New session entries by real id; an unknown saved id still shows.
- Ping and Split rows hide where the app refuses them (off Windows); autostart label comes from the app.
- Tray code deleted (choice.rs, theme/voices menus, all `#[allow(dead_code)]` keep-alives); theme published at start (the deleted `theme::menu` used to do it).
- settings.css on wall.css tokens; focus ring scoped; reduced motion; Ledger/Queue tabs hidden behind the page; APG radio groups.
- Guards: `src/css-tokens.test.js` (every var() defined per page), `src/settings.test.js` (answers not asks, commands registered, one code path per bound row, Voices labels = Rust table, tray hash). 12/12 mutants caught (node).
- README Settings section; tray references updated in README and docs/fleet.md.

## Next
- Browser cases (`settings_view settings_rows_show_answers settings_bound_controls settings_by_hash`, both schemes, 1920 + 390) and `scripts/build-windows.sh --check` (KLEPSYDRA_STAGE=klepsydra-build-settings): queued on the heavy lock.
- Mutation-check a browser case (page shows the ask) once it passes.
- Independent Opus review round 2: report at the session scratchpad `review-r2.md`; fix, re-review until clean.
- Shots to fleet-briefing/shots/2026-11-19, PR body (short top), push, CI green, `fleet send` Athena, `fleet done`.

## Verify
`node --test src/*.test.js` · `npm run -s lint` · `uvx ruff check scripts/test_wall_browser.py` ·
`flock -o /tmp/fleet-heavy.lock timeout 900 uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py settings_view settings_rows_show_answers settings_bound_controls settings_by_hash` ·
`KLEPSYDRA_STAGE=klepsydra-build-settings flock -o /tmp/fleet-heavy.lock timeout 2400 bash scripts/build-windows.sh --check` · `cargo test -p klepsydra-fleet` (in src-tauri).
