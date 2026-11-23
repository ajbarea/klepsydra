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

## Next
- CI (test-fleet has the new resume cases), wall browser suite locally, fresh-reader verify.

## Verify
- `bash hooks/test_fleet.sh` (610/0), `node --test src/*.test.js` (586/0), `make test-fleet`.
