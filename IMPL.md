# IMPL

Slice: #86 Queue panel, phase 1 (read-only). Branch feat/queue-panel,
worktree `.claude/worktrees/queue-panel`. No PR yet; lands after #82 and #83.

## Done
- Fleet crate: `bounded::read_text` (regular file only: symlink, FIFO and
  folder refused before and after the open; O_NOFOLLOW | O_NONBLOCK on Unix;
  a byte cap), shared with keryx's `speaking.json` read. `queue.rs`: path
  from the `queue_path` pref or the Desktop known folder, `QueueView`, and a
  `Follower` that watches the folder, debounces 250 ms (1 s cap), polls 5 s.
- App: `QueueFeed` hub, `queue_subscribe`, `start_queue` thread.
- Wall: markdown-it 15.0.3 vendored (`src/vendor/markdown-it`, sha256 in
  VENDOR.json, guard). `queue.js` walks tokens into elements and text only;
  links are text plus Copy link, never an href. `queuepanel.js` docks at
  1200 px and wider, modal dialog below; keyboard-resizable separator; width
  and open state in localStorage. Header reads "Queue · N for you".
- Tests: fleet-queue.test.js, guards (markup, vendor bytes, demo sample),
  style contrast, Rust reader and follower, four browser cases.

## Next
- Open the PR (AJ asked to hold); questions for AJ in it: links copy rather
  than open; the wall has one (dark) theme, so "both themes" is one.
- Independent review (`/techne:elenchus`), at most 3 rounds; then CI, merge.
- Phase 2 (separate PR): tick a Needs you item, atomic replace with an mtime
  precondition.

## Verify
- `node --test src/*.test.js`
- `cd src-tauri && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings && cargo test -p klepsydra-fleet`
- every `hooks/test_*.sh`, `statusline/test_statusline.sh`, `scripts/test_*.sh`; shellcheck
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py`
- `KLEPSYDRA_STAGE=klepsydra-build-queue_panel bash scripts/build-windows.sh --check </dev/null`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
