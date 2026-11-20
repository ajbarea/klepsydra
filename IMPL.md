# IMPL: fix(fleet): agy 1.5.12 idle and busy screens (#488)

Branch fix/agy-footer-488 (worktree .claude/worktrees/agy-488), cut with `--no-track` from origin/main (958dbb2).
Push only with explicit refspec: `git push -u origin fix/agy-footer-488:fix/agy-footer-488`. Never push to main.

## Problem
In agy 1.5.12+, the interactive screen no longer ends with `? for shortcuts` (idle) and `esc to cancel` (busy).
Instead, its idle and busy screens end with a status line:
`<Model> · ctx <N>% · 5h <N>% · 7d <N>%`
Because `eng_state` in `fleet/engines.sh` only checked the old footer strings, it reported state `unknown`, causing interactive `fleet delegate` lanes to time out or fail to start.

## Plan
1. Step 1: Capture live idle and busy screens from agy in a clean scratch tmux session (`tmux -L agy488`), and commit fixtures to `fleet/fixtures/`. (Done)
2. Step 2: Update `eng_state` in `fleet/engines.sh` to recognize agy 1.5.12's idle and busy screens, while preserving support for legacy footers. Match on stable line components (`· ctx `) without coupling to model name or percentages. (Done)
3. Step 3: Add tests in `fleet/test_delegate.sh` using the real fixtures and verify old fixtures still pass. Perform a mutation check (revert engines.sh and verify failure). (Done)
4. Step 4: Add a class guard in `fleet/doctor.sh` checking that installed `agy --version` has a matching fixture in `fleet/fixtures/`, warning if absent so CLI updates are caught before lanes break. Add tests for this check. (Done)
5. Step 5: Run all verification suites (test_delegate.sh, shellcheck on changed files), commit, push branch, open PR, and report when CI is green.

## Done
- Step 1: Captured real screens from live agy 1.5.12 and 1.5.13 sessions in scratch tmux server (`-L agy488`). Saved `fleet/fixtures/agy-1.5.12-idle.txt`, `fleet/fixtures/agy-1.5.12-busy.txt`, `fleet/fixtures/agy-1.5.13-idle.txt`, `fleet/fixtures/agy-1.5.13-busy.txt`, `fleet/fixtures/agy-legacy-idle.txt`, `fleet/fixtures/agy-legacy-busy.txt`. Scratch server cleanly destroyed.
- Step 2: Updated `eng_state` in `fleet/engines.sh` to match `· ctx ` on the footer line and check for spinner / activity phrases above the prompt box for busy state. Legacy footers continue to work.
- Step 3: Added tests in `fleet/test_delegate.sh` for idle, busy, quota, and 429 states on agy 1.5.12. Ran mutation check (reverting engines.sh to origin/main failed with `got: unknown` on both idle and busy tests).
- Step 4: Added class guard in `fleet/doctor.sh` reporting `agy version` status and warning if installed version has no fixture. Added tests in `fleet/test_delegate.sh` verifying warning on missing fixture (fake version 99.99.99) and pass on present fixture (1.5.12).
- Step 5: Shellcheck on changed files (`fleet/engines.sh`, `fleet/doctor.sh`, `fleet/test_delegate.sh`) passed clean. All 163 tests in `fleet/test_delegate.sh` passed.
- Round 2 Review Fixes:
  - Item 1 (Blocking): Recognized background task rows ending in `running` under input box as busy; debounced idle detection in `cmd_watch` by requiring 3 consecutive idle polls. Captured real screen `agy-1.5.13-bg-running.txt` and verified test reads busy.
  - Item 2: Matched entire braille block U+2800-U+28FF (`[\x{2800}-\x{28ff}]`) and added `Loading...` to activity phrases. Tested `⢿ Loading...` reads busy.
  - Item 3: Mapped agy folder-trust dialog (`enter Confirm` in tail -2) to `trust` state, answered with Enter. Captured real trust dialog `agy-1.5.13-trust.txt` and tested.
  - Item 4: Added dedicated indicators fixtures (`agy-busy-spinner-only.txt`, `agy-busy-phrase-only.txt`, `agy-busy-task-only.txt`) so mutations dropping braille, phrases, or task rows fail. Ensured `eng_state` returns `$footer` when not idle, so reverted 1.5.12 footer check causes limit tests to fail.
  - Item 5: Wrapped `agy --version` in `timeout "${FLEET_AGY_TIMEOUT_S:-5}"`, parsed version after "agy" or "CLI" or standalone dotted number, warned `agy version unreadable: <text>` on parse failure, removed non-existent `hooks/fixtures/` candidates, and added tests for timeout, unparseable version, and CLI parsing.
  - Item 6: Renamed `agy-1.5.13-busy.txt` (which was a quota screen) to `agy-1.5.13-limit.txt`, captured a real 1.5.13 busy screen, and added explicit tests for every agy fixture file (12 total).
  - NIT: Left the last 12 lines check as-is: reading busy when "Thinking..." or braille appears in the last 12 lines is the safe direction and avoids brittle AST parsing of ANSI terminal output.

## Next
- Commit IMPL.md, push branch with explicit refspec, update PR #507 body with round 2 details, watch CI checks, and send report to orchestrator.

## Verify
- `bash fleet/test_delegate.sh > /tmp/t488.log 2>&1; echo $? > /tmp/t488.exit` (179 passed, 0 failed)
- `uvx --from shellcheck-py shellcheck -x fleet/engines.sh fleet/doctor.sh fleet/delegate.sh fleet/test_delegate.sh` (clean)
- Mutation checks:
  - Reverting 1.5.12 check: 1.5.12 limit test returns `unknown` instead of `limit`.
  - Dropping braille regex: `agy-busy-spinner-only.txt` reads `idle` instead of `busy`.
  - Dropping activity phrases regex: `agy-busy-phrase-only.txt` reads `idle` instead of `busy`.
  - Dropping task row check: `agy-busy-task-only.txt` reads `idle` instead of `busy`.
