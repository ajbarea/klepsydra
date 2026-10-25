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
- Review round 2 fixed: each sync derives its cards from the latest render
  (`reveal_race`, `reveal_does_not_arrive`, `bar_follows_empty_state`); focus
  on <body> counts as lost (`ended_only`); the folder is read again on window
  focus, latest answer only (`launch_dir_follows_prefs`); Clear hides outside
  the app (`browser_hides_app_actions`); a dev snapshot without `at` is
  filtered (`demoSnapshot`); Start answers in the bar's note
  (`launch_note_outlives_empty_state`); one `<main>` with an `h1` (`landmarks`).
- Review round 3 fixed: one launch at a time across both start buttons
  (`one_launch_at_a_time`); a cleared id stays off the link until its card
  leaves (`cleared_link_waits`); a focus request waits one snapshot only
  (`stale_focus_never_reveals`); the ring key counts shown cards only; the bar
  is a `<header>` landmark; `get_launch_dir` is async; filled buttons share
  `button.primary`; README says when the label omits the folder.

## Next
- Merge after #82 (CI green).
- After merge: live UIA check with zero sessions on the installed Windows build.

## Verify
- `node --test src/*.test.js`
- `cd src-tauri && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings && cargo test -p klepsydra-fleet`
- every `hooks/test_*.sh`, `statusline/test_statusline.sh`, `scripts/test_*.sh`
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py`
  (the empty-state cases listed in the PR body)
- `KLEPSYDRA_STAGE=klepsydra-build-empty_state bash scripts/build-windows.sh --check`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
