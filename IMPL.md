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
  - Added `runtime_dir` helper to `hooks/klepsydra-launch.sh`, `hooks/klepsydra-fleet.sh`, and `statusline/klepsydra-statusline.sh`.
  - Routed `LOCK`, `PENDING`, and pane locks in `klepsydra-launch.sh`, `klepsydra-fleet.sh`, and `klepsydra-statusline.sh` through `RUN_DIR=$(runtime_dir)`.
  - Added configurable `KLEPSYDRA_LOCK_WAIT` in `take_lock()`.
  - Added 10 regression tests in `hooks/test_launch.sh` covering fallback to `/tmp` on missing or group-writable `XDG_RUNTIME_DIR`, contention on held fallback lock, avoidance of contention when existing dir is used, and cold tab pending stamp in `/tmp`.
  - Added regression tests in `hooks/test_fleet.sh` and `statusline/test_statusline.sh` for missing runtime dir.
  - Verified mutation check: flipping existence test `-d` went RED.
  - Verified live launcher execution with `XDG_RUNTIME_DIR=/nonexistent` takes lock in `/tmp`.
  - Full suite verified: Biome lint, ruff, cargo fmt, clippy, cargo test, node --test, test_statusline, test_fleet, test_launch, test_engine, test_headless, shellcheck.
- Next: commit on branch, push, open PR with label bug, assignee ajbarea, short top, depth in details, Closes #517.
