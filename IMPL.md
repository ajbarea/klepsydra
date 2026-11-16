# IMPL: klepsydra#408 pass engine to fleet cards and guard agy account detection

Brief: `https://github.com/ajbarea/klepsydra/issues/408`

## Slice
1. Add `pub engine: Option<String>` and `pub model: Option<serde_json::Value>` to `SessionFile` and `View` in `src-tauri/fleet/src/session.rs` and `src-tauri/fleet/src/view.rs`.
2. In `hooks/klepsydra-fleet.sh`, guard account extraction: when `$engine == "agy"`, set account to `agy-primary` (`Google AI Pro`) instead of reading `~/.claude.json`.
3. Verify all Rust tests (431 tests) pass, all 501 Node unit tests pass, and shell check passes.

## Done
- Created worktree `.claude/worktrees/engine-card-408` on branch `fix/engine-card-408`.
- Updated `SessionFile` in `src-tauri/fleet/src/session.rs`.
- Updated `View` and `view()` in `src-tauri/fleet/src/view.rs`.
- Updated test card initializers in `cue.rs`, `picks.rs`, `speaking.rs`, and `view.rs`.
- Added unit tests for `engine` and `model` serialization and deserialization in `session.rs` and `view.rs`.
- Updated `hooks/klepsydra-fleet.sh` to extract `engine` in `main()` and guard account resolution for `agy` and `copilot`.
- Verified `cargo test -p klepsydra-fleet` (431 passed, 0 failed).
- Verified `cargo clippy -p klepsydra-fleet --all-targets -- -D warnings` (clean).
- Verified `cargo fmt --check` (clean).
- Verified `bash hooks/test_fleet.sh` (585 passed, 0 failed).
- Verified `bash hooks/test_engine.sh` (passed).
- Verified `make shellcheck` (0 warnings).
- Verified `node --test src/*.test.js` (501 passed, 0 failed).

## Next
- Commit changes with conventional commit message (zero attribution trailers, zero em-dashes).
- Push branch and create PR linking #408.
- Merge on green CI.
- Rebuild Windows binary in `C:\Users\ajbar\klepsydra-build` and deploy to `C:\Users\ajbar\AppData\Local\klepsydra\klepsydra.exe`.
