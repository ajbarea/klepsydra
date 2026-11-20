# IMPL: fleet close refuses at-rest panes, the /exit menu wraps (#483)

Brief: fleet worker close-menu (task-close-menu.src). Branch fix/close-slash-menu, worktree
.claude/worktrees/close-menu. Push only `git push -u origin HEAD:refs/heads/fix/close-slash-menu`.
Do not merge: Heph reviews and merges.

## Cause (found 11-19)
- Typing /exit opens Claude Code 2.1.316's command menu over the transcript's last rows. In an
  84-column pane, the /context and /usage-credits descriptions wrap onto lines indented to the
  description column (37). The old screen_lines only dropped `  /cmd` rows, so it dropped nothing,
  and same_transcript refused every close. At 160 columns nothing wraps, which is why close-454
  closed at 00:02. Replay: scratchpad st.sh on ns-before/after (84: differs) and live captures.
- Ctrl-D (option A) rejected: its "Press Ctrl-D again" window is ~0.8 s, too short to re-run the
  session-file and screen checks before the second press. Double Ctrl-D with a background shell
  shows the same stop-tasks dialog as /exit.

## Done
- close.sh: screen_lines drops exactly the menu block (❯ /exit row, entries in its description
  column, wrapped lines indented to that column); five mutated menus all still refuse.
- Each refusal: WARN log with check (busy, input_box, session_file, quiet_screen, fingerprint,
  transcript, input_text; also typing, lock, orchestrator) and a bounded excerpt (5 x 120 chars),
  fingerprints, session brief; one-line error naming the check; `fleet close --why NAME` (NUL-safe,
  rotated logs); `-h`.
- fake_pane.py draws the real menu (wrapped default, "wide"), overlaying exactly its rows;
  `slash_after` (stray line), `slash_hidden` (lines that scroll up under the menu); tests.
- Review round 1 (fresh Opus): nothing blocking; all 3 should-fixes + nits applied in commit 3:
  compare by row position only (no tail branch, no +1), FLEET_CLOSE_SETTLE (2 s) re-read of screen
  and session file before Enter, column off-by-one tests, NUL-safe --why. The reviewer's 9 scrolled
  screens (scratchpad rev/scroll*.txt) all refuse now; the three real captures all read `same`.

## Done 11-19 (fresh session, Personal)
- `make test-fleet`: 1003 passed, 0 failed (fixed the #445 orchestrator test, whose grep also counted the
  new WARN log echo; that refusal now logs check orchestrator).
- Live proof (scratchpad proof.sh; needs the trust dialog accepted and FLEET_SESSION set): 84 cols at rest
  closed; printing refused (busy); background shell refused (session_file, 1 shell); wrap-up continuation
  refused (busy); 160 at rest closed. main's close.sh at 84 at rest: refused "screen or box changed".
- Live finding: right after a turn Claude Code shows a "◐ medium · /effort" hint for a few seconds; a close
  then is refused at quiet_screen (safe), and the excerpt quoted only 5 blank lines. excerpt now counts
  blank lines and quotes the changed line first (test added).
- Real ns477 (%48) closed with this branch at 13:35.

## Review rounds 2 and 3 (fresh Opus each)
- Round 2: blank rows were dropped before the row compare, so a scroll under the menu could hide behind
  blank top rows (S1); no test pinned the row-position compare (S2); nothing isolated the settle re-read
  (N1); the box was not read again before Enter (N2). All fixed in cb1042c, with real captures in
  fleet/tests/close-screens/ replayed by the suite (no tmux).
- Round 3: S1's fix counted rows from strings that `$( )` had stripped of trailing blanks, so a resting
  pane with a blank row just above the menu was refused every time. Rows now come from the rule's
  position (above_rows); blankabove-84 fixture added. Comments on the 84-column busy check and the
  fingerprint's role corrected.

- Round 4: clean (19 adversarial screen pairs, the blankabove fixture pins the fix). Suite 1008/0; live rest
  closes at 84 and 160, mid-turn refused.

## Independent round 1 (Athena's Opus, 11-19 ~21:15; report reports/close-496-r1.md)
- Should-fix: a turn could land wholly under the 5-row menu in a 2-5 row gap a bottom-pinned box leaves
  under a short transcript. Now refused at check menu_gap (gap >= 2 and the transcript's last row at or
  past the compared rows). Replay matrix 84 (gaps 0-6) and 160 (1-4), the reviewer's gap screen, a live
  fake-pane test (`slash_fill`); mutant without the check closes the hidden turn (caught).
- Nits taken: last look also compares the screen with the settle window's; check= on every refusal
  (finished, pane_session, exit_dialog, exit_wait, typing, lock); the session file's .orchestrator flag
  is a second orchestrator guard; PR body current. Footer "← N agents" = agent-view sessions run by a
  separate supervisor (survive /exit): comment, no refusal. Nits 2, 5, 6 left (fingerprint backs 2;
  5 and 6 pre-existing).
- Suite 1014/1 locally: my new test's name collided with the `--why nobody` test; renamed to ghost.

## Independent round 2 (fresh Opus, 11-19 ~23:30; report reports/close-496-r2.md)
- Should-fix: menu_gap was one row short. Claude Code draws a blank row above every block, so a turn's
  first visible row is t+2; at t = m-1 (gap of menu rows + 1: 6 at 84 cols, 4 at 160) only the blank row
  shows. Now `t + 1 >= m`; matrices 84 (0-7, 6 gap) and 160 (1-5, 4 gap); comment corrected.
- Nit 1: the last look (busy, screen compare, box) was untested. Pulled into last_look(), replayed with a
  stubbed screen on bg-160-after: ok / busy / quiet_screen / input_text; each of the 3 mutants caught.
- Nit 2: docs/fleet.md names menu_gap, the orchestrator flag and every check. Nit 3: the menu_gap reason
  says it stays refused until the transcript grows, so close it by hand.
- Reviewer saw one flake in 7 slice runs (indented-38 case refused at quiet_screen, pane gone next case;
  stderr discarded). Not reproduced.

## Next (saved 11-20 for the account move; e912f2d pushed, make test-fleet 1016/0)
1. 📋 CI on e912f2d (was pending at the move); report to Heph (fleet send, else inbox/close-menu.md).
2. 📋 Round 3: a fresh Opus reviewer verifies the round-2 fixes (brief: diff e912f2d + reports
   close-496-r1.md and r2.md; write reports/close-496-r3.md). A round 3 started 11-20 was stopped
   unfinished at the account move, so rerun it. Do not merge.
3. 📋 `fleet done` once #496 is clean; #502 and techne #387 are green and wait on Heph.
