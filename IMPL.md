# IMPL: klepsydra#492: perf: session files one-jq consolidation (Slice 1)

Branch `perf/sessions-one-jq` (worktree `.claude/worktrees/perf-sessions`), PR #497.
Push refspec: `git push -u origin perf/sessions-one-jq:perf/sessions-one-jq`. Never push to main.
Issue: https://github.com/ajbarea/klepsydra/issues/492
PR: https://github.com/ajbarea/klepsydra/pull/497

## Status / Stopped State (PC Restart Handoff)
- Working tree is clean at commit `2f44364` (and will be committed with this IMPL.md).
- Round 2 review items (brief `~/.local/state/fleet-orchestrator/briefs-free/perf-shell-forks-1-r2.md`) 1-4 fully resolved, tested, and committed:
  1. `e8ff56e` (SHOULD-FIX 1): `fleet/test_forks_sessions.sh` updated to create 20 ended session files per pane so main's grep prefilter fails fork scaling (`a-base=12`, `b-base=62`) while branch passes (`a-base=4`, `b-base=4`). Updated strace check to SKIP locally if missing and FAIL in CI. Added comment explaining the 4-fork cap floor. Removed false line from PR body.
  2. `cc29f24` (SHOULD-FIX 2): `fleet/test_forks_sessions.sh` checks strace exit code (`rc == 0`) and asserts `base > 0` in `forks_of`, preventing false passes on disabled or blocked ptrace.
  3. `abf802a` (SHOULD-FIX 3): `fleet/resume-at-reset.sh` caches `SESSION_ROWS=$(fleet_sessions_tsv)` once per `pass()`, eliminating redundant whole-folder jq invocations per pane.
  4. `2f44364` (SHOULD-FIX 4): `fleet/lib.sh` adds count check in `fleet_sessions_tsv` (files named vs rows parsed), logging `flog WARN` and appending to `$FLEET_STATE/bad-sessions` if counts mismatch. `fleet/doctor.sh` checks session files and reports `warn session files: corrupt or truncated: <file>` or `ok session files: every session file parsed`. Added regression test in `fleet/test_fleet.sh`.
- Paired measurements on frozen seed data (`SANDBOX_SEED=/tmp/perf-seed`, 130 session files, live panes `%84 %85 %86`):
  - `fleet doctor`: forks 1694 -> 1027 (-667 forks, target >= 370 met); jq 454 -> 79 (-375 jq, target >= 370 met).
  - `resume pass`: forks 973 -> 937 (-36 forks); jq 64 -> 37 (-27 jq, target >= 20 met).
- PR #497 description and fleet report `~/.local/state/fleet-orchestrator/briefs-free/perf-shell-forks-1-sessions-report.md` are updated with exact paired measurement numbers and reproduction steps.
- Head pushed to `origin/perf/sessions-one-jq`.
- CI run [44711522783](https://github.com/ajbarea/klepsydra/actions/runs/44711522783) was in flight at checkpoint.

## What is Next
1. Verify CI run [44711522783](https://github.com/ajbarea/klepsydra/actions/runs/44711522783) is green via `gh pr checks 497`.
2. Once CI is all green, notify orchestrator Athena in pane `%61`:
   `fleet send %61 "CI green on PR #497 (commit 2f44364), round 2 review items 1-4 clean and verified"`
3. Await orchestrator review and merge (Athena holds merge rights; do not merge or push to main).

## What a Fresh Session Must Rerun
1. Check git status:
   `git -C /home/ajbar/ajsoftworks/klepsydra/.claude/worktrees/perf-sessions status`
2. Check CI status:
   `gh pr checks 497`
3. If local verification of fork tests is needed:
   `STRACE=/tmp/claude-1001/rev500/strace/root/usr/bin/strace bash fleet/test_forks_sessions.sh`
