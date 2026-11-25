# IMPL: klepsydra#492: perf: session files one-jq consolidation (Slice 1)

Branch `perf/sessions-one-jq` (worktree `.claude/worktrees/perf-sessions`), PR #497.
Push refspec: `git push -u origin perf/sessions-one-jq:perf/sessions-one-jq`. Never push to main.
Issue: https://github.com/ajbarea/klepsydra/issues/492
PR: https://github.com/ajbarea/klepsydra/pull/497

## Status (11-25, review-batch3, Opus)
- Fix rounds: r1 96777d2, r2 e8ff56e..2f44364, r3 f239c7f (agy) = free-engine cap reached; Opus is the only author now.
- CI red at f239c7f (run 45582840437, 9 #515 cases): not f239c7f. This branch's reader keeps only one-line `v: 1` session files (as the hook writes); main's #515 fixture wrote pretty JSON without `v`. Fixed in the fixture, with a loud setup check; main (#502) merged in.
- Review r4 (fresh Opus, 11-25): 1 Should-fix, reproduced: the pass's cached SESSION_ROWS leaked into spawn's background move, so heph_move's stamp check could miss a /clear during the move. Fixed: the move subshell unsets SESSION_ROWS; `test_forks_sessions.sh` runs the real spawn inside a pass-like function (red without the unset). Its no-strace SKIP now exits 1 when a case before it failed.
- Next: CI green, one fresh verify reader on the r4 fix, merge. Slices 2, 3, 5 of #492 wait on this merge.

## What a Fresh Session Must Rerun
1. Check git status:
   `git -C /home/ajbar/ajsoftworks/klepsydra/.claude/worktrees/perf-sessions status`
2. Check CI status:
   `gh pr checks 497`
3. If local verification of fork tests is needed:
   `bash fleet/test_forks_sessions.sh` (needs strace on PATH or `STRACE=<path>`; without it the cases before the fork counts still run)
