# IMPL: klepsydra fleet-module brief, resume state 2026-10-31 00:35

Session 9b (fresh start on Personal after RIT's limit) parked at Athena's ask: Personal has 9% weekly room until Mon 11-02 13:00. RIT resets 04:40; the resume service moves this agent back there.
Resume from this file, `git log`, open PRs and their comments. Brief: task-fleet-module.src.

## In flight (in order)
1. **#225 Play button (#223):** review clean (session 9). CI's "Gauge logic + statusLine hook" job was still running at 00:30. When green and no new comments: merge, Windows build (`flock /tmp/fleet-heavy.lock bash scripts/build-windows.sh`), reinstall.
2. **#226 Athena (#222):** needs an independent review. Two reviewers were cut off (the first by the 04:40 limit, the second stopped at the park). The brief is in session 48c3c56a's scratchpad `review226.txt`; if that is gone, rebuild it: the three passes, plus every consumer of CAST (16), HEPH, ATHENA, ORCHESTRATORS, orchestrator_face, View/SessionFile fields, phone.rs, agora.rs, the ledger, the keeper, fleet/*.sh and *.py, and the app crate; migration of picks.json and session files on disk; a /clear in the orchestrator pane.
3. **#220 doctor one verdict + `--prune`:** branch fix/doctor-220, commit c258a07 (WIP: the code and tests are written, shellcheck clean, but the fleet suite has not been rerun). Next: `flock /tmp/fleet-heavy.lock timeout 1800 bash fleet/test_fleet.sh`, squash the WIP message, PR (assignee ajbarea, closes #220), review.
4. **#216 launches open behind:** branch fix/focus-216, commit b5ed15c, pushed. hooks/test_launch.sh 191/191, shellcheck clean. Every fleet path (fresh, move, resume, recover) goes through launch.sh, and every orchestrator relaunch uses the name `heph`, so Heph and Athena both come forward. Next: PR (closes #216), review, merge. The timers' trailing `select-window -t fleet:0` can go once this is live.
5. Then #217 needs-you lingering, #157 part 3 rotation, #221 Heph terminal, #150, #154 wall Recover, #158 `--apply`, #185 part 3, #204 demo mode, #215, #163.

## Cleanup held (check each before deleting)
- Orphan tmux servers `fleet-test-271533`, `-1318791`, `-3176838`, `-4149558` (6 h to 27 h old at 00:35) from earlier killed suites. They do not hold the heavy lock. Owner unknown, so left alone (#193 covers the cause).
- worktree impl-1029, worktree recover (1 uncommitted change), worktree split-182 (its src-tauri/target is the CARGO_TARGET_DIR for `-p klepsydra-fleet`), branch docs/impl-late-1029, remote branch docs/brief-no-public-asks: see the session 8 notes in git history (#219).

## Notes
- `gh pr edit` fails on klepsydra (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`. Issue Types are not enabled here; labels stand in.
- `fleet/test_fleet.sh` takes about 19 min: `flock /tmp/fleet-heavy.lock timeout 1800`.
- The app crate needs GTK headers WSL lacks: lint and test `-p klepsydra-fleet` with CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target; CI builds the app.
- shellcheck: `uvx --from shellcheck-py shellcheck -x fleet/*.sh fleet/fleet hooks/*.sh`. `receiver::bad_paths_bodies_and_sizes_get_their_status` flakes under load (#174).
- Install before cutover: `make install-fleet`, then `fleet cutover`, then `fleet doctor` (doctor's exit code is lost behind a pipe; read the FAIL lines).
