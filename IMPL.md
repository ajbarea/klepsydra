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

## Round 2 (fresh Opus reader) - IN PROGRESS, PARKED 11-23 for the Personal 5h reset
Commit "wip(fleet): r2" holds the structural fix, NOT yet green:
- checkpointed[] = "SID STAMP", persisted as resume-state field 12, removed from forget();
  cleared only by moved PANE NEW or a new session in the pane; relaunch gated on move_hold_ok;
  turn_done PANE [SID]; drawer cast only when id.voiceKey === s.pick.
- Isolated run of the #515 resume block: 9 pass, 6 FAIL. First pass sends no ask (0 0 wanted 1 0):
  something before the context block still returns on pass 1 (rc "on" was added; check what else,
  e.g. the Remote Control turn-on or another branch); with no ask, later cases cascade.
- Repro: S=/tmp/claude-1001/-home-ajbar-ajsoftworks/44c5c2dd-fed7-4f68-a74b-08c16458756e/scratchpad;
  sed -n '/^echo "#515: the context budget: checkpoint/,/^check "#515: the wall warns/p' fleet/test_fleet.sh | sed '$d' >$S/scen_r2.sh;
  flock -o /tmp/fleet-heavy.lock timeout 900 env SCEN=$S/scen_r2.sh bash $S/harness.sh
  (harness.sh = the suite header + helpers; `here=` points at this worktree).

## Next
1. Make the 6 cases pass (start with why pass 1 does not reach the context block).
2. hooks/test_fleet.sh (610/0 at abcf242) and node tests again; push; CI.
3. Fresh-reader round 3 with the open list above; rewrite PR body (claim drift); merge only when clean.

## Verify
- `bash hooks/test_fleet.sh`, `node --test src/*.test.js`, the isolated block above, then `make test-fleet`.
