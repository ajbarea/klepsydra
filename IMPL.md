# IMPL: klepsydra living wall backgrounds & character arrival motifs (#385), resume state 2026-11-15

Brief: `https://github.com/ajbarea/klepsydra/issues/385` (design with #224, research in `fleet-briefing/review/klepsydra-224-character-research-2026-11-13.md`).

## Slice
Living wall backgrounds behind cards reflecting active theme (Kourai: forge glow & drift; Professions: studio grid; DiceBear: floating geometric dual-tone), swapping live with theme switch. Compositor-only, zero infinite loops, paused on hidden, disabled under reduced motion.
Worker arrival motion with per-character signature motifs (sparks, shimmer, aperture eyes, sand vortex, mist fade) while orchestrator retains full conic burst.

## Done (branch feat/living-wall-385)
- Theme declarations: `backdrop` property in `src/fleet/themes/kourai.json`, `professions.json`, `dicebear.json` with theme glow and secondary accents; `motif` declared across all 16 cast members per theme.
- Living Backdrop element: `#wall-backdrop` in `src/wall.html` with `.orb-1`, `.orb-2`, `.ambient-drift`. Dynamic styling in `src/fleet/wall.css` and live theme switching via `updateBackdrop(theme)` in `src/fleet/wall.js`.
- Paused on hidden: `visibilitychange` handler toggles `.paused` on `#wall-backdrop`.
- Battery and contrast compliance: compositor-only (`transform`, `opacity`), zero `infinite` loops (finite `1 both`), zero static `opacity:` outside `@keyframes` (alpha via `color-mix` with `--bg-orb1-alpha` / `--bg-orb2-alpha`).
- Per-character arrival motifs: `card()` passes `c.motif`; `.card.arriving[data-motif="..."] .burst` styles all 6 motifs with keyframes `sparks-scatter`, `shimmer-burst`, `aperture-dilate`, `sand-wave`, `mist-fade`.
- Tests: `node --test src/*.test.js` 497 passed (including `fleet-theme.test.js`, `fleet-cast.test.js`, `fleet-model.test.js`, `guards.test.js`, `fleet-style.test.js`, `fleet-accent.test.js`).
- Toolchain: `npm run lint` Biome clean (65 files checked). Cargo unit + integration tests clean (429 + 7 passed), clippy clean.
- Browser tests: `living_backdrop_and_arrival_motifs`, `arrival_is_an_event`, `reveal_does_not_arrive`, `themes_switch_live` all passed via `scripts/test_wall_browser.py`.
- Review shots: 1920 single card A/B shots in dark & light themes committed to fleet-briefing `shots/2026-11-15/` with `shots/README.md` entry.

## Next
1. Commit changes on `feat/living-wall-385` with zero attribution lines and zero em-dashes.
2. Push branch to `origin/feat/living-wall-385`.
3. Open PR with short visible top (<= 150 words) and depth folded.
4. Shepherd CI checks and merge.
