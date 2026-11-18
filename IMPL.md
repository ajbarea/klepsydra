# IMPL: klepsydra#453 watcher wakes the orchestrator while a worker waits on its own background shell

Brief: https://github.com/ajbarea/klepsydra/issues/453

## Slice
1. In `fleet/watch-panes.sh`, replace the fragile screen-text grep for "still running" with `turn_settled "$p"` from `fleet/lib.sh`, which reads the session JSON's `.background` entries.
2. Add two tests to `fleet/test_fleet.sh`: an idle pane with a running background shell (no wake), and the same pane after the shell ends (wakes after IDLE_S).

## Done
- Replaced screen-text grep (`'still running|Waiting for [0-9]+ background'`) with `turn_settled "$p"` on line 104 of `watch-panes.sh`. DRY: reuses the existing function that checks `.background | length > 0` in the session JSON.
- Added two test cases after the #246 watcher section in `test_fleet.sh`: one verifying the watcher stays watching while a background shell runs, one verifying it wakes once the shell ends.

## Next
- Run `make test-fleet` and `make shellcheck` to confirm.
- Commit, push, open PR.

## Verify
- `make test-fleet` passes (including the new #453 checks).
- `make shellcheck` clean.
