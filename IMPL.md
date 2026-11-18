# IMPL: klepsydra#453 watcher wakes the orchestrator while a worker waits on its own background shell

Brief: https://github.com/ajbarea/klepsydra/issues/453

## Slice
1. In `fleet/lib.sh`, add `pane_background` helper mirroring `view.rs`: ignore entries older than `BACKGROUND_STALE_AFTER` (3600s), cap shells by `shells_live`. With no file, two files for the pane, or no `.background` key, fail so caller falls back to screen grep.
2. In `fleet/watch-panes.sh`, place the done-line check before scanning session files on `/mnt/c`, and keep the screen grep OR'd with `pane_background`.
3. Make watcher wakes diagnosable: on wake, log reason, pane, and last 3 non-empty screen lines (joined by `~`).
4. Add tests covering all 5 cells in `fleet/test_fleet.sh`: (A) stale 2-hour entry with `shells_live: 0` wakes; (B) two live files falls back to grep; (C) no file falls back to grep; (D) no `.background` falls back to grep; plus the shell-running case (holds while shell running, wakes after exit). Verify diagnosable wake log.

## Done
- Added `pane_background` in `fleet/lib.sh` without altering `turn_settled`.
- Updated `fleet/watch-panes.sh`: fast done-line check runs before session file lookup; screen grep is kept and OR'd with `pane_background`; on wake, logs reason, pane, and last 3 screen lines.
- Added test cases in `fleet/test_fleet.sh` with footer text in fixtures for all cells (A, B, C, D, and shell-running), each verified to fail under its respective reversion.
- Verified shellcheck clean on `fleet/watch-panes.sh`, `fleet/lib.sh`, `fleet/test_fleet.sh`.

## Next
- Commit and push to `fix/watcher-busy-shell-453`.
- Update PR #457 description to use `Refs #453` and describe the exact changes without guessing root causes.
- Wait for CI green with one background wait.
- Send one-line report to orchestrator pane with `fleet send` and stop.

## Verify
- GitHub Actions CI pipeline passes all checks.
