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

## Next
- Final verify done on 1a32196: CI green; `make test-fleet` 962 passed, 1 failed (#273 keryx-config
  isolation: a live session's keryx off at 00:11:21Z wrote AJ's config mid-run; the suite's stubs never
  reach the daemon; friction.md line logged); section run 44/49, the 5 FAILs standalone-only (pass in the full suite).
- Reported to Heph; Heph runs a fresh Opus verify. Do not merge. Section runner fleet/.sec445.sh is untracked.

## Known residual
- A prompt that lands in the last ~0.1-0.3 s before Enter is not seen: spinner 60-104 ms, fleet file 140-255 ms, transcript 190-280 ms after submit (measured). /exit mid-turn ends the session at once.

## Verify
`make test-fleet`, `make shellcheck`; section run: lines 1-113 + 284 + done_live + the #445 section of fleet/test_fleet.sh.
