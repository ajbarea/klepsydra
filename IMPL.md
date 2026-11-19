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

## Next
1. Review round 2 (fresh Opus) verdict; fix and verify-pass if it finds anything.
2. Open the PR (draft /tmp/claude-1001/close-menu-handoff/pr.md), assigned ajbarea, label bug, Fixes #483;
   CI green; report to Heph via `fleet send`; `fleet done`. Do not merge.
