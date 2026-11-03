# IMPL: klepsydra fleet-module brief, resume state 2026-11-03 18:10 (EST)

Session 20 (Chronos) moved back to RIT-CS-DQL at 18:10 (the fleet's account move). Resume from this
file, `git log`, open PRs and their comments, and the klepsydra line under "Running now" in
/mnt/c/Users/ajbar/fleet-briefing/queue.md. Readers: opus, dispatched with the elenchus SKILL at
~/ajsoftworks/techne/.claude/worktrees/leak-audit/plugins/techne/skills/elenchus/ (has ledger.py);
at most two at a time.

## Done this session
- ✅ #229 merged (a1f045c), installed, cut over. Main red was the watcher flake: rerun green.

## Next, in order (two readers at a time)
1. #296 fix/watch-alert-race (watch-race), r1 reader: STOPPED by the move, re-dispatch. Real race behind
   the watcher flake (main, athena-222, #261 CI). Merge first once clean; then merge main into #261.
2. #261 fix/doctor-truth-246 (doctor-246), head 5a68e40: r9 fix (pane on the fleet's socket only; pane_runs
   checks the socket; mutants of the 3 checks each fail). Dispatch r10. Its CI 41690357522 failed only on
   the watcher flake; failed job rerun requested. Body's test counts are stale (section now 112). Deferred #294.
3. #230 fix/ask-217 (ask-217), head bd3e51a (main merged, hook suite 569): r1 reader STOPPED by the move,
   re-dispatch. Body says 515.
4. #287 feat/orch-guard-264 (guard-264), head 0852f9c: r9. Deploy after merge: install, PreToolUse in
   ~/.claude/settings.json, `fleet accounts sync`.
5. #291 fix/tasks-max-289 (tasks-289), head f64796b: r3 verify.
6. #292 fix/tmux-dead-pane-290 (tmux-290), head 427822d: r3 (body rewritten). needs-you has AJ's .wslconfig line.
7. #293 feat/resume-now-271 (resume-271) and #295 feat/agora-270 (agora-270): r1 each.
8. #288 fix/watch-dead-288 (dead-288), stacked on #261: rebase after #261 merges; combine with #296's
   watch-panes.sh change.
9. #272 (resume-method experiment, design first).

## Notes
- Rule (#289, 11-03): tmux-spawning tests and multi-file shellcheck run under the heavy lock, timeout inside it.
- A suite section run alone: lines 1..91 + the section + the summary line (scratch t288.sh, t290.sh).
- Never nest a heredoc inside a python <<'EOF' edit: write the edit script with Write and run it.
- `gh pr edit` fails (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`.
- App crate needs GTK headers WSL lacks: test `-p klepsydra-fleet` with CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target.
- Cleaned 11-03: worktrees recover, impl-1029, impl-s9/s14/s16/s17; PR #228 closed (superseded).
