# IMPL

Repo resume state, 2026-10-28 16:20 (10-28 perf + logging brief; session
stopped for a lab task). Merged 10-28: #142 (KLEPSYDRA_NO_AUTOSTART), #143
(#137 Loading… nit), #144 (#138 Ledger after a sleep across midnight), #147
(perf audit: idle exe CPU 1.20% -> 0.49% of a core; `docs/perf/2026-10-28/`),
#145 (techne logging standard: JSON lines in `<data dir>/logs/klepsydra.log`,
pages through `src/log.js`, a monotonic quiet-minute repeat limiter; 4 review
rounds, last CLEAN), #152 (DiceBear 9.4.3 for the face renderer, Dependabot
alert #2; 15 of 15 seeds render identical SVGs, so LICENSES.json keeps 9.4.2).
Filed: #146 (hidden wall keeps 91-141 MB; try MemoryUsageTargetLevel Low).
Installed build: still d0e4a46, quarantined by Defender (06:57 false
positive, docs/perf/2026-10-28); AJ's running gauge was PID 24580 from
`C:\Users\ajbar\klepsydra-build-logging` (an unmerged logging build).

## This branch: fix/theme-select-dark (#151), PR not yet opened
- Commit 03b06a4 (rebased on #145): `.theme-pick select` background
  `var(--wall-bg)`, options `var(--card-bg)`, `option:checked`
  `var(--button-hover)`; browser case `theme_list_is_dark`.
  `appearance: base-select` was tried and dropped (it broke #137's arrow
  keys wearing each theme at once; Chrome 135+ opt-in only).
- Shots verified in real WebView2 (dark, 1920, demo fleet), filed as
  `fleet-briefing/shots/2026-10-28/klepsydra-151-list-{before,after}-dark.png`.
  The README line under 2026-10-28 is still to add, with the PR link. The
  chosen row keeps Windows' own light highlight; AJ judges.
  Harness: `C:\Users\ajbar\klepsydra-perf\run151.ps1 -Build <exe>` (pins
  the wall topmost, captures around the select by named args).
- Gates: node 446 pass, Biome and ruff clean on the rebased head. The wall
  and phone browser suites were queued on the lock when the session
  stopped, with no result read: rerun both before the PR.
- Next: PR (label bug, assignee ajbarea, "Closes #151", shots, sources:
  redmine.pfsense.org/issues/11730, bugs.webkit.org/show_bug.cgi?id=111873,
  developer.chrome.com/blog/rfc-customizable-select); a fresh Opus
  reviewer; merge.

## Other open PRs
- #97 Dependabot cargo group (tauri-build, hyper, tokio...): CI green
  before #145; `@dependabot rebase` asked after #145 changed Cargo.lock.
  Next: CI green on the rebase, an Opus read of the bump, merge.
- #77 feat/linux-parity: AJ's older PR, not in this brief.

## Deploy (after #151 and #97 merge)
- As on 10-27: `scripts/build-windows.sh` from main (stage
  klepsydra-build-deploy), stop the running gauge, installer `/S`, start;
  copy `hooks/klepsydra-{fleet,launch}.sh` and `hooks/klepsydra-tmux.conf`
  to `~/.claude/` with `.bak-<stamp>` backups. The installer recreates the
  exe, shortcuts and Uninstall key; AJ then ticks Start with Windows (the
  first-run marker exists, so autostart stays off). Check Defender does not
  quarantine the new exe.
- Then `scripts/perf/sample.ps1 -Path %LOCALAPPDATA%\Klepsydra\klepsydra.exe`
  for the 8-hour release memory reading (README, Releasing).

## Cleanup still open
- Worktrees: `.claude/worktrees/logging` and `dicebear` (both merged),
  `deploy-1026` (detached), `faces-place` (feat/faces-place, unmerged, not
  this brief).
- Windows folders: `C:\Users\ajbar\klepsydra-perf`,
  `klepsydra-build-logproof`, `klepsydra-logproof`,
  `klepsydra-logproof-tools`, `klepsydra-build-select151`, and
  `klepsydra-build-logging` once 24580 is gone. Guarded deletes only.

## Open
- #134: "end: the process is gone" fails now and then in full gate runs
  only; `gone()` prints its dead status, so the next failure names how the
  fake ended.
- #146: hidden wall memory (above).
- Grip watcher still makes four main-thread round trips at 2 Hz; caching
  the HWND is cheap.
- This PC's audio server was hung on 10-28; reply-playback cases ran with
  audio pointed at nothing.

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
