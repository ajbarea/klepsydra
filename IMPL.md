# IMPL

Current slice: the fleet strip and card wall, so one glance shows how many
Claude Code sessions are up, where each works, which need AJ and why, and what
each was last asked and said.

## Done
- ✅ `hooks/klepsydra-fleet.sh`, async on nine events: one file per session,
  written only on change through a same-directory temp file, under one lock.
  A need is cleared only by the asker's own tool; a `Notification` of type
  `idle_prompt` corrects a session still marked working or needing AJ.
- ✅ Pruning at session start, at most once an hour, deleting only names from
  its own `fleet/<uuid>.json` glob inside the absolute app data dir.
- ✅ Heartbeat from the status line, at most once per 10 s, and
  `refreshInterval: 30`.
- ✅ `src-tauri/fleet`, a crate free of Tauri: v1 parsing with time bounds
  2020 to 2100, silent after 90 s with no word, clock skew corrected from
  `written_at`, `quiet_since` for "working?", ordering, a notify watcher with
  a 5 s re-read, bad files logged once to `fleet.log`, the hub.
- ✅ Strip in the gauge window, card wall made on the first click, Jump to
  terminal through UI Automation by exact tab title.
- ✅ Ten kourai portraits cast to keryx voices; Lorelei faces for 54 Kokoro
  voices and 24 fallbacks, each licensed in `LICENSES.json`.
- ✅ A guard for every rejected idea in the spec, one that the guards scan
  every fleet source, and one that the README settings block matches the
  hook's event list. The spec's addendum records each ruling made on the way.

## Verified, not inferred
- ✅ Hook, statusline, memory-check, node and fleet-crate suites pass in WSL.
- 📋 Live check with eight real sessions (README, Releasing).
- 📋 Working set at 5 minutes and at 8 hours, growth within 10%.
- 📋 Jump to terminal takes the foreground after a click in the wall.
- 📋 A click on a portrait reaches the webview of the click-through window.
- 📋 Payload shapes come from the hooks docs; the live check confirms them.
- 📋 The app crate and clippy run only through `scripts/build-windows.sh
  --check` and CI, since WSL has no WebKitGTK.

## Open
- The default display name (`my-app-3f`) reaches no hook and no status line,
  so a session with no voice and no name is named by its launch folder.
- A denied permission dismissed with Esc keeps "needs you" until the next
  prompt, its age showing.

## Verify
    node --test src/*.test.js
    bash statusline/test_statusline.sh && bash hooks/test_fleet.sh
    bash scripts/test_measure_memory.sh
    (cd src-tauri && cargo test -p klepsydra-fleet && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings)
    bash scripts/build-windows.sh --check
    bash scripts/visual-check.sh
