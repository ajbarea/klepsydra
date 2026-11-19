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

## Next
1. `make test-fleet` on commit 3 (a run was cut short by the account move; earlier run never ran).
2. Live proof: scratchpad proof.sh (`flock -o /tmp/fleet-heavy.lock bash proof.sh fleet/close.sh 84
   rest busy bg wrapup`, then `... 160 rest`). If the scratchpad is gone: private socket
   `tmux -L closefix-$$`, KLEPSYDRA_DIR + FLEET_STATE + FLEET_LOG in a scratch dir, KLEPSYDRA_AGENT
   unset, `claude --model haiku --settings '{"autoMemoryEnabled": false}'`, finished.tsv row
   `PANE\tNAME\t/dev/null\tSID\tDIR\tCFG\tDATE`, run `bash fleet/close.sh NAME`; wrap-up case:
   write `$KLEPSYDRA_DIR/wrapup/request.json` {"id":"<ms>","until":<now+900>,"ids":["SID"]}.
3. Close the real ns477 (%48) with this worktree's close.sh (`bash fleet/close.sh ns477`).
4. Fresh Opus review round 2 on commits 1..3 with round 1's findings; then open the PR (draft
   body: fill the results table), assigned ajbarea, label bug, `Fixes #483`; CI green; report
   to Heph via `fleet send`; `fleet done`. Do not merge.
- Friction to log: fleet.log contains NUL runs (line ~328), so plain grep calls it binary.
