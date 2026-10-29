# IMPL: klepsydra fleet-module brief, resume state 2026-10-29 ~09:00

Order (AJ 10-28): #159 -> techne#227 -> #162 -> #161 -> two accounts -> #154 -> #158 -> #148 -> #149 -> #150.
Fresh session 10-29 06:20 (the 05:00 one stopped at the usage limit).

## Done
- #159, techne#227 (#232), #162 parts 1-2 (#164): merged and deployed.
- #161 fleet engine: merged ffb4e53; cut over 06:41 from the main checkout
  (`bash fleet/install.sh --force`: the worktree guard misfired on main, fixed in #165;
  `fleet cutover` ok). Old scripts in ~/.local/state/fleet-orchestrator/archive/fleet-scripts-20261029
  (delete after 11-05). Units installed: fleet-resume-at-reset, fleet-memfrag-log.timer, wsl-mem-watch.

## Open PRs (stacked: #165 <- recover PR; #166 <- feat/cast-picks)
- #165 two accounts (feat/two-accounts): review round 1 had 1 blocking + 6 should-fix, all fixed
  with tests (fed7e6c, 8c259ad); round 2 running. Second folder is ~/.claude-rit (RIT), since
  ~/.claude holds Personal. After merge: reinstall (`make install-fleet`, `fleet cutover` for the
  new units: accounts-sync path+timer, ci-watch), then AJ runs
  `CLAUDE_CONFIG_DIR=~/.claude-rit claude auth login` (in the queue's Needs you).
- #166 card account chip + Remote Control link from bridge-session records (feat/card-account):
  round 1 one should-fix (RC back on at its menu), fixed 694d306; round 2 running.
  After merge: `cp hooks/klepsydra-fleet.sh ~/.claude/`; the chip needs a Windows build
  (scripts/build-windows.sh from stage klepsydra-build-deploy).
- feat/recover (this branch, on #165): `fleet recover` (#154), `fleet shots` (#158),
  briefing sync as an installed 5-min timer (the old sync-briefing.sh was never installed),
  doctor "agents" check, FLEET_SETTINGS. 168 + 5 tests. Needs its PR review.
- feat/cast-picks (on #166): #148 castPicks in model.js, View.started_at, wall+strip wired;
  model tests pass; needs browser suites, shots, PR, review.

## Next
1. Land #165, #166 (rounds clean), then the recover PR and #148, retargeting stacked PRs
   to main BEFORE merging the lower one (memory feedback_stacked_pr_merge_dance).
2. Deploy: install-fleet + cutover; copy the hook; Windows build for #166/#148.
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
