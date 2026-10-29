# IMPL: klepsydra fleet-module brief, resume state 2026-10-29 ~15:00

Order (brief): #159 -> techne#227 -> #162 -> #161 -> two accounts -> techne#241 -> techne#229
-> #154/#158 -> #148 -> #149 -> #150; plus #157, #167, #173.
Session 3 (10-29 10:30, Personal account) replaced the one that hit the RIT limit.

## Merged and deployed
- #159 (#160), techne#227 (#232), #162 parts 1-2 (#164), #161 fleet engine, #165 two accounts,
  #166 account chip. Cut over 10:11; old scripts in archive/fleet-scripts-20261029 (delete after 11-05).

## Open PRs (all in review; each round is a fresh opus reviewer given the diff + open findings)
- techne #247 secret gate (#241 part 1), branch feat/secret-gate: rounds 1-4 fixed, round 5
  verify clean; nit fixes 87d3b3f+815d567 in a last verify pass. Then merge, update the plugin,
  switch `block_secrets` on in both config folders (accounts-sync keeps them equal).
- techne #248 security floor, sisters check 17 (#241 part 2), branch feat/security-floor: needs
  review round 1. After merge: one PR per repo for the gaps it reports (10 repos lack zizmor;
  ajbarea.github.io ci.yml lacks permissions:). papers/askesis private scanning = AJ's call.
- klepsydra #171 recover/shots/sync (part of #154, #158), branch feat/recover: rounds 1-4 fixed
  (b057b9a, 223 fleet checks); round 5 next. After merge: `make install-fleet`, `fleet cutover`,
  `fleet brief --refresh`, `fleet doctor`.
- klepsydra #168 characters (#148), branch feat/cast-picks: round 4 redesign 0cd0a6e (the crate's
  picks.rs assigns and keeps picks; Ledger day.picks); round 5 (last) running. After merge:
  Windows build (scripts/build-windows.sh) for #166 + #168.

## Next
1. #173 Heph moves at a limit (AJ 10-29): the resume service moves Heph FIRST (fresh session on
   the other account from HEPH.md + AJ's messages, recover's handoff), then the workers itself;
   Heph's note lists what moved (from the log). Design + sources on the issue comment. Needs #171.
   Warm standby Heph held: only if move timings show cold starts are slow.
2. techne#229 length + plain-language gate on issue/PR bodies.
3. Fleet health on the wall (4b), #162 follow-up (one CI line per branch), #149, #150 (research UX
   first), #157 part 3 (Heph rotation), #167 (bash counted as shells).
4. Follow-ups from reviews: recover launches Heph last (memory HOLD risk, consider first);
   #154 wall Recover button; #158 next Review issue + `fleet shots --apply` at the morning rewrite.

## Notes
- PRs on klepsydra: `gh pr edit` fails (Projects classic); use `gh api -X PATCH repos/.../pulls/N -F body=@file`.
- Heavy runs under `flock /tmp/fleet-heavy.lock`; never edit test_fleet.sh while it runs (bash reads it live).
