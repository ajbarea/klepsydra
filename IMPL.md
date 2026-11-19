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
  transcript, input_text) and a bounded excerpt (5 lines x 120 chars), fingerprints, session brief;
  one-line error naming the check; `fleet close --why NAME`; `-h`.
- fake_pane.py draws the real menu (wrapped default, "wide"), `slash_after` stray line; tests.

## Next
- make test-fleet green; live proof (scratchpad proof.sh: rest/busy/bg/wrapup at 84 and 160);
  close the real ns477 (%48) with this worktree's close.sh; review round(s); PR; report to Heph.

## Verify
- `make test-fleet`; `uvx --from shellcheck-py shellcheck -x fleet/close.sh`.
