# IMPL: klepsydra#445 + #446: `fleet done "REPORT"`, `fleet close`, queued sends

Branch feat/fleet-done-report-445. Issues: #445 (and its comment), #446.

## Slice
1. `fleet done [NAME] "REPORT"` sends REPORT to orchestrator.pane (fleet send handling); no report = refused; undelivered = queue file Running now line + done-reports.tsv row + doctor warn. brief-tail.md closes with the one line.
2. `fleet close NAME` (close.sh) calls `retire`; doctor flags a pane done and unread > 30 min.
3. `deliver_now` (lib.sh; the issue calls it wait_sent) prints `queued` on Claude Code's queue line and `sent` for a pane that closed after Enter.

## Done
- Steps 1-3 written (done.sh, close.sh, lib.sh queue_note/took_enter, doctor.sh, send.sh, brief-tail.md, README).
- Tests added in fleet/test_fleet.sh (two new sections), fake_pane.py `queue` mode.

## Next
- Green `make test-fleet`, `make shellcheck`, `make test-launch`, repo lint; `fleet brief --check`.
- Live run on `tmux -L scratch445`; PR (label enhancement, assignee ajbarea); CI; report to Heph.

## Verify
`make test-fleet` (takes the heavy lock itself), `make shellcheck`, live scratch-socket run.
