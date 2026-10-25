# IMPL

Slice: #32 Split mode (wall left, fleet terminal right). Branch
feat/split-mode, worktree `.claude/worktrees/split-mode`. PR not opened yet.
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

## Next
- Independent review (opus, `/code-review high`), at most 3 rounds; open PR
  citing the sources below; CI green; merge after #82, #83, #52.
- Live check on Windows (needs an installed build, AJ's call): open the
  fleet tab and the wall, then a UIA/PowerShell script that presses
  "Split with terminal" (InvokePattern on the button by name), reads both
  windows' DWM extended frame bounds and asserts wall.right == terminal.left,
  both tops/bottoms == rcWork, outer edges == rcWork; repeat with the
  terminal maximized, minimized and on a second monitor at another scale;
  press again and assert both GetWindowPlacement match the saved ones; Jump
  a card and assert neither rect changed.

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
