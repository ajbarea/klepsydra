<!-- budget: 1300 words, sources excluded -->
# Performance audit, 2026-10-28

This audit measures klepsydra.exe and its own WebView2 processes on the home PC: an AMD Ryzen 5 3600X (6 cores, 12 threads) running Windows 11 Home with WebView2 Runtime 155.0.4283.62. CPU is a percent of one logical core (the machine has 12). Memory is private bytes summed over the exe and its WebView2 processes.

**Result.** One thing measured badly and is fixed: the Rust shell woke its UI thread 60 times a second at idle. The exe's idle median fell from 1.20% to 0.49% of a core, and the whole process tree's from 1.51% to 0.75%. Memory over two live spans (18 and 48 minutes) showed no leak but no 8-hour reading yet; render cost (below) needs no change.

## How it was measured

- **Live:** `scripts/perf/sample.ps1` read the CPU time and memory of `klepsydra.exe` and its WebView2 processes every 3 minutes (`live.csv`). Two spans are clean, with the real fleet running and the wall open: the installed d0e4a46 build, 06:39 to 06:57 (Defender closed it), and the same build from its build folder, 07:00 to 07:48. Later rows caught test copies too; the sampler now matches by path.
- **Controlled:** `scripts/perf/run.ps1` starts a build with its own data folder (`KLEPSYDRA_DIR`), its own WebView2 user data folder, `KLEPSYDRA_NO_AUTOSTART=1` (#142) and a DevTools port. Its data folders hold 0, 3, 6 or 10 demo sessions, written first by `scripts/perf/fixture.py` from `scripts/fixtures/fleet-demo.json`. It measures, in order:
  1. idle with only the gauge, for 120 s;
  2. idle with the wall shown, for 120 s;
  3. the wall reloaded 5 times, timed from navigation start to N cards in the new document's DOM (`cdp.mjs cold`);
  4. one session file rewritten 5 times as the hook writes it, with the renderer's main-thread time (`Performance.getMetrics` TaskDuration) over the 3 s after each write, counted only once the card shows the new reply, next to a quiet 3 s just before (`cdp.mjs update`);
  5. the wall closed (it hides), then idle for 120 s.

  The raw output is in `run-1.txt`, `run-2.txt` and `run-3.txt`; `environment.txt` holds the machine, the WebView2 version and Defender's history. Baseline is main with #142 (C:\Users\ajbar\klepsydra-build-noauto); "fix" is the same plus the change below (klepsydra-build-perf).
- **Not used:** readings spoiled by two harness bugs in `run-1.txt` (a `-Cards` list read as 3610; JS quotes PowerShell 5.1 stripped, so the wall never opened), both fixed.

Guidance read first: Microsoft's WebView2 performance page (2026-09-02) recommends one environment per app (klepsydra's windows share one browser process), CSS over JS animation, few host messages, and a Low memory target for an inactive WebView.

## Idle CPU

Gauge only, 0 cards, 120 s each, three alternating pairs (`run-2.txt`, "ab"):

| | exe, each run | exe median | whole tree median (range) |
|---|---|---|---|
| baseline | 1.33, 1.20, 1.18 | 1.20% | 1.51% (1.50 to 1.58) |
| fix | 0.38, 0.49, 0.51 | 0.49% | 0.75% (0.73 to 0.87) |

Live, wall open and sessions writing, the tree used 4.95% (18 minutes) and 4.98% (48 minutes), the exe 2.03% and 2.33%.

**Cause.** The grip watcher (`watch_grip`, `src-tauri/src/main.rs`) polls the pointer every 16 ms to make the click-through gauge interactive over its handle. It used `AppHandle::cursor_position()`, which in tauri-runtime-wry 2.12.1, off the main thread, sends the event loop a message and waits for the answer (`event_loop_window_getter!`, `lib.rs:2654`). So the UI thread woke 60 times a second, even when nothing moved.

**Fix.** `pointer()` calls `GetCursorPos` on the watcher thread: the call tao itself makes for `cursor_position` (tao 0.37.1, `platform_impl/windows/util.rs:216`), in the same physical pixels since the process is per-monitor DPI aware. Four main-thread round trips remain, twice a second: three for the window's placement and one for the window handle the taskbar re-assert uses.

## Memory

| | private MB |
|---|---|
| gauge only, 0 cards | 155 to 159 |
| gauge only, 10 cards | 163; once 256 (GPU process at 150 MB, fix build, `run-1.txt`) |
| wall shown, 3 / 6 / 10 cards | 258 / 301 / 263 to 301 |
| wall hidden, 3 / 6 / 10 cards | 265 / 294 / 281 to 308 |
| live, wall open, 06:39 to 06:57 | 328 to 338, first 329, last 327 |
| live, wall open, 07:00 to 07:48 | 310 to 371; 354 at start (GPU process at 186 MB), then 310 at 07:03 rising to 345, peak 371 at 07:33 |

