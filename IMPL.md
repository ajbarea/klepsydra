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
  reports; idle with background work routes Type; marks first, parallel
  typing; End all ready re-checks readiness; restart warning; wrapup/ watched.
- Review round 3 fixed: a ready answer counts once the Stop hook settles it
  (the turn that gave it ended) and until the next turn (`turn_at`, which the
  fleet hook stamps on every prompt, notifications too), never while working
  or waiting; the launcher judges mid-turn by the line above the input box
  (2.1.302 spinner fixtures); Start over keeps a running ask; each session is
  re-read just before typing; the reader makes `wrapup/` and drops a request
  past its hour; prune never follows a symlinked folder.

## Next
- Round 3 was the last review round: CI, then merge on AJ's word.
- Deploy needs AJ's ok: copy `klepsydra-wrapup.sh` and the updated
  `klepsydra-fleet.sh` (it now stamps `turn_at`) to `~/.claude/`, the skill
  to `skills/klepsydra-wrapup/SKILL.md` in each config folder, the Stop hook
  block into both `settings.json`, and install the app build.

## Verify
- Full gate list in `.claude/skill-context.md`, plus `bash hooks/test_wrapup.sh`.
- `KLEPSYDRA_STAGE=klepsydra-build-wrap_up bash scripts/build-windows.sh --check`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
