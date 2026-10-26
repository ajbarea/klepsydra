# IMPL

Repo resume state (2026-10-25). Main holds #82 Wrap up, #83 empty state,
#88 Queue panel (#86), #91 phone wall (part of #52), #89 split mode (#32).
None of these is deployed: the installed build is still 4bc0fb9 (10-22).

## Next
1. #87: the ledger credits every session to one character when sessions
   share a voice. Attribute by the card's character; test three sessions
   sharing one voice.
2. Queue item 17: AJ's shared portrait style prompt and negative prompt,
   word for word, into `docs/characters/portrait-briefs.md` (docs-only PR;
   text in the archived brief under `~/.local/state/fleet-orchestrator/archive/`).
3. #90: after every session ends under a wrap-up, the bar reads "0 of 0
   ready" and Safe to restart vanishes.

## Waits on AJ
- Deploy (his yes): copy `hooks/klepsydra-wrapup.sh` and the updated
  `hooks/klepsydra-fleet.sh` (stamps `turn_at`, reads the Remote Control
  link) to `~/.claude/`; the skill `hooks/klepsydra-wrapup.md` to
  `skills/klepsydra-wrapup/SKILL.md` in `~/.claude` and `~/.claude-personal`;
  the README's Stop hook block into both `settings.json`; then
  `scripts/build-windows.sh` from main, stop the exe, installer `/S`, start.
- After the deploy: the live checks below, then close #86 (Queue panel)
  and #32 (split mode).
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
