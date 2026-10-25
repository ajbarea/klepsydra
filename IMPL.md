# IMPL

Slice: #86 Queue panel, phase 1 (read-only). Branch feat/queue-panel,
worktree `.claude/worktrees/queue-panel`, PR #88 (refs #86; closes after the
live check on the installed build). Lands after #82 and #83.

## Done
- Fleet crate: `bounded::read_text` (regular file only: symlink, FIFO and
  folder refused before the open, the handle checked after; O_NOFOLLOW |
  O_NONBLOCK on Unix; a byte cap), shared with keryx's `speaking.json` read. `queue.rs`: path
  from the `queue_path` pref or the Desktop known folder, `QueueView`, and a
  `Follower` that watches the folder, debounces 250 ms (1 s cap), polls 5 s.
- App: `QueueFeed` hub, `queue_subscribe`, `start_queue` thread.
- Wall: markdown-it 15.0.3 vendored (`src/vendor/markdown-it`, sha256 in
  VENDOR.json, guard). `queue.js` walks tokens into elements and text only;
  links are text plus Copy link, never an href. `queuepanel.js` docks at
  1200 px and wider, modal dialog below; keyboard-resizable separator; width
  and open state in localStorage. Header reads "Queue · N for you".
- Tests: fleet-queue.test.js, guards (markup, vendor bytes, demo sample),
  style contrast, Rust reader and follower, seven browser cases.
- Review round 1 fixed: the Needs you count reads the shown sections; no
  spreads of long node lists, and a render that throws is a problem line;
  comments cut out wherever they sit; Copy labels and failed copies; a
  refused queue_subscribe and an unreadable prefs.json say so; a drag stores
  and measures Auto once, on release. Windows follows a link swapped in
  after the check (FILE_FLAG_OPEN_REPARSE_POINT left out for OneDrive
  placeholders); the doc says so.

## Next (2026-10-25)
- Rebased onto main 50faa64 (#82 Wrap up, #83 empty state). `speaking::read_small`
  (Wrap up's reader) now goes through `bounded::read_text` too.
- Review round 2 done: one should-fix (a changed `queue_path` waited up to two
  polls) fixed, read at once, test red first. Its nits left open: the
  post-open handle check in `bounded.rs` has no test; a link in a `##`
  heading nests a button in `<summary>`; same-titled sections share one
  open state.
- After the rebase the 945 px bar wrapped (Queue + Wrap up): below the dock
  breakpoint the label reads "Queue · N", the name keeps "for you"; a guard
  ties the CSS breakpoint to DOCK_MIN_PX. #89's Split toggle adds to this
  line, so recheck the 945 fit when #89 rebases.
- Then: closing check (round 3), CI, merge. Live check on the installed
  build, then close #86. Phase 2 (tick a Needs you item) is a separate PR.

## Verify
- `node --test src/*.test.js`
- `cd src-tauri && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings && cargo test -p klepsydra-fleet`
- every `hooks/test_*.sh`, `statusline/test_statusline.sh`, `scripts/test_*.sh`; shellcheck
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py`
- `KLEPSYDRA_STAGE=klepsydra-build-queue_panel bash scripts/build-windows.sh --check </dev/null`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
