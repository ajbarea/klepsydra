# agy-532: flaky fleet test (klepsydra#532)

## State
- PR: [#540](https://github.com/ajbarea/klepsydra/pull/540) (`Fixes #532`)
- CI: Green on all checks (Gauge logic + statusLine hook in 50m13s, Rust ubuntu in 1m5s, Rust windows in 2m30s, GitGuardian in 1s)
- Branch: `fix/flaky-relaunch-test-532`

## Cause
In `fleet/test_fleet.sh`, the test at line 3056 ("review 3: a relaunch whose brief never started keeps the old pane, points the row back and exits the new one") launched a mock new pane running `fake_pane.py` with an unsent brief (`"input": "the brief, never sent"`) and immediately printed `echo "pane=$new ... brief=NOT-DELIVERED"` without waiting for `fake_pane.py` to start and draw the screen.

When `relaunch-fresh.sh` received `brief=NOT-DELIVERED`, it initiated rollback (`rollback_fresh` -> `retire "$new" interrupt`). Under CPU contention or delayed startup, `retire()` inspected `screen "$new"` before `fake_pane.py` rendered its input box. Because `holds_input` evaluated to false, `retire()` skipped sending `C-c` to clear the box and immediately called `type_enter "$new" "/exit"`. When `fake_pane.py` finished initializing and drew the unsent brief, `type_exactly` detected unexpected extra characters in the box, backed out `/exit`, and failed. As a result, `/exit` was never submitted to `relnew` (`SUBMIT /exit` count was 0 instead of 1).

In real launches (`fleet/launch.sh`), `launch.sh` always waits for the prompt to show and delivers the brief before returning `NOT-DELIVERED`, so the race was strictly in the test's mock launcher.

## Fix
In `fleet/test_fleet.sh:3048-3054`:
1. Polled `tmux capture-pane` in `launch-rel.sh` until `'the brief, never sent'` is drawn before returning from the mock launcher, ensuring `holds_input` is guaranteed to be true when `retire()` inspects the screen.
2. Added `"exit_on_exit": true` to `relnew.json` so `fake_pane.py` terminates upon receiving `/exit` (matching Claude Code behavior) rather than waiting out the 30-second `retire()` timeout.

## Verification
- **Reproduction (unpatched)**: Under simulated CPU load, the unpatched test case failed deterministically (iterations 81 and 102 failed with `got 0 want 1`).
- **Loop verification (patched)**: 200 iterations under heavy lock with CPU load: 0 failures (all 200 passed in 207s).
- **Test suites checked locally**:
  - `make test-fleet`: 989 passed, 0 failed
  - `make test-launch`: 278 passed, 0 failed
  - `make test-delegate`: 157 passed, 0 failed
  - `make test-heavy-lock`: 30 passed, 0 failed
  - `make test-slice`: 59 passed, 0 failed
  - `make test-headless`: 125 passed
  - `make test-engine`: passed
  - `node --test src/*.test.js`: 508 passed
  - `bash statusline/test_statusline.sh`: passed
  - `bash hooks/test_fleet.sh`: passed
  - `bash scripts/test_measure_memory.sh`: passed
  - `bash scripts/test_build_windows.sh`: passed
  - `npm run lint`: clean
  - `uvx ruff check`: clean
  - `(cd src-tauri && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings && cargo test -p klepsydra-fleet)`: clean, 446 passed
  - `uvx --from shellcheck-py shellcheck -x ...`: clean
- **CI**: Full CI pipeline on GitHub Actions green ([run 45318625287](https://github.com/ajbarea/klepsydra/actions/runs/45318625287)).

## Next
Handoff to Opus reviewer.
