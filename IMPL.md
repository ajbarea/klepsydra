# IMPL: klepsydra fleet-module brief, resume state 2026-10-29 ~05:00

Order (AJ 10-28): #159 -> techne#227 -> #162 -> this (#161) -> two accounts -> #154 -> #158 -> #148 -> #149 -> #150.

## Done
- #159 Split auto-uncheck: PR #160 merged and deployed (da83e7b).
- techne#227 ci-audit report mode: techne #232 merged. Follow-up: techne#233 (eval skill load).
- #162 CI watch: PR #164 merged and deployed (0240820, 04:15). Unit `fleet-ci-watch` is live:
  transient, Restart=always, TECHNE_CI_REPORT=techne main checkout, CI_SWEEP_HOUR=99 (sweep off, AJ decides).
  #163 phone push waits on AJ (it needs the phone wall's first write route).
- #161 fleet engine: review rounds 1-4 done, final verify clean, 111 tests. Un-drafted;
  CI was starting when the session stopped.

## Next
1. #161: re-read comments, check CI is green, squash-merge. Then the cut-over on this PC, from
   the main checkout (ff it first): `make install-fleet`, `fleet cutover`, `fleet doctor`.
   Old scripts go to archive/fleet-scripts-<date>/ for a week. Make the CI watch an installed
   unit too. Never restart or message other panes.
2. feat/two-accounts (WIP 1218281): rebase on main, finish 4c with tests. AJ runs once:
   `CLAUDE_CONFIG_DIR=~/.claude-personal claude auth login`.
3. #154, #158 (shots prune, dry-run default), then #148, #149, #150.
4. klepsydra main IMPL.md: rewrite from this file after #161 merges.
