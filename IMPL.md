# IMPL: agy and Copilot lanes (#323), branch feat/agy-copilot-lanes

Resume from this file, `git log`, the PR and its comments. Docs for the adapter: docs/engines.md.

## Slice
Hand read-only work to agy and Copilot before spending Claude: `fleet delegate` (print mode, plus a locked interactive agy window the orchestrator can message, watch, read and stop). Guards first, proven by attack.

## Done
- Lock policy shared by the launcher and delegate: `hooks/klepsydra-agy-locked.json` (+ short `klepsydra-engine-rules.md`, under agy's 24,000-byte limit). `+ New session` for agy is locked, uses `--settings`/`--sandbox`, starts nothing if the policy is unreadable.
- `fleet/engines.sh` (one adapter per engine), `fleet/delegate.sh` (command, snapshot, fallback, interactive lane, watcher, msg/read/stop/ls), `fleet/test_delegate.sh` (stubs, `make test-delegate`), `fleet/attack_live.sh` (real engines, by hand).
- Live attack by hand (agy print, Copilot print, agy interactive): locked lanes refused write and shell; unlocked controls succeeded. Results in docs/engines.md.
- Return path: adapter outside the model detects turn end, saves the answer, notifies via `fleet send`. Tested for print and interactive, including limit, timeout and gone.
- `deliver_brief` re-reads the box before a second Enter (mock test in test_fleet.sh fails on the old code).
- doctor: engine lines; brief tail and HEPH.md: one delegation line.

## Next
1. Review rounds (fresh Opus reviewer per round, ceiling 5), then merge when CI is green and review is clean.
2. `make install-fleet`, `fleet cutover`, `fleet doctor`, one real `fleet delegate` per engine.
3. Later stages, listed on #323: wall cards, `+ New session` for Copilot, Copilot interactive lane, agy Stop hook / status-line signals, narrow MCP report tool.

## Verify
`make test-delegate`, `make test-launch`, `make test-fleet` (about 19 min), `make shellcheck`; `bash fleet/attack_live.sh` and `--control` by hand.

## Notes
- agy: `read_file(<dir>)` allow rules did not match below the dir and `strict` blocks workspace reads, so the policy is `request-review` plus denies; a URL fetch is stopped only by a `read_url(*)` deny.
- `make test-fleet`'s heavy lock is shared: the mutation sweep (`python3 -I mutate.py`, in the scratchpad) takes it per mutant.
