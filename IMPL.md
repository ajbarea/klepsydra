# IMPL: design pass 2026-11-18 (mockups only)

Issues: #421 gauge strip (+ System chip, docked gauges), #438 bar opacity, #440 + New session, #384 settings.
Branch `design/mockups-1118`, draft PR #459 (no merge). Nothing in `src/` changes.

## Slice
Static HTML/CSS mockups for AJ to pick from, in `docs/mockups/2026-11-18/`: two variants per surface, real readings, app tokens, 1920 and 390 shots in both themes.

## Done
- ✅ Pages: `gauge-{a,b}`, `new-session-{a,b}`, `settings-{a,b}`, `wall-cards`, `wall-header`; shared `mock.css`, `icons.js`, `readings.js` (every figure, frozen with its source).
- ✅ AJ's 11-18 additions: System chip in all three strip layouts, per-card RAM/CPU, Engines switches, Show gauge strip, Gauges settings, docked header + pinned strip.
- ✅ All 32 shots taken after the last edit (no overflow, clipping or console errors; strip 671 px A, 634 px B); WebP copies in `shots/`, PNGs and the review in fleet-briefing (`shots/2026-11-18/design-*`, `review/design-pass-2026-11-18.md`).
- ✅ Phone fixes found by eye on the re-shoot: the docked strip is one chip per row (values no longer wrap, chevron no longer clipped); wallpaper tags no longer cover the strip.
- ✅ Reviews: one Opus round and two verify passes on the first set, one round on the additions.

## Next
- 📋 Waits on AJ's pick per surface (needs-you). Then one build PR per surface, from the picked page.

## Verify
`cd docs/mockups/2026-11-18 && flock -o /tmp/fleet-heavy.lock timeout 900 uv run --no-project --with playwright python shoot.py OUT`
prints each shot's overflow, clipped elements and console errors. Its clip check misses content pushed past a rounded container's edge: look at the 390 shots too.
