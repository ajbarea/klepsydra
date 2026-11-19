# IMPL: klepsydra#438: gauge background opacity (step 2 of #421)

Branch feat/gauge-opacity-438 (worktree .claude/worktrees/gauge-438), cut `--no-track` from
feat/gauge-strip-a-421-v2 (PR #482), so its PR is stacked: base it on that branch until #482 merges, then
rebase onto main. Push only with `git push -u origin HEAD:refs/heads/feat/gauge-opacity-438`. Never push to main.
Design: AJ's pick on #459; thresholds from the mockup (docs/mockups/2026-11-18/mock.css `.panel.halo/.thin`,
review.md): halo below 60% dark / 50% light, full ink below 70%.

## Plan (the #421 brief, one PR per step)
1. #482 floating strip, variant A: in review (Heph).
2. **This branch: #438 opacity.** 0-100 step 5 in prefs.json (`gauge_opacity`, default 80), live.
3. Docked gauges in the wall header + floating strip hidden while the wall has focus + Settings › Gauges rows
   (+ #479 double, #481 tap/keyboard detail). Phone dockKey needs an id mapping (usage ids are a1..).
4. System chip (off by default), only after 1-3.

## Done (this branch)
- klepsydra_fleet::opacity (KEY, DEFAULT, snap, of, value, confirm; tested); app src-tauri/src/opacity.rs
  (`Opacities` hub, `opacity_subscribe`, `set_gauge_opacity`, published at startup); phone serves opacity.js.
- src/opacity.js (inkFor thresholds, applyOpacity on :root so readStops sees the halo ramp; tested);
  main.js follows it and redraws; style.css `--panel-alpha`, `:root[data-ink=full|halo]`, `[data-clear]`.
- Wall gear slider (src/fleet/opacitypick.js: echoes held while saves are in flight; tested), README section.

## Next
1. `KLEPSYDRA_STAGE=klepsydra-build-gauge438 bash scripts/build-windows.sh --check` (app crate compiles only
   on Windows), then a full build to the same stage and the live check: test copy via the PR 1 worktree's
   `.live/live_app.sh` (copy it here; it copies the real readings and the fleet folder with timestamps).
2. Shots: browser at 1920, `?opacity=0|50|100`, dark and light desktop and scheme; exe on the taskbar at 0 and 100.
3. CPU before/after (scripts/perf/measure_gauge.py vs the #482 head), fresh Opus review, PR (base the #482
   branch, assignee ajbarea, label enhancement, "Closes #438"), CI, report to Heph.

## Verify
- `node --test src/*.test.js`; `npm run lint`; `(cd src-tauri && cargo fmt --all --check && cargo test -p klepsydra-fleet)`.
