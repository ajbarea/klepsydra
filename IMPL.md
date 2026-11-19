# IMPL: klepsydra#384 PR 1: Settings page shell with search and existing settings wiring

Branch `feat/settings-page-384` (worktree `.claude/worktrees/settings-384`), cut with `--no-track` from `origin/main` (`958dbb2`).
Push only with an explicit refspec: `git push -u origin feat/settings-page-384:feat/settings-page-384`. Never push to main.
Decision: Issue #384, Brief `~/.local/state/fleet-orchestrator/briefs-free/settings-384-step2.md`.
Design reference: Design A (`docs/mockups/2026-11-18/settings-a.html` on PR #459 branch `mock-459`).

## Scope & Constraints (PR 1)
- Settings page view following Design A inside wall window (`#settings.settings-view`):
  - Header with Back button, title, and search input (`/` to focus, `Esc` to clear search or return).
  - Sticky section navigation.
  - Rows are data, not markup: defined in `src/settings/registry.js` with `{ id, section, label, description, control, read, write }`.
  - Instant apply (no Save button).
  - Dark and light color schemes; responsive at 1920 and 390 viewport widths; full ARIA markup.
- Wire exactly the 13 settings that exist on `main` today:
  1. Start with Windows (Autostart toggle)
  2. Compact layout (Segmented / toggle: Compact vs Full)
  3. Ping chime (Toggle)
  4. Phone wall (Toggle)
  5. Character set (Theme select: Kourai / Professions / Dicebear)
  6. Voices mode (Segmented: Off / Orchestrator only / Everyone)
  7. Choose queue file (Button / path display)
  8. Choose Needs you file (Button / path display)
  9. Reset position (Button)
  10. Set home here (Button)
  11. Split with terminal (Toggle)
  12. Card density (Segmented: Auto / Comfortable / Compact)
  13. New session default (Select: Last used / Claude / agy / Copilot)
- Tray menu keeps ONLY 3 items:
  - `Open wall`
  - `Settings...`
  - `Quit`
- Banned files: DO NOT touch `src/style.css`, `src/main.js`, `src/gauge.js`, or `src/gaugeview.js`.

## Done (PR 1)
- Step 1: Research, inventory of existing settings, and Design A plan completed and approved by Athena.
- Step 2:
  - `src/settings/registry.js`: Data-driven registry with `SECTIONS`, `ROWS` (13 wired items), and `filterRows(rows, query)`.
  - `src/fleet/settings.css`: Design A styles with sticky section nav, responsive layouts (1920 & 390px), dark/light theme support, accessibility indicators.
  - `src/fleet/settings.js`: Controller mounting the view, instant apply on inputs, live search filtering (`/` focus, `Esc` clear), bidirectional sync with wall state.
  - `src/wall.html`: Added `#settings` container and `Settings…` button in gear dropdown.
  - `src/fleet/wall.js`: Wired view switching (`openSettings`/`closeSettings`), hash `#settings`, IPC `open-settings` event, two-way sync for density and character theme.
  - `src-tauri/src/main.rs`: Slimmed tray menu down to exactly 3 items (`open_wall`, `settings`, `quit`), added Rust test `tray_menu_has_exactly_three_items`, exposed required commands.
  - `src-tauri/src/fleet.rs`, `src-tauri/src/voices.rs`, `src-tauri/src/theme.rs`: Exposed Tauri commands for reading/writing prefs.
  - `src-tauri/fleet/src/phone.rs`: Updated asset serving to include `settings/` modules.
  - `src/settings.test.js`: Added unit tests for schema, filtering, read/write wiring, and mutation verification.
  - `scripts/test_wall_browser.py`: Added browser test capturing 4 screenshots at 1920 and 390 in dark and light modes.
- Verified:
  - `node --test src/*.test.js`: 574 passed, 0 failed.
  - `npm run lint`: Biome checked 75 files, 0 errors.
  - `uvx ruff check`: 0 errors.
  - `cargo fmt --all --check` & `cargo clippy -p klepsydra-fleet -- -D warnings`: clean.
  - `cargo test -p klepsydra-fleet`: 442 passed, 0 failed.
  - `test_wall_browser.py settings_view`: 16 passed, 0 failed.
  - `bash statusline/test_statusline.sh`: passed.
  - `bash hooks/test_fleet.sh`: 606 passed, 0 failed.
  - `bash scripts/test_measure_memory.sh`: 28 passed, 0 failed.
  - `bash scripts/test_build_windows.sh`: 14 passed, 0 failed.
  - `make test-headless`: 125 passed, 0 failed.
  - `make test-engine`: passed.

## Next
1. Commit changes with title `feat(wall): settings page with search, tray keeps Open, Settings, Quit (#384)`.
2. Push with explicit refspec: `git push -u origin feat/settings-page-384:feat/settings-page-384`.
3. Open PR with `gh pr create` (label `enhancement`, assignee `ajbarea`, short top, live vs tested declaration).
4. Watch CI until green (`gh pr checks <pr> --watch --interval 60`).
5. Write report to `~/.local/state/fleet-orchestrator/reports/settings-384.md` and notify Athena (`fleet send`).
