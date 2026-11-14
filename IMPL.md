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

## Headless run 11-13 21:2x (LDQIS credit)
- ✅ Ended or quiet sessions never arrive (still remembered), model test added.
- ✅ Fleet ok: #248's rule (healthy is quiet) wins; the case now expects the button hidden while all ok.
- ✅ split_toggle reads `.bar-right #split`; the gear bar (never run before) fixed at every width: gear lays out 18 px (32 px target), < 1200 px narrower gaps + panels give way, 420 px right group on its own line with the gear at its right foot, tools rows 8 px apart (24 px hit areas stay apart).
- ✅ theme.js retry: Chromium < 156 caches a failed import(); retry asks ?retry=N (case failed on main too).
- ✅ Wall browser suite green, run in 6 chunks (case names as args); node 489/489, Biome + ruff clean. Commit 226f5f2.
- Decision: README shots in the dark scheme (klepsydra's own); the hero catches Hephaestus's arrival 1.3 s in (scripts/readme-shots.py `arrival()`).
- Note: the previous headless process was still alive in this worktree and editing; it was stopped (friction log).

## Done since (11-13 23:xx to 11-14 00:1x)
- ✅ Phone wall stays dark in either scheme (light block scoped to `:root:not(.served)`, served page drops the light theme-color): f5bc0a8. Phone suite: 88 ok, 4 FAIL, the same 4 as main (gh/branch links under 44 px x3, Play again flaky).
- ✅ Perf (`docs/perf/2026-11-13/cards-247/measure.json`, headless Chromium, relative): refresh task 3 cards 5.40 -> 5.46 ms, 16 cards 14.38 -> 14.09 ms; idle 0.79 -> 0.73 and 1.90 -> 1.49 ms/s.
- ✅ Shots in fleet-briefing `shots/2026-11-13/klepsydra-247-373-*` (wall 1920 x density x scheme, app mode; arrival frames + webm) with README line; needs-you line for AJ's look.
- ✅ README screenshots retaken (dark, hero = Hephaestus arriving); bar's gauge ramp/panel warm (style.css, badge ring #14100b): c003b87.

## Headless ship run 11-14 (AJ 11-13: "ship it")
- ✅ Wall-suite strip/theme chunk (split_toggle to the end) rerun: 112 passed.
- ✅ Merged origin/main (#375, #376, #378): only IMPL.md conflicted (kept this branch's); main touched no src/ or scripts/. Light suites green.
- ✅ PR #387 opened (closes #247 #248 #373, enhancement, ajbarea); shots linked to fleet-briefing.
- ✅ Review: /code-review medium + 3 fresh Opus rounds + verify pass, clean. Commits 760c088, dbe4d09, e19411f, 1f389d2; the PR's Review fold lists each round. New: src/fleet/scheme.js (phone .served before first paint), gear closes on Escape/outside, CI/Fleet popovers close with their button, arrival line names loud states, --primary-hover, slim figureless portrait at scale 0.75 (the `scale` property, composes with the arrival).
- Node 493/493, Biome + ruff clean, phone suite 88/4 (the same 4 as main).

## Next (in order)
1. Heph checks CI and merges #387 (not this session). Open call for AJ: the strip's blue working badge (Okabe-Ito #0072b2), noted in the PR.
2. Open nits (in the PR): gear stays open when focus tabs out; density switch mid-arrival restarts the burst.
3. After merge: `fleet install`; remove worktrees main-measure and design-247 (branch design/cards-247). Windows WebView2 perf needs AJ's build: needs-you line, not the PR.

## Notes
- Browser suite in chunks: case names as args (`sed` the `cases` tuple in main()); each chunk under 300 s. Heavy lock: hold it with `setsid nohup flock /tmp/fleet-heavy.lock -c "touch FLAG; exec sleep N"` and poll the flag in foreground calls (headless runs end when a turn ends).
- App-mode shots: ~/.local/state/fleet-orchestrator/cards-247-harness/shots-app.py (test_wall_browser.open_app + emulate_media); shoot.py serves at / (phone mode), which is now always dark.
- Scratch harnesses (copy them into scripts/perf if kept): `shoot.py` (serve a worktree at `/` over /events, density x scheme, `--probe`) and `arrive.py` (load without the first fixture session, push it, stepped frames, `--motion=reduce`, `--video=DIR`, `--probe=1` logs animation events) copied to `~/.local/state/fleet-orchestrator/cards-247-harness/` with the arrival fixture `arrive4.json`.
- Pin `playwright==1.63.0` (its browsers are installed).
- Searches behind the palette: Chrome dark-mode guidance (system scheme default, CSS branching), warm near-black surfaces and surface-lightness depth (atmos.style dark-mode practices); #373's sources are in the issue.
