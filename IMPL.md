# IMPL: klepsydra#445 + #446: `fleet done "REPORT"`, `fleet close`, queued sends

Branch feat/fleet-done-report-445, PR #454. Issues: #445 (and its comment), #446. Follow-up: #468.

## Slice
1. `fleet done [NAME] "REPORT"` sends REPORT to orchestrator.pane; undelivered = queue-file line + done-reports.tsv row + doctor warn.
2. `fleet close NAME` (close.sh) closes a finished agent's pane only once it is confirmed at rest; doctor flags a pane done and unread > 30 min.
3. `deliver_now` (lib.sh) prints `queued` on Claude Code's queue line and `sent` for a pane that closed after /exit.

## Done
- Rounds 1-4 (Sonnet author): see git log.
- Round 5 (Opus author), round-4 verify findings:
  - B1: `wrapup_pending` (lib.sh) refuses while the wall's wrap-up is asked or answered-unsettled for the request on file; close also waits FLEET_CLOSE_QUIET (6 s) with the raw screen above the box and the session file both unchanged.
  - S1: /exit is typed, file + screen + box re-checked (the slash menu Claude Code draws over the transcript's last rows is allowed for), then Enter. close never kills: Claude Code's "Background work is running" dialog is cancelled with Esc; a pane still there after 30 s is reported, left open, record kept.
  - Nit: refused when the session file was last written before the pane's process started.
  - Mirror: `turn_done`, `watchers_only`, `ready_to_move` also hold on `wrapup_pending`; the quiet window and no-kill retire for those paths are #468.
- fake_pane.py: `exit_dialog`, `slash_menu`, `slash_adds`.
- Mutation checked: each #454 test fails on a5ec5fc's close.sh/lib.sh; `steady` and `same_transcript` stubbed true each fail their test.
- Live, private socket close454-live, haiku 2.1.316: (a) printing turn refused 33/33; (b) wrap-up continuation refused throughout (5 reads with file done + asked); (c) dialog cancelled, shell kept; (d) closed at rest (twice, short and full screen).

- Round 5 verify (Heph, fresh Opus): clean on Blocking; two vacuous guards fixed in tests:
  the S1 file-write test now greps `written within` and asserts /exit was never typed (fake_pane
  `log_typed` logs TYPED runs); new cases: settled + quiet with text in the box, and with a menu where
  the box was, both refused. Mutation: deleting close.sh's fingerprint line (145) or idle_empty line
  (140) turns its test red. #468 gained the other-Stop-hooks line.

- Heph's final verify at 6011263: CLEAN. Rebased on origin/main (b361220: #463, #465, #466); README
  and docs/fleet.md conflicts resolved to main's structure (README rows short, depth in docs/fleet.md,
  close row corrected to never-kill); IMPL kept. fleet/ vs 6011263 = main's lines only (close.sh,
  done.sh, lib.sh identical). Nit: stdin case uses TMUX_PANE=%99999, never the orchestrator's.

## Next
- CI green on the rebased head, report to Heph (fleet send %36), fleet done. Heph merges; do not merge.
- Section runner fleet/.sec445.sh is untracked (rebuilt for the rebased line numbers).

## Known residual
- A prompt that lands in the last ~0.1-0.3 s before Enter is not seen: spinner 60-104 ms, fleet file 140-255 ms, transcript 190-280 ms after submit (measured). /exit mid-turn ends the session at once.

## Verify
`make test-fleet`, `make shellcheck`; section run: lines 1-113 + 284 + done_live + the #445 section of fleet/test_fleet.sh.
