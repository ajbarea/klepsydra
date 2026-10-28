# IMPL

Repo resume state, 2026-10-28 19:05. The 10-28 perf + logging brief is done
and deployed; the session stopped there for an LDQIS brief (Heph's call).
Merged 10-28: #142 (KLEPSYDRA_NO_AUTOSTART), #143 (#137 Loading… nit), #144
(#138 Ledger across midnight), #147 (perf audit: idle exe CPU 1.20% -> 0.49%
of a core; `docs/perf/2026-10-28/`), #145 (techne logging standard: JSON
lines in `<data dir>/logs/klepsydra.log`), #152 (DiceBear 9.4.3), #153
(cargo bumps; #97 closed for it), #155 (#151: the Characters list opens dark;
shots in `fleet-briefing/shots/2026-10-28/klepsydra-151-*`, AJ judges the
chosen row's light Windows highlight).

## Installed build
- e7a83d3, installed 10-28 18:59 from stage `klepsydra-build-deploy`
  (`scripts/build-windows.sh`, NSIS `/S`); running from
  `%LOCALAPPDATA%\Klepsydra`; Start menu shortcut and Uninstall key back.
  Defender: no detection in the minutes after install and start.
- `~/.claude/klepsydra-{fleet,launch}.sh` and `klepsydra-tmux.conf` already
  matched main, so nothing was copied.
- Not yet done: the 8-hour release memory reading
  (`scripts/perf/sample.ps1 -Path %LOCALAPPDATA%\Klepsydra\klepsydra.exe`,
  README, Releasing).

## Next (next free slot)
1. `task-fleet-module.src` (same folder as this brief): the fleet module in
   klepsydra, both accounts at once, then #148, #149, #150.
2. #154: recover the fleet after a hard shutdown with one command.
3. Logging follow-ups from #145's reviews, if any are still open.

## Cleanup still open
- Worktrees: `.claude/worktrees/logging`, `dicebear` and `select151`
  (merged), `deploy-1026` (detached, used for the deploy), `faces-place` (feat/faces-place, unmerged, not
  this brief).
- Windows folders: `C:\Users\ajbar\klepsydra-perf`,
  `klepsydra-build-logproof`, `klepsydra-logproof`,
  `klepsydra-logproof-tools`, `klepsydra-build-select151`,
  `klepsydra-build-logging` (its gauge is stopped). Keep
  `klepsydra-build-deploy` (incremental deploys). Guarded deletes only.

## Open
- #134: "end: the process is gone" fails now and then in full gate runs
  only; `gone()` prints its dead status, so the next failure names how the
  fake ended.
- #146: a hidden wall keeps 91-141 MB; try MemoryUsageTargetLevel Low.
- Grip watcher still makes four main-thread round trips at 2 Hz; caching
  the HWND is cheap.
- This PC's audio server was hung on 10-28; reply-playback cases ran with
  audio pointed at nothing.

## Waits on AJ
- Tick Start with Windows in the tray (the reinstall leaves it off).
- Judge the #151 shots.
- On the new build: the iPhone wall (gauges, a reply clip, the theme
  switch), and #52, the iPhone check over Tailscale.

## Ideas
1. Unfiled from #87/#98: the wall could tell home-voiced cards apart the way
   the ledger now does.
2. The card's title is Claude Code's session name; a long-lived session
   keeps its first one unless renamed (`/rename`).

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
