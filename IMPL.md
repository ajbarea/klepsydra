# IMPL: #516 keryx isolation check tells AJ's toggle from a leak (PR #519)

Branch fix/keryx-isolation-516 (agy's, reviewed and fixed by Opus agy-review-k 11-23).
Push: `git push origin fix/keryx-isolation-516:fix/keryx-isolation-516`. Never push to main.

## Done
- agy: skip the #273 check when daemon.log has any quit line in the run window.
- Opus r1: that skip also hid a real leak (a case running `fleet voices off` writes the same quit).
  Now a skip needs all of: only `enabled` differs from a copy taken at the start, the file still
  parses as an object, and the daemon's own `quit requested` line within 5 s of the file's mtime
  (`keryx off` writes config.json, then sends quit). Stale ~/.cache/keryx path dropped (unused since 11-02).
- 9 cases, each guard mutation-checked (5/5 red); real daemon.log finds the 11-20 15:50:17Z quit.
- Opus r2 reader: code mergeable. Its minors fixed: the log is read line by line (a non-JSON
  line no longer ends the read; `first()` instead of head), and only a toggle OFF (enabled now
  false) is skipped. 11 cases, new guards mutation-checked. Deferred: exporting XDG_CACHE_HOME
  suite-wide (doctor reads it; needs its own full-suite run).

## Next
- CI green, fresh-reader verify, merge (restore main's IMPL.md first).

## Verify
- The #516 block alone: extract check(), keryx_quit_event, check_keryx_isolation and the
  "keryx isolation check (#516)" block into one script (see the PR), `bash` it.
- Whole suite: `make test-fleet` (takes the heavy lock itself).
