# IMPL: klepsydra fleet-module brief, resume state 2026-10-29 19:45

Session 5 (Personal) ends here for the move back to RIT; the next session resumes from this file,
`git log`, the PRs below and their comments. Brief: task-fleet-module.src.

## Merged and live (main checkout pulled, `fleet cutover` run, doctor clean)
- #186 (#180) CI reds to the agent on the branch and to Heph; HEPH.md explains the `CI HEPH` / `CI ESCALATE` watcher lines.
- #188 (#183 part) workers start with keryx off (worker-settings env). The wall's Voices setting on #183 is still open.
- #189 (#187 P0) moves side by side (two at a time), 120 s launch cap, failed move retried next pass, pre-move at 95%.

## Open PRs (each review round is a fresh opus reviewer given the diff + open findings)
| PR | Issue | Branch / worktree (.claude/worktrees/) | Next |
|---|---|---|---|
| #197 | #187 nits | fix/move-nits-187 / move-fix | verify pass was running at handoff; merge when clean + CI green |
| #190 | #182 Split on a hand snap | feat/split-autocheck-182 / split-182 | round 2 fixed (c593cf5); verify pass was running |
| #191 | #172 Heph's face reserved | fix/heph-face-172 / heph-face-172 | round 2 fixed + rebased (fbbb274); verify pass was running |
| #192 | #185 Agora part 1 | feat/agora-185 / agora-185 | round 2 fixed (a06d2d1); needs round 3 |
| #194 | #167 shell count | fix/shells-167 / shells-167 | round 2 fixed (1fe822f); needs round 3 |
| #195 | #149 folder + GitHub links | feat/card-links-149 / links-149 | round 1 review was running |
| #196 | #170 CI triage on the account with room | fix/triage-account-170 / triage-170 | round 1 fixed (622d9ea); needs round 2 |
| techne#251 | techne#229 body budget gate | techne feat/body-gate / techne worktrees/body-gate | round 1 fixed (553df87, CI clean); needs round 2 |

Reviewer results that arrive after this file are appended below under "Late results".

## After merges (deploy)
1. `git pull` in the main checkout, `fleet cutover` (resume-at-reset changed: #197), `make install-fleet` (agora.py in #192), `fleet brief --refresh` (#192 adds a brief-tail line), `fleet doctor`.
2. Windows build (scripts/build-windows.sh) for #190, #191, #194, #195 (Rust and hook changes); reinstall.
3. techne#251: update the plugin, switch `block_long_bodies` on in both config folders.

## Next after the open PRs
#185 parts 2-3 (wall/phone Agora panel with reactions; Ledger measured friction), Fleet health on the wall, #150 (research UX first), #157 part 3, the #183 Voices setting.

## Notes
- PRs on klepsydra: `gh pr edit` fails (Projects classic); use `gh api -X PATCH repos/.../pulls/N -F body=@file`.
- Heavy runs under `flock /tmp/fleet-heavy.lock`; another agent's pytest held it for long stretches on 10-29, so CI carried the suites.
- 10-29 16:50 incident (#187): the new session drew the pasted brief but took no key for 9 min; launch.sh now logs took_s per step.
- The launcher test "end: the process is gone" flakes in CI under load (#134); rerun the failed job.

## Late results
- #195 round 1 (19:55): two Blocking, both fixed in ad374a5 (rebased, one commit): the branch had reverted #188 (a squash onto a newer main; restored), and `wsl.exe -e explorer.exe` finds no explorer on the relay's PATH (now `-e env -C DIR explorer.exe .`, which also reports a folder that is gone). Phone no longer gets `where.dir`. Needs round 2. Lesson: squash with `git reset --soft $(git merge-base HEAD origin/main)`, never onto origin/main directly.
- #197 (#187 nits) reviewed clean, merged and cut over 19:51. Doctor then: FAIL phone wall (no answer on 127.0.0.1:8318) and FAIL Tailscale (not running): the Windows klepsydra app or Tailscale is down on this PC, not the cut-over; check the app is running.
- #190 verify (19:50): (A) fixed; (B) Blocking: the Windows build fails on the new test: `lpfnWndProc: Some(DefWindowProcW)` is E0308 at split.rs ~1521; add `unsafe extern "system" fn proc_(h: HWND, m: u32, w: WPARAM, l: LPARAM) -> LRESULT { unsafe { DefWindowProcW(h, m, w, l) } }` and pass `Some(proc_)`. Then CI and one verify.
- #191 verify (19:50): Should-fix: the /clear rule holds for SessionStart only; the next event recomputes false. Fix: with no KLEPSYDRA_AGENT and the pane equal to orchestrator.pane, keep an `"orchestrator":true` already in the session's file; extend the hook test with a later event. Low: KLEPSYDRA_AGENT is inherited by a `claude` Heph starts from his own shell (none does today). PR body: 476 tests, not 473.
