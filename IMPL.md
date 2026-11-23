# IMPL: #515 context budget: checkpoint and a fresh session at 300k tokens (PR #523)

Branch feat/context-budget-515 (agy's, reviewed and fixed by Opus agy-review-k 11-23).
Push: `git push origin feat/context-budget-515:feat/context-budget-515`. Never push to main.

## Done (Opus r1, on agy's 67f72a8)
- Blocking: `checkpointed` was never `declare -A`d, so `${checkpointed[%N]}` is an arithmetic
  syntax error that aborts the resume service on every idle registered worker (reproduced).
- Blocking: the hook's `if ($was | objects | ...)` yields empty when no file exists yet, so a
  session first seen mid-session was never written (14 hook tests red; main 606/0).
- Race: the relaunch fired on any finished turn after the ask, including the one the ask was
  typed at; now only when the turn stamp differs from the one asked at.
- The resume service reads `call_tokens` the hook records at Stop (one parser, `context_tokens`
  in the hook: byte-bounded tail, main thread only); lib.sh's transcript parser removed.
- The ask says what to do (IMPL.md, commit, push, end the turn).
- Wall: warn on the request size only (the session-total rule lit nearly every card);
  "305k context" names the number; neutral emphasis, not amber (needs you); a tooltip says why;
  a compact card keeps the size when warning. Budget parity test lib.sh <-> ledger.js.
- brief.sh: agy's rule warned on 123 of 133 real briefs ("the PR" counted as a repo). Now
  only names that are repos under FLEET_REPOS_ROOT: 14 of 133, each truly multi-repo.
- drawer.js (agy): kept; the old `id.voice === null` test was always false (voiceName is never null).

## Round 2 (fresh Opus reader): fixed
- checkpointed[] = "SID STAMP", resume-state field 12, out of forget(); cleared only by
  moved PANE NEW or a new session in the pane; relaunch gated on move_hold_ok and kept across a
  put-off or failed move (no second ask); turn_done PANE [SID]; drawer cast only when the card
  wore the pick (id.voiceKey === s.pick).
- Isolated #515 resume block 15/15 (each pass its own --once process, with a busy pass between
  ask and turn end); mutations killed: forget clears it (4 red), no load (7), no move_hold_ok (2),
  no session drop (1). hooks 610/0, node 586/0, shellcheck clean (reduced mode = main's findings).
- Tests need a warm-up pass: an idle pane's first pass turns Remote Control on and returns.

## Round 3 (fresh reader): one Should-fix, fixed
- A relaunch AJ undid (fresh rc 4) counted as one try (the other kinds: two), and rc 1 as a
  failure: the refusal rule is now one helper, move_refused, that back, pre, limit and context
  call (unit test over rc 1/3/4, plus a check that every kind calls it). A `held` ask is recorded.

## Next
1. Fresh verify pass on the round-3 fix; rewrite PR body (claim drift); CI; merge when clean.

## Verify
- Isolated block: sed -n '/^echo "#515: the context budget: checkpoint/,/^check "#515: the wall warns/p'
  fleet/test_fleet.sh | sed '$d' >scen.sh; SCEN=scen.sh bash harness.sh (suite header + helpers),
  under flock -o /tmp/fleet-heavy.lock. Then `make test-fleet`.
