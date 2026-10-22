# IMPL

Slice: #69 "Tokens by character" groups by kourai character only.
Branch feat/ledger-voices, worktree `.claude/worktrees/ledger-voices`,
stacked on feat/ledger-verify (#68, PR #72); rebase onto main once #72 merges.

## Done
- `Day.voices`: the voice in each session's own fleet file (not the wall's
  de-duplicated one) when first seen in today's file. `Ledger::note_voice`
  rolls to `now`'s day first; `Reader::step` saves at once after a new voice
  and reports a failed save as a `ledger` problem.
- Drawer groups by recorded voice through cast.json; every session with no
  cast character is one "Other sessions" row, last. Its tooltip sits on the
  visible words (hidden from readers); a visually hidden span carries the
  full label, read once.
- `characterOf` (ledger.js) is the one session-to-character lookup, used by
  tokens by character, "Showing X only" and the blocked list; the live wall
  only when the day has no voice. `cast.js` holds the own-key cast lookup and
  accent check that `identity()` shares.
- Tests: JS unit (`src/fleet-ledger.test.js`), browser
  (`scripts/test_wall_browser.py`), Rust (`ledger.rs`, `watch.rs`).
- PR #74 review fixes: persistence, midnight, shared voice, cleared-session
  names, accessible name.

## Next
- Re-review PR #74; rebase onto main after #72 merges, full gate, merge.
- Deploy both (see project Deploy steps) and check the drawer live.

## Verify
- `node --test src/*.test.js`
- `cd src-tauri && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings && cargo test -p klepsydra-fleet`
- every `hooks/test_*.sh`, `statusline/test_statusline.sh`, `scripts/test_*.sh`
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py`
- `KLEPSYDRA_STAGE=klepsydra-build-ledger_voices bash scripts/build-windows.sh --check`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
