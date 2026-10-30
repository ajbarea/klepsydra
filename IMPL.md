# IMPL: klepsydra fleet-module brief, resume state 2026-10-29 20:45

Session 6 (RIT) picked up at 19:52 from session 5. Resume from this file, `git log`, the PRs
below and their comments. Brief: task-fleet-module.src. Doctor clean at 19:57.

## Open PRs (each review round is a fresh opus reviewer given the diff + open findings)
| PR | Issue | Worktree (.claude/worktrees/) | Next |
|---|---|---|---|
| #190 | #182 Split on a hand snap | split-182 | Windows build fixed (e8049c7, CI green); verify pass running |
| #191 | #172 Heph's face reserved | heph-face-172 | /clear rule kept on later events (dedfa8f, mutation-checked); verify running; CI rerun (midnight flake #201) |
| #192 | #185 Agora part 1 | agora-185 | round 3 fixed (identity guards tested, all 8 mutation-red); needs round 4 |
| #194 | #167 shell count | shells-167 | round 3 fixed (268536d: sh/dash wrappers and zombies not counted, Stop's list stands); needs round 4 |
| #195 | #149 folder + GitHub links | links-149 | round 1 fixed (ad374a5); needs round 2 |
| #196 | #170 CI triage on the account with room | triage-170 | round 1 fixed (622d9ea); needs round 2 |
| #202 | #201 ledger test fails at UTC midnight | flake-201 | test-only; reproduced at 23:59:06 and fixed; merge on green |
| (to open) | #198 move-back with background work | moveback-198 | ask READY-TO-MOVE, move on the reply; fleet suite running; body in scratch |
| techne#251 | techne#229 body budget gate | techne worktrees/body-gate | round 1 fixed (553df87, CI clean); needs round 2 |

## After merges (deploy)
1. `git pull` in the main checkout, `fleet cutover` (resume-at-reset changes in #197, #198), `make install-fleet` (agora.py in #192), `fleet brief --refresh` (#192 adds a brief-tail line), `fleet doctor`.
2. Windows build (scripts/build-windows.sh) for #190, #191, #194, #195; reinstall.
3. techne#251: update the plugin, switch `block_long_bodies` on in both config folders.

## Next after the open PRs
#185 parts 2-3, Fleet health on the wall, #154's wall Recover button, #158 `--apply` at the morning rewrite, #150 (research UX first), #157 part 3, the #183 Voices setting, #163 phone push.

## Notes
- PRs on klepsydra: `gh pr edit` fails (Projects classic); use `gh api -X PATCH repos/.../pulls/N -F body=@file`. Issue types do not exist on this user-owned repo; labels carry the type.
- `fleet/test_fleet.sh` takes over 15 min: give it `timeout 1800`.
- Squash with `git reset --soft $(git merge-base HEAD origin/main)`, never onto origin/main directly (#195 round 1 reverted #188 that way).
- Heavy runs under `flock /tmp/fleet-heavy.lock`.
