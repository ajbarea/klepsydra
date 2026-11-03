# IMPL: klepsydra fleet-module brief, resume state 2026-11-03 11:10 (EST)

Session 20 (Chronos, relaunched 10:33 on the other account after a usage limit) replaced session 19.
Resume from this file, `git log`, open PRs and their comments, and the klepsydra line under "Running
now" in /mnt/c/Users/ajbar/fleet-briefing/queue.md. Order (Heph 11-03 09:50): #287 #261 #229, then
#288 #289 #290, then #271 #270 #272.

## In flight
| PR / branch (worktree) | Issue | State |
|---|---|---|
| #287 feat/orch-guard-264 (guard-264) | #264 | round 7 reader running on 67c40e0 (ledger: pr 287 round 7). Deploy after merge: install, PreToolUse entry in ~/.claude/settings.json, `fleet accounts sync`. |
| #261 fix/doctor-truth-246 (doctor-246) | #220 #246 | round 5 found sticky-recorded-finish a third time (+ unpause twin); structural fix 9e0ea59 (forget_resumed reconciles finished.tsv + unpaused.tsv with the fleet file on every read, in doctor, --prune and recover; prune re-checks under the lock; pause refuses a row with no sid). CI running; round 6 reader next. |
| #229 fix/focus-216 (focus-216) | #216 | main merged (3bbc6d2); verify round 3 reader running. |
| fix/watch-dead-288 (dead-288), STACKED on #261 | #288 | no PR yet: rebase onto main once #261 merges, then PR + review. |
| #291 fix/tasks-max-289 (tasks-289) | #289 | CI green; review round 1 owed. |
| #292 fix/tmux-dead-pane-290 (tmux-290) | #290 | pane-died hook + watchdog; review round 1 owed. |
| feat/resume-now-271 (resume-271), uncommitted | #271 | written: fleet resume now (resume-now.sh: request file + SIGUSR1, re-signal every 5 s, else --once), service pid file + `sleep & wait` + USR1 trap, pass lock via flock -o re-exec (--once exits 75 while held), prefs.json heph_account -> lib.sh heph_pick (picked folder first in FLEET_HEPH_ACCOUNTS; explicit pick needs only room to work), tray "Run resume pass now" + status line + "Heph's account" submenu (src/heph.rs, fleet crate heph_account.rs), launcher resume-now, README. Tests written: test_fleet.sh "Heph's account as AJ picked it" + "fleet resume now"; hooks/test_launch.sh pass (199); fleet crate tests pass. Next: run section runner scratch/t271now.sh (queued), fleet-crate clippy, commit, PR, review. Phone half waits on #163. |

## Parked
- #230 (#217, conflicting) after #229 lands.
- #270, #272 after #271.

## Notes
- Rule (#289, 11-03): tmux-spawning tests and multi-file shellcheck run under the heavy lock, timeout inside it.
- A suite section run alone: lines 1..91 + the section + the summary line (scratch t288.sh, t290.sh).
- Never nest a heredoc inside a python <<'EOF' edit: write the edit script with Write and run it.
- `gh pr edit` fails (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`.
- App crate needs GTK headers WSL lacks: test `-p klepsydra-fleet` with CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target.
- Cleaned 11-03: worktrees recover, impl-1029, impl-s9/s14/s16/s17; PR #228 closed (superseded).
