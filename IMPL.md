# IMPL: agy and Copilot lanes (#323), branch feat/agy-copilot-lanes, PR #340

Resume from this file, `git log`, the PR and its comments. Adapter notes: docs/engines.md.

## Slice
`fleet delegate` hands read-only work to agy and Copilot before spending Claude: print mode, plus locked interactive windows (agy and Copilot) the orchestrator can message, watch, read and stop. `+ New session` for agy is locked. Guards first, proven by attack.

## Done
- Lock policy shared by launcher and delegate (`hooks/klepsydra-agy-locked.json`, short `klepsydra-engine-rules.md`); the launcher refuses home, parents of home, the Windows side and folders that ship agy workspace config.
- `fleet/engines.sh` (adapters), `fleet/delegate.sh` (command, snapshot, fallback, lanes, watcher, msg/read/stop/ls), `fleet/test_delegate.sh` (143 cases, `make test-delegate`), `fleet/attack_live.sh` (real engines, by hand; `--control` shows the check can fail).
- Live attack 2026-11-09: all four lanes clean locked, all four controls attacked.
- Five independent review rounds and a verify pass, all findings fixed with tests; five mutation sweeps. Full suites green at the last push (test-fleet 815, test-launch 240, node, shellcheck).
- `deliver_brief` re-reads the box before a second Enter (mock test fails on old code). Doctor engine lines. Delegation line in the brief tail and HEPH.md.

## Open
1. Review ceiling reached (5 rounds): the verify pass came back with 4 Should-fix, all fixed since, but nothing independent has read those fixes. Merge needs a reader's decision or one more fresh round.
2. After merge: `make install-fleet`, `fleet cutover`, `fleet doctor`, one real `fleet delegate` per engine (both were run live from the worktree before the last rounds).
3. Not built, listed on #323: wall cards, `+ New session` for Copilot, agy Stop hook as a second signal, narrow MCP report tool.

## Verify
`make test-delegate`, `make test-launch`, `make test-fleet` (about 20 min), `make shellcheck`, `node --test src/*.test.js`; `bash fleet/attack_live.sh` and `--control` by hand when a lock changes.

## Notes
- agy: `read_file(<dir>)` allow rules did not match below the dir and `strict` blocks workspace reads, so the policy is `request-review` plus denies; a URL fetch is stopped only by a `read_url(*)` deny; a headless `agy -p` runs a folder's hooks with no trust question.
- Test stubs read file knobs under `$STUB_DIR`: a tmux window inherits the server's environment, not the caller's.
- The ECHO the engines draw for a follow-up can wrap; the extractor skips the wrapped lines using the sent text.
