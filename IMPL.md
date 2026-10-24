# IMPL

Slice: #58 Wrap up. Branch feat/wrap-up, worktree `.claude/worktrees/wrap-up`,
PR #82. Design: the 10-21 comment on #58.

## Done
- `hooks/klepsydra-wrapup.sh`: sync Stop hook (asks once per request through
  `additionalContext`, silent otherwise, fails open) and the reporter
  (`ready SESSION`, `blocked SESSION REASON`). `hooks/klepsydra-wrapup.md` is
  the skill, read from `${CLAUDE_CONFIG_DIR:-~/.claude}/skills/klepsydra-wrapup/`.
- Launcher `wrapup` verb: Ctrl+C, types `/klepsydra-wrapup`, Enter only when
  the line reads exactly that; refuses mid-turn; takes #22's pane lock, with
  its own refusal texts.
- Fleet crate `wrapup.rs` (request, answers, `route()`, start/cancel,
  create-only marks, `ask()`); app `start_wrapup` / `cancel_wrapup`.
- Wall: Wrap up… confirm grouped by route (`src/fleet/wrapup.js` mirrors
  `route()`, a guard parses both), card line, "N of M ready", Stop wrap-up,
  Safe to restart, End all ready sessions…. README "Wrapping up".
- Review round 2 fixed: answer times get the session files' clock
  correction and the script judges the request by the folder's clock; late
  reports from an asked session while the wall shows the request; idle with
  background work out routes Type; every Type session marked first, typed
  in parallel, unmark takes only its own mark; End all ready re-checks
  readiness at expiry and on every snapshot; restart warning; wrapup/ watched;
  result note counts only the asked and names failures.

## Next
- Review round 3 (independent, opus), CI, merge.
- Deploy needs AJ's ok: copy `klepsydra-wrapup.sh` to `~/.claude/`, the skill
  to `skills/klepsydra-wrapup/SKILL.md` in each config folder, the Stop hook
  block into both `settings.json`, and install the app build.

## Verify
- Full gate list in `.claude/skill-context.md`, plus `bash hooks/test_wrapup.sh`.
- `KLEPSYDRA_STAGE=klepsydra-build-wrap_up bash scripts/build-windows.sh --check`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
