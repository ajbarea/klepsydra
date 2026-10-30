# IMPL: klepsydra fleet-module brief, resume state 2026-10-30 evening

Session 7 (since 10-29 21:11) moved to RIT at Heph's request; the next session resumes here.
Resume from this file, `git log`, the PRs below and their comments. Brief: task-fleet-module.src.

## Merged this session
- #191, #190, #192 (Agora part 1), #194, #195 (#149 folder and GitHub links, 10-30). Lows recorded on #149, #167, #185, #205.

## Open PRs (each round is a fresh opus reviewer given the diff + open findings)
| PR | Issue | Worktree (.claude/worktrees/) | State |
|---|---|---|---|
| #214 | #213 clock (main's suite red since 10-30) | clock-213 | round 5 fixed (4e3cae6), suite 324/0; **round 6 must be run again** (stopped at the move). Destructive: review until clean. Merge FIRST, before 2026-11-01's clock change |
| #196 | #170 CI triage on the account with room | triage-170 | clean (round 5); merge after #214 |
| #207 | #185 Agora part 2 | agora-wall | clean (round 2); merge after #214 |
| #210 | #208 Fleet health | health-208 | clean (round 2); merge after #214 |
| #211 | #183 Voices | voices-183 | clean (round 3); merge after #214 |
| #206 | #198 move-back with background work | moveback-198 | clean (round 5 verify); merge after #214 |
| #212 | this IMPL | impl-1029 | docs |

Every branch except #214 fails the same 11 clock checks (long-idle and resume-review sections) until #214 is in main; `git merge-tree` shows no conflicts with clock-213. After #214 merges: `gh api -X PUT repos/ajbarea/klepsydra/pulls/N/update-branch` for each, wait for green, re-read comments, squash-merge.

Review notes: /tmp/claude-1001/-home-ajbar-ajsoftworks/7ca80650-7c23-4a2a-9c12-f369616daae2/scratchpad/ (r214b..r214e hold the sweep harness: r214e/worker.sh with fn_r5.sh, nows_run.txt; r206..r206e, r210b, r211b/c, r207b).

## After merges (deploy)
1. In the main checkout: `git pull`, `fleet cutover` (#206, #210's fleet-doctor timer, #214), `make install-fleet`, `fleet doctor`.
2. Windows build (scripts/build-windows.sh) for #190, #191, #194, #195, #207, #210, #211; reinstall; click a card's GitHub mark once and check the `open github` log line (#195).

## Next after the open PRs
#185 part 3 (Ledger measured friction), #154 wall Recover button, #158 `--apply`, #150 (research done: portable-pty + xterm.js, a grouped tmux session), #157 part 3, #163 phone push, #204 demo mode, #215 (Heph moving back with a watcher).

## Notes
- `gh pr edit` fails on klepsydra (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`. Issue Types are not enabled on this repo; labels stand in.
- `fleet/test_fleet.sh` takes about 19 min: `flock /tmp/fleet-heavy.lock timeout 1800`. For mutation checks use a cut-down runner (lines 1-66 plus the section under test).
- The app crate needs GTK headers WSL lacks: lint/test `-p klepsydra-fleet` with CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target; CI builds the app.
- shellcheck: `uvx --from shellcheck-py shellcheck -x fleet/*.sh fleet/fleet hooks/*.sh`. `receiver::bad_paths_bodies_and_sizes_get_their_status` flakes under load (#174).
- Never nest a heredoc's own EOF inside another heredoc: write the edit script to the scratchpad first.
