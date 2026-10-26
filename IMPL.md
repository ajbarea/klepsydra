# IMPL

Repo resume state (2026-10-25, late). Main holds #82 Wrap up, #83 empty
state, #88 Queue panel (#86), #91 phone wall (part of #52), #89 split mode
(#32), #93 ledger rows for shared home voices (#87) and #92 (portrait style
prompt label). Installed build: 1ad1405, deployed 10-25 21:48 (Wrap up and
its Stop hook, empty state, Queue panel, phone wall). Not yet live: #89
split mode and #93.

## Next
1. #90: after every session ends under a wrap-up, the bar reads "0 of 0
   ready" and Safe to restart vanishes.
2. Open question from #87: sessions launched from `~/ajsoftworks` while
   keryx holds no voice all take that folder's home voice, so the wall shows
   several cards of one character (the ledger now keeps their rows apart).
   Whether the wall should tell them apart too is unfiled.

## Waits on AJ
- Deploy of #89 and #93 (his yes): `scripts/build-windows.sh` from main,
  stop the exe, installer `/S`, start. No hook or settings change this time.
- Live checks on the installed build (below), then close #86 (Queue panel)
  and, once split mode is installed, #32.
- #52: the iPhone check over Tailscale (tray "Phone wall"; README "Fleet on
  your phone"), and whether to check Serve's `Tailscale-User-Login` header.

## Follow-ups (from reviews, not blocking)
- Phone: load the Queue panel only off the phone; filter the wrap-up
  objects field by field before they reach the phone.
- Queue: the post-open handle check in `bounded.rs` has no test; a link in a
  `##` heading nests a button in `<summary>`.
- Split: turning split off has no second DPI pass; split drops Windows
  Terminal's always-on-top (README says so); a stale placement survives a
  wall close.

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
- Full gate list in `.claude/skill-context.md`; all heavy commands under
  `flock /tmp/fleet-heavy.lock`; app crate via
  `KLEPSYDRA_STAGE=klepsydra-build-<name> bash scripts/build-windows.sh --check </dev/null`.
