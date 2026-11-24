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
- Done at c8e4238 (main merged in; doctor.sh header conflict kept both lines): CI green
  (hooks 655, launcher 289, fleet 1071, status line 146, wrap-up 98, browser 33); local
  hooks 657, status line 142, wrap-up 98, fleet 1071, launcher 288/1 (#290 flake, klepsydra#134).
- Independent Opus review of 3e5aa12..1b7b4bb: 0 Blocking; its Should-fix (a host named
  unknown pruned the unusable hosts' folders) and nits fixed in bedbfb0.
- Mutants at bedbfb0: 22 run, 22 killed. Not run: F2, F3 (doctor trace age), F4, F5
  (uptime wait), stopped by WSL memory pressure; each is listed in the PR body's
  mutation table with its exact edit, to rerun on a quiet machine.
- Next: Heph's r3; after merge update the main checkout before `fleet install`.
- Verify: `bash hooks/test_fleet.sh`, `bash statusline/test_statusline.sh`, `bash hooks/test_wrapup.sh`,
  `make test-launch`, `make test-fleet`; shellcheck per file (fleet/test_fleet.sh OOMs locally, #503).
