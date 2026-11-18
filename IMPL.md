# IMPL: klepsydra#445 + #446: `fleet done "REPORT"`, `fleet close`, queued sends

Branch feat/fleet-done-report-445. Issues: #445 (and its comment), #446.

## Slice
1. `fleet done [NAME] "REPORT"` sends REPORT to orchestrator.pane (fleet send handling); no report = refused; undelivered = queue file Running now line + done-reports.tsv row + doctor warn. brief-tail.md closes with the one line.
2. `fleet close NAME` (close.sh) calls `retire`; doctor flags a pane done and unread > 30 min.
3. `deliver_now` (lib.sh; the issue calls it wait_sent) prints `queued` on Claude Code's queue line and `sent` for a pane that closed after Enter.

## Done
- Steps 1-3 written and tested; PR #454 open (label enhancement, assignee ajbarea).
- Opus review round 1 fixed: queue file rewritten under a lock by atomic rename, queue note read only near the box, pane-gone `sent` only for /exit, no self-send, arity guards, pending row before the send, close says "left open" for a reused pane.
- CI fix: locale-independent excerpt in the queue-line test.
- `make test-fleet` 940 passed (LC_ALL=C), `make shellcheck` clean, live scratch-socket run done.

## Next
- Wait for CI on the pushed head; send the report to Heph; `fleet done "REPORT"`.
- Open: the queued screen shape is from the issue text, not a real capture.

## Verify
`make test-fleet`, `make shellcheck`, scratchpad live445.sh.
