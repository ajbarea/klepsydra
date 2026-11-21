# IMPL: #516 test_fleet keryx isolation check on mid-run quit (agy, Gemini; stop at a PR)

## Task
Fix https://github.com/ajbarea/klepsydra/issues/516.
When `make test-fleet` runs, it records the SHA256 of AJ's live `~/.config/keryx/config.json` at startup
and verifies at the end that no test touched it (`#273: no case touched AJ's own keryx config`).
If keryx is quit or toggled off mid-run (e.g., from the tray menu), `config.json` is modified by the live
keryx daemon, causing a false red on the 40-minute suite.

## Fix shape
- In `fleet/test_fleet.sh`:
  - Record the suite start time `real_keryx_start=$(date -u +%s)` alongside `real_keryx_sum`.
  - When the hash differs at the end of the suite, check keryx's `daemon.log` (in `$XDG_STATE_HOME/keryx/log`
    or `$HOME/.cache/keryx`) for a `quit` or `turned off` event within the test run's time window `[start - 2, end + 2]`.
  - If a matching quit/off line is found within the window, report a skip with a note explaining the live toggle
    (`skip #273: no case touched AJ's own keryx config: AJ's live keryx was quit/toggled mid-run ($event)`)
    rather than failing.
  - If the hash differs without a matching quit/off entry in the run window, fail as before.
- Regression tests verifying:
  - Hash match -> ok.
  - Hash change with quit in run window -> skip with note.
  - Hash change with quit outside run window -> fail.
  - Hash change with empty log -> fail.

## State
- Slice: keryx isolation check mid-run quit detection.
- Done:
  - Analyzed keryx daemon logging format (`ts` in UTC ISO 8601 with fractional seconds and `Z`).
  - Implemented `keryx_quit_event` and `check_keryx_isolation` in `fleet/test_fleet.sh`.
  - Added 4 unit test cases in `fleet/test_fleet.sh` testing matching config, mid-run quit skip, outside-window quit fail, and empty log fail.
  - Replaced end-of-suite line 4933 check with `check_keryx_isolation`.
  - Mutation check: mutated regex pattern to `bogus_pattern` and verified mutation was killed (`fail=1`).
  - Passed shellcheck on `fleet/test_fleet.sh`.
  - Passed `npm run lint`, `uvx ruff check .`, `node --test src/*.test.js`, `make test-engine`, `make test-headless`, `cargo fmt`, `clippy -p klepsydra-fleet`, and `cargo test -p klepsydra-fleet`.
- Next:
  - Commit and push to `fix/keryx-isolation-516`.
  - Open PR with issue ceremony (short top <150 words, depth in details, labelled `bug`, assigned `ajbarea`, closes #516).
  - Verify CI green.
