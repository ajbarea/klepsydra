# IMPL: klepsydra fleet-module brief, resume state 2026-10-29 23:05

Session 7 (the account with room) took over at 21:11 from session 6, which stopped at a usage limit.
Resume from this file, `git log`, the PRs below and their comments. Brief: task-fleet-module.src.

## Merged this session
- #191 (#172 Heph's face is his alone), #190 (#182 Split checks itself on a hand snap), #192 (#185 Agora part 1, installed + briefs refreshed), #194 (#167 shell count). Lows filed: #205 (Split), #185 comment (Agora, fixed in #207), #167 comment (shell count).

## Open PRs (each review round is a fresh opus reviewer given the diff + open findings)
| PR | Issue | Worktree (.claude/worktrees/) | Next |
|---|---|---|---|
| #195 | #149 folder + GitHub links | links-149 | round 3 fixed (01340bb; real wsl.exe/explorer chain run on this PC); needs round 4 |
| #196 | #170 CI triage on the account with room | triage-170 | round 3 fixed (4018a5e; limited-then-failed waits, 5 guards mutation-killed); needs round 4 |
| #206 | #198 move-back with background work | moveback-198 | SC1010 fixed (41eaedc); round 1 running |
| #207 | #185 Agora part 2 (wall + phone feed, reactions) | agora-wall | needs round 1; shot in shots/2026-10-29 |
| techne#251 | techne#229 body budget gate | techne worktrees/body-gate | round 5 fixed (ddad535: one rule for every `$(...)`); round 6 running; governance code, review until clean |
| (to open) | #208 Fleet health on the wall | health-208 | doctor `--json` + fleet-doctor timer + crate health.rs + wall Fleet button written; run fleet suite + crate tests, then PR |

Review notes per round: /tmp/claude-1001/-home-ajbar-ajsoftworks/7ca80650-7c23-4a2a-9c12-f369616daae2/scratchpad/ (rev/, r3/, r4/, r5b/, r195/, r196/).

## After merges (deploy)
1. `git pull` in the main checkout, `fleet cutover` (#206 resume-at-reset, #208 new fleet-doctor timer), `make install-fleet`, `fleet doctor`.
2. Windows build (scripts/build-windows.sh) for #190, #191, #194, #195, #207, #208; reinstall; click a card's GitHub mark once and check the `open github` log line (#195).
3. techne#251: update the plugin, switch `block_long_bodies` on in both config folders.

## Next after the open PRs
#185 part 3 (Ledger measured friction), #154's wall Recover button, #158 `--apply`, #150 (research UX first), #157 part 3, the #183 Voices setting, #163 phone push, #204 demo mode.

## Notes
- PRs on klepsydra: `gh pr edit` fails (Projects classic); use `gh api -X PATCH repos/.../pulls/N -F body=@file`.
- `fleet/test_fleet.sh` takes over 15 min: `timeout 1800`. The app crate needs GTK headers WSL lacks: lint/test `-p klepsydra-fleet` locally, CI covers the app.
- shellcheck is not installed: `uvx --from shellcheck-py shellcheck -x hooks/*.sh statusline/*.sh scripts/*.sh fleet/*.sh fleet/fleet`.
- Squash with `git reset --soft $(git merge-base HEAD origin/main)` before a rebase over many review commits.
- Heavy runs under `flock /tmp/fleet-heavy.lock`. `receiver::bad_paths_bodies_and_sizes_get_their_status` flakes under load (#174).
- The pane watcher was not running at 21:12 (doctor FAIL); that is Heph's to start.
