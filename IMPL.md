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

- 11-19 session 3: heavy runs done. Live exe on the taskbar at 0/50/100% and solid with Windows
  transparency off (restored to 1); browser montages at 1920/390; contrast split fresh/stale/placeholder
  (fresh text >= 4.6:1 wherever the panel carries it); CPU 0.069 -> 0.070% (85%), 0.067 -> 0.075% (0%).
  Stale chip's 0.5 dim is 3.1:1 in light at 100%: pre-existing (#482), filed #486. test_wall_browser's
  2 Ledger fails are on main too (#363). Shots: fleet-briefing shots/2026-11-19/klepsydra-438-*.png.

## Next (resume here)
1. PR open for this branch (see `gh pr list --head feat/gauge-opacity-438`): wait for CI and Heph's review;
   fix findings on this branch. Do not merge.
2. Step 3, split in two PRs on new branches off main (after this PR merges, or stacked):
   - 3a: chips docked in the wall header (desktop: toRows(read_usage); phone: usageRows(snapshot), one chip per
     row, replacing the `.limits` rings), chevron to hide, pref `gauges_in_header` (default on), gear row.
   - 3b: floating strip hidden while the wall has focus (fleet.rs wall window Focused events), floating strip
     on/off (tray item + gear), Reset position (main.rs reset_position) and click-through in the gear.
   Mockups: design-pass worktree docs/mockups/2026-11-18/wall-header.html, review.md; shots 2026-11-18/design-wall-header-*.
3. Step 4 System chip only after 1-3.

## Heavy runs (each under `flock -o /tmp/fleet-heavy.lock timeout N`; system python3 has no Playwright)
- PY="uv run -q --no-project --with playwright --with pillow python -I"
- Browser: `$PY .live/live_opacity.py . /mnt/c/Users/ajbar/AppData/Local/dev.ajsoftworks.klepsydra <out>`
  (WIDTHS=1920 for numbers only).
- CPU: `git worktree add --detach <scratch>/main origin/main`; `$PY scripts/perf/measure_gauge.py <main> .
  .live/readings.json .live/fleet.json 120 3 layout=compact` (and `'layout=compact&opacity=0'`).
- Build: `KLEPSYDRA_STAGE=klepsydra-build-gauge421 bash scripts/build-windows.sh [--check]`; live:
  `OPACITY=0 .live/live_app.sh start <exe> compact`, `shot <name>`, `stop` (SP in the script = your scratchpad).

## Verify
- `node --test src/*.test.js`; `npm run lint`; `(cd src-tauri && cargo fmt --all --check && cargo test -p klepsydra-fleet)`.
