# IMPL: #517 launch lock before /run/user exists (PR #518, review r2, r3 & r4 fixes)

## Task
PR #518 review r3 & r4 (PR #551 into `fix/launch-lock-runtime-dir-517`):
S1 (vacuous guard on trace-age in doctor / test), N1-N3, plus r4 fixes (in-place `lock_trace`, single Linux `tab-pending` path, docs & PR #518 body, O1 & F6 tests).
Design from r1/r2 stands: one lock folder per host and boot under ~/.local/state/klepsydra.

## Shape
- `lock_dir` + `lock_why` (identical block in hooks/klepsydra-fleet.sh, hooks/klepsydra-launch.sh,
  statusline/klepsydra-statusline.sh, test-checked): LOCK_DIR = `run-<host>-<boot>` (seams
  KLEPSYDRA_STATE, KLEPSYDRA_BOOT_ID, KLEPSYDRA_HOSTNAME); on refusal LOCK_WHY names the
  reason (symlink, missing, not a folder, another user's, not writable / read-only, group or
  other writable, mkdir's own error text). Prune touches only this host's `run-<host>-<uuid>`
  while hostnames differ (an unusable hostname locks in `run-_-<boot>` and prunes nothing).
- Hook: `lock_trace` writes `<epoch> <why>` in-place (`{ printf ...; } 2>/dev/null >"$file"`) to
  `$KLEPSYDRA_DIR/lock-refused` only when `own_data_dir` (`dev.ajsoftworks.klepsydra`) holds and
  the target is a regular file or absent (never a symlink or FIFO), at most every 600 s, builtins
  only; also when the lock file will not open.
- Launcher: the message carries LOCK_WHY; jump says the window changed and no tab opened.
- `fleet doctor` "lock folder": runs the installed hook's block (else the checkout's): FAIL with
  the reason, warn on a trace from this boot in the last hour (`t >= btime && t <= now`), else
  ok with the folder.
- recover's wait: deadline on /proc/uptime (FLEET_UPTIME seam); tick count if unreadable.

## State
- r3/r4 (agy, #551) merged into this branch; r5 review clean (all r4 findings mutation-checked).
- main merged in (conflicts in launch.sh, test_launch.sh, IMPL.md came from #551's squash dropping its main-merge parent; branch side kept).
- PR body rewritten from the final state (status, mutation table F2-F7, O1, T1).
- Next: CI green on the merged head, whole-PR review against main (review-batch3), merge, `fleet install`.
- Last step before merge: reread the #518 body against the final diff.
