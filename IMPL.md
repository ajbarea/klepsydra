# IMPL: one memory cap for the whole fleet (#353), branch fix/fleet-slice-353

Resume from this file, `git log`, the PR and its comments. Brief: the k353 task file in the fleet state folder.

## Slice
The kernel, not the heavy lock, keeps one run from taking WSL down. `fleet.slice` caps every fleet scope's total (MemTotal less `FLEET_SLICE_MARGIN_MB`), the orchestrator's included; `fleet-workers.slice` inside it caps the workers at that less the orchestrator's recorded peak of kept memory. Claude runs at OOM rank 0, every shell it starts at 1000 (`fleet/oom-tool.sh` as BASH_ENV), scopes keep `OOMPolicy=continue`, so a cap kills the job, not the agent.

## Done
- lib.sh helpers (sizes, caps, slice options, OOM floor and BASH_ENV, the orchestrator's peak), launch.sh, delegate.sh, install.sh (writes both slice units), doctor.sh (one `systemctl show` for all scopes and slices; FAIL on no cap or a scope outside its slice; warn when the orchestrator outgrows its room), brief tail, docs, `make test-slice`, CI step.
- Measured live: an unprivileged process cannot lower oom_score_adj below 0 (EACCES); scopes reject OOMScoreAdjust=; OOMPolicy=stop stopped the whole scope after one OOM kill; MemoryHigh (slice 80%, or per scope) throttled for 5+ min with no kill, so slices and scopes carry MemoryMax only; a real `claude -p` gives its Bash child rank 1000 under BASH_ENV.
- `fleet/test_slice.sh`: 37 cases, live part 3 s; five mutations each fail it (no --slice, no OOMPolicy=continue, no tool rank, no floor, MemoryHigh back).

## Next
1. Held until the suites end (bash reads a running script as it goes): doctor's astray check only for ActiveState=active scopes (a scope gone between list-units and show), and the brief tail's "never an agent" softened to "first".
2. Suites green, Copilot and agy lanes read and checked, fresh Opus rounds until clean, then a verify read.
3. PR (assignee ajbarea, closes #353), merge on clean + green, `make install-fleet`, `fleet cutover`, then `systemctl --user show fleet.slice fleet-workers.slice -p MemoryMax` and `fleet doctor` on the live fleet. Running agents stay in app.slice until their next fresh start.

## Verify
`make test-slice` (or `SLICE_LIVE=0 bash fleet/test_slice.sh` bare), `make test-fleet`, `make test-launch`, `make test-delegate`, `make shellcheck`.
