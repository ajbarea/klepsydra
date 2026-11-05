# IMPL: klepsydra fleet-module brief, resume state 2026-11-05 (session 31)

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

## Resume here (session 31, fresh start 11-05 04:00 on the other account)
Reports: /tmp/claude-1001/<round>/report.md. Never wrap a lock-taking make target in an outer timeout; finish edits
to a suite before queuing it. PR bodies: write the file, then GraphQL updatePullRequest (`-f query=...`, not `q=`).
Order (Heph 11-04): bug queue -> #326 (PR #331) -> #323 stage 1 (PR #332) -> #327 -> #324 -> #323 later stages;
reader backlog (#318, #316, #314, #308, #310, claude-prefs #42 #43) and cut 7, #8 between.
- 🔄 #287 (guard-264): r17 fixes (S1 dash-named dir case, S2 root-owned bash/python3.N exe check, S3 readlink -e,
  M2 regex narrowed to bash|python3) uncommitted in the worktree; suite 250/0; mutants running
  (scratchpad mut287.sh). Body: Deferred line rewritten (M1 .pth), staged as scratchpad body287-new.md.
  Then commit, push, body, r18 reader. fleet/test_s287.sh there is an untracked cut harness: never commit it.
- 🔄 #330 (phone-328) r3 reader -> /tmp/claude-1001/r3b-330/report.md.
- 🔄 #325 (send-320) r4 reader -> /tmp/claude-1001/r4b-325/report.md. After merge: `fleet brief --refresh`, tell Heph.
- 🔄 #336 (sort-335, new bug): newest_reading kept #319's sort | head pipe; journal still logged sort write errors
  (systemd IgnoreSIGPIPE=yes). One pick_file helper; case + mutant red. CI, then r1 reader.
- 📋 #331 (agora-326) verify reader, merge, `fleet install`, `fleet brief --refresh`.
- 📋 #334 (face-333) r1; deploy needs install-fleet + Windows build (installed exe is 10-31).
- 📋 r1 owed: #332, #318. Readers: #316 r1, #314 r1, #308 r2, #310 verify, claude-prefs#42 r2 + #43 r1.
- 📋 Cut 7, then the #8 trial; #327; #324. Held (freeze): #293, #295, #300/#272.
- Held worktree split-182: kept on purpose (CARGO_TARGET_DIR; src-tauri/gen is Tauri's generated schema).

## Notes
- Rule (#289, 11-03): tmux-spawning tests and multi-file shellcheck run under the heavy lock, timeout inside it.
- Never nest a heredoc inside a python <<'EOF' edit: write the edit script with Write and run it.
- `gh pr edit` fails (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`;
  phylax wants the body file written in its own call before the PATCH.
- shellcheck: `make shellcheck` for the tree (takes the heavy lock itself); one file: `uvx --from shellcheck-py shellcheck -x <file>`; ruff: `uvx ruff@0.17.3`.
- `make test-fleet`, `make test-launch`, `make test-heavy-lock` take the heavy lock themselves: run them bare.
- App crate needs GTK headers WSL lacks: test `-p klepsydra-fleet` with CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target.
