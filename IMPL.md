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
- Committed 49b1691 + this IMPL; pushed. NOT yet run on the final close.sh: the section run (the last
  edit tightened `exit_dialog` to the dialog's own shape) and `make test-fleet`. Run both, then CI green.
- Section runner (untracked, rebuild if missing): fleet/.sec445.sh = test_fleet.sh lines 1-113, a
  `mkdir -p "$FLEET_STATE/log"` line, line 284 (LIMIT), the done_live def (~2035-2036), and the
  "fleet done reports the finish" section through its `: >"$REGISTRY"; rm -f ...` line, then the pass/fail
  tail. Its 5 doctor/wrk2 FAILs are standalone-only (the doctor stubs live elsewhere in the suite).
- Then: PR body from the draft below (short top already written in round 5 plan), report to Heph via
  `fleet send` (else inbox/close-454.md), queue line, `fleet done "REPORT"`. Heph runs a fresh Opus verify; do not merge.
- PR body draft: why/what table as before; Status table of live results (a) refused 33/33, (b) refused
  throughout incl. file done + wrapup asked, (c) dialog cancelled + shell kept, (d) closed; depth in
  <details>: decision steps, mutation checks, latency numbers, sources (mcp-tmux tmux_wait_for_idle,
  twmux, Claude Code hooks reference), rounds 1-4 design notes.

## Known residual
- A prompt that lands in the last ~0.1-0.3 s before Enter is not seen: spinner 60-104 ms, fleet file 140-255 ms, transcript 190-280 ms after submit (measured). /exit mid-turn ends the session at once.

## Verify
`make test-fleet`, `make shellcheck`; section run: lines 1-113 + 284 + done_live + the #445 section of fleet/test_fleet.sh.
