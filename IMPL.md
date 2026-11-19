# IMPL: klepsydra#440 + New session: split button, engine menu, and sensible default (Variant A)

Brief: ~/.local/state/fleet-orchestrator/briefs-free/newsession-440.md
Issue: https://github.com/ajbarea/klepsydra/issues/440
Decision: Variant A (split button and menu) from PR #459

## Slice
1. Create `src/fleet/newsession.js` implementing engine metadata, default engine resolution (user preference -> last used -> first installed/signed in), menu model grouping, quota calculations from existing gauge readings, and free-first route marks.
2. Add unit tests in `src/fleet-newsession.test.js` covering default engine determination, menu contents, default engine omission from menu, and disabled states for missing/unsigned engines.
3. Integrate split button and engine menu in `src/wall.html`, `src/fleet/wall.js`, and `src/fleet/wall.css`:
   - Split button naming default engine with logo, account mono badge, and accessible title.
   - Caret popover toggle with chevron icon, keyboard reachable without opening on focus.
   - Engine menu rendered with other engines, quota room, model picker for Antigravity, recommended badge, and "Set as default".
   - Start session wired to default engine and individual menu engines.
4. Update `scripts/test_wall_browser.py` with browser test covering 1920 and 390 viewports in dark and light themes, verifying button labels, engine menu contents, and saving comparison screenshots to `shots/2026-11-18/new-session-build-*.png`.
5. Run full test suite, lint, commit, push branch, open PR, and report to orchestrator.

## Done
- Created `src/fleet/newsession.js` implementing engine resolution (preferred -> last used -> first installed/signed in), menu entry construction, Antigravity model grouping, account quota room calculations, free-first recommendation marks.
- Created `src/fleet-newsession.test.js` with 13 unit tests covering all resolution rules, menu engine listing, default exclusion, disabled states.
- Implemented Variant A split button and engine menu in `src/wall.html`, `src/fleet/wall.js`, and `src/fleet/wall.css`:
  - Split button naming default engine with logo, account mono badge, and accessible title.
  - Caret button with chevron icon toggling native popover engine menu.
  - `#new-menu` rendered with other engines, quota room, Antigravity models (grouped into Gemini usable vs Claude/GPT spent), Recommended badge, "Start session" with chosen model, and "Set as default".
  - Popover positioning fixed for desktop (`1920x1000`) and mobile (`390x844`), with viewport boundary overrides for popover UA styles.
- Updated browser tests in `scripts/test_wall_browser.py` (`agy_menu`):
  - Verified 1920 and 390 viewports in dark and light schemes (28 passed, 0 failed).
  - Saved comparison shots to `shots/2026-11-18/new-session-build-*.png` and `/mnt/c/Users/ajbar/fleet-briefing/shots/2026-11-18/`.
- Verified all test suites pass:
  - `node --test src/*.test.js`: 527 passed, 0 failed.
  - `npm run lint`: Biome checked 67 files, 0 errors.
  - `uvx ruff check`: clean.
  - Shell suites: `statusline/test_statusline.sh`, `hooks/test_fleet.sh` (606 passed), `scripts/test_measure_memory.sh` (28 passed), `scripts/test_build_windows.sh` (14 passed).
  - Rust suites: `cargo clippy -p klepsydra-fleet -- -D warnings` (clean), `cargo test -p klepsydra-fleet` (434 passed).

## Next
- Commit and push to `feat/new-session-split-440`.
- Open PR for #440 with labels, assignee, short top, screenshots, and live verification notes.
- Report to Heph (orchestrator pane) via `fleet send`.

## Verify
- `node --test src/*.test.js`: 527/527 passed.
- `scripts/test_wall_browser.py agy_menu`: 28/28 passed across 1920 and 390 dark and light viewports.
- Biome lint & ruff check: 0 errors.
- `cargo clippy` & `cargo test -p klepsydra-fleet`: 434/434 passed, clean.
