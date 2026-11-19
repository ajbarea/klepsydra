# IMPL: klepsydra#471 test_slice start barrier for capped slice OOM race

Issue: https://github.com/ajbarea/klepsydra/issues/471
PR: https://github.com/ajbarea/klepsydra/pull/474

## Slice
1. In `fleet/test_slice.sh`, synchronize stand-ins and children with start barriers (`$work/ready$i`, `$work/ready$(( 3 - i ))`, `$work/ready$i.child`, and `$work/ready$(( 3 - i )).child`). Both stand-ins allocate 110 MiB, signal ready, and wait for peer before launching `hungry.py`. Both hungry children set rank 1000 and wait for peer before allocating memory, preventing the start-up race where one scope exceeded the 300 MiB slice cap before the peer spawned its rank-1000 child.
2. Drop wrapper-rank change and `SLICE_WRAPPER_RANK` knob (wrapper, systemd-run, floor, and stand-in share one PID through exec, and `fleet_oom_floor` at `lib.sh:705` resets `oom_score_adj` to 0 before stand-in starts). Keep wrapper at standard 1000 matching tmux caller.
3. In `fleet/test_slice.sh`, update skip handling so `SLICE_LIVE=0` prints `live runs: skipped` instead of `N/N passed`.
4. In `.github/workflows/ci.yml`, pass `slice_live_repeat` through `env:`, sanitize with `^[1-9][0-9]*$` regex check, and fail if invalid (preventing script injection). Drop `slice_wrapper_rank`.
5. Run 50-repeat BEFORE soak on CI and 50-repeat AFTER soak on branch, updating PR #474 description with counts.

## Done
- Rebased branch on `origin/main` (commit `2507029`).
- Diagnosed root cause: floor resets OOM score to 0; race occurred because stand-in 1 launched child which allocated up to the slice cap while stand-in 2 was starting, causing OOM kill on stand-in 2 at rank 0 before it could spawn its rank-1000 child.
- Added start barrier to `standin.py` and `hungry.py` in `fleet/test_slice.sh`: stand-ins sync before spawning children, and children sync via `sys.argv` ready files before either allocates beyond baseline memory.
- Removed explicit `echo 1000` from child invocation in `standin.py`, preserving `BASH_ENV=oom-tool.sh` test coverage: mutation test `FLEET_OOM_TOOL=/nonexistent SLICE_LIVE_ONLY=1 make test-slice` fails (0/1 passed, 3 fail) while normal run passes (1/1 passed, 0 fail).
- Added in-script validation for `SLICE_LIVE_REPEAT` in `test_slice.sh` (rejects 0 or non-numeric with exit 2).
- Cleaned `$work/ready*` in iteration teardown.
- Restored wrapper invocation `bash -c "echo 1000 >/proc/self/oom_score_adj; exec $cmd"`.
- Fixed skip reporting: `live()` returns 2 on skip; outer loop reports `live runs: skipped`.
- Sanitized `ci.yml` `workflow_dispatch` input via `INPUT_REPEAT` env var with regex validation `^[1-9][0-9]*$`.
- Completed 50-repeat AFTER soak on CI run 44483716058: 50/50 passed. Note that soak testing cannot tell fixed from unfixed code since soak passes both before and after (flake rate on CI was ~2 in 4 runs on 11-18 under specific runner conditions); the fix rests on the barrier's logic.
- Verified local live runs with barrier: 5/5 passed (`pass=50 fail=0`), full suite passed (`pass=59 fail=0`).
- Verified `SLICE_LIVE=0` output: prints `live runs: skipped`.

## Next
- Commit barrier fix, CI sanitization, skip fix, SLICE_LIVE_REPEAT validation, and updated IMPL.md with hooks on.
- Push branch `fix/slice-oom-wrapper-471` to origin (`--force-with-lease`).
- Monitor PR #474 CI pipeline on head commit until green.
- Update PR #474 body with mutation results, soak clarification, and barrier logic.
- Write report to `~/.local/state/fleet-orchestrator/reports/slice-471.md` and notify orchestrator via `fleet send`.

## Verify
- `env -u BASH_ENV SLICE_LIVE=0 bash fleet/test_slice.sh`: prints `live runs: skipped`.
- `env -u BASH_ENV SLICE_LIVE_REPEAT=3 SLICE_LIVE_ONLY=1 bash fleet/test_slice.sh`: 3/3 passed.
- `env -u BASH_ENV make test-slice`: 59/59 passed.
- `grep -c "make test-slice .*FLEET_HEAVY_HELD=1" .github/workflows/ci.yml`: exactly 1.
