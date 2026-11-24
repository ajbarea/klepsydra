# IMPL: #517 launch lock before /run/user exists (PR #518, review r1 fixes)

## Task
PR #518 review r1 (~/.local/state/fleet-orchestrator/reports/launch-518-r1.md) was NOT CLEAN:
B1-B3, S1-S4, N1-N5. Design (Heph, option b): the launch lock, tab-pending stamp, pane
locks, the fleet hook's write and ask locks and the statusline's prune lock and stamp
live in one folder that always exists and is ours; only `fleet recover` waits.

## Shape
- `lock_dir` (hooks/klepsydra-fleet.sh, hooks/klepsydra-launch.sh,
  statusline/klepsydra-statusline.sh, identical block, test-checked): LOCK_DIR =
  `~/.local/state/klepsydra/run-<boot id>` (KLEPSYDRA_STATE, KLEPSYDRA_BOOT_ID seams);
  mkdir -m 700; -O and ! -L on it and its parent; parent writable by no one else (checked
  once a boot); a known boot's new folder removes run-<uuid> folders last changed before
  btime. No wait, no output, no lib.sh, no XDG_RUNTIME_DIR.
- `wait_runtime_dir` (fleet/lib.sh), only from recover.sh under its lock: waits while the
  folder is missing or, where systemd booted, its systemd/private socket is; foreign or
  symlink warned at once; FLEET_RUNTIME_WAIT validated. No systemctl --wait (no timeout).

## State
- Done: code; tests in all four suites; own Opus review (0 Blocking, 3 Should-fix, 6 Nit),
  its Should-fix 1-2 and Nits 1, 2, 4, 5 (lock wait), 6 (jump message) fixed in e0c3ccd.
- Open by choice: no doctor check for an unusable lock folder (Nit 5); old design spec
  keeps its historical XDG_RUNTIME_DIR text.
- Done at 40e38b9: CI green; 30 mutants, 25 killed, 5 survivors by design (PR body);
  make test-fleet 1007/0; latency table in the PR body.
- Next: Heph's r2 review and merge; after merge, update the main checkout before
  `fleet install`.
- Verify: `bash hooks/test_fleet.sh`, `bash statusline/test_statusline.sh`, `make test-launch`,
  `make test-fleet`; shellcheck per file (whole-tree `make shellcheck` OOMs, klepsydra#503).
