# IMPL: klepsydra#438: gauge background opacity (step 2 of #421)

Branch feat/gauge-opacity-438 (worktree .claude/worktrees/gauge-438), on main since #482 merged (958dbb2).
Push only with `git push --force-with-lease origin HEAD:refs/heads/feat/gauge-opacity-438`. Never push to main.
Design: AJ's pick on #459; thresholds from the mockup (docs/mockups/2026-11-18/mock.css `.panel.halo/.thin`,
review.md), moved by measured contrast in review: full ink below 85%, halo below 65% dark / 50% light; default 85.

## Plan (the #421 brief, one PR per step)
1. ✅ #482 floating strip, variant A: merged 11-19 (958dbb2).
2. **This branch: #438 opacity.** 0-100 step 5 in prefs.json (`gauge_opacity`, default 85), live.
3. Docked gauges in the wall header + floating strip hidden while the wall has focus + Settings › Gauges rows
   (+ #479 double, #481 tap/keyboard detail). Phone dockKey needs an id mapping (usage ids are a1..).
4. System chip (off by default), only after 1-3.

## Done (this branch)
- klepsydra_fleet::opacity (KEY, DEFAULT 85, snap, of, value, confirm; tested); app src-tauri/src/opacity.rs
  (`Opacities` hub, `opacity_subscribe`, `set_gauge_opacity`, published at startup); phone serves opacity.js.
- src/opacity.js (inkFor thresholds, applyOpacity; tested); main.js follows it and redraws on ink change;
  style.css `--panel-alpha`, ink tokens on #panel, `[data-clear]`.
- Wall gear slider (src/fleet/opacitypick.js: saves once it rests or on release; tested), README section.
- Live (pre-round-1 build, stage klepsydra-build-gauge421): taskbar at 0% and 100% work
  (/mnt/c/Users/ajbar/klepsydra-live-gauge421/exe438-op{0,100}.png).
- Review round 1 fixed (809f5b6: thresholds by measured contrast, full ink <85, halo <65 dark / <50 light).
- 11-19 session 2 (Personal): rounds 2 and 3 fixed (resets and route word take the ink, a stale chip keeps
  its dim, solid under prefers-reduced-transparency, tray cache, confirm checks the stored key); #484 filed for
  the theme save's twin gap. Rebased on main; toRows duplicate keys removed, biome noDuplicateObjectKeys on.
  Pushed (no PR yet). Live harness: .live/live_opacity.py (real readings, 0/50/100, both schemes, both desktops).

## Next
2. Rebuild (`KLEPSYDRA_STAGE=klepsydra-build-gauge421 bash scripts/build-windows.sh`, PR 1's stage, under the
   heavy lock), live check via `.live/live_app.sh` (OPACITY=0|50|100 env), dark + light desktop.
3. Browser shots 1920/390 dark/light at ?opacity=0|50|100 -> fleet-briefing shots/2026-11-19/klepsydra-438-*.
4. CPU: `measure_gauge.py <main worktree> . .live/readings.json .live/fleet.json 120 3 [query]` under the
   heavy lock, at `layout=compact` and `layout=compact&opacity=0` (before = main 958dbb2).
5. PR base main, assignee ajbarea,
   label enhancement, "Closes #438"; CI; report to Heph. Then step 3 (wall header) on a new branch off this one.

## Verify
- `node --test src/*.test.js`; `npm run lint`; `(cd src-tauri && cargo fmt --all --check && cargo test -p klepsydra-fleet)`.
