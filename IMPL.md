# IMPL: klepsydra#501, perf class (b): read only the files that changed

Branch perf/readers (worktree .claude/worktrees/perf-readers), PR #510 (Closes #501). Base origin/main 5dfdff5
(main is at 7ed5e88; #500 touched only shell, no Rust conflict).
Push only: `git push -u origin perf/readers:perf/readers`. Never push to main. Do not merge (Athena merges).

## Done (11-20, after the hard shutdown)
- Athena round 1 (~/.local/state/fleet-orchestrator/reports/readers-510-r1.md) SF1 + nits answered in 10764b6:
  Stamp {len, modified, changed, id}; Windows listing via GetFileInformationByHandleEx(FileIdBothDirectoryInfo).
- Verified: Linux `cargo test --lib` 462/462, fmt clean; Windows clippy (cross) clean; native Windows
  `build-windows.sh --check` clean (fleet 449 pass, incl. the in-place test: NTFS ChangeTime moves on write).
- 9e9a224: NTFS directory-entry lag documented on `Stamp` (copied on last handle close; Raymond Chen 2011),
  new test a_file_written_in_place_lists_its_new_stamp_once_its_writer_closes; Windows unused-mut fixed.
- New: docs/perf/2026-11-19-readers/winmutate.sh (4 Windows-listing mutations on the NTFS stage),
  appab.ps1 (whole-app A/B on one data copy, per-PID I/O counters, restores .window-state.json).

## Next
1. winmutate.sh result (running); then `flock -o /tmp/fleet-heavy.lock timeout 3000 python3 docs/perf/2026-11-19-readers/mutate.py` (15 expected killed); Linux clippy.
2. SF2: build release exes: `KLEPSYDRA_STAGE=klepsydra-build-perf-before` from worktree perf-readers-before
   and `klepsydra-build-perf_readers` from here (`scripts/build-windows.sh`, under the lock); then
   `powershell.exe -File appab.ps1 -Before <exe> -After <exe> -Data C:\Users\ajbar\klepsydra-perf\data-1119`.
   Static copy: no writes during the run, so it measures the idle steady state; say so.
3. Rerun readcost on Windows (`ab.sh`): the listing changed, after counts change. Update README tables.
4. PR body: SF1 design + sources (MS FILE_ID_BOTH_DIR_INFO, MS-FSCC EaSize = reparse tag, Raymond Chen NTFS lag),
   fix "Checked live" and the NTFS-lag line (it can serve the old value while a writer holds the file open;
   no klepsydra writer does). Fresh Opus self-review, CI green, report to Athena.
5. Then #423 (heavy lock as a slot pool sized from the machine; Heph 11-20, design in the issue's latest comment).
6. Then #515 (context budget: relaunch fresh past a token threshold, live ledger alert, one PR per brief; Heph 11-20).

## Verify
- see Next 1-3. Data copy: C:\Users\ajbar\klepsydra-perf\data-1119 (delete when the PR merges).
