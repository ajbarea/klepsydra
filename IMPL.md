# IMPL: klepsydra fleet-module brief, resume state 2026-11-01 17:30

Session 14 (Chronos, RIT) paused at Heph's ask (RIT ~78%, CISC-810 A6 deadline); the resume service brings it back after the reset.
Resume from this file, `git log`, open PRs and their comments. Brief: `~/.local/state/fleet-orchestrator/task-fleet-module.src`. Read `~/.local/state/fleet-orchestrator/friction.md` first.

## Done this session
- ✅ #245 (#244 install copies) verify clean, merged 487f44b. ✅ #243 (#242 recover stdin) verify clean, merged 98690da.
- ✅ `bash fleet/install.sh` from main at 98690da (exit 0); `fleet doctor` clean on rerun (first run: transient phone-wall FAILs, see friction.md).
- ✅ CI inbox: empty (Heph re-sent the notes 11:16).
- ✅ #226 flake: `test_the_watcher_wakes...` waited a fixed 1.5 s for alerts.seen; now waits on the file; watch-panes.sh writes alerts.seen atomically (77523e8, pushed).
- ✅ #254 opened (#239 + #193): suites close inherited fds and exit through cleanup on a signal; brief tail says `flock -o`; new `fleet/test_heavy_lock.sh` in CI (10 pass; both mutations caught).
- ✅ #229 rebased onto main (conflict with #243 in launch.sh resolved: keeps `KLEPSYDRA_BACKGROUND=1` and `</dev/null`), force-pushed 7077606; `hooks/test_launch.sh` 192 pass, shellcheck clean.

## Next (in order)
1. Tell Heph (only at his idle, empty prompt): #242 merged + installed, so `~/.local/state/fleet-orchestrator/recover-stdin-fix.sh` can be deleted. Not yet delivered (his prompt was busy).
2. Verify passes (one fresh opus reviewer each, two at a time): #226 (0515bba + 77523e8; the stopped reviewer had the hook suite 531/0 clean), #254, #229 (7077606 + rebase), #230 (31d6041). Merge each on clean + green + no new comments; `bash fleet/install.sh` from main after fleet changes.
3. #220 + #246 doctor items as one PR on worktree `doctor-220` (rebased on main before #243, local only, not pushed; remote has an older WIP c258a07, so push with `--force-with-lease`). Rerun `fleet/test_fleet.sh` there first (the 11-01 run was stopped). Then add: phone wall pass/fail = answers, usage age a separate warn only while a pane is mid-turn (`busy`), missing readings = warn "unknown"; retry Windows interop once before FAIL; watcher none + every live worker limited = warn naming the reset; watch-panes.sh skips panes limited at start; `fleet pause NAME WHY` / `fleet unpause NAME` (paused.tsv keeps the row) and doctor lists paused agents; each check logs the values it decided on (report() passes key=values to flog). Then `/techne:logging` on touched files. Research done: liveness vs freshness, gate staleness on outstanding work (cloudnativenow, oneuptime frozen-exporter, Google Cloud alerting guidelines).
4. #246 rest on worktree `truth-246` (3 commits + local WIP e215c39 `fleet report`): rebase after the doctor PR, finish, PR.
5. #245 nits (follow-up): install.sh:9 and fleet/fleet:15 comments, dry-run error path writes fleet.log, no test for the cmp skip, `"${tmp:?}"` at install.sh:53.
6. Then #241 (waits on AJ's 1Password Fleet vault), #157 part 3, #227, #221, #150. Close #228 (superseded by this file).

## Notes
- `gh pr edit` fails on klepsydra (Projects classic): `gh api -X PATCH repos/ajbarea/klepsydra/pulls/N -F body=@file`.
- `fleet/test_fleet.sh` ~19 min: `flock -o /tmp/fleet-heavy.lock timeout 1800 bash fleet/test_fleet.sh`.
- Never `pkill -f` a pattern that also matches your own shell's command line (exit 144 killed the calling shell).
- Rust: `CARGO_TARGET_DIR=.claude/worktrees/split-182/src-tauri/target cargo test -p klepsydra-fleet`.
- shellcheck: `uvx --from shellcheck-py shellcheck -x fleet/*.sh fleet/fleet hooks/*.sh`.
