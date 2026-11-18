# IMPL: design pass 2026-11-18 (mockups only)

Issues: #421 gauge strip, #438 bar opacity, #440 + New session, #384 settings page.
Branch `design/mockups-1118`, draft PR (no merge). Nothing in `src/` changes.

## Slice
Static HTML/CSS mockups for AJ to pick from, under `docs/mockups/2026-11-18/`:
two variants per surface, real readings (1:23 PM 11-18), app tokens, 1920 and 390 shots in both themes.

## Done
- ✅ Pages: `gauge-{a,b}`, `new-session-{a,b}`, `settings-{a,b}`; shared `mock.css`, `icons.js` (copied from wall.js MAKER_ICONS), `readings.js` (single source for every figure).
- ✅ Shots: `shoot.py` (24 full-page PNGs, no overflow, no clipped content, no console errors); repo copies in `shots/` as WebP.
- ✅ Review: `review.md` here and `fleet-briefing/review/design-pass-2026-11-18.md`. Recommends gauge A with B's docked faces, New session A, and settings A with the sisters list behind an expander.
- ✅ Added 11-18 evening (AJ via Athena, #421 and #384 comments): the optional System chip (WSL RAM, CPU, GPU + VRAM; % and GB) on both strips, per-card RAM/CPU on `wall-cards.html`, an Engines section with a switch per harness, and a Show gauge strip switch. System figures: /proc, the fleet slice cgroup and nvidia-smi at 4:00 PM, frozen in `readings.js`.
- ✅ Reviews: one Opus round (no blockers), two verify passes (a light-theme halo regression found and fixed); the additions had their own round.

## Next
- 📋 AJ picks a variant per surface. Then a build issue per surface, starting with #421 (the one shared icon module first, as #421 asks).
- 📋 Build notes carried from #421: read the session 90% and weekly 5% room from one source; drop the claude/gpt meter once `agy models` stops listing its models.

## Verify
`cd docs/mockups/2026-11-18 && flock -o /tmp/fleet-heavy.lock uv run --no-project --with playwright python shoot.py /tmp/out`
prints overflow, clipped elements and errors per shot (28 shots, all should read none) and the linear strip width (671 px A, 634 px B).
