# IMPL: klepsydra fleet-module brief, resume state 2026-11-04 (session 28)

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

## Resume here (session 28, fresh on Personal %26, 11-04 evening)
Reports: /tmp/claude-1001/<round>/report.md. Never wrap a lock-taking make target in an outer timeout; finish edits
to a suite before queuing it. PR bodies: Write the file, then PATCH in its own call (phylax reads the written file).
Order (Heph 11-04): bug queue -> #326 (PR #331) -> #323 stage 1 (PR #332) -> #327 Agora v2 -> #324 -> #323 later
stages; reader backlog (#318, #316, #314, #308, #310) and cuts 7, #8 between.
- ✅ merged + installed: #230, #313, #292, #329 (r5 clean, 2328e02).
- 🔄 #322 (room-319) 7190c60: r3 fixed (26b2cf1) + main merged; suite 760/0; body updated; r4 reader ->
  /tmp/claude-1001/r4-322/report.md.
- 🔄 #325 (send-320): r1 F1/F2 Blocking fixed in the worktree commit after 325dddc (per-pane flock in
  inbox_deliver -> deliver_now; msg_in_box before each retry Enter; brief-tail "fleet send" rule + check; N1-N4
  cases; send.sh +x). Full suite running; then push, body (F8 = known limit: real queued-hint unverified), r2.
  After merge: `fleet brief --refresh`, tell Heph (HEPH.md + worker-report memory still say raw send-keys).
- 🔄 #330 (phone-328) b69fcd4: r1 reader -> /tmp/claude-1001/r1-330/report.md.
- 🔄 #287 (guard-264): r15 committed 41111e9 (7/7 mutants killed, base 238/0), main merged (doctor/install/test_fleet
  conflicts: both sides kept); suites running (scratch tf-287.log, og-287.log); then push, body count, r16 verify.
- 📋 r1 owed: #331 (e6af965), #332 (5cf7473), #318 (behind main).
- 📋 Readers: #316 r1, #314 r1, #308 r2, #310 verify, claude-prefs#42 r2 + #43 r1.
- 📋 Cut 7 (friction triage + SessionStart last 10 lines), then the #8 trial; #327; #324.
- Held worktree split-182: kept on purpose (CARGO_TARGET_DIR; src-tauri/gen is Tauri's generated schema).

## Next, in order (session 21 list; items 1-3 moved above)
1. (done) #296 fix/watch-alert-race (watch-race), head 0a10fe1, review-clean r3. CI run 41702648814 was still in
   its Fleet engine step at park. If green: merge (squash), `make install-fleet` from main, then tell
   Heph the watcher fix is live. If red: read the log; a red outside test_ci_watch.py is not this PR.
2. #230 fix/ask-217 (ask-217), head a7ea3c5: r1 fixes pushed (turns_at stamped in ask_answered; a busy
   lock makes ask_answered fail so the watcher retries; tests for the question filter, debounce, per-ask
   reset and SubagentStop with no agent_id; stub tmux serves $work/screens in turn; per-run session id).
   Next: PR body (515 -> 573; the "each guard fails its test" line is now true), then r2 reader.
   Minor left: answer before the watcher's first look (PLAUSIBLE), one lock file per session.
3. #291 fix/tasks-max-289 (tasks-289), head de9671c: r4 reader was STOPPED by the park, re-dispatch
   (brief: verify r3's two Should-fix; the briefs section runs alone as lines 1..91 + 617..731 + last 2).
   CI on de9671c was starting at park.
4. #261 fix/doctor-truth-246 (doctor-246), head 5a68e40: merge main after #296, then r10. Its CI
   41697027451 is the one to read (no rerun was made; Heph 11-03). Deferred #294.
5. #287 feat/orch-guard-264 (guard-264), head 3c5822e: PAUSED after r9 by the elenchus pause rule (r8
   and r9 each found bugs the previous fix made). Needs Heph's go-ahead for the approach change:
   date the stop by cache warmth = last main-chain assistant entry without isApiErrorMessage and
   model != <synthetic>; take the earliest of that, the screen's done time, and the first limit
   after it; no good reply = unknown refusal. Repro /tmp/claude-1001/r9/probe.sh (ok at HEAD,
   cold-limit at 5fd44a8). Minors: pin the format oracle to 30 ran on tmux 3.4; grep prefilter before
   tac|jq on huge transcripts; body count 214 -> 218. Deploy after merge: install, PreToolUse in
   ~/.claude/settings.json, `fleet accounts sync`.
6. #292 fix/tmux-dead-pane-290 (tmux-290), head 427822d: r3. needs-you has AJ's .wslconfig line.
7. #293 feat/resume-now-271 (resume-271) and #295 feat/agora-270 (agora-270): r1 each.
8. #288 fix/watch-dead-288 (dead-288), stacked on #261: rebase after #261 merges; combine with #296's
   watch-panes.sh change.
9. #272 (resume-method experiment, design first).

## Notes
- Rule (#289, 11-03): tmux-spawning tests and multi-file shellcheck run under the heavy lock, timeout inside it.
- Never nest a heredoc inside a python <<'EOF' edit: write the edit script with Write and run it.
- `gh pr edit` fails (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`;
  phylax wants the body file written in its own call before the PATCH.
- shellcheck: `make shellcheck` for the tree (takes the heavy lock itself); one file: `uvx --from shellcheck-py shellcheck -x <file>`; ruff: `uvx ruff@0.17.3`.
- `make test-fleet`, `make test-launch`, `make test-heavy-lock` take the heavy lock themselves: run them bare.
- App crate needs GTK headers WSL lacks: test `-p klepsydra-fleet` with CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target.
