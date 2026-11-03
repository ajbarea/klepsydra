# IMPL: klepsydra fleet-module brief, resume state 2026-11-03 10:30 (EST)

Session 19 (Chronos, relaunched after the 11-03 hard shutdown) replaced session 18. Resume from this
file, `git log`, open PRs and their comments, and the klepsydra line under "Running now" in
/mnt/c/Users/ajbar/fleet-briefing/queue.md. Order (Heph 11-03 09:50): #287 #261 #229, then #288 #289
#290, then #271 #270 #272.

## In flight
| PR / branch (worktree) | Issue | State |
|---|---|---|
| #287 feat/orch-guard-264 (guard-264) | #264 | round 6 reader dispatched 09:40 on 4412d8a; findings land in ~/.local/state/elenchus/findings.jsonl (pr 287 round 6). Deploy after merge: install, PreToolUse entry in ~/.claude/settings.json, `fleet accounts sync`. |
| #261 fix/doctor-truth-246 (doctor-246) | #220 #246 | round 4 reader dispatched 09:40 on e763a09 (ledger: pr 261 round 4). Merge only after a clean round. |
| #229 fix/focus-216 (focus-216) | #216 | verify round still owed on 2dc9d6c. |
| fix/watch-dead-288 (dead-288), STACKED on #261 | #288 | pane_dead_why in lib.sh; watcher DEAD; doctor gone-with-pane. Pushed; CI by `gh workflow run ci.yml --ref fix/watch-dead-288`. No PR yet (opens against main once #261 merges: rebase onto main). |
| #291 fix/tasks-max-289 (tasks-289) | #289 | TasksMax = tightest pids.max above / 3 (8745 here); doctor 80% warn; make test-fleet/shellcheck under the lock; brief tail. CI running. Peak sampler: scratchpad tasks.log(.max), 119-126 so far. |
| fix/tmux-dead-pane-290 (tmux-290), not pushed | #290 | Backtrace on #290 (comment): 3.4 focus-out to an exited pane. pane-died hook (hooks/klepsydra-pane-died.sh) respawns the dead pane on its saved screen + @klepsydra_dead mark; fleet/tmux-watch.sh + fleet-tmux-watch.timer run fleet recover on a crash record (WSL dump or kernel line for the server's pid). Tests: watchdog section in test_fleet.sh; crash repro scratch/crash290.sh (hook vs nohook) to turn into a test. |

## Parked
- #271 (worktree resume-271, branch feat/resume-now-271, clean): design: service records its pid, USR1 trap +
  `sleep & wait`, `fleet resume now` writes a request token and waits for resume-now.done; `--once` refuses
  while the service lives; Heph's account = prefs.json `heph_account` (account uuid or auto) put first in
  FLEET_HEPH_ACCOUNTS by lib.sh each pass, so the existing move-back path moves him; tray: "Run resume pass
  now" + status line, "Heph's account" radio submenu built from account readings. Phone half waits on #163.
- #230 (#217, conflicting) after #229 lands.

## Notes
- Rule (#289, 11-03): tmux-spawning tests and multi-file shellcheck run under the heavy lock, timeout inside it.
- A suite section run alone: lines 1..91 + the section + the summary line (scratch t288.sh, t290.sh).
- Never nest a heredoc inside a python <<'EOF' edit: write the edit script with Write and run it.
- `gh pr edit` fails (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`.
- App crate needs GTK headers WSL lacks: test `-p klepsydra-fleet` with CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target.
- Cleaned 11-03: worktrees recover, impl-1029, impl-s9/s14/s16/s17; PR #228 closed (superseded).
