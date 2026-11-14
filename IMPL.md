# IMPL: klepsydra cards C + warm palette + arrival (#247, #248, #373), resume state 2026-11-13 20:4x

Brief: `~/.local/state/fleet-orchestrator/task-card-design.src` (PRIORITY 1 block, AJ 11-13). Parked 11-13 20:4x on Heph's word (all work moves to the API credit / agy / Copilot; Heph relaunches headless on the LDQIS credit from this file). Resume from this file, `git log`, and the comments on #373, #247, #248 (read them again first).

## Slice
Design C (AJ's pick, fleet-briefing #4) with A's Open terminal slice. Palette rule (AJ 11-12): klepsydra's own warm bronze/gold, no slate, no blue background or card; each character's colour carries its card (text 4.5:1, borders 3:1, both schemes). #373: a session's first appearance is an event. AJ drew the black box on his Desktop screenshot himself to mark the top-left portrait corner: the arrival must own that corner, unmissably.

## Done (all pushed on feat/cards-247)
- ✅ Merged origin/main (505a87e): Agora gone, split + New session in the bar's right group, ring key stays gone. The three fixed browser cases from the parking commit: 14 passed.
- ✅ Palette (e516e02): warm bronze dark tokens; light scheme follows `prefers-color-scheme` (parchment), block at the END of wall.css (equal-specificity rules must lose to it); the band + portrait dialog stay the dark stage in both (band scope re-declares dark tokens; `.card header` re-derives `--tone`); `model.js accentLight` deepens each character to 3:1 on `LIGHT_SURFACES` (`--on-card`, `--accent-light`); working = quiet parchment, badge too; light needs amber #ac6700, done #00805c, error text #a83a08. Tests in `fleet-accent.test.js`.
- ✅ Arrival (47500ec): `model.js arrivals()` (first snapshot seeds, bounded 500) + `arrivalLine()` ("Hephaestus has arrived, Master of the Forge", live region, replaces that session's status line); figure springs over the frame, ray burst + ring, flare glow, name slams in, banner holds then gives the header back (~3.5 s); transform/opacity only; reduced motion = `herald-calm` crossfade (!important beats the blanket rule); Compact arrives too; several arrive 450 ms apart; a hidden window holds them until shown. Removed wall.js's old "not comfortable => strip .arriving" line. Browser case `arrival_is_an_event` (not yet run in the suite: the run crashed first).
- ✅ Node 488/488, Biome + ruff clean, mutation checks 7/7 killed (arrivals seed + bound, compositor-only keyframes, calm !important, calm opacity-only, accentLight, a light text token).
- ✅ Step 3 (black block) dropped: not a render bug (Heph 11-13).

## Full browser suite, 11-13 (289 ok, 2 FAIL, crashed at split_toggle; the rest never ran)
1. FAIL `sixteen ended cards shown by a focus request: ... none arriving` (arriving: 16). Cause: the first snapshot held no sessions, so the 16 ended ones counted as new. Fix: an ended (or quiet) session never arrives; still add it to `seen`. Add that cell to the model test.
2. FAIL `all ok reads Fleet ok` (hidden: True). Likely #248's "healthy hidden" vs the merged test's expectation from main (#328/#330 doctor work): read the case, then decide which side is right.
3. CRASH `split_toggle` (scripts/test_wall_browser.py ~4441, KeyError 'key'): main's case measures the Split toggle on the ring key's line; this branch moved Split into `.bar-right .tools` and removed the ring key. Adapt the case to the new group.
Then rerun the whole suite and `test_phone_browser.py`.

## Next (in order)
1. Fix the three above; rerun suites (node, browser, phone, shellcheck/cargo per AGENTS.md as touched).
2. Measure: `flock -o /tmp/fleet-heavy.lock uv run -q --no-project --with playwright==1.63.0 python scripts/perf/measure_ba.py ../main-measure . docs/perf/2026-11-13/cards-247` (main-measure = detached origin/main worktree, already added) + a trace of one arrival.
3. Shots 1920 (Comfortable + Compact, dark + light) + arrival frames/clip into fleet-briefing `shots/2026-11-13/klepsydra-247-373-*` + README line; tell Heph BEFORE review rounds (AJ's look first).
4. PR (closes #247 #248 #373, assignee ajbarea, short top + details), `/code-review medium` + one independent Opus reader until clean, merge, `fleet install`, report. Windows WebView2 perf run needs AJ's build: needs-you line, not the PR.
5. After merge: remove worktrees main-measure and design-247 (branch design/cards-247).

## Notes
- Scratch harnesses (copy them into scripts/perf if kept): `shoot.py` (serve a worktree at `/` over /events, density x scheme, `--probe`) and `arrive.py` (load without the first fixture session, push it, stepped frames, `--motion=reduce`, `--video=DIR`, `--probe=1` logs animation events) copied to `~/.local/state/fleet-orchestrator/cards-247-harness/` with the arrival fixture `arrive4.json`.
- Pin `playwright==1.63.0` (its browsers are installed).
- Searches behind the palette: Chrome dark-mode guidance (system scheme default, CSS branching), warm near-black surfaces and surface-lightness depth (atmos.style dark-mode practices); #373's sources are in the issue.
