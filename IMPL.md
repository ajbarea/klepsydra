# IMPL: feat/fleet-module (PR #161, draft)

AJ's order (10-28): #159 (done, deployed da83e7b) -> techne#227 (merged #232) ->
#162 (PR #164) -> this branch -> two accounts (feat/two-accounts WIP) -> #154 -> #158
-> #148 -> #149 -> #150.

## Done
- Fleet engine: lib.sh, resume service, launch, fresh-now, relaunch, watch, doctor,
  brief tail and generator, install, cutover; 98 tests against fake panes.
- Review round 1: B1 (cutover replaces transient units; install no longer enables),
  B2 (pane identity via the registry's session id before /exit, kill or /clear),
  S1-S8 and nits fixed with tests.

## Next
1. Review round 2 (fresh Opus reviewer, given this diff and round 1's findings).
2. Un-draft, CI, merge; then cut-over on this PC: `make install-fleet` from the
   main checkout, `fleet cutover`, `fleet doctor`; old scripts stay in
   archive/fleet-scripts-<date>/ for a week. Never restart or message other panes.
3. Rebase feat/two-accounts onto main and finish 4c (test it; AJ logs in once per
   folder: `CLAUDE_CONFIG_DIR=~/.claude-personal claude auth login`).
