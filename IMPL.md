# IMPL

Slice: #22 End and Interrupt from a card. Branch feat/end-session, worktree
`.claude/worktrees/end-session`, PR #70, on main.

## Done
- Launcher `end` / `interrupt` verbs (pane + pid checks as Jump, fleet tmux
  only); `end` sends Esc, Ctrl+C, types `/exit`, presses Enter only when the
  input line reads exactly `/exit`, then waits for Claude to exit. Leaves
  tmux copy mode first; `KLEPSYDRA_END_WAIT` must be 1-3 digits.
- App: `end_session`, `interrupt_session`; a per-session `PaneFlight` gate
  so a second End of one session is refused while Jump and New run on.
- Wall: "Session actions" menu (Interrupt while working, "End session…"),
  confirm dialog naming the session with Cancel focused, 5 s undo window;
  the menu stays off from the send until `end_session` answers.

## Next
- Independent review (opus, `/code-review high`), at most 3 rounds; fix,
  CI green, merge. Then #58 (feat/wrap-up) rebases onto main.

## Verify
- `node --test src/*.test.js`
- `cd src-tauri && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings && cargo test -p klepsydra-fleet`
- every `hooks/test_*.sh`, `statusline/test_statusline.sh`, `scripts/test_*.sh`
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py`
- `KLEPSYDRA_STAGE=klepsydra-build-end_session bash scripts/build-windows.sh --check`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
