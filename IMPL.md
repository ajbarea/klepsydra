# IMPL: klepsydra fleet-module brief, resume state 2026-10-29 ~10:40

Order (AJ 10-28): #159 -> techne#227 -> #162 -> #161 -> two accounts -> #154 -> #158 -> #148 -> #149 -> #150.
Fresh session 10-29 06:20 (the 05:00 one stopped at the usage limit).

## Done
- #159, techne#227 (#232), #162 parts 1-2 (#164): merged and deployed.
- #161 fleet engine: merged ffb4e53; cut over 06:41 from the main checkout
  (`bash fleet/install.sh --force`: the worktree guard misfired on main, fixed in #165;
  `fleet cutover` ok). Old scripts in ~/.local/state/fleet-orchestrator/archive/fleet-scripts-20261029
  (delete after 11-05). Units installed: fleet-resume-at-reset, fleet-memfrag-log.timer, wsl-mem-watch.

## Merged and deployed 10-29
- #165 two accounts (e71984c): installed + cut over 10:11; resume and ci-watch restarted on it.
  ~/.claude holds RIT since a /login at 09:23, so AJ signs ~/.claude-rit in with PERSONAL
  (Heph told; queue Needs you). Doctor FAIL on ~/.claude-rit settings (model opus[1m]) is fixed
  by this branch (the second folder keeps its own model).
- #166 account chip + RC link from bridge records (189f895): hook copied to ~/.claude.

## Open
- feat/recover (this branch): fleet recover (#154), fleet shots (#158), briefing sync timer,
  team-ceremony rule in brief-tail.md + `fleet brief --refresh`, cutover restarts running
  installed services, second folder keeps its own model. After merge: `make install-fleet`,
  `fleet cutover`, `fleet brief --refresh`, `fleet doctor`.
- #168 (#148 characters): round 2 blocking (ceded order) + Ledger table fixed; needs round 3.

## Next
1. Land the recover PR and #168; Windows build for the #166 chip and #168 (scripts/build-windows.sh).
2. Rewrite each open PR body to the team-ceremony format when touching it (AJ 10-29).
3. Fleet health on the wall (4b): doctor --write health.json on a timer, crate follower like
   ci.rs, a bar button + popover with a Recover button (runs `fleet recover`).
4. #162 follow-up (Heph 10-29): one Needs-you line per repo+branch/PR, updated in place,
   removed on green or close; reds on agent branches go to the owning pane and the morning file.
5. #149 (folder + GitHub links on cards), #150 (Heph docked, Talk to Heph, read-only workers,
   Agent controls setting). Research UX first.
6. #157 Heph rotation (part 3); measurement with the Ledger after a week.
7. `fleet shots --apply` at the morning rewrite (Heph's), and Review-issue drafting for new shots.

## Notes
- fleet doctor on 10-29: phone wall off (tray toggle after the 04:15 reinstall) and Tailscale not
  reaching its coordination server: both in Needs you. No pane watcher running (Heph's).
- Usage 10-29 ~08:00: Personal 5h 23%, week 34%; RIT 5h full.
