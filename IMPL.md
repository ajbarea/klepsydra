# IMPL: klepsydra#501, perf class (b): read only the files that changed

Branch perf/readers (worktree .claude/worktrees/perf-readers), cut `--no-track` from origin/main 5dfdff5.
Push only: `git push -u origin perf/readers:perf/readers`. Never push to main.
Sibling: class (a) shell forks is #492 (PR #500 slice 4, agy PRs for slices 1-3, 5), branch perf/shell-forks.

## Plan
1. `memo.rs`: `Memo<T>` keeps a value per path against the (len, mtime) the directory entry lists; racy rule
   (a file written within 2 s is read every pass); kept only when listed stamp == handle stamp; errors never kept;
   a pass drops paths it did not ask for (memory bounded by the last listing).
2. `scan::Scanner` (Reader holds one) and `usage::Reader` (one shared by gauge, phone, launch: `UsageReader`
   app state in src-tauri/src/main.rs). Free `scan()` / `usage::read()` stay for one-off callers and tests.
3. Guards: read-count tests (`a_pass_over_an_unchanged_fleet_opens_no_file`,
   `a_read_of_unchanged_readings_opens_no_file`) + memo unit tests. Mutation-check them.
4. Measure: Windows-native `examples/readcost.rs` (GetProcessIoCounters per call) on a copy of the real data
   folder, A/B against a detached origin/main worktree (perf-readers-before), 3 alternating runs.
   Live: `C:\Users\ajbar\klepsydra-perf\io1119.ps1` samples the installed exe's I/O counters for 60 s.

## Done
- Live baseline (installed exe, 60 s, 18:2x): 16,231 reads, 34,991 other ops, 3.23 MB, 1,422 ms CPU.
- Steps 1-3 coded; fleet crate tests 451 pass on Linux. App crate builds only on Windows (no GTK here).

## Next
1. A/B numbers (scratchpad ab.log), `scripts/build-windows.sh --check` with KLEPSYDRA_STAGE=klepsydra-build-perf-readers.
2. What remains per Reader::step after the cache: reply::written_at stats the replies folder once per session;
   wrapup reads per session. Hoist if measured large.
3. Mutation checks, Opus review, PR (label performance, assignee ajbarea), report to Athena.

## Verify
- `cd src-tauri/fleet && cargo test --lib`; `cargo clippy --workspace --all-targets -- -D warnings` on Windows.
- Data copy: C:\Users\ajbar\klepsydra-perf\data-1119 (delete when done; holds session text).
