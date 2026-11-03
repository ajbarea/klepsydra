# IMPL: klepsydra fleet-module brief, resume state 2026-11-03 17:30 (EST)

Session 20 (Chronos, relaunched 10:33). Resume from this file, `git log`, open PRs and their
comments, and the klepsydra line under "Running now" in /mnt/c/Users/ajbar/fleet-briefing/queue.md.
Readers: opus, dispatched with the elenchus SKILL at
~/ajsoftworks/techne/.claude/worktrees/leak-audit/plugins/techne/skills/elenchus/ (has ledger.py).

## Done this session
- ✅ #229 merged (a1f045c), installed, cut over.

## In flight (worktree)
| PR | Issue | State |
|---|---|---|
| #296 fix/watch-alert-race (watch-race) | main red | MAIN IS RED (watcher test) after a1f045c: real race, a killed watcher's $(ci_wake) subshell marks an alert read. Fix + deterministic test pushed f135d80; r1 reader running. Merge first, before any other merge. |
| #261 fix/doctor-truth-246 (doctor-246) | #220 #246 | r8 fix 3ec064d (finished rows park their pane "-", restore on start), main merged; r9 reader running (waiting on CI). Deferred: #294. |
| #287 feat/orch-guard-264 (guard-264) | #264 | r8 fixes 0852f9c (stop dated by transcript entries; oracle waits on its job); r9 next. Deploy after merge: install, PreToolUse in ~/.claude/settings.json, `fleet accounts sync`. |
| #291 fix/tasks-max-289 (tasks-289) | #289 | r2 fixes f64796b (FLEET_HEAVY_HELD on make's command line; AGENTS.md + skill-context name make targets; sweep check; CI runs make test-fleet); r3 verify next. |
| #292 fix/tmux-dead-pane-290 (tmux-290) | #290 | r2 fixes 427822d (previous-boot crash recovery, doctor .wslconfig + hook-script checks, launcher suite stubs systemd-run, AccuracySec); body rewritten; r3 next. needs-you has AJ's .wslconfig line. |
| #293 feat/resume-now-271 (resume-271) | #271 | r1 review not yet run. |
| #295 feat/agora-270 (agora-270) | #270 | r1 review not yet run; shot in shots/2026-11-03. |
| #230 fix/ask-217 (ask-217) | #217 | main merged (bd3e51a, hook conflict kept both); hook suite 569; needs a review round (none in the ledger); body says 515. |
| fix/watch-dead-288 (dead-288), stacked on #261 | #288 | after #261 merges: rebase, PR; note #296 also changes watch-panes.sh. |

## Parked
- #272 (resume-method experiment, design first).

## Notes
- Rule (#289, 11-03): tmux-spawning tests and multi-file shellcheck run under the heavy lock, timeout inside it.
- A suite section run alone: lines 1..91 + the section + the summary line (scratch t288.sh, t290.sh).
- Never nest a heredoc inside a python <<'EOF' edit: write the edit script with Write and run it.
- `gh pr edit` fails (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`.
- App crate needs GTK headers WSL lacks: test `-p klepsydra-fleet` with CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target.
- Cleaned 11-03: worktrees recover, impl-1029, impl-s9/s14/s16/s17; PR #228 closed (superseded).
