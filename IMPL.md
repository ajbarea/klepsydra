# IMPL

Slice: #32 Split mode (wall left, fleet terminal right). Branch
feat/split-mode, worktree `.claude/worktrees/split-mode`, PR #89 open;
review round 1 addressed (no `/code-review high` run yet).
Lands after #82 (wrap-up), #83 (empty state) and #52 (phone wall); edits to
shared files (main.rs handler list, wall.html bar, wall.js, wall.css,
README, test_wall_browser.py) are small insertions away from theirs.

## Done
- `geometry.rs`: `halves` (floor left, rest right: exact meet for odd
  widths and negative origins), `frame_insets` (GetWindowRect minus the DWM
  extended frame bounds, clamped at 0), `widen`, `Rect::from_edges`.
- `split.rs`: `get_split_mode` / `set_split_mode`; prefs key `wall_split`
  through `read_prefs` / `write_pref` (true only once a split lands; bad
  value reads off). Windows: refuses unless the thread is per-monitor DPI
  aware; finds the fleet window through `jump::fleet_window` (UIA, exact
  `FLEET_TAB`, shared `with_tab`); work area = rcWork of the wall's monitor;
  saves both WINDOWPLACEMENTs, SW_RESTOREs a max/min window, places once,
  measures insets at the target DPI, places widened; a half-failed split
  puts both back. Off: SetWindowPlacement (showCmd made non-activating),
  skipping a closed window or a reused handle that is not a terminal.
  Placements are in memory only.
- Wall: `split.js` toggle button "Split" (name "Split with terminal",
  `aria-pressed`, hidden outside the app and off Windows) on the ring key's
  line beside Ledger, so the half-screen bar grows no taller (a first try
  beside the density control wrapped the tally and failed the 945x1000 fit);
  applies a saved on at load; the note shows NOT_OPEN.
- Jump: unchanged behaviour; a guard (fleet-split.test.js) keeps jump.rs and
  launch.rs free of any placement call.

## Review round 1 (PR #89): all five items fixed, failing test first
1. Linux clippy (CI red on d651cc2): geometry `from_edges`/`right`/`bottom`,
   `Insets`, `halves`, `frame_insets`, `widen`, split `NOT_OPEN` and the new
   pure helpers carry `cfg_attr(not(windows), allow(dead_code))`. Not
   checkable locally (no WebKitGTK); CI on the pushed head decides.
2. Z-order: the terminal's last SetWindowPos passes the wall as
   hWndInsertAfter, `terminal_pos_flags()` = NOACTIVATE|NOOWNERZORDER (no
   NOZORDER). Test `the_terminal_goes_under_the_wall_and_neither_activates`.
3. Fleet tab selected: `uia::window` runs `select(tab)?`. JS source test
   "split's lookup selects the fleet tab in the window it places".
4. Restore: SetWindowPlacement with the current placement, showCmd
   SW_SHOWNOACTIVATE, WPF_RESTORETOMAXIMIZED cleared (`restore_placement`,
   test `restoring_shows_normal_without_activating_or_maximizing`); still
   min/max is an error and both go back. A probe on Windows 11 showed that
   restoring a minimized window activates it even so (SetWindowPlacement or
   ShowWindow with SW_SHOWNOACTIVATE; SW_SHOWNA does not restore), so
   `hand_back` gives the foreground back to whoever had it
   (`give_focus_back`, test `the_focus_goes_back_only_from_a_window_that_took_it`).
   Windows-only test `a_maximized_then_minimized_window_is_placed_normal_without_the_focus`
   makes its own STATIC window, maximizes then minimizes it, places it,
   asserts not min/max, DWM frame == target, foreground unchanged.
5. SendMessageTimeoutW(WM_NULL, SMTO_ABORTIFHUNG, 500 ms) before each call
   to a window (`answering`/`responds`); no window call under the SAVED lock
   (`saved()`/`take()` copy out); TabError::Hidden has its own sentence
   (`lookup_error`, test `each_lookup_failure_has_its_own_note`);
   `write_pref_at` serialised by `PREFS_WRITE` (test
   `writers_of_different_keys_at_once_keep_every_key`); split-off hands the
   focus back too; README sentence on maximized-then-minimized.

Red first: every new Rust test failed against the old behaviour (6 FAILED
in one Windows run), the JS select test failed before `select(tab)`.
Mutations (Windows, by hand): dropping `hand_back` fails the window test;
restore flag kept, `before != moved` dropped, NOZORDER back, Hidden arm
bypassed, write lock removed each fail their test (5 of 5).

Last gate on this head: `build-windows.sh --check` green (clippy clean,
75 app tests incl. the window test); `node --test src/fleet-split.test.js`
11/11. NOT yet rerun on this head: full `node --test src/*.test.js`, hooks/
statusline/scripts suites, shellcheck, fleet fmt/clippy/test, browser
suite; CI for the pushed head not yet read.

## Next
- Run the rest of the gate (list above) and read CI for the pushed head:
  `gh api "repos/ajbarea/klepsydra/actions/runs?branch=feat/split-mode"`;
  push fixes until both Rust legs and the JS job are green.
- Review round 2; `/code-review high` not yet run; merge after #82, #83, #52.
- Live check on Windows (needs an installed build, AJ's call): open the
  fleet tab and the wall, then a UIA/PowerShell script that presses
  "Split with terminal" (InvokePattern on the button by name), reads both
  windows' DWM extended frame bounds and asserts wall.right == terminal.left,
  both tops/bottoms == rcWork, outer edges == rcWork; repeat with the
  terminal maximized, minimized and on a second monitor at another scale;
  press again and assert both GetWindowPlacement match the saved ones; Jump
  a card and assert neither rect changed. Also: a maximized browser over the
  terminal (the terminal must end above it, under the wall); the fleet tab
  not the active tab (it must be selected); a terminal maximized then
  minimized (it must end normal on the right, the wall keeping the focus).

## Sources
- GetWindowRect includes invisible borders; use DWMWA_EXTENDED_FRAME_BOUNDS,
  which is not DPI-virtualized: learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowrect
- rcNormalPosition is workspace coordinates: devblogs.microsoft.com/oldnewthing/?p=38523
- WM_DPICHANGED: a window crossing to another DPI resizes itself to the
  suggested rect: learn.microsoft.com/windows/win32/hidpi/wm-dpichanged
  (hence measure after the first move, then place again).
- Per-monitor v2 awareness: tao 0.37.1 `become_dpi_aware` (event loop
  default `dpi_aware: true`), checked at runtime with
  GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext()).

## Verify
- `node --test src/*.test.js`
- `cd src-tauri && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings && cargo test -p klepsydra-fleet`
- every `hooks/test_*.sh`, `statusline/test_statusline.sh`, `scripts/test_*.sh`
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py`
- `KLEPSYDRA_STAGE=klepsydra-build-split_mode bash scripts/build-windows.sh --check`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
