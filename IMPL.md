# IMPL: #517 launch lock before /run/user exists (PR #518, review r1 fixes)

## Task
PR #518 review r1 (~/.local/state/fleet-orchestrator/reports/launch-518-r1.md) was NOT CLEAN:
B1-B3, S1-S4, N1-N5. Design (Heph, option b): the launch lock, tab-pending stamp, pane
locks, the fleet hook's write and ask locks and the statusline's prune lock and stamp
live in one folder that always exists and is ours; only `fleet recover` waits for
XDG_RUNTIME_DIR, bounded, with one log line.

## Shape
- `lock_dir` (hooks/klepsydra-fleet.sh, hooks/klepsydra-launch.sh,
  statusline/klepsydra-statusline.sh, identical block, test-checked): sets LOCK_DIR to
  `~/.local/state/klepsydra/run-<boot id>` (KLEPSYDRA_STATE, KLEPSYDRA_BOOT_ID seams),
  mkdir -m 700, -O and ! -L on it and its parent; a known boot's new folder prunes the
  earlier uuid-named ones. No wait, no output, no lib.sh, no XDG_RUNTIME_DIR.
- `wait_runtime_dir` (fleet/lib.sh), called by recover.sh under its lock: waits only
  while the folder is missing; foreign/symlink warned at once; FLEET_RUNTIME_WAIT validated.
- No systemctl --wait (no timeout of its own).

## State
- Done: code, tests in all four suites, README line.
- Next: full suites under the heavy lock, latency table (scratchpad lat.sh: main 72.3/15.4 ms,
  05ff079 107.3/50.0 ms hook/statusline), mutation checks, PR body, push
  HEAD:fix/launch-lock-runtime-dir-517, `fleet done`.
- Verify: `bash hooks/test_fleet.sh`, `bash statusline/test_statusline.sh`, `make test-launch`,
  `make test-fleet`, `make shellcheck`.