The first span is flat. The second rose 11% from 07:03 to 07:48, too short to tell a leak from a working set settling; the README's 8-hour release reading decides that, and is taken at the next deploy. The wall adds 94 to 141 MB, mostly its renderer and the GPU process, and keeps it while hidden. Microsoft suggests `MemoryUsageTargetLevel` Low for a WebView that is not in use; tauri and wry have no API for it, and Microsoft gives no figure for the saving. #146 tracks measuring it.

## Render cost

From `run-3.txt` (fix build, the probe gated on the new document and on the card showing the new reply):

| cards | navigation start to N cards in the DOM (5 reloads) | file write to the card showing it (5) | renderer time per update (5) |
|---|---|---|---|
| 3 | 63 to 74 ms | 92 to 101 ms | 4.2 to 23.6 ms |
| 6 | 89 to 100 ms | 95 to 105 ms | 6.0 to 33.5 ms |
| 10 | 101 to 114 ms | 96 to 108 ms | 8.1 to 23.6 ms |

The first update after a reload costs most (23.6, 33.5, 23.6 ms); the others 4.2 to 14.3. A quiet 3 s costs 0.2 to 1.2 ms, or 3.8 to 6.6 ms when the 15 s tick falls in it, which it does in the fifth window of each series. The earlier runs, whose probe did not check the redraw, agree (65 to 195 ms to N cards; 3.5 to 28 ms per update, once 121). With nothing changing, renderers spend per minute 18 to 39 ms on the shown wall, 29 to 39 on the hidden one (once 473), and 22 to 27 on the gauge.

## Windows Defender, 06:57

The first harness ran a copy of the installed exe (`kperf.exe`) with its own data folder. The copy re-registered the login entry with its own path, as `tauri-plugin-autostart` does when it is enabled, and the harness wrote the original back from PowerShell. Defender's history (`environment.txt`):

- 06:57:10, `Behavior:Win32/Persistence.A!ml` (Suspicious Behavior, Severe), PowerShell writing the Run entry, resource `kperf.exe`; remediation failed (status 103).
- 06:57:16 and 06:57:34, `Trojan:Win32/Bearfoos.B!ml` on `kperf.exe`, quarantined.
- 06:57:53, the same on the installed app, quarantined as one item: the exe, both shortcuts, the `Uninstall` key and the `Run` value; the running app stopped.

`!ml` marks a machine-learning verdict, not a signature match. The trigger was an unsigned copy in a user folder rewriting a Run entry and another process rewriting it back. #142 keeps test copies off the entry, and the harness never writes it.

How to keep it from happening again:

1. **Report the false positive** (WDSI file submission, "incorrectly detected") with the hash and both detection names: free and can clear it for everyone, but slow and not guaranteed.
2. **Sign release builds** with Azure Artifact Signing (formerly Trusted Signing): open to individual developers in the US and Canada, about $9.99 a month, and supported by Tauri's `bundle.windows.signCommand`. Reputation builds over releases signed with one certificate.
3. **A narrow exclusion** AJ adds himself (admin): `%LOCALAPPDATA%\Klepsydra` only. It is quick, but that folder is then unscanned.

Option 1 now, and 2 if a detection returns, keeps the most protection. No Defender setting was changed.

## Sources

- Microsoft, Performance best practices for WebView2 apps (2026-09-02): https://learn.microsoft.com/microsoft-edge/webview2/concepts/performance
- Microsoft, `CoreWebView2.MemoryUsageTargetLevel`: https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2.memoryusagetargetlevel
- Microsoft, `CoreWebView2.TrySuspendAsync`: https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2.trysuspendasync
- Tauri, Windows code signing (Azure Artifact Signing, `signCommand`, SmartScreen reputation): https://v2.tauri.app/distribute/sign/windows/
- Tauri autostart plugin: https://v2.tauri.app/plugin/autostart/
- Azure Artifact Signing pricing: https://azure.microsoft.com/pricing/details/artifact-signing/ ; eligibility and price as of June 2026: https://codenote.net/ja/posts/ov-ev-code-signing-certificate-pricing-japan-2026/
- `!ml` detections on unsigned installers (MakeMKV, Bearfoos.B!ml): https://forum.makemkv.com/forum/viewtopic.php?p=201257
- Microsoft Q&A, false-positive submissions for signed apps: https://learn.microsoft.com/en-ca/answers/questions/5929545/microsoft-defender-false-positive-and-wdsi-submiss
