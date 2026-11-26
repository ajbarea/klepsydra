# IMPL: #416 agy cards read silent (PR #563, branch agy/silent-416-r2)

Issue: https://github.com/ajbarea/klepsydra/issues/416. Supersedes #508.
Opus redesign at the free-engine cap; spec: the 9 findings in
https://github.com/ajbarea/klepsydra/pull/563#issuecomment-7173164692

## Slice
agy has no status line and lists no background work, so the resume service
gives it a heartbeat from screen progress and reads its tasks from the
pane's live child shells. Claude's readings stay as on main.

## Done (11-26)
- B1: `shells_live` is agy's crew in `view.rs` and in lib.sh's `turn_done`,
  `turn_settled`, `pane_background` (shared `CREW_JQ`, `AGY_IDLE_JQ`); a Rust
  test parses the exact JSON the service writes.
- B2: the extglob squeeze is gone; `screen_progress` is one bash pass over
  `SCR_PLAIN`'s lines. Real captures 2.6/3.2/5.0 KB: old 14.4/30.8/138.7 s,
  new 7/6/9 ms; a 300x80 timing check in `fleet/test_forks_screen.sh`.
- S3/S4: the no-child rule and the Done-not-Silent exemption are agy-only, in
  the hook and `view.rs`; Claude cases on both sides.
- S5: progress reads the plain screen less spinner, cue and usage lines;
  seeded property test (60 redraws, 60 one-char edits) + real agy fixtures.
- S6: only bash/zsh/bwrap children count; agy starts MCP servers as npm, uv
  or node, so no cmdline match is needed.
- S7: the service takes the hook's lock (lock_dir block shared with the
  hooks since #517) and re-reads the file under it.
- S8: agy rules run every pass; only the beat waits on a screen change.
- S9: idle comes from `eng_state agy`.
- The last progress per pane persists in `$FLEET_STATE/screens/` (a restart
  never beats a frozen screen); closed panes' files are pruned.
- Review r1 (fresh Opus, on 6d7a81c): 1 Blocking, 2 Should-fix, fixed:
  `eng_state agy` reads agy 1.5.17's status-line footer (spinner or running
  task line = busy), fed the plain screen; a known Claude pane forks nothing
  (strace test); calls recounted under the lock; empty pane list prunes
  nothing; statusline name fallback dropped, hook registry read builtin;
  `live_shells` array renamed (`callers`); resume-at-reset.sh finds its
  folder from BASH_SOURCE so sourcing it never runs a pass. Mutants: no fast
  path, no status-line footer: each red.
- Review r2 (on 78060e0): 1 Should-fix (vacuous-guard): the fast path's
  `ended` test never matched the hook's `{reason, at}` object. Now the fast
  path holds only while the pane's Claude process (pid + start, read from
  /proc, no fork) runs; tests: still running = not looked up, gone = looked up.
- Review r3 (on a781016): the r2 fix holds and opened nothing new; 1
  Should-fix (test only): the cache was hand-filled in every test. Now the
  first pass fills it from a session file in the hook's format, and the fork
  count is 3 passes less 1; deleting the fill line turns both red.

## Verify
- `make test-delegate` (takes the heavy lock)
- `bash fleet/test_forks_screen.sh`
- `make test-fleet FLEET_SHARD=resume` (takes the heavy lock)
- `flock -o /tmp/fleet-heavy.lock timeout 1500 bash hooks/test_fleet.sh`
- `cd src-tauri && cargo test -p klepsydra-fleet view`

## Next
1. 📋 Verify pass clean (its strace guard added: a no-trace strace now fails), CI green, merge,
   then `fleet install` (touches hooks and fleet scripts).
2. Follow-up: one shared copy of `live_shells` with the hooks-common work.
