# IMPL: klepsydra fleet-module brief, resume state 2026-11-05 (session 32; #325 closed out 15:15)

Session 22 (Chronos) resumed 16:09 after the IAAI-27 park. Resume with the same brief from this file, `git log`,
open PRs and their comments, and the klepsydra line under "Running now" in /mnt/c/Users/ajbar/fleet-briefing/queue.md.
Readers: opus, dispatched with the elenchus SKILL at ~/ajsoftworks/techne/.claude/worktrees/leak-audit/plugins/techne/skills/elenchus/
(has ledger.py); at most two at a time; each brief carries the guarded-rm and heavy-lock rules and writes its
report to /tmp/claude-1001/<round>/report.md.

## FEATURE FREEZE (AJ via Heph, 11-03 evening)
Until AJ approves the independent klepsydra bloat audit (read-only, running): finish and merge only the
bug-fix PRs in review (#261, #287, #291, #230, #292), CI fixes, and #305 (brief-tail waiting rule).
Prefer deleting or consolidating code over new special cases.
HELD (no code): #293, #295, #302, #271, #270, #272 (design PR #300), any new feature; also #303 and #301
(bugs filed today, not yet in review) until Heph says.

## Audit cuts (Heph 11-03, fleet-briefing/review/klepsydra-bloat-audit-2026-11-03.md, last section)
After the bug-fix PRs: 1 (poll guard: claude-prefs #41/PR #42 open, 91/91 + 7 mutants; needs an
independent reviewer, then merge and `git -C ~/claude-prefs pull`), 3 (hooks/common.sh), 4 (no stale-PR
SessionStart in workers), 2 (limits from StopFailure + resets_at, staged), 5 (experiment:
claude --remote-control NAME "brief"), 6 (--append-system-prompt-file, tail ~260 words), 7 (friction.md
triage + inject last 10), then the #8 trial. #9 deferred, #10 denied. #304/#305 closed (withdrawn).
Each cut: a small PR with the proof test the report names.

## Resume here (session 32 parked 11-05 for AJ's papers; relaunch from the brief)
Reports: /tmp/claude-1001/<round>/report.md (subagents cannot write report files: their final message is the report).
Session-32 scratch: /tmp/claude-1001/s32-*. Never wrap a lock-taking make target in an outer timeout.
PR bodies: write the file, then GraphQL updatePullRequest (`-f query=...`, `-F b=@file`).
Order (Heph 11-04): bug queue -> #323 stage 1 (PR #332) -> #327 -> #324 -> #323 later stages;
reader backlog (#318, #316, #314, #308, #310, claude-prefs #42 #43) and cut 7, #8 between.
- ✅ #331 (Agora removal) merged a8f7daf; ✅ #330 (doctor phone off) merged 7c9fb69. Both installed, doctor 0 FAIL.
- ✅ #325 (send-320) merged a7de690 (11-05 budget-week session), installed from main, cutover, doctor 0 FAIL.
  CI's last red was the test: the lock-wait case's background `fsend &` inherited fd 8 (the held flock), so it
  waited on itself; it now gets `8>&-` (61d4e99). Local suite 788/0; CI green incl. test-launch; a fresh Opus
  reader on 61d4e99 was clean (2 nits left: `sleep 1` does not prove the sender is waiting on the lock).
  📋 Owed: an r5 reader on the r4 fix commit a0f0787 itself (never read independently before the merge).
- 🔄 #287 (guard-264): r17 mutants s1-dash, s2-exe, s3-e killed; m2-sh NOT RUN (stopped at the park): run only
  that line of /tmp/claude-1001/s32-287/mut.sh (S=/tmp/claude-1001/s32-287; it restores the file). Then r18.
- 🔄 #336 (sort-335) @6df71b0: r1 0B/0S/2M fixed; verify 0B/0S/1M (tie case missed a last-listed-wins
  mutant) fixed in 6df71b0. Merge once CI on 6df71b0 is green (re-read comments first), then `fleet install`.
- 📋 #334 (face-333) r1 (a reader was stopped at the park, no findings kept); deploy needs install-fleet + Windows build (installed exe is 10-31).
- 📋 r1 owed: #332, #318. Readers: #316 r1, #314 r1, #308 r2, #310 verify, claude-prefs#42 r2 + #43 r1.
- 📋 Cut 7 (after #318: both edit the tail's friction line): triage 98 friction.md lines (fix/issue/delete;
  snapshot /tmp/claude-1001/cut7/friction-snapshot.md), then SessionStart injects the last 10 for the repo.
- 📋 Then the #8 trial; #327; #324. Held (freeze): #293, #295, #300/#272.
- Held worktree split-182: kept on purpose (CARGO_TARGET_DIR; src-tauri/gen is Tauri's generated schema).

## Notes
- Rule (#289, 11-03): tmux-spawning tests and multi-file shellcheck run under the heavy lock, timeout inside it.
- Never nest a heredoc inside a python <<'EOF' edit: write the edit script with Write and run it.
- `gh pr edit` fails (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`;
  phylax wants the body file written in its own call before the PATCH.
- shellcheck: `make shellcheck` for the tree (takes the heavy lock itself); one file: `uvx --from shellcheck-py shellcheck -x <file>`; ruff: `uvx ruff@0.17.3`.
- `make test-fleet`, `make test-launch`, `make test-heavy-lock` take the heavy lock themselves: run them bare.
- App crate needs GTK headers WSL lacks: test `-p klepsydra-fleet` with CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target.
