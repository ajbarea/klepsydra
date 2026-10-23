# IMPL

Slice: #58 Wrap up. Branch feat/wrap-up, worktree `.claude/worktrees/wrap-up`,
stacked on feat/end-session (#22), which is stacked on feat/ledger-ui (#64).
Design: the 10-21 comment on #58 (`gh api repos/ajbarea/klepsydra/issues/58/comments`).

## Done (pushed, no PR yet)
- `hooks/klepsydra-wrapup.sh`: sync Stop hook (asks once per request via
  additionalContext, silent otherwise, fails open) and the reporter
  (`ready SESSION`, `blocked SESSION REASON`). Tests: `hooks/test_wrapup.sh`
  (47), in CI and skill-context.
- `hooks/klepsydra-wrapup.md`: the instructions, installed as the personal
  skill `~/.claude/skills/klepsydra-wrapup/SKILL.md` (`${CLAUDE_SESSION_ID}`).
- Launcher `wrapup` verb: Ctrl+C, type `/klepsydra-wrapup`, Enter only when
  the input line reads exactly that; refuses mid-turn (footer "esc to
  interrupt"). Shares `run_command` with `end`. test_launch.sh 157 pass.
- Fleet crate `wrapup.rs`: request/answer reading, `route(status, in_fleet)`,
  `start`/`cancel`/`mark_asked`/`unmark`; snapshot carries `wrapup` and each
  session's answer. 216 fleet tests.
- App: `start_wrapup`, `cancel_wrapup` commands (launch.rs). NOT yet built on
  Windows (interop was down).
- README: install block (`wrapup-settings` markers, tested).
- Wall UI (`src/fleet/wrapup.js`, wall.js/html/css): Wrap up… confirm grouped
  by route (ROUTES mirrors `route()`, guard parses both), card line in both
  densities, "N of M ready", Stop wrap-up, Safe to restart, End all ready
  sessions… through #22's one confirm (`openConfirm`) and per-card undo.
  `?demo&wrapup` sample (`scripts/fixtures/wrapup-demo.json`). README "Wrapping up".

## Next
1. After #64 and #22 merge: rebase onto main (`git rebase --onto origin/main <old base>`).
2. `build-windows.sh --check`, live test with two real sessions, PR (Closes #58),
   review, merge, deploy (copy script + skill, add Stop hook to both settings.json).

## Verify
- Full gate list in skill-context, plus `bash hooks/test_wrapup.sh`.
