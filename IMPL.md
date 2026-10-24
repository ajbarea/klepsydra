# IMPL

Slice: #46 First-use empty state kept by Hesychia. Branch feat/empty-state,
worktree `.claude/worktrees/empty-state`. No PR yet.

## Done
- `src/fleet/empty.js`: the wall's state (empty / only ended / cards), the
  start label, the clear-N label, `clearAll` (clear_session per ended id).
- Wall: `<section id="empty">` in the wall's place: Hesychia's full portrait
  (decorative, `alt=""`), "All quiet.", one line on what will appear,
  **Start a session in <launch_dir>** (the same `launch_session` call and
  note as + New session, hidden outside the app), and with only ended cards
  a quiet **Clear N ended sessions** link. A fade only, none under reduced
  motion. Focus that was in the wall goes to the empty state's title.
- Only ended cards: the empty state replaces them (Carbon: an empty state
  replaces the element it stands for). A focus request for an ended card
  (a strip click) shows the ended cards until a session starts or all clear.
- App: read-only `get_launch_dir` (None when prefs.json is unreadable or
  `launch_dir` is not a folder the launch takes); `launch_session` reads the
  folder through the same helper.
- Demo: `?demo&empty`, `?demo&ended`.

## Next
- Open the PR (label enhancement, Closes #46), independent review (opus,
  `/code-review high`), at most 3 rounds; fix, CI green, merge.
- Live UIA check with zero sessions on the Windows build (issue's Done when).

## Verify
- `node --test src/*.test.js`
- `cd src-tauri && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings && cargo test -p klepsydra-fleet`
- every `hooks/test_*.sh`, `statusline/test_statusline.sh`, `scripts/test_*.sh`
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py`
  (`empty_state`, `ended_only` for this slice)
- `KLEPSYDRA_STAGE=klepsydra-build-empty_state bash scripts/build-windows.sh --check`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
