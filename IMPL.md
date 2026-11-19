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

## Next (resume here; nothing is running)
1. Heavy runs, each under its own `flock -o /tmp/fleet-heavy.lock timeout N` (another agent's test-fleet held the
   lock for 40+ min on 11-19, so none ran yet):
   - Browser: `python3 .live/live_opacity.py . /mnt/c/Users/ajbar/AppData/Local/dev.ajsoftworks.klepsydra <out>`
     (real readings + live fleet from :8318; 0/50/100, both schemes, dark and light desktop; prints each small
     text's worst contrast; montage-1920/390.png). Copy montages to fleet-briefing
     shots/2026-11-19/klepsydra-438-opacity-{1920,390}.png + a README line.
   - CPU: `git worktree add --detach <scratch>/main origin/main`, then `python3 scripts/perf/measure_gauge.py
     <main> . .live/readings.json .live/fleet.json 120 3 layout=compact`, and again with
     `'layout=compact&opacity=0'` (the halo's shadows). One number each side; keep it no worse. Remove the worktree.
   - Build: `KLEPSYDRA_STAGE=klepsydra-build-gauge421 bash scripts/build-windows.sh --check`, then without
     --check (the brief's live proof needs the exe; AGENTS.md otherwise reserves it). Live: copy
     `.live/live_app.sh`'s flow (`OPACITY=0|50|100 .live/live_app.sh start <exe> compact`, `shot`, `stop`).
     Solid mode: check `matchMedia('(prefers-reduced-transparency: reduce)')` in WebView2 with Windows
     Transparency effects off (HKCU Themes\Personalize EnableTransparency=0), then restore it to 1.
2. PR: base main, assignee ajbarea, label enhancement, "Closes #438"; short top (why, table, status) and
   <details> for rounds 1-3, contrast table, CPU, sources (W3C G18 halo; mrec.github.io/blog/2025/text-shadow;
   Chrome + MDN prefers-reduced-transparency). Say: the wall's own strip view (#438's last line) comes in step 3.
   CI green, report to Heph (`fleet send $(cat ~/.local/state/fleet-orchestrator/orchestrator.pane) -`).
3. Step 3, split in two PRs on new branches off main (after this PR merges, or stacked):
   - 3a: chips docked in the wall header (desktop: toRows(read_usage); phone: usageRows(snapshot), one chip per
     row, replacing the `.limits` rings), chevron to hide, pref `gauges_in_header` (default on), gear row.
   - 3b: floating strip hidden while the wall has focus (fleet.rs wall window Focused events), floating strip
     on/off (tray item + gear), Reset position (main.rs reset_position) and click-through in the gear.
   Mockups: design-pass worktree docs/mockups/2026-11-18/wall-header.html, review.md; shots 2026-11-18/design-wall-header-*.
4. Step 4 System chip only after 1-3.

## Verify
- `node --test src/*.test.js`; `npm run lint`; `(cd src-tauri && cargo fmt --all --check && cargo test -p klepsydra-fleet)`.
