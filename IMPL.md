# IMPL: klepsydra fleet-module brief, resume state 2026-11-03 17:00 (EST)

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

## Done (session 22)
- ✅ Merged + installed: #296 (watcher race, 9c4c79e), #299 (11-03 Quality rule, ce20046).
- ✅ Filed #298 (done), #301 (doctor scan cost), #303 (panes.tsv loses rows: launch.sh writes no row
  without task-NAME.src; unlogged rewrites; unlocked hand edits), #304 (wait rule).
- #291 (tasks-289): r4, r5, r6 fixes; r7 final verify CLEAN. m1 + m4 follow-ups (test env, ppid without
  awk) uncommitted in the worktree, mutants rerunning; then commit, CI, merge, make install-fleet.
- #261 (doctor-246): r10 Blocking fixed (a8bbe24), CI 19-red fixed (5cdd429: fresh() registers a row its
  launch left unregistered). r11 reviewer running (/tmp/claude-1001/r11-261/report.md).
- #230 (ask-217): r2 + r3 fixes pushed (7339b19); needs r4 reader.
- #287 (guard-264): Heph's go-ahead implemented (7bd0020 + main merged c83583c): stop dated by the last
  good main-chain reply, tail-only read (7 ms vs 727 ms on 48 MB). Suite 222/223 (strict local 60 ms
  budget on a sends-nothing call read 64 ms under load). Needs a fresh r10 reader (ceiling 5 more).
- #288 (dead-288): merged #261's branch; CI green on 41725667867. PR against main after #261 merges.
- #305 (wait-rule): brief-tail long-runs rule + brief.sh --check of a missing brief fails. CI pending.
- #292 (tmux-290): r3 still owed.

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
- shellcheck under WSL: `uvx --from shellcheck-py shellcheck -x <file>`; ruff: `uvx ruff@0.17.3`.
- App crate needs GTK headers WSL lacks: test `-p klepsydra-fleet` with CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target.
