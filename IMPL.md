# IMPL: klepsydra#492, perf class (a): one process per batch in the fleet's shell loops

Branch perf/shell-forks (worktree .claude/worktrees/perf-shell-forks), cut `--no-track` from origin/main 958dbb2.
Push only: `git push -u origin perf/shell-forks:perf/shell-forks`. Never push to main.
Role (Athena 11-19): perf-k measures and specifies; agy workers implement slices from the specs; perf-k
verifies each PR against before.md. perf-k codes a slice only when it is too subtle for Flash.

## Slices (specs in ~/.local/state/fleet-orchestrator/briefs-free/perf-shell-forks-N-*.md)
1. sessions: one jq for every session file (hook's fleet_rows block shared into lib.sh). agy, first.
2. panes: live_panes_load once + pane_live. agy, after 1.
3. lib-load: lib.sh load 16-19 -> 1 fork, flog +8 -> +5, hook mkdir. agy, after 1.
4. screen parse (THIS BRANCH, perf-k): one awk per capture; armed_at; stopped_at via printf.
5. paths: basename/dirname -> parameter expansion + lint. agy, after 1 and 3.

## Done
- Baseline 06df2c2: docs/perf/2026-11-19-shell-forks/before.md, harness scripts/perf/forks/.
- Slice 4 7662892: resume pass 772 -> 472, watch tick (3 panes) 152 -> 39, doctor 1645 -> 1479.
  Differential test 22227 checks (368 screens x gawk+mawk, both orders) + stopped_at DST; Opus review
  round 1: no divergence; should-fix (failed parse cached, cache transitions untested, 4 helpers
  missing) fixed. Mutations: 7 of 9 killed and confirmed, keep-failed + no-idle-order rerunning.
- Specs 1-3, 5 written, SOTA guard policy folded in (gate on counts, wall time reported only).
- Reported to Athena 16:42 (fleet send).

## Next
1. #500: round 2 (fresh Opus) CLEAN; its nits (armed_at takes its own screen, harness hook rows run with the read-only
   tmux shim) committed with this IMPL. test_forks_screen.sh 26069 passed (strace 6.8). Report to Athena; do not merge.
2. #510 (perf/readers, Closes #501): verify pass CLEAN; should-fix (ctime part of the change marker untested) fixed
   on that branch. Do not merge.
3. #497 (agy slice 1): re-verified 11-20 01:50 on 96777d2, both should-fix fixed (PR comment). #497 and #500 conflict
   (test-forks target, CI step, lib.sh): second to merge rebases.
4. Slices 2, 3, 5 (specs in briefs-free) start after #497 merges; agy implements unless Athena hands them to perf-k.
5. Class c (frontend P1-P3, P12, A1) after the gauge header PR (feat/gauge-header-421) merges.
- Checked and left: statusLine 6 processes / 2 jq per 30 s refresh per session (fixture run, strace).
- Lesson: while a PR's CI runs, commit IMPL locally and push it with the next code change (a lone IMPL push cancels the run).

## Verify
- `bash fleet/test_forks_screen.sh` (STRACE=, mawk on PATH; ~2.5 min); `make test-forks`. strace here: `apt-get download strace && dpkg -x strace_*.deb root`, then STRACE=root/usr/bin/strace.
- BEFORE/AFTER: detached worktree at origin/main + `SANDBOX_SEED=<copy> bash scripts/perf/forks/run.sh OUT %59 %60 %63`
  for each checkout, under `flock -o /tmp/fleet-heavy.lock`.
- strace/hyperfine/mawk without root: `apt-get download X && dpkg -x X_*.deb root`.
- Never pkill -f a pattern that appears in your own command line (it kills your shell: exit 144).
