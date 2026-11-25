# IMPL: fleet close refuses at-rest panes, the /exit menu wraps (#483)

Brief: fleet worker close-menu (task-close-menu.src). Branch fix/close-slash-menu, worktree
.claude/worktrees/close-menu. Push only `git push -u origin HEAD:refs/heads/fix/close-slash-menu`.
Do not merge: Heph reviews and merges. PR #496.

## Cause
- Typing /exit opens Claude Code 2.1.316's command menu over the transcript's last rows. At 84
  columns two descriptions wrap and main's filter refused every close; at 160 nothing wraps.

## Design
- close types `/exit ` (trailing space: no menu; Enter still exits, submit trims). The screen above
  the box must equal the pre-quiet-window screen byte for byte, after typing, after the settle and
  at the last look. If the menu opens anyway: check `menu`. back_out erases our /exit only.

## Done (11-20)
- Merged main (#500 screen_parse in lib.sh) at 3065376: CI green; suite 1018/0.
- Round 5 (fresh Opus): 0 Blocking; Should-fix = stale PR body (rewritten); minors fixed in
  95b1edc (menu check replayed on 16 real menu screens + 6 "/exit " screens; comment rename).
- Live proof (private socket, haiku, 2.1.316), branch: rest and 60-line reply closed at 84 and
  160; busy refused `busy`; background shell and wrap-up refused `session_file`. main: rest
  refused at 84, closed at 160. A close within seconds of a turn can refuse at quiet_screen when
  a usage notice vanishes (safe).
- ns477 (%48) and tech-labels (%4) panes were gone before a real close could be run.
- Suite on 95b1edc: one run failed only the keryx isolation check (keryx turned off mid-run,
  filed #516); rerun 1018/0.

- Review-batch3 (11-25): main merged twice (5774651, then after #497). Round 6 (fresh Opus):
  1 Should-fix: a refusal after AJ typed past our "/exit " kept "/exit " at the box's head
  without saying so; 1320a64 adds a note to the refusal and the #483 review 2 case checks it.
  Verify pass clean (551/0 to the end of the close section; the case fails without the note).
  Deferred Minors: type_exactly's and back_out's blind backspaces (sub-second race), no test
  that the note stays silent on a backed-out refusal.

## Next
1. 📋 CI on the final head green, then merge (review-batch3).
2. After merge (Heph): HEPH.md lines 14 and 19 still describe the pre-fix close (kill-pane advice).
