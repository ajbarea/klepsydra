# IMPL: #517 launch lock before /run/user exists (PR #518, review r2 & r3 fixes)

## Task
PR #518 review r3 (~/.local/state/fleet-orchestrator/reports/launch-518-r3.md):
S1 (vacuous guard on trace-age in doctor / test), N1-N3.
Design from r1/r2 stands: one lock folder per host and boot under ~/.local/state/klepsydra.

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
- Merged origin/main cleanly.
- Implementing r3: S1 (doctor boot seam), N1 (atomic trace write & own_data_dir), N2 (wording), N3 (pruning & docs).
- Next: run suites, mutants F2/F3, push agy/518-r3, open PR into fix/launch-lock-runtime-dir-517.
