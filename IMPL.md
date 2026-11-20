# IMPL: klepsydra#501, perf class (b): read only the files that changed

Branch perf/readers (worktree .claude/worktrees/perf-readers), cut `--no-track` from origin/main 5dfdff5.
Push only: `git push -u origin perf/readers:perf/readers`. Never push to main. No PR yet.
Sibling, class (a) shell forks #492: PR #500 (perf/shell-forks, slice 4) rebased onto 5dfdff5, SC2016 fix
e613a35 pushed at Athena's ask; CI run 44645744466 was running. Local: make test-fleet 989/0, hooks 606/0
(posted on #500). `make shellcheck` was killed twice (exit 137) while waiting on the heavy lock; CI's shell
lint decides. NEXT for #500: when CI is green, `fleet send` Athena one paragraph; do not merge.
agy's slice 1 PR #497 is red (119 fleet-suite fails, limits-from-events); agy was out of quota till ~20:45.

## Design (done, commit f50778f)
- `memo.rs`: `Memo<T>` keeps a value per path against the (len, mtime) the directory entry lists; racy rule
  (written within 2 s: read every pass); kept only when listed stamp == handle stamp; errors never kept;
  a `Pass` drops paths it did not ask for. `scan::Scanner` (in `watch::Reader`), `usage::Reader` shared by
  gauge, phone and launch (`UsageReader` state, src-tauri/src/main.rs). `usage::read` is now cfg(test) only.
- Sources: git racy-git doc; Raymond Chen "file size reported incorrectly for files still being written"
  (NTFS dir entry updates on close; klepsydra writers use tmp+rename); gungraun docs (count-based gates).

## Measured (docs/perf/2026-11-19-readers/)
- Live installed exe, 60 s: 16,231 reads, 34,991 other ops, 3.23 MB, 1,422 ms CPU (scripts/perf/io.ps1).
- Windows native readcost example, real data copy, 3 alternating runs: scan 234 reads/9.4 ms -> 0/0.63 ms;
  usage 426/8.5 ms -> 0/0.57 ms; reader step 768 other ops/10.2 ms -> 66/1.3 ms.

## Guards and mutations
- Read-count tests in scan, usage, watch + memo unit tests; fleet crate 452 pass on Linux.
- Mutations (docs/perf/2026-11-19-readers/mutate.py, 9): 7 killed. Two weak tests were rewritten after: watch
  `a_step_over_an_unchanged_fleet_opens_no_session_file` (same stamp, new text -> step must be None) and memo
  `a_value_is_kept_only_under_a_stamp_the_listing_showed`. Rerun those two mutations ("reader rescans afresh",
  "listed vs held not compared"), skipping receiver:: tests (receiver::bad_paths_bodies_and_sizes_get_their_status
  looks flaky; one unreproduced crate-test failure in 18 runs early on).

## Next
1. Rerun the 2 mutations; Windows `KLEPSYDRA_STAGE=klepsydra-build-perf_readers bash scripts/build-windows.sh --check`
   under `flock -o /tmp/fleet-heavy.lock` (stage name may not contain '-' after klepsydra-build-).
2. Fresh Opus review (the first was stopped before reporting; brief it with the diff, elenchus bug-classes,
   reproduce/trace/whole-repo passes).
3. PR: label performance, assignee ajbarea, Closes #501, results table from the docs README, live vs tested line.
   Report to Athena. Optional follow-up: Reader::step's remaining 57 ops (reply clip stats per session).
4. Then class (c) frontend only after #487 (merged) and the gauge header PR merge.

## Verify
- `cd src-tauri/fleet && cargo test --lib`; data copy C:\Users\ajbar\klepsydra-perf\data-1119 (delete when done).
- A/B: docs/perf/2026-11-19-readers/ab.sh + winrun.sh (fix their scratchpad paths); before = detached worktree .claude/worktrees/perf-readers-before.
