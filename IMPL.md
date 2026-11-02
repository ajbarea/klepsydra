# IMPL: klepsydra card and cast design pass (AJ 11-01), resume state 2026-11-02

Brief: `~/.local/state/fleet-orchestrator/task-card-design.src`. Resume from this file, `git log`, and the open PRs' and Review issue's comments (re-read them first).

## Done
- ✅ Step 1, five redrawn portraits (#252): kourai-khryseai #301 merged (54be27b). klepsydra #255: review clean (round 1 + verify), CI was finishing at last write; merge it once green, then retarget nothing (no dependents).
- ✅ Steps 2 + 4, kits + cast canon (#249): #253, review rounds 1-2 + verify clean. Merges after #226 (Athena) and kourai #300; when resolving, keep #253's `portrait-briefs.md` and hand-merge the README paragraph.
- ✅ Step 3 shots (#247 + #248): prototype on this branch behind `?design=b|c` (browser only). Shots in fleet-briefing `shots/2026-11-02/klepsydra-247-*` and Review issue fleet-briefing #4 (pick A/B/C; Athena redraw). Readings in `docs/perf/2026-11-02/design-247-measure.json` (16 cards: refresh 16.0 / 14.5 / 14.8 ms, idle 2.10 / 2.15 / 1.92 ms/s). Contrast test `src/fleet-design-247.test.js` 4/4.

## Next (in order)
1. Merge #255 when CI is green (comments re-read first).
2. Wait for AJ's pick in fleet-briefing #4 (Heph relays). Then: fold the chosen rules from `src/fleet/design-247.css` into `wall.css` (drop the `[data-design]` scoping), move the bar regrouping from `design-247.js` into `wall.html`, delete the prototype files, keep the contrast test as part of `fleet-style`/`fleet-theme`, run every suite in AGENTS.md, build Windows (`--check` here; AJ's build), measure before/after with `scripts/perf/run.ps1`. PR closes #247 and #248.
3. If AJ says redraw Athena: hand him the kit (Athena section of portrait-briefs.md) as a Desktop paste kit; on his pick run the step-1 asset flow (kourai originals + klepsydra crops).
4. Cleanup after #255 merges: hash-check every file in `kourai-khryseai/assets/avatars/incoming-2026-11-01/` against kourai main's originals (images) and portrait-prompts.md (text), then `rm -rf -- "${D:?}"` that folder. Remove worktrees portraits-1101 (both repos) once merged.

## Notes
- AGENTS.md lists cut-portraits.py as not-to-run; the brief named it for this job, and it ran without the heavy lock (seconds of Pillow).
- In served mode (wall at `/`) the density picker is hidden; scripts set it by script.
