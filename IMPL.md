# IMPL: klepsydra fleet-module brief, resume state 2026-10-30 20:25

Session 8 (fresh start on RIT, 10-30 evening) went idle at Heph's ask: moved to Personal (14% weekly room), waiting for RIT's 23:40 reset.
Resume from this file, `git log`, open PRs and their comments. Brief: task-fleet-module.src.

## Done this session
- Merged, each review-clean with green CI and no new comments: #196, #206, #207 (earlier in session 8), then #218 (#134 launch end case), #210 (#208 Fleet health), #211 (#183 Voices).
- Deployed from the main checkout at 73a49d9: `make install-fleet` (old scripts in archive/fleet-scripts-20261030), `fleet cutover` (all units enabled and active, fleet-doctor.timer new, resume service logged its start). The #214 clock fix is live before 2026-11-01's clock change.
- `fleet doctor` after the cutover: two FAILs, neither from the deploy:
  - phone wall over Tailscale: Windows Tailscale was still starting ("NoState", coordination server unreachable).
  - agents: finished agents youtube, cisc810, bonsai-prs still have rows in panes.tsv. The remote-control check calls the same rows a warn ("a finished agent's row"), the agents check a FAIL, so the wall's Fleet health shows red until Heph prunes them. Candidate small fix: tell finished rows apart from a hard shutdown in doctor.sh's agents check.

## Next (in order)
1. Windows build (`flock /tmp/fleet-heavy.lock bash scripts/build-windows.sh`) for #190, #191, #194, #195, #207, #210, #211; reinstall; click a card's GitHub mark once and check the `open github` log line (#195).
2. #216 launches must not steal focus (new-window -d), #217 needs-you lingering after a permission answer.
3. #150 (research done: portable-pty + xterm.js, a grouped tmux session), #154 wall Recover button, #158 `--apply`, #157 part 3, #185 part 3, #204 demo mode, #215, #163.

## Cleanup held (not removed; check each before deleting)
- worktree impl-1029: tip differs from merged #212's head (2b9ca17, "session 7 moving to RIT"): superseded by this file.
- worktree recover: #171 merged, 1 uncommitted change.
- worktree split-182: #190 merged; holds src-tauri/target used as CARGO_TARGET_DIR for `-p klepsydra-fleet`, plus src-tauri/gen/.
- branch docs/impl-late-1029 (local + remote): 1 commit after #200 merged.
- remote branch docs/brief-no-public-asks: #179 closed as #178's duplicate.

## Notes
- `gh pr edit` fails on klepsydra (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`. Issue Types are not enabled here; labels stand in.
- `fleet/test_fleet.sh` takes about 19 min: `flock /tmp/fleet-heavy.lock timeout 1800`.
- The app crate needs GTK headers WSL lacks: lint/test `-p klepsydra-fleet` with CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target; CI builds the app.
- shellcheck: `uvx --from shellcheck-py shellcheck -x fleet/*.sh fleet/fleet hooks/*.sh`. `receiver::bad_paths_bodies_and_sizes_get_their_status` flakes under load (#174).
- Install before cutover: `make install-fleet`, then `fleet cutover`, then `fleet doctor` (doctor's exit code is lost behind a pipe; read the FAIL lines).
