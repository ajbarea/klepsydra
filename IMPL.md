# IMPL: klepsydra#410 cards go silent through a long turn: show latest agent narration

Brief: https://github.com/ajbarea/klepsydra/issues/410

## Slice
1. In `hooks/klepsydra-fleet.sh`, harvest the newest assistant text narration from a bounded transcript tail on `PostToolUse` (and from `last_assistant_message` if supplied by engine/hook), storing it as `.said = {text: ..., at: ...}` apart from `.reply`.
2. In `hooks/klepsydra-engine.sh`, harvest agy's latest `PLANNER_RESPONSE` mid-turn on `PostToolUse` from a bounded tail (matching `Stop`).
3. In `src-tauri/fleet/src/session.rs`, `src-tauri/fleet/src/view.rs`, and `src-tauri/fleet/src/phone.rs`, support `pub said: Option<Said>` so Rust deserialization / serialization passes `.said` to views and snapshots.
4. In `src/fleet/model.js`, ensure the "now" line displays `said` while working, replaced by `reply` once the turn ends.
5. In `hooks/test_fleet.sh`, `hooks/test_engine.sh`, and `src/*.test.js`, add regression tests for narration mid-turn, Stop replacing with reply, and empty tail changing nothing.
6. Benchmark hook latency before and after (baseline 59.94ms, after 63.12ms).
7. Capture 1920x1080 screenshots before and after in dark and light themes, and record in `shots/README.md`.

## Done
- Assigned issue #410 to `ajbarea`.
- Bounded transcript tail harvesting implemented in `hooks/klepsydra-fleet.sh` (shared single `remote_lines` pass with record-separator split, zero additional transcript reads) and `hooks/klepsydra-engine.sh`.
- Rust backend updated with `pub said: Option<Said>` in `SessionFile` and `View`, `phone.rs` schema updated to 27 fields with `"said"`, unit tests added (`session_file_reads_said`, `view_carries_said`). All 433 backend unit tests and 7 integration tests pass.
- Frontend `card()` in `src/fleet/model.js` updated to display `said` mid-turn on `.reply` while working, replaced by `reply` at `Stop` / `done` / `ended` / `background`.
- Added regression tests in `hooks/test_fleet.sh`, `hooks/test_engine.sh`, and `src/fleet-model.test.js`.
- Performed mutation checks in `hooks/klepsydra-fleet.sh`, `hooks/klepsydra-engine.sh`, and `src/fleet/model.js` - all caught by tests.
- Measured hook call latency: baseline 59.94ms/call (100 runs), after 63.12ms/call (100 runs), well within the 100ms budget (+3.18ms delta).
- Captured 1920x1080 screenshots in dark and light themes before and after (`klepsydra-410-narrate-{before,after}-{dark,light}.png`), recorded under `## 2026-11-16: cards narration mid-turn (#410)` in `/mnt/c/Users/ajbar/fleet-briefing/shots/README.md`.
- All linters and test suites pass cleanly: `cargo test -p klepsydra-fleet`, `cargo clippy`, `cargo fmt`, `node --test`, `test_fleet.sh`, `test_engine.sh`, `npm run lint`, `uvx ruff check`.
