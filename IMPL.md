# IMPL

Slice: #69 "Tokens by character" groups by kourai character only.
Branch feat/ledger-voices, worktree `.claude/worktrees/ledger-voices`,
stacked on feat/ledger-verify (#68, PR #72); rebase onto main once #72 merges.

## Done
- `Day.voices`: the voice each session had when first seen in today's file
  (`Ledger::note_voice`, called from `Reader::step`), so a cleared card keeps
  its character's tokens.
- Drawer groups by recorded voice through cast.json; every session with no
  cast character is one "Other sessions" row, last. Its tooltip and
  accessible name count the sessions with no voice and those with a voice
  outside the cast.
- Tests: JS unit (`src/fleet-ledger.test.js`), browser
  (`scripts/test_wall_browser.py`), Rust (`ledger.rs`, `watch.rs`).

## Next
- Rebase onto main after #72, full gate, PR "Closes #69", review, merge.
- Deploy both (see project Deploy steps) and check the drawer live.

## Verify
- `node --test src/*.test.js`
- `cd src-tauri && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings && cargo test -p klepsydra-fleet`
- every `hooks/test_*.sh`, `statusline/test_statusline.sh`, `scripts/test_*.sh`
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py`
- `KLEPSYDRA_STAGE=klepsydra-build-ledger_voices bash scripts/build-windows.sh --check`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
