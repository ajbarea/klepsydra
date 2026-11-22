# IMPL: #517 launch lock before /run/user exists (agy, Gemini; stop at a PR)

## Task
Fix https://github.com/ajbarea/klepsydra/issues/517 (read it and its comment first).
Root cause: `hooks/klepsydra-launch.sh:54` and `:57` build paths from `${XDG_RUNTIME_DIR:-/tmp}`.
WSL sets XDG_RUNTIME_DIR=/run/user/1001 at login, but systemd-logind created that folder only
~6 min after boot, so `flock` on the lock path failed and `fleet recover` lost the worker.

## Fix shape
- One helper picks the runtime folder: XDG_RUNTIME_DIR only when it is an existing directory
  owned by this user and not group/world-writable; else the existing /tmp fallback, keeping the
  planted-file / FIFO protection described near line 92. Use it for LOCK and PENDING (DRY).
- Grep the whole repo for other `XDG_RUNTIME_DIR` uses (fleet/, hooks/, src/) and route them
  through the same rule if they have the same failure.
- Regression test in the existing hook/fleet test suite: XDG_RUNTIME_DIR set to a missing dir
  -> launch takes the lock in the fallback; existing dir -> uses it. Mutation-check: flip the
  existence test and confirm the test goes red, then restore.

## State
- Slice: runtime directory fallback when XDG_RUNTIME_DIR is nonexistent, missing, or group/world-writable.
- Done:
  - Added canonical `runtime_dir` helper in `fleet/lib.sh` with polling loop and timeout fallback (`FLEET_RUNTIME_WAIT:-180`).
  - `runtime_dir` polls until `$XDG_RUNTIME_DIR` exists and is owned by the user, or systemd user manager finishes startup (`systemctl --user is-system-running --wait`).
  - Sourced `fleet/lib.sh` in `hooks/klepsydra-launch.sh`, `hooks/klepsydra-fleet.sh`, and `statusline/klepsydra-statusline.sh` instead of duplicating helper.
  - Wired `runtime_dir >/dev/null` at startup of `fleet/recover.sh` before taking `.recover.lock`.
  - Added unit tests in `fleet/test_fleet.sh` testing immediate return on existing dir, zero-wait fallback, delayed creation success, and timeout warning fallback.
  - Fixed timing retry in `hooks/test_launch.sh` for dead pane viewer cleanup.
- Next: run test suite, commit, push to branch, update PR #518 with review response comment.
