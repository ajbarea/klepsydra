# IMPL: #517 launch lock before /run/user exists (PR #518, review r2 fixes)

## Task
PR #518 review r2 (~/.local/state/fleet-orchestrator/reports/launch-518-r2.md) was NOT CLEAN:
S1 (a refused lock folder is silent and undiagnosable) and N1-N6. Design from r1 stands:
one lock folder per host and boot under ~/.local/state/klepsydra; only `fleet recover` waits.

## Shape
- `lock_dir` + `lock_why` (identical block in hooks/klepsydra-fleet.sh, hooks/klepsydra-launch.sh,
  statusline/klepsydra-statusline.sh, test-checked): LOCK_DIR = `run-<host>-<boot>` (seams
  KLEPSYDRA_STATE, KLEPSYDRA_BOOT_ID, KLEPSYDRA_HOSTNAME); on refusal LOCK_WHY names the
  reason (symlink, missing, not a folder, another user's, not writable / read-only, group or
  other writable, mkdir's own error text). Prune touches only this host's `run-<host>-<uuid>`.
- Hook: `lock_trace` writes `<epoch> <why>` to `$KLEPSYDRA_DIR/lock-refused`, at most every
  600 s, builtins only; also when the lock file will not open.
- Launcher: the message carries LOCK_WHY; jump says the window changed and no tab opened.
- `fleet doctor` "lock folder": runs the installed hook's block (else the checkout's): FAIL with
  the reason, warn on a trace from this boot in the last hour, else ok with the folder.
- recover's wait: deadline on /proc/uptime (FLEET_UPTIME seam); tick count if unreadable.

## State
- Done: code and tests (hooks 649, statusline 142, wrapup 98, make test-launch 289).
- Next: make test-fleet, mutation run (scratchpad mutate.py, 23 mutants), commit, push,
  PR body, CI, `fleet done`; Heph runs round 3.
- Verify: `bash hooks/test_fleet.sh`, `bash statusline/test_statusline.sh`, `bash hooks/test_wrapup.sh`,
  `make test-launch`, `make test-fleet`; shellcheck per file (fleet/test_fleet.sh OOMs locally, #503).
