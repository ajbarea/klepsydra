# IMPL: one memory cap for the whole fleet (#353), branch fix/fleet-slice-353

Resume from this file, `git log`, the PR and its comments. Brief: the k353 task file in the fleet state folder.

## Slice
The kernel, not the heavy lock, keeps one run from taking WSL down. `fleet.slice` caps every fleet scope's total (MemTotal less `fleet_slice_margin`: 847 MiB measured WSL base plus earlyoom's line, up to 512), the orchestrator's included; `fleet-workers.slice` inside it caps workers and delegates at that less the orchestrator's 7-day peak (orchestrator.mem, dated lines). Claude runs at OOM rank 0, every bash it starts at 1000 (`fleet/oom-tool.sh` as BASH_ENV), scopes keep `OOMPolicy=continue`. Programs claude starts without bash keep rank 0: #354.

## Done
- lib.sh helpers, launch.sh, delegate.sh, install.sh (both slice units, rewritten only on change), doctor.sh (cap, nesting, sized-for-this-machine, scopes astray: FAIL if started since the slices, warn if before), brief tail, README, `make test-slice`, CI step.
- Measured live: no unprivileged lowering below 0 (EACCES); scopes reject OOMScoreAdjust=; OOMPolicy=stop stops the whole scope; MemoryHigh throttles without killing, so MemoryMax only.
- Copilot + agy lanes read and checked (6 leads fixed, 2 rejected); Opus round 1 (1 Blocking, 6 Should-fix, 6 Nits) fixed in 04a4d38; mutation-checked the live test (5 guards).

## Next
1. Rounds 2 to 4 fixed (round 4: one test-only Should-fix); suites rerun, then a verify read of the round-3 and round-4 fixes.
2. PR (assignee ajbarea, closes #353; body draft in the session scratchpad), merge on clean + green, `make install-fleet` from main, `fleet cutover`, then `systemctl --user show fleet.slice fleet-workers.slice -p MemoryMax,MemoryCurrent` and `fleet doctor`. Running agents stay in app.slice until their next fresh start (doctor warns). Then in a fresh fleet session: the Bash tool's `cat /proc/self/oom_score_adj` prints 1000 and its claude's is 0.

## Verify
`make test-slice`, `make test-fleet`, `make test-launch`, `make test-delegate`, `make shellcheck`. Never run doctor or install from this worktree against the live state.
