# IMPL: klepsydra fleet-module brief, resume state 2026-11-03 15:40 (EST)

Session 20 (Chronos, relaunched 10:33 on the other account). Resume from this file, `git log`, open
PRs and their comments, and the klepsydra line under "Running now" in
/mnt/c/Users/ajbar/fleet-briefing/queue.md. Review readers: opus, dispatched with the elenchus SKILL
at ~/ajsoftworks/techne/.claude/worktrees/leak-audit/plugins/techne/skills/elenchus/ (has ledger.py).

## Done this session
- ✅ #229 merged (a1f045c) + installed + cut over (fleet install from the main checkout).

## In flight
| PR / branch (worktree) | Issue | State |
|---|---|---|
| #287 feat/orch-guard-264 (guard-264) | #264 | r7 fixes 5fd44a8 (send alone in its call; any #{ + E/T refused, differential vs real tmux; undated limit = unknown). r8 reader running. Deploy after merge: install, PreToolUse entry in ~/.claude/settings.json, `fleet accounts sync`. |
| #261 fix/doctor-truth-246 (doctor-246) | #220 #246 | r8 fix uncommitted: a recorded finish parks the row's pane ("-"), restore_pane on start (hook event / doctor sees alive); main merged (recover.sh conflict kept both sides, 0ec62a2); recover logs a repair only when it happened. Section 89/89. Next: mutant + shellcheck + hook suite (running), commit, push, r9. Hook change (registry-event.sh) deploys with install. |
| #291 fix/tasks-max-289 (tasks-289) | #289 | r1 fixes 362d4ef (Makefile lock once via FLEET_HEAVY_HELD, make shellcheck = CI's). r2 verify reader running. |
| #292 fix/tmux-dead-pane-290 (tmux-290) | #290 | r1 fixes 7623bb5 (interop + WSL_DISTRO_NAME for the unit, retry pending, scope for a unit-started server, dated dumps, CaptureCrash line, tmux-conf.sh for the live server, doctor hook check, TERM test). r2 next. |
| #293 feat/resume-now-271 (resume-271) | #271 | open, review r1 not yet run. |
| feat/agora-270 (agora-270), pushed 86e4677, no PR | #270 | design posted on #270; agora.py replies/react, fleet done invite, brief tail drop, agora.rs view, wall replies/accent/counts; tests pass (py 34, rust 16, js 488). Owed: README rows, browser test run, demo screenshot to shots/2026-11-03/, PR, review. |
| fix/watch-dead-288 (dead-288), STACKED on #261 | #288 | rebase onto main once #261 merges, then PR + review. |

## Parked
- #230 (#217, conflicting): rebase on main now that #229 landed.
- #272 after #270.

## Notes
- Rule (#289, 11-03): tmux-spawning tests and multi-file shellcheck run under the heavy lock, timeout inside it.
- A suite section run alone: lines 1..91 + the section + the summary line (scratch t288.sh, t290.sh).
- Never nest a heredoc inside a python <<'EOF' edit: write the edit script with Write and run it.
- `gh pr edit` fails (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`.
- App crate needs GTK headers WSL lacks: test `-p klepsydra-fleet` with CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target.
- Cleaned 11-03: worktrees recover, impl-1029, impl-s9/s14/s16/s17; PR #228 closed (superseded).
