<!-- budget: 1300 words, sources excluded -->
# Performance audit, 2026-10-28

This audit measures klepsydra.exe and its own WebView2 processes on the home PC: an AMD Ryzen 5 3600X (6 cores, 12 threads) running Windows 11 Home with WebView2 Runtime 155.0.4283.62. CPU is given as a percent of one logical core, so 100% is one core fully busy and the machine has 12. Memory is private bytes, summed over the exe and its WebView2 processes; working set (which double-counts shared pages) is in the raw files only.

**Result.** One thing measured badly and is fixed. The Rust shell kept the UI thread awake 60 times a second at idle, about 1.2% of a core. After the fix the median is 0.49%, and the whole process tree went from 1.51% to 0.75%. Memory stayed flat over 66 minutes of live use. A wall update costs 3.5 to 28 ms of renderer main-thread time (once 121 ms), and a full wall paints its cards in 65 to 195 ms. Neither needs a change.

## How it was measured

- **Live:** `scripts/perf/sample.ps1` read the CPU time and memory of `klepsydra.exe` and its WebView2 processes every 3 minutes (`live.csv`). Two spans are clean, 66 minutes, with the real fleet running and the wall open: the installed d0e4a46 build from 06:39 to 06:57 (when Defender closed it, below) and the same build from its build folder, 07:00 to 07:48. Later rows also caught the test copies, since the sampler then matched the first process named klepsydra; it now matches the installed path.
- **Controlled:** `scripts/perf/run.ps1` starts a build with its own data folder (`KLEPSYDRA_DIR`), its own WebView2 user data folder, `KLEPSYDRA_NO_AUTOSTART=1` (#142) and a DevTools port. It feeds the build 0, 3, 6 or 10 demo sessions (`scripts/perf/fixture.py`, from `scripts/fixtures/fleet-demo.json`) and measures in this order:
  1. idle with only the gauge, for 120 s;
  2. idle with the wall shown, for 120 s;
  3. the wall reloaded 5 times, timed to the moment N cards are drawn (`cdp.mjs cold`);
  4. one session file rewritten 5 times as the hook writes it, with the renderer's main-thread time (`Performance.getMetrics` TaskDuration) over the 3 s after each write, next to a quiet 3 s just before (`cdp.mjs update`);
  5. the wall closed (it hides), then idle for 120 s.

  The raw output is in `run-1.txt` and `run-2.txt`. Baseline is main with #142 (C:\Users\ajbar\klepsydra-build-noauto); "fix" is the same plus the change below (klepsydra-build-perf).
- **Not used:** two harness bugs (a `-Cards` list PowerShell's `-File` read as 3610, and JS quotes PowerShell 5.1 stripped, so the wall never opened) spoiled part of `run-1.txt`; both are fixed, and only valid readings are quoted. The baseline 3-card copy was closed from outside before its last reading.

Guidance read first: Microsoft's WebView2 performance page (2026-09-02) recommends one environment per app (klepsydra's two windows share one browser process), CSS over JS animation, few host messages, and `MemoryUsageTargetLevel` Low or `TrySuspend` for an inactive WebView. Tauri issue #5889 reports a hidden window's renderer kept busy by a CSS loop; klepsydra's CSS animations all run once.

## Idle CPU

Gauge only, 0 cards, 120 s each, three alternating pairs (`run-2.txt`, "ab"):

| | exe, each run | exe median | whole tree median (range) |
|---|---|---|---|
| baseline | 1.33, 1.20, 1.18 | 1.20% | 1.51% (1.50 to 1.58) |
| fix | 0.38, 0.49, 0.51 | 0.49% | 0.75% (0.73 to 0.87) |

Live, with the wall open and sessions writing all the time, the tree used 4.95% of a core (installed build, 18 minutes) and 4.98% (build folder, 48 minutes). The exe's share was 2.03% and 2.33%.

**Cause.** The grip watcher (`watch_grip`, `src-tauri/src/main.rs`) polls the pointer every 16 ms so that it can make the click-through gauge interactive over its handle. It read the pointer with `AppHandle::cursor_position()`. In tauri-runtime-wry 2.12.1 that call, from any thread but the main one, sends a message to the event loop and waits for the answer (`event_loop_window_getter!`, `lib.rs:2654`). So the UI thread woke 60 times a second, even when nothing moved.

**Fix.** `pointer()` calls `GetCursorPos` on the watcher thread: the call tao itself makes for `cursor_position` (tao 0.37.1, `platform_impl/windows/util.rs:216`), in the same physical pixels since the process is per-monitor DPI aware. The 2 Hz placement read and taskbar re-assert still use the main thread.

## Memory

| | private MB |
|---|---|
| gauge only, 0 cards | 155 to 160 |
| gauge only, 10 cards | 160 to 163; once 256 (GPU process at 150 MB, fix build, `run-1.txt`) |
| wall shown, 3 / 6 / 10 cards | 258 / 301 / 263 to 301 |
| wall hidden, 3 / 6 / 10 cards | 265 / 294 / 281 to 308 |
| live, wall open, 66 min | 310 to 371, first 354, last 345 |

Live memory did not grow: it ended within 3% of its start, its peak mid-span. The wall adds 100 to 140 MB, mostly its renderer and the GPU process, and keeps it while hidden. Microsoft suggests `MemoryUsageTargetLevel` Low for a WebView that is not in use; tauri and wry have no API for it, and Microsoft gives no figure for the saving. That is filed as a follow-up to measure, not changed here. The release rule's 8-hour reading (README, Releasing) is still to be taken on the next deploy.

## Render cost

| cards | first paint to N cards (5 reloads) | renderer time per update, after the first |
|---|---|---|
| 3 | 65 to 73 ms | 3.5 to 8.2 ms |
| 6 | 87 to 195 ms, median 105 | 5.8 to 11.2 ms |
| 10 | 100 to 162 ms, median 113 | 7.1 to 27.9 ms |

The first update after a reload costs 22 to 27 ms, and once 121 ms with 10 cards (32 layouts and 44 style recalculations in that window). A quiet 3 s costs 0.2 to 0.5 ms. With the wall shown and nothing changing, its renderer spends 15 to 31 ms per minute on the 15 s tick. The gauge page spends 9 to 45 ms per minute.

## Windows Defender, 06:57

The first harness ran a copy of the installed exe (`kperf.exe`) with its own data folder. On start, the copy found the installed app's login entry enabled and re-registered it with its own path, as `tauri-plugin-autostart` does. The harness then wrote the original value back from PowerShell. Defender's history (`Get-MpThreatDetection`, read only):

- 06:57:10, `Behavior:Win32/Persistence.A!ml` (Suspicious Behavior, Severe), PowerShell writing the Run entry, resource `kperf.exe`; remediation failed (status 103).
- 06:57:16 and 06:57:34, `Trojan:Win32/Bearfoos.B!ml` on `kperf.exe`, quarantined.
- 06:57:53, the same detection on the installed app, quarantined as one item: `%LOCALAPPDATA%\Klepsydra\klepsydra.exe`, the Start-menu and Desktop shortcuts, the `Uninstall\klepsydra` key and the `Run\klepsydra` value, with the running process (PID 25696) stopped.

`!ml` marks a machine-learning verdict, not a signature match. The trigger was an unsigned copy in a user folder rewriting a Run entry and another process rewriting it back. #142 keeps test copies off the entry, and the harness never writes it.

How to keep it from happening again:

1. **Report the false positive** to Microsoft (WDSI file submission, "incorrectly detected") with the hash and both detection names. It is free and can clear the verdict for everyone, but takes days and is not guaranteed.
2. **Sign release builds** with Azure Artifact Signing (formerly Trusted Signing): open to individual developers in the US and Canada, about $9.99 a month, and supported by Tauri's `bundle.windows.signCommand`. Reputation builds over releases signed with one certificate.
3. **A narrow exclusion** AJ adds himself (admin): `%LOCALAPPDATA%\Klepsydra` only. It is quick, but that folder is then unscanned.

Option 1 now, and option 2 if a detection returns, keeps the most protection. No Defender setting was changed in this audit.

## Sources

- Microsoft, Performance best practices for WebView2 apps (2026-09-02): https://learn.microsoft.com/microsoft-edge/webview2/concepts/performance
- Microsoft, `CoreWebView2.MemoryUsageTargetLevel`: https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2.memoryusagetargetlevel
- Microsoft, `CoreWebView2.TrySuspendAsync`: https://learn.microsoft.com/en-us/dotnet/api/microsoft.web.webview2.core.corewebview2.trysuspendasync
- Tauri issue #5889, idle CPU from a hidden window: https://github.com/tauri-apps/tauri/issues/5889
- Tauri, Windows code signing (Azure Artifact Signing, `signCommand`, SmartScreen reputation): https://v2.tauri.app/distribute/sign/windows/
- Tauri autostart plugin: https://v2.tauri.app/plugin/autostart/
- Azure Artifact Signing pricing: https://azure.microsoft.com/pricing/details/artifact-signing/ ; eligibility and price as of June 2026: https://codenote.net/ja/posts/ov-ev-code-signing-certificate-pricing-japan-2026/
- `!ml` detections on unsigned installers (MakeMKV, Bearfoos.B!ml): https://forum.makemkv.com/forum/viewtopic.php?p=201257
- Microsoft Q&A, false-positive submissions for signed apps: https://learn.microsoft.com/en-ca/answers/questions/5929545/microsoft-defender-false-positive-and-wdsi-submiss
