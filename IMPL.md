# IMPL: klepsydra#453 watcher wakes the orchestrator while a worker waits on its own background shell

Brief: https://github.com/ajbarea/klepsydra/issues/453

## Slice
1. Define `BACKGROUND_STALE_AFTER=3600` and `BACKGROUND_AHEAD=60` in `fleet/lib.sh` and add drift tests reading both values from `src-tauri/fleet/src/view.rs` and `fleet/lib.sh`.
2. Update `pane_background` in `fleet/lib.sh` to strictly mirror `view.rs`: drop entries without `at`, count crew only when state is `working` or `needs_you`, ignore unknown kinds, drop individual malformed entries without failing the check, and cap shells by `shells_live`.
3. In `fleet/watch-panes.sh`, record the lines that decided the wake (the done line and any still running line on idle, or the limit line on limit) in the wake log.
4. In `fleet/test_fleet.sh`, update fixtures to carry `at`, split Cell A into fresh-entry-with-cap-0 and 3602s-stale-entry, and verify divergence probes (no-at, state error, malformed entry, hostile screen text).
5. Update PR #457 description and status line, submit self-review on PR, wait for CI green, report via `fleet send`.

## Done
- Defined `BACKGROUND_STALE_AFTER` and `BACKGROUND_AHEAD` in `fleet/lib.sh` and added drift tests matching `view.rs`.
- Updated `pane_background` in `fleet/lib.sh` to mirror `view.rs` lenient parsing and state gating.
- Updated `fleet/watch-panes.sh` to log the deciding lines on wake (`screen="$decided"`).
- Updated `fleet/test_fleet.sh` with split cells A1/A2, divergence probes, and hostile screen text safety checks. All 16 tests pass.
- Verified shellcheck clean across `fleet/watch-panes.sh`, `fleet/lib.sh`, `fleet/test_fleet.sh`.

## Next
- Commit changes and push to `fix/watcher-busy-shell-453`.
- Update PR #457 description and status line, and record self-review comment on PR #457.
- Wait for GitHub Actions CI run to complete cleanly with one bounded wait.
- Send one-line report to orchestrator pane with `fleet send` and stop.

## Verify
- Local test harness passes 16/16 tests.
- Shellcheck passes with code 0.
- GitHub Actions CI pipeline passes all checks.
