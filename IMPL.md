# IMPL: klepsydra#501, perf class (b): read only the files that changed

Branch perf/readers (worktree .claude/worktrees/perf-readers), PR #510 (Closes #501). Base origin/main 5dfdff5,
main merged in (ce06f00). Push only: `git push -u origin perf/readers:perf/readers`. Never push to main.
Do not merge (Athena merges).

## Done (11-20)
- Athena round 1 (reports/readers-510-r1.md) and my fresh-Opus round 2: all should-fix fixed, both in the
  elenchus ledger. Round 2 S2: the Windows directory walk bounds every entry/name to its buffer (d48c983).
- Linux: 462 tests, fleet clippy clean, node guards 48/48. Windows native: clippy + 450 tests,
  mutate.py 14/15 (Unix inode equivalent, documented), winmutate.sh 5/5.
- Whole-app A/B (appab.ps1, 3 rounds, static live-data copy): reads 8,036 -> 118, other 16,818 -> 1,506,
  bytes 1.48 MB -> 6 KB, CPU 500 -> 281 ms per 60 s. readcost reproduced on HEAD. README + PR body rewritten
  from tables.py (ab.txt, appab.txt).

## Next
1. CI green on the last push, then `fleet send` the report to Athena (orchestrator.pane) and update queue.md.
2. Then #423 (heavy lock as a slot pool sized from the machine; Heph 11-20, design in the issue's latest comment),
   in its own worktree `perf-heavylock` from origin/main.
3. Then #515 (context budget: relaunch fresh past a token threshold, live ledger alert, one PR per brief).

## Verify
- `python3 docs/perf/2026-11-19-readers/tables.py` prints the README tables. Stage names allow no hyphen after
  `klepsydra-build-` (perf_before, perf_readers). Data copies: C:\Users\ajbar\klepsydra-perf\data-1119 and
  ab-501\ (delete when the PR merges).
