# IMPL

Slice: #46 First-use empty state kept by Hesychia. Branch feat/empty-state,
worktree `.claude/worktrees/empty-state`, PR #83 open.

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
- Review round 1 fixed: a long `launch_dir` stays in a narrow window
  (`long_folder_fits`); the label names a folder only when `new_args`
  accepts the folder and the distro (`the_label_names_a_folder_only_when_the_launch_would_run`);
  Auto skips the hidden wall and measures on reveal, no card arrives unseen
  (`reveal_density`); Start and Clear have their own notes (`separate_notes`);
  `ended_only` runs at 1920x1000 and 945x1000.

## Next
- Review round 2 on PR #83 (at most 3 rounds), then CI green and merge.
- After merge: live UIA check with zero sessions on the installed Windows build.

## Verify
- `node --test src/*.test.js`
- `cd src-tauri && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings && cargo test -p klepsydra-fleet`
- every `hooks/test_*.sh`, `statusline/test_statusline.sh`, `scripts/test_*.sh`
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py`
  (`empty_state`, `ended_only`, `long_folder_fits`, `reveal_density`,
  `separate_notes` for this slice)
- `KLEPSYDRA_STAGE=klepsydra-build-empty_state bash scripts/build-windows.sh --check`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
