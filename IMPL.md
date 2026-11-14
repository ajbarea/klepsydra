# IMPL: harden `fleet headless` (#260, the 11-13 failures), branch headless-headless-guards

Resume from this file, `git log`, the PR and the comments on #260.

## Slice
Three failures of 11-13 (comments on #260): a job's turn ended on a background wait; a call moved to the background at the 10-minute tool limit; a `sleep` a job wrapped the heavy lock around outlived it. Guards: `fleet/headless-rules.md` put before every brief; `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` and a 16-minute tool timeout in the job's env; a resume loop until `FINAL REPORT:` (FLEET_HEADLESS_RESUMES, 4, within the budget), then `stalled`; a reaper after every run (the job's own scope, matched by the unit name in job.json; every process with the job's variables; claude's session; only processes newer than the runner); `fleet doctor` names the heavy lock's holders and warns on a bare sleep or a holder whose job ended. Docs: `docs/headless.md`, "Seeing a job to its end".

## Done
- Code, tests in `fleet/test_headless.sh` (116 checks), docs, README rows; `hooks/test_launch.sh` no longer inherits a headless job's keyed `CLAUDE_CONFIG_DIR`; `fleet/test_fleet.sh`'s doctor uses a private heavy lock.
- Mutation check by hand: 29 guards, 29 caught (the unit-name guard run inside a throwaway scope, since its mutation kills the caller's cgroup).
- One independent Opus review: 0 Blocking, 5 Should-fix, all fixed (reaper misses Bash's own sessions without a scope; waiting check too broad; zeroed crash cost; claude < 2.1.277; Monitor not enforced), and the nits that change behavior.
- Suites: test-headless 116/116, test-launch 241/241, test-heavy-lock 30/30, shellcheck clean, node 475/475, statusline, hooks/test_fleet, measure_memory, build_windows, Biome, ruff green. test-fleet: 377 checks, 0 failed, then cut at the 8-minute rule.

## Next
1. Run test-fleet in full, test-delegate, test-slice and the cargo checks outside a headless job (they were not run, or not to the end, here).
2. Heph verifies and merges. No `make install-fleet` needed: headless.sh reads headless-rules.md beside itself in the checkout.
