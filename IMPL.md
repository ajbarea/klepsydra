# IMPL: klepsydra fleet-module brief, resume state 2026-11-03 01:00 (EST)

Session 18 (Chronos, fresh on Personal = `~/.claude-rit`) replaced session 17. Resume from this file,
`git log`, open PRs and their comments, and the klepsydra line under "Running now" in
/mnt/c/Users/ajbar/fleet-briefing/queue.md. Brief: task-fleet-module.src (its last "11-02 18:00 Heph"
line sets the order).

## Merged (session 18, not yet deployed)
#283 (#269 `fleet done`), #285 (#274), #286 (#276 Needs you + Queue). Deploy once #257 merges:
`git -C ~/ajsoftworks/klepsydra pull`, `make install-fleet`, `fleet brief --refresh` (#283's tail rule),
`fleet doctor`; then `bash ~/.claude/klepsydra-fleet.sh queue set /mnt/c/Users/ajbar/fleet-briefing/queue.md --by "Heph (orchestrator)"` (#286).
#286's Windows app build is AJ's app update (`scripts/build-windows.sh` is not for agents).

## In flight
| PR / branch | Issue | State |
|---|---|---|
| #257 fix/install-nits-244 | #244 nits | rebased on #283 + #285 (install.sh SCRIPTS conflict: kept done.sh and voices.sh); CI running. Merge on green. |
| feat/orch-guard-264 (worktree guard-264) | #264 | built: fleet/orch-guard.sh + orch_guard_parse.py + test_orch_guard.sh (75/0) + tests/orch_parse_differential.py (0 missed). Opus reader round 1 running; full fleet suite running (scratchpad fleet-264.log). Then /code-review medium, PR, CI, merge. Deploy adds the PreToolUse entry (README "Orchestrator guard") to ~/.claude/settings.json, then `fleet accounts sync`. |

## Next (in order, from the brief)
#261 (PR, CONFLICTING: rebase), #229 (uncommitted review fixes in worktree focus-216); then #271, #270, #272.

## Notes
- #264 design: the guard never models bash (a shlex reading disagreed with bash on 72/300 generated
  commands); it over-approximates so doubt lands on refusing. The two "ask first" guards deny with an
  ORCH_GUARD_ALLOW override instead of a prompt: a prompt in an unattended orchestrator stalls the fleet.
- `stopped_at`, `clock` and `FRESH_AFTER_S` moved from resume-at-reset.sh to lib.sh (shared by the guard).
- Running only part of fleet/test_fleet.sh: lines 1..N plus the summary under `flock -o /tmp/fleet-heavy.lock`;
  standalone sections: briefs, reset times, doctor, recover, fleet voices, relaunch.
- CI runs `ruff check` only; shellcheck covers fleet/*.sh fleet/fleet hooks/*.sh (WSL: `uvx --from shellcheck-py shellcheck`).
- Subagent briefs must state: any rm with a variable uses `rm -rf -- "${S:?}/${m:?}"`.
- `gh pr edit` fails here (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`.
- App crate needs GTK headers WSL lacks: test `-p klepsydra-fleet` with
  CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target; CI builds the app.
- Plugin marketplace refresh fails under CLAUDE_CONFIG_DIR=~/.claude-rit: refresh with `env -u CLAUDE_CONFIG_DIR`.

## Cleanup held (check each before deleting)
- worktrees impl-1029, recover (1 uncommitted change), split-182 (cargo target dir); branch
  docs/impl-late-1029; remote branch docs/brief-no-public-asks. Merged this session: done-269, relaunch-274,
  panels-276 (remove after checking nothing unpushed). IMPL branches impl-s9..s17 superseded by this one.
