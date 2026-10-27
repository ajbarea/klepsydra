# IMPL

Repo resume state (2026-10-27). The 10-26 queue is merged: #101
README lead, #103 (#90 wrap-up after every session ends; an unreadable
fleet folder keeps the last snapshot), #104 (#98 ledger attribution), #105
(#99 Queue text size), #106 (#100 reply playback, with keryx #61). Installed
build: 1ad1405 (10-25 21:48). Not yet live: #89 split mode, #93, and all of
the above.

## This branch: feat/phone-gauges (#123)
- Done: the phone wall's sticky bar shows the usage-limit gauges. Model and
  words stay in `src/gauge.js` (`entryText`, `ringStyle`, `usageRows`); the
  row's DOM moved out of `main.js` and `index.html` into `src/gaugeview.js`,
  which the gauge and the wall both import. The fleet crate's `usage.rs`
  reads `accounts/*/*.json` (`read_usage` uses it too) and cuts each reading
  for the phone (label, times, percent and reset; account id to `a1`, `a2`).
  The phone server polls a usage source every 5 s, puts `usage` on the
  snapshot, and sends only a changed one.
- Next: AJ checks the PR screenshots, then the live phone after a deploy.
- Verify: the gate list below; the phone suite now writes demo readings.

## Waits on AJ
- Deploy (his yes): `scripts/build-windows.sh` from main, stop the exe,
  installer `/S`, start; copy `hooks/klepsydra-fleet.sh` to `~/.claude/`
  (#104 changed it: home voice by edited repo, `where.git`). keryx: update
  the plugin to main 43711a2 so it writes `replies/<session>.wav`
  (`reply_clips` on by default), then restart its daemon.
- After the deploy: tap a reply clip on the iPhone wall (Safari plays via
  byte ranges; only Chromium is tested here) and check #86/#32 live.
- #52: the iPhone check over Tailscale.

## Next
1. Unfiled from #87/#98: the wall could tell home-voiced cards apart the way
   the ledger now does.
2. The card's title is Claude Code's session name; a long-lived session
   keeps its first one unless renamed (`/rename`).
3. `split::win::tests::a_maximized_then_minimized_window_is_placed_normal_without_the_focus`
   failed once on the windows-latest runner (#105 run 40404101948) and
   passed on rerun: watch for a flake.

## Follow-ups (from reviews, not blocking)
- Phone: load the Queue panel only off the phone; filter wrap-up objects
  field by field before they reach the phone.
- Queue: the post-open handle check in `bounded.rs` has no test; a link in a
  `##` heading nests a button in `<summary>`.
- Split: turning split off has no second DPI pass; split drops Windows
  Terminal's always-on-top; a stale placement survives a wall close.
- Reply clips: the phone server reads the whole clip per range request (8 MB
  cap); `-e` on a git dir reads an unreadable one as gone.

## Live checks (installed build)
- Split mode:
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
- Queue panel: an edit from WSL reaches the panel within seconds; Copy works
  in WebView2.

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
- Full gate list in `.claude/skill-context.md`; heavy commands under
  `flock /tmp/fleet-heavy.lock`; app crate via
  `KLEPSYDRA_STAGE=klepsydra-build-<name> bash scripts/build-windows.sh --check </dev/null`.
- After every rebase, rerun the wall and phone browser suites.
