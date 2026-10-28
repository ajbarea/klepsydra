# IMPL

Repo resume state (2026-10-28). The 10-27 queue is merged: #126 (Open in
Claude across /clear), #127 (phone usage gauges), #129 (Windows usage-cap
test), #131 (Tauri CLI 2.12.4), #132 (README screenshots), #133 (#128
load-timing flakes), #136 (#130 Ledger side panel), #139 (launch waits, part
of #134), #140 (#124 ask line, phone Full text), #137 (#135 character
themes). #120 (Claude-orange trial) closed: AJ scrapped it.
Installed build: d0e4a46 (10-28 06:17), with the fleet and launch hooks
copied to `~/.claude/` (backups `.bak-20261028-0616`).

## In flight: feat/logging (techne logging standard)
- Rust logs through `log` + tauri-plugin-log: JSON lines in
  `<data dir>/logs/klepsydra.log` (1 MiB, 4 rotated kept), plain on stderr,
  `KLEPSYDRA_LOG` sets the level; `fleet.log` and `problem_log.rs` are gone.
  The fleet crate's receiver and phone server log through the facade.
- Pages log through `src/log.js` (`plugin:log|log`, granted in
  `src-tauri/capabilities/default.json`). Lints: workspace clippy print
  lints, Biome `noConsole`, ruff `G`/`LOG`, all in CI.
- Verified: every gate in `.claude/skill-context.md`, `logcheck.py` clean,
  and a Windows proof run (KLEPSYDRA_DIR of its own, KLEPSYDRA_NO_AUTOSTART
  from PR #142 cherry-picked locally only) logging a malformed session file
  and the taken OTLP port. Not yet seen live: a page's line through
  `plugin:log|log` (the wall suite covers it against a stubbed invoke).

## Open
- #134: "end: the process is gone" fails now and then in full gate runs
  only (twice in #136's); the suite's tmux config keeps a failed pane
  (`remain-on-exit failed`), and `gone()` now prints its dead status, so
  the next failure names how the fake ended.
- #138: Ledger midnight read: a tighter test, a second night, sleep across
  midnight.
- #137 nit: after a theme file fails, picking that theme again shows
  "Loading…" at once instead of after 3 s (`asked` is never cleared).
- This PC's audio server was hung on 10-28; the browser suites ran with
  audio pointed at nothing (reply-playback cases).

## Waits on AJ
- After the deploy: the iPhone wall (gauges, a reply clip, the theme
  switch), and #52, the iPhone check over Tailscale.

## Next
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
