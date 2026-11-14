# IMPL: headless jobs on the API credit (#260), branch feat/headless-260

Resume from this file, `git log`, PR #375 and its comments.

## Slice
`fleet headless NAME BRIEF` runs one `claude -p` job in a fresh worktree on `~/.claude-api` (apiKeyHelper over `ant --profile ldqis`), under a required `--max-budget-usd` (default 10, at most 50) and the workers' capped scope; each end goes to the fleet log and `headless/ledger.jsonl`; `--status` lists jobs. Interactive sessions never get a key: `launch.sh` and the tray's launcher drop `ANTHROPIC_API_KEY/AUTH_TOKEN/PROFILE` and refuse keyed settings; doctor reports the auth mode. Design and sources: `docs/headless.md`, the PR's Decisions.

## Done
- Code, tests (`fleet/test_headless.sh`, `make test-headless`, CI step), docs, README rows.
- Live on the LDQIS credit 11-13: two haiku jobs (foreground and background), `apiKeySource: apiKeyHelper`, $0.0047 total, scope in `fleet-workers.slice`.
- Opus review round 1 (5 Should-fix, 5 nits) fixed in 9b469e6; verify round 2 (2 Should-fix, 3 nits) fixed in 2e0a9de; verify round 3 (2 Should-fix, 2 nits) fixed in the next commit; guard mutations 19 of 20 killed, 1 equivalent.

## Next
1. Heavy suites on the final tree (test-fleet, test-launch, test-delegate, shellcheck).
2. Heph verifies and merges; then `make install-fleet` from main, and `fleet doctor` shows `auth mode: subscription + headless credit`.

## Verify
`make test-headless`, `make test-fleet`, `make test-launch`, `make test-delegate`, `make shellcheck`. A live check costs cents: `fleet headless NAME brief.md --model claude-haiku-5-5 --budget 0.5 --wait`, then remove its worktree and branch.
