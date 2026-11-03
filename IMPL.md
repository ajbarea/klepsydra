# IMPL: klepsydra fleet-module brief, resume state 2026-11-03 07:30 (EST)

Session 18 (Chronos, fresh on Personal = `~/.claude-rit`) replaced session 17. Resume from this file,
`git log`, open PRs and their comments, and the klepsydra line under "Running now" in
/mnt/c/Users/ajbar/fleet-briefing/queue.md. Brief: task-fleet-module.src (its last "11-02 18:00 Heph"
line sets the order).

## Merged and deployed (session 18)
#283, #285, #286, #257: `make install-fleet` (cut over), `fleet brief --refresh`, queue file set (#286), doctor
green except Windows Tailscale (down since 11-02 20:27). #286's Windows app build is AJ's app update.

## In flight
| PR / branch | Issue | State |
|---|---|---|
| #287 feat/orch-guard-264 (worktree guard-264) | #264 | 5 review rounds; redesigned twice: sends checked at run time by fleet/orch-tmux.sh (Heph's tmux, orch-bin first on PATH via launch.sh), refusing whatever it cannot work out, (command, flag) allow-list, sweep of all 285 tmux names/aliases/flags; hook keeps bypass / api-key / registry-by-shape. test_orch_guard.sh 191/0 at 4412d8a. Round 6 reader running. Deploy after merge: install, PreToolUse entry in ~/.claude/settings.json, `fleet accounts sync`; the shim reaches Heph at his next move. |
| #261 fix/doctor-truth-246 | #220, #246 | 3 review rounds (r1 blocker: any ended file counted as finished, so recover skipped lost agents and --prune dropped them; fixed). e763a09: sections 85/0 + doctor 50/1 (setup-only). Round 4 next. Heph told not to merge before a clean round. |
| #229 fix/focus-216 | #216 | retire_into fix 2dc9d6c; slice + mutant verified; CI pass; verify round running. |

## Next (in order, from the brief)
#271 (wall: resume pass now + Heph's account; the phone half waits on AJ's #163 decision), #270 (Agora, design first),
#272 (resume experiment, design first).

## Notes
- #264 design: the guard never models bash (a shlex reading disagreed with bash on 72/300 generated
  commands); it over-approximates so doubt lands on refusing. The two "ask first" guards deny with an
  ORCH_GUARD_ALLOW override instead of a prompt: a prompt in an unattended orchestrator stalls the fleet.
- `stopped_at`, `clock` and `FRESH_AFTER_S` moved from resume-at-reset.sh to lib.sh (shared by the guard).
- Running only part of fleet/test_fleet.sh: lines 1..N plus the summary under `flock -o /tmp/fleet-heavy.lock`;
  standalone sections: briefs, reset times, doctor, recover, fleet voices, relaunch.
- CI runs `ruff check` only; shellcheck covers fleet/*.sh fleet/fleet hooks/*.sh (WSL: `uvx --from shellcheck-py shellcheck`).
- Subagent briefs must state: any rm with a variable uses `rm -rf -- "${S:?}/${m:?}"`.
- `gh pr edit` fails here (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`.
- App crate needs GTK headers WSL lacks: test `-p klepsydra-fleet` with
  CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target; CI builds the app.
- Plugin marketplace refresh fails under CLAUDE_CONFIG_DIR=~/.claude-rit: refresh with `env -u CLAUDE_CONFIG_DIR`.

## Cleanup held (check each before deleting)
- worktrees impl-1029, recover (1 uncommitted change), split-182 (cargo target dir); branch
  docs/impl-late-1029; remote branch docs/brief-no-public-asks. Merged this session: done-269, relaunch-274,
  panels-276 (remove after checking nothing unpushed). IMPL branches impl-s9..s17 superseded by this one.
