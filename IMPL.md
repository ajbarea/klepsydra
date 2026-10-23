# IMPL

Slice: #58 Wrap up. Branch feat/wrap-up, worktree `.claude/worktrees/wrap-up`,
on main (after #22, PR #70). Design: the 10-21 comment on #58.

## Done
- `hooks/klepsydra-wrapup.sh`: sync Stop hook (asks once per request through
  `additionalContext`, silent otherwise, fails open) and the reporter
  (`ready SESSION`, `blocked SESSION REASON`). `hooks/klepsydra-wrapup.md` is
  the skill (`~/.claude/skills/klepsydra-wrapup/SKILL.md`).
- Launcher `wrapup` verb: Ctrl+C, types `/klepsydra-wrapup`, Enter only when
  the line reads exactly that; refuses mid-turn; takes #22's pane lock.
- Fleet crate `wrapup.rs` (request, answers, `route()`, start/cancel/mark);
  app `start_wrapup` / `cancel_wrapup` (per-session pane gate).
- Wall: Wrap up… confirm grouped by route (`src/fleet/wrapup.js` mirrors
  `route()`, a guard parses both), card line, "N of M ready", Stop wrap-up,
  Safe to restart, End all ready sessions… through #22's one confirm and
  per-card undo. `?demo&wrapup` sample. README "Wrapping up".
- Live (Claude Code, throwaway session, project-only settings, private
  `KLEPSYDRA_DIR`): the Stop hook made the session checkpoint, commit and
  report `ready`; asked once.

## Next
- PR (Closes #58), independent review (opus, at most 3 rounds), CI, merge.
- Deploy needs AJ's ok: copy `klepsydra-wrapup.sh` to `~/.claude/`, the skill
  to `~/.claude/skills/klepsydra-wrapup/SKILL.md`, the Stop hook block into
  both `settings.json` (`~/.claude`, `~/.claude-personal`), and install the
  app build.

## Verify
- Full gate list in `.claude/skill-context.md`, plus `bash hooks/test_wrapup.sh`.
- `KLEPSYDRA_STAGE=klepsydra-build-wrap_up bash scripts/build-windows.sh --check`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
