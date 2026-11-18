# IMPL: design pass 2026-11-18 (mockups only)

Issues: #421 gauge strip (+ System chip, docked gauges), #438 bar opacity, #440 + New session, #384 settings.
Branch `design/mockups-1118`, draft PR #459 (no merge). Nothing in `src/` changes.

## Slice
Static HTML/CSS mockups for AJ to pick from, in `docs/mockups/2026-11-18/`: two variants per surface, real readings, app tokens, 1920 and 390 shots in both themes.

## Done
- ✅ Pages: `gauge-{a,b}`, `new-session-{a,b}`, `settings-{a,b}`, `wall-cards`, `wall-header`; shared `mock.css`, `icons.js`, `readings.js` (every figure, frozen with its source).
- ✅ Shots and review for the first 7 pages are pushed (`shots/*.webp`, `review.md`; briefing copies in fleet-briefing `shots/2026-11-18/` and `review/design-pass-2026-11-18.md`).
- ✅ AJ's 11-18 additions are in the source: the System chip in all three strip layouts, per-card RAM/CPU, the Engines switches, and a Gauges settings section; `wall-header.html` shows the docked header and the pinned strip (Game Bar model).
- ✅ Reviews: one Opus round and two verify passes on the first set, plus one round on the additions; every finding is fixed in the source.

## Next (stopped at RIT 94%, 11-18 17:15)
- 📋 Re-shoot all 8 pages (32 PNGs): the settings pages, the gauge pages' System section and `wall-header` were never shot after their last edits. Command under Verify.
- 📋 Look at `wall-header` at 1920 and 390 in both themes, and at the System chip's stacked row and A's 390 GPU+VRAM pair.
- 📋 `python .scratch/finalize.py "[klepsydra#459](https://github.com/ajbarea/klepsydra/pull/459)"` (run with `uv run --no-project --with pillow`). It copies the PNGs to the briefing, writes the WebP copies, and writes both review files from `.scratch/review-template.md`. Before running it, fix its SCR and SHOTS paths to the new shots folder. Then commit and push.
- 📋 PATCH the PR body from `.scratch/pr-body.md` (`gh api -X PATCH repos/ajbarea/klepsydra/pulls/459 --input` with a jq `{body}`). Update the shots/README entry to add `design-wall-header-*`. Send `.scratch/report.txt` to Heph, refreshed with the docked-gauges addition. Then `fleet done`.
- `.scratch/` is untracked resume tooling: never commit it, and delete it once the PR is final.

## Verify
`cd docs/mockups/2026-11-18 && flock -o /tmp/fleet-heavy.lock timeout 900 uv run --no-project --with playwright python shoot.py OUT`
prints each shot's overflow, clipped elements and console errors (all should read none) and the linear strip width (671 px A, 634 px B). `node .scratch/render-check.js "$PWD/docs/mockups/2026-11-18"` checks the renderers without a browser.
