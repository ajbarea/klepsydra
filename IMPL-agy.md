# agy: bring 17 conflicting PRs up to date with main

One PR at a time, in this order (newest first). klepsydra: #514 #510 #507 #504 #502 #497 #496 #493 #459 #318 #316 #314 #308 #293 #287. techne (use a worktree in ~/ajsoftworks/techne/.claude/worktrees/agy-rebase from origin/main): #387 #304.
SKIP #518 and #508: other agy sessions own them.

For each PR:
1. Re-read its comments and reviews (`gh pr view N --comments`, `gh api repos/ajbarea/REPO/pulls/N/comments`).
2. `git checkout -B <head branch> origin/<head branch>`, then `git merge origin/main` (a merge, NOT a rebase; never force-push).
3. Resolve conflicts keeping BOTH intents: main's current behaviour plus the PR's change. If a conflict means the PR's change is already on main, or the resolution needs a design decision, do not guess: `git merge --abort`, comment one line on the PR ("Conflict needs an owner decision: <file>: <why>") and move on.
4. Check only what the resolution touched: shellcheck on changed .sh files (through `flock -o /tmp/fleet-heavy.lock`, one at a time; test_fleet.sh takes 3.6 GB), ruff/biome on changed files (no lock), and only the tests that cover the changed files. Do NOT run the full fleet suite locally; CI runs it.
5. Push with an explicit refspec (`git push origin HEAD:<head branch>`), then comment one line on the PR: "Merged main in at <sha>; conflicts in <files> resolved by <how>." Move on without waiting for CI.

Rules: never push to main, never merge a PR, never force-push, no cluster, no attribution lines, never --no-verify. State only what you checked. At the end write a table here (PR, result: pushed / needs-owner / skipped, sha) and stop; Heph's Opus reviewer takes it from there.

## Follow-up after the batch (Heph 11-24 14:2x)
PR #497 went red after your merge: fork budget 25 > 23 in fleet/test_forks_screen.sh (run 45445785664). Read the PR comment; check the merge kept #497's one-jq read; fix in perf/sessions-one-jq, rerun that test under the heavy lock, push, comment. Same rules.
Also PR #507 (fix/agy-footer-488): two #513 doctor model-list tests fail after your merge (lister asked 4 times, want 1; fleet/test_fleet.sh:3868, run 45445439175). Read the PR comment, fix, rerun those tests under the heavy lock, push, comment.
Also PR #493 (feat/settings-page-384): does not compile after your merge (E0308, src-tauri/src/voices.rs:74, match arms bool vs ()). Fix, cargo check + clippy, push, comment.

## Rule tightened (Heph 11-24 14:5x): 3 of your merges went red in CI (#497, #507, #493)
Before every push from now on: if the merge touched src-tauri, run `KLEPSYDRA_STAGE=klepsydra-build-rebase bash scripts/build-windows.sh --check` (the app crate cannot compile under WSL; never run Windows cargo on the WSL path, it took 80+ minutes); if it touched fleet/*.sh, run the test files for the functions you changed under the heavy lock. A push that does not build is not "done". For PRs you already pushed, check `gh pr checks N` after the batch and fix every red one in the follow-up pass.

## Follow-up (Athena 17:40): techne #304 red after your main merge
CI run 45499494890 (validate) fails: guard `block_gh_implicit_repo` (added by #304) has no entry in PROBES in tests/test_phylax_conformance.py (the conformance test came in from main). Add a probe that fires the guard through hooks.json, following the other PROBES entries. Run `uv run pytest -q tests/test_phylax_conformance.py` (timeout 20m) before pushing; push only fix/phylax-fork-guard.

## Follow-up (Athena 18:45): techne #304 mutation red is NOT yours
The mutation shards on #304 fail (survivors in the new guard code). That is guard code: an Opus worker writes the killing tests. For #304 you only keep the branch current and `validate` green; do not add mutation tests. Move on to the next PR in your list.
