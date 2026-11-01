# IMPL: klepsydra card and cast design pass (AJ 11-01), resume state 2026-11-01 evening

Paused at Heph's ask (RIT ~78%, CISC-810 A6 tonight). Brief: `~/.local/state/fleet-orchestrator/task-card-design.src`.
Resume from this file, `git log`, and the open PRs' comments (re-read them first).

## Done
- ✅ Step 1, Hesychia + the four re-prompts (issue #252):
  - kourai-khryseai #301 (branch art/portraits-1101): five new originals, old ones kept as `<name>-2026-10-20.jpg`, prompts appended. SHA-256 vs staged: 5/5.
  - klepsydra #255 (branch feat/portraits-1101, worktree portraits-1101): 1024 crops (q88, optimised; the recipe reproduces the old Hesychia crop byte for byte), cut-outs from TIGRIS job 716141 (`~/klepsydra-cutout` on tigris), faces re-cut, HEAD boxes + theme `head` refit. 151/151 cast/theme/style/speaking/model tests.
- ✅ Step 2 + 4, #249 kits + cast canon: klepsydra #253 (branch docs/briefs-249). Review round 1 (2 blocking, 6 should-fix) fixed in 2f9e899; PR body states the merge order.
- 🔄 Step 3, #247 + #248 prototype on this branch (design/cards-247, no PR yet): `src/fleet/design-247.{js,css}` worn with `?design=b|c` in a browser only; `src/fleet-design-247.test.js` contrast check, 4/4 pass (worst: Aletheia's edge 3.16:1; task on the washed band 4.72:1 after fading the wash to 6% from 150 px); `faces/kourai/cupid-figure-wide.webp` (full-width cut of the 640 px transparent PNG: no 1254 px Cupid original exists).

## Next (in order)
1. Re-run reviews (fresh opus reviewers, round prompts as before): #255 + kourai #301 (round 1; the stopped run found nothing reported), #253 round 2 (verify the round-1 fixes).
2. Shots: `uv run --no-project python scripts/design-247/make-fixture.py`, then `flock /tmp/fleet-heavy.lock timeout 400 uv run -q --no-project --with playwright python -I scripts/design-247/shots.py . <out> a,b,c`. Look at every shot, iterate the CSS, then copy to `/mnt/c/Users/ajbar/fleet-briefing/shots/2026-11-01/klepsydra-247-<variant>-<density>-dark.png` + one line each in shots/README.md.
3. Measure: `flock /tmp/fleet-heavy.lock timeout 900 uv run -q --no-project --with playwright python -I scripts/design-247/measure.py . <out>` (idle ms/s over 30 s, median of 15 refreshes, a trace per variant; headless Chromium, relative only). The Windows WebView2 run (`scripts/perf/run.ps1`, docs/perf/2026-10-28) comes after the build.
4. Review issue in ajbarea/fleet-briefing for AJ's pick (A/B/C; the wall has one dark scheme, so no light shots; Athena's portrait is gold, the canon says flesh: ask whether to redraw from her kit). Add the ask to claude-queue.md "Needs you". Public issues stay neutral.
5. After AJ picks: fold the chosen CSS into wall.css, delete the prototype files, build, measure before/after on Windows.
6. Cleanup after #301 and #255 merge: hash-check `assets/portraits` and kourai originals against `kourai-khryseai/assets/avatars/incoming-2026-11-01/`, then `rm -rf -- "${D:?}"` that staging folder.

## Notes
- Merge order: kourai #301 → klepsydra #255; kourai #300 + klepsydra #226 → #253. #226 and #255 both edit the `HEAD` line in cut-portraits.py (mechanical merge).
- Light Pillow scripts run without the heavy lock (friction.md line, 11-01).
