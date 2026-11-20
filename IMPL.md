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

## Next
1. ✅ PR #496 open (Fixes #483). 11-19 evening: CI went red on shellcheck SC2030/SC2031 after the main merge
   (the scroll replay loop's `b` shadowed the pane's `b`); renamed to `fn` in 3de0833, both replay checks
   re-run standalone (5 same, 10 differs).
2. ✅ CI green on dd0e926; reported to Heph 11-19 19:43. Do not merge.
3. 📋 `fleet done` once #502 (klepsydra CI) and techne#386 are through (their IMPL.md files on ci/best-practice).
