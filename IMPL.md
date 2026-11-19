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
1. make test-fleet + make shellcheck + hooks/test_fleet.sh (running), then PR for slice 4 (Part of #492).
2. Verify each agy PR: rerun `ba.sh`-style BEFORE/AFTER with SANDBOX_SEED, compare with before.md.
3. Class (b) specs (Rust readers, phone server). SOTA: notify + notify-debouncer-full for Linux paths,
   but inotify misses Windows-side writes on /mnt/c (9P): files there need notify PollWatcher or an
   mtime+size cache; measure both. Gate on instruction counts (CodSpeed simulation), report wall time.

## Verify
- `bash fleet/test_forks_screen.sh` (STRACE=, mawk on PATH; ~2.5 min); `make test-forks`.
- BEFORE/AFTER: detached worktree at origin/main + `SANDBOX_SEED=<copy> bash scripts/perf/forks/run.sh OUT %59 %60 %63`
  for each checkout, under `flock -o /tmp/fleet-heavy.lock`.
- strace/hyperfine/mawk without root: `apt-get download X && dpkg -x X_*.deb root`.
- Never pkill -f a pattern that appears in your own command line (it kills your shell: exit 144).
