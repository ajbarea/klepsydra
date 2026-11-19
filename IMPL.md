# IMPL: klepsydra#453 watcher wakes the orchestrator while a worker waits on its own background shell

Brief: https://github.com/ajbarea/klepsydra/issues/453

## Slice
1. Define `BACKGROUND_STALE_AFTER=3600` and `BACKGROUND_AHEAD=60` in `fleet/lib.sh` and add drift tests reading both values from `src-tauri/fleet/src/view.rs` and `fleet/lib.sh`.
2. Update `pane_background` in `fleet/lib.sh` to strictly mirror `view.rs`: drop entries without `at`, count crew only when state is `working` or `needs_you`, ignore unknown kinds, drop individual malformed entries without failing the check, and cap shells by `shells_live`.
3. Add `pane_background_summary` to `fleet/lib.sh` and update `fleet/watch-panes.sh` to log deciding lines (`done_line~session=$bg_summary`) and session state on idle wake.
4. In `fleet/test_fleet.sh`, bound watcher kills with `kill_watch` (2s SIGTERM poll + SIGKILL fallback) to prevent hangs; add boundary tests for future entry beyond ahead (F61), unknown kind (K_unk), and empty id (ID_empty).
5. Update PR #457 description to "Closes #453" and record self-review, wait for CI green, report via `fleet send`.

## Done
- Defined `BACKGROUND_STALE_AFTER` and `BACKGROUND_AHEAD` in `fleet/lib.sh` and added drift tests matching `view.rs`.
- Updated `pane_background` in `fleet/lib.sh` to mirror `view.rs` lenient parsing and state gating.
- Added `pane_background_summary` in `fleet/lib.sh` and updated `fleet/watch-panes.sh` to log `done_line~session=$bg_summary` on wake.
- Added `kill_watch` bounded kill in `fleet/test_fleet.sh` to prevent lost-TERM hangs under heavy lock.
- Added boundary tests for future `at` (cell F61), unknown kind (cell K_unk), and empty id (cell ID_empty); verified each fails under reversion.
- Verified all 924 tests pass in `fleet/test_fleet.sh`.
- Verified shellcheck clean across `fleet/watch-panes.sh`, `fleet/lib.sh`, `fleet/test_fleet.sh`.

## Next
- Commit changes and push to `fix/watcher-busy-shell-453`.
- Update PR #457 description ("Closes #453") and record self-review comment on PR #457.
- Wait for GitHub Actions CI run to complete cleanly with one bounded wait.
- Send one-line report to orchestrator pane with `fleet send` and stop.

## Verify
- Local test suite passes 924/924 tests.
- Reversions for cells A1, A2, F61, K_unk, ID_empty proven.
- Shellcheck passes with code 0.
- GitHub Actions CI pipeline passes all checks.
