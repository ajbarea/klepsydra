# IMPL: klepsydra#421 + #438: gauge strip, variant A with docked faces

Branch feat/gauge-strip-a-421 (worktree .claude/worktrees/gauge-421). Decision: PR #459 last comment (AJ 11-18).
Mockups: branch design/mockups-1118, docs/mockups/2026-11-18 (gauge-a.html, strip.js/css, readings.js, wall-header.html, settings-a.html).
Untracked helpers in `.live/` (excluded): live_strip.py (browser shots from real readings + live fleet at 127.0.0.1:8318),
live_app.sh (test copy of a branch klepsydra.exe beside AJ's, own KLEPSYDRA_DIR, backs up/restores the shared
%APPDATA% .window-state.json, stops only its own PID), pr1.md (PR body draft), readings.json + fleet.json (frozen real data for perf).
**Fix SP= in both scripts to the new session's scratchpad (or .live) before running.**

## Plan: one PR per step
1. **PR 1 (this branch): floating strip as variant A.** Code done, committed (see git log). Not yet a PR.
2. **PR 2: #438 opacity** 0-100 step 5 in prefs.json, live. Copy the theme pattern: `set_theme` + Hub publish + `theme_subscribe`
   (src-tauri/src/theme.rs) as `set_gauge_opacity` / `gauge_subscribe`; slider in the wall's gear (src/wall.html `.gear .view`).
   Halo below 60% (dark) / 50% (light), full ink below 70% (mockup mock.css `.panel.halo/.thin`).
3. **PR 3: docked gauges in the wall header** + floating strip hidden while the wall has focus + Settings › Gauges rows (+ #479 double).
   Phone: usage ids are anonymised (a1..) by usage.rs but sessions keep real account ids, so dockKey needs a mapping there.
4. **PR 4: System chip** (off by default), only after 1-3.

## Done (PR 1)
- chips.js (model, 17 tests), chipview.js, icons.js (MAKER_ICONS moved), strip.js `dock`/`root` options (3 dock tests,
  mutation-checked), main.js/index.html/style.css (light scheme added), README + readme-shots.py updated, #479 filed.
- Dropped the hard-coded "ends Nov 18" note: `agy models` on 11-19 still lists Claude Sonnet/Opus 4.6 and GPT-OSS.
- Live in Chromium with real readings + live fleet: linear 771x42 px, faces docked (agy 1, Personal 2, RIT 1), no errors.
- CPU sanity (10 s, main only): ~0.1-0.2% of a core. Full before/after run was stopped by the account move.

## Next
1. Perf: `flock -o /tmp/fleet-heavy.lock timeout 1800 uv run -q --no-project --with playwright python -I scripts/perf/measure_gauge.py <main worktree> . .live/readings.json .live/fleet.json 120 3`
   (make a detached main worktree first: `git -C ~/ajsoftworks/klepsydra worktree add --detach <dir> origin/main`; remove it after).
2. Windows build: `KLEPSYDRA_STAGE=klepsydra-build-gauge421 flock -o /tmp/fleet-heavy.lock timeout 3000 bash scripts/build-windows.sh`,
   then `.live/live_app.sh start 'C:\Users\ajbar\klepsydra-build-gauge421\src-tauri\target\release\klepsydra.exe' compact`,
   `shot name` and `shot name X Y` (hover: is the native title tooltip shown in the unfocused window?), `stop` (restores window state).
3. Independent Opus review (stopped mid-run; start fresh), fix, regenerate README bar shots (readme-shots.py bar() only).
4. Shots to fleet-briefing/shots/2026-11-19/klepsydra-421-*.png + README line; PR (assignee ajbarea, label enhancement, "Part of #421"),
   CI green, report to Heph (`fleet send`), queue line. Do not merge.

## Verify
- `node --test src/*.test.js` (530 pass at 2de19ec); `npm run lint`.
