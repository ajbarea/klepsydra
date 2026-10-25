# IMPL

Slice: #32 Split mode (wall left, fleet terminal right). Branch
feat/split-mode, worktree `.claude/worktrees/split-mode`, PR #89 open;
review rounds 1 and 2 addressed.
Rebased on main 50faa64 (#82 wrap-up and #83 empty state are in); merges
after #88 and #91. Edits to shared files (main.rs handler list, wall.html
bar, wall.js, wall.css, README, test_wall_browser.py) are small insertions.

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
  applies a saved on at load (a failed one saves off); the note shows NOT_OPEN.
- Jump: unchanged behaviour; a guard (fleet-split.test.js) keeps jump.rs and
  launch.rs free of any placement call.

## Review round 1 (PR #89): five items fixed, failing test first
Linux clippy dead-code attrs; z-order (terminal stacked under the wall,
`terminal_pos_flags`); fleet tab selected (`select(tab)?`); restore through
SetWindowPlacement without activating (`restore_placement`, `hand_back`,
Windows window test); hung guard (`answering`, 500 ms WM_NULL), no window
call under the SAVED lock, Hidden note, `PREFS_WRITE`.

## Review round 2 (PR #89): five items fixed, red then green
1. Browser `ended_only_at` filtered only `get_launch_dir`, so the wall's
   load-time `get_split_mode` failed "the link clears each ended session"
   at both sizes (red: 2 failed). `READS` lists the read-only queries; any
   other call still fails it. `page.close()` restored at the end of
   `one_click_or_key_never_ends_all` (the rebase moved it).
2. Z-order fully guarded: `moves(wall, terminal, work)` plans
   [(wall, left, None), (terminal, right, Some(wall))]; test
   `the_wall_takes_the_left_and_the_terminal_goes_right_under_it`, and a JS
   source test pins split's loop to `place(hwnd(h), r, under.map(hwnd))`.
3. Hung guard tested: Windows test
   `a_window_that_stops_answering_is_refused_within_a_second` (a window on a
   thread that stops pumping; `placement` and `set_rect` each return HUNG in
   under 1 s; a 5 s recv_timeout fails instead of hanging). Mutations: guard
   off in `placement` alone fails it (read None); both off times out.
4. A saved on that fails at load: `set_split_mode` saves
   `saved_on(on, landed)` (on only once a split lands), so the pref goes off
   and the note is not repeated at every open. Rust test
   `only_a_split_that_landed_is_saved_on`; JS source test pins the write.
5. README: split drops Windows Terminal's always-on-top and off does not set
   it again (known limitation). Live check below gains the DPI case.

Red evidence: browser 2 failed before item 1; one Windows run with the old
behaviour (saved_on = on, terminal under None, both guards off) failed the
3 new Rust tests; JS 2 failed before items 2 and 4.

## Next
- Round 3: a closing check of these five by the reviewer, then merge after
  #88 and #91 (rebase on main first; rerun the gate).
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
  minimized (it must end normal on the right, the wall keeping the focus);
  off after a split across monitors with different DPI restores the same
  size.

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
