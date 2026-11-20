# IMPL: klepsydra#501, perf class (b): read only the files that changed

Branch perf/readers (worktree .claude/worktrees/perf-readers), cut `--no-track` from origin/main 5dfdff5.
Push only: `git push -u origin perf/readers:perf/readers`. Never push to main.

## Done
- f50778f: `memo.rs` (`Memo<T>`, per-path value against the listed (len, mtime, change) stamp; racy 2 s;
  kept only when listed == handle stamp; errors never kept; a pass drops unlisted paths). `scan::Scanner`
  in `watch::Reader`; one `usage::Reader` shared by gauge, phone and launch.
- Measured (docs/perf/2026-11-19-readers/README.md): Windows native, real data copy, per call:
  scan 234 reads / 9.4 ms -> 0 / 0.63 ms; usage 426 / 8.5 ms -> 0 / 0.57 ms; reader step 10.2 -> 1.3 ms.
- b47c1ec: P6, P7, A2 measured and left as is (0.22 ms per 5 s; 0.22 ms per range request; 0.57 ms).
  A1 goes to the frontend class. Examples pass clippy; mutate.py runs a green baseline first.
- 0ce13c7: Opus review round 1 (nothing blocking): change marker in Stamp (Unix ino + ctime, Windows
  creation time), a path asked twice per pass read once, bounded stamps after the read, watch test counts
  opens per thread, phone.rs doc. Mutations: 11 of 11 killed. Linux fleet tests 454 pass; Windows
  `build-windows.sh --check` passes; clippy clean.

## Next
1. PR (label performance, assignee ajbarea, Closes #501), report to Athena; do not merge.
2. Class (c) frontend only after the gauge header PR (feat/gauge-header-421) merges: P1-P3, P12, A1.
3. Verify agy's #492 slices against docs/perf/2026-11-19-shell-forks/before.md.

## Verify
- `cd src-tauri/fleet && flock -o /tmp/fleet-heavy.lock timeout 1500 cargo test -q --lib`
- `flock -o /tmp/fleet-heavy.lock timeout 3000 python3 docs/perf/2026-11-19-readers/mutate.py`
- `KLEPSYDRA_STAGE=klepsydra-build-perf_readers flock -o /tmp/fleet-heavy.lock timeout 2400 bash scripts/build-windows.sh --check`
- Data copy: C:\Users\ajbar\klepsydra-perf\data-1119 (delete when the PR merges).
