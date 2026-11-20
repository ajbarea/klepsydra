# IMPL: fleet close refuses at-rest panes, the /exit menu wraps (#483)

Brief: fleet worker close-menu (task-close-menu.src). Branch fix/close-slash-menu, worktree
.claude/worktrees/close-menu. Push only `git push -u origin HEAD:refs/heads/fix/close-slash-menu`.
Do not merge: Heph reviews and merges. PR #496.

## Cause (found 11-19)
- Typing /exit opens Claude Code 2.1.316's command menu over the transcript's last rows. At 84
  columns two descriptions wrap, and close's filter dropped nothing, so it refused every close.
  At 160 nothing wraps, which is why close-454 closed at 00:02.

## Design now (11-20, after independent round 3)
- Round 3 found that the old design (skip the menu block, refuse at `menu_gap` when a turn could
  hide in blank rows under it) left every gap-layout pane refused forever, and its error told the
  reader to type a bare /exit, the unchecked close menu_gap exists to stop.
- Live probe 11-20 (2.1.316, private socket, haiku): `/exit ` with a trailing space opens no menu,
  and Enter on it exits. Esc also dismisses the menu but would interrupt a turn that started, so not used.
- close now types `/exit `, and the screen above the box must equal the one read before the quiet
  window byte for byte (escapes kept). screen_lines, same_transcript and menu_gap are gone. Any menu,
  line or turn above the box is a refusal at `transcript`; nothing is hidden, so no gap case remains.
- Fixtures: fleet/tests/close-screens/space-{gap,short,full}-{84,160}-{before,after}.txt (captured
  11-20) all read same; the 16 old menu captures all read differs. fake_pane: the menu shuts on a
  space (`slash_menu_space` keeps it open, a refusal test); the arrival options apply with or without it.
- Kept from earlier rounds: per-check WARN logs with bounded excerpts, `fleet close --why NAME`,
  the 2 s settle re-read, last_look, the session-file fingerprint and orchestrator flag. Ctrl-D was
  rejected 11-19 (its second-press window is ~0.8 s).

## Next
1. 📋 make test-fleet green; mutants (no trailing space; no screen check) caught.
2. 📋 Live proof with the new code: scratchpad proof.sh (FLEET_SESSION=t) rest/full/busy/bg/wrapup at
   84 and 160.
3. 📋 Push, CI green (shellcheck SC2329/SC2034 in the look test fixed), PR body rewritten.
4. 📋 Round 4: a fresh Opus reviewer on the new design (reports/close-496-r4.md). Do not merge.
5. 📋 Report to Heph; `fleet done`.
