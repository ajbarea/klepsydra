# IMPL: klepsydra#421 step 3a: gauges docked in the wall header

Branch feat/gauge-header-421 (worktree .claude/worktrees/gauge-header-421), stacked on
feat/gauge-opacity-438 (#487, under review). After #487 merges: `git rebase origin/main` (drop #487's commits).
Push only with `git push --force-with-lease origin HEAD:refs/heads/feat/gauge-header-421`. Never push to main.
Design: AJ's pick on #459 (A + docked faces, gauges in both places); mockup design-pass worktree
docs/mockups/2026-11-18/wall-header.html; shots fleet-briefing/shots/2026-11-18/design-wall-header-*.png.

## Plan (the #421 brief, one PR per step)
1. ✅ #482 floating strip, variant A: merged 11-19.
2. 📋 #487 #438 opacity: round 1 fixed (6f182aa: hard halo, stale words keep ink = #486, Not saved note,
   forced colours, step test); CI on 6f182aa then Athena's round 2. Its IMPL lives on that branch.
3. **3a, this branch:** chips docked in the wall header; gear row "Gauges in wall header"; chevron hides.
   3b next (new branch off this one): floating strip hidden while the wall has focus (fleet.rs wall Focused
   events) and paused while hidden; floating strip on/off (tray + gear); Reset position; click-through.
   Both add toggles to klepsydra_fleet::toggles::ALL.
4. System chip (off by default), only after 1-3.

## Done (this branch)
- src/fleet/chips.css: the chip rules and tokens (ramp, track, route, sizes) moved out of style.css, every
  rule scoped to `.chips`; both pages link it; wall.css's ramp copy removed. style.test.js: zoom guard over
  both sheets; scoping guard (no `.chips` inside `:is()`, each rule starts `.chips`), mutation-checked.
- src/fleet/dock.js: wireDock (toChips -> syncChips, linear); toggle via toggles_subscribe /
  set_gauge_toggle (held while saving, reverts on refusal); phone read-only, always on. fleet-dock.test.js.
- klepsydra_fleet::toggles (GAUGES_IN_HEADER, find/of/all/confirm; tested) + app src-tauri/src/toggles.rs
  (Toggles hub, published at startup).
- wall.js: one read_usage reader for the dock and + New session, every 5 s while visible with the dock on,
  else 60 s; `.limits` section, gaugeview entries, ring helpers, formatPctShort, --bar-* removed (dead).
- Tests: fleet-phone.test.js rewritten for the dock; test_phone_browser.py ported to chips;
  test_wall_browser.py stub answers toggles_subscribe. README + skill-context updated.

## Next (resume here)
1. Read the browser runs (phone, wall) after the toggles stub and chip-name fixes; the wall test's 2 Ledger
   fails are on main too (#363).
2. Live: Windows build (`KLEPSYDRA_STAGE=klepsydra-build-gauge421 bash scripts/build-windows.sh`), run the exe
   with the real readings (.live/live_app.sh in the gauge-438 worktree; the wall opens from the tray); shots of
   the header at 1920 and of the phone at 390, dark and light, beside the mockup shots. Check whether
   `document.hidden` turns true when the wall is closed to the tray (WebView2); if not, pace by focus too.
3. CPU: the wall's reader is new work; measure the wall page before/after (scripts/perf) or state it.
4. PR: base feat/gauge-opacity-438 (or main once #487 merges), assignee ajbarea, label enhancement,
   "Part of #421"; short top + details; follow-up: one Rust usage hub feeding strip, wall and phone.

## Verify
- `node --test src/*.test.js`; `npm run lint`; `(cd src-tauri && cargo fmt --all --check && cargo test -p klepsydra-fleet)`.
- Heavy (flock -o /tmp/fleet-heavy.lock): `uv run -q --no-project --with playwright python -I scripts/test_phone_browser.py`,
  same for test_wall_browser.py.
