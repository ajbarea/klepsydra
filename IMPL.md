# IMPL: klepsydra#421 step 3a: gauges docked in the wall header

Branch feat/gauge-header-421 (worktree .claude/worktrees/gauge-header-421), stacked on fix/fade-guard-498
(PR #504, Closes #498). After #504 merges: `git rebase --onto origin/main 632baba` (drop #498's two commits).
Push only with `git push --force-with-lease origin HEAD:refs/heads/feat/gauge-header-421`. Never push to main.
Design: AJ's pick on #459 (A + docked faces, gauges in both places); mockup design-pass worktree
docs/mockups/2026-11-18/wall-header.html; shots fleet-briefing/shots/2026-11-18/design-wall-header-*.png.

## Plan (the #421 brief, one PR per step)
1. ✅ #482 floating strip, variant A: merged 11-19.
2. ✅ #487 #438 opacity: merged 11-19 (5dfdff5).
   📋 #504 (#498 guard bypasses, Athena's order: first): open, CI was finishing (Gauge logic job pending);
   report to Heph when green. Its IMPL is on fix/fade-guard-498.
3. **3a, this branch:** chips docked in the wall header; gear row "Gauges in wall header"; chevron hides.
   3b next (new branch off this one): floating strip hidden while the wall has focus (fleet.rs wall Focused
   events) and paused while hidden; floating strip on/off; Reset position; click-through. Settings rows go
   in #493's registry (src/settings/registry.js) once #493 merges; it keeps the gear (adds "Settings…").
4. System chip (off by default), only after 1-3.

## Done (this branch)
- Rebased on main, then stacked on #504; chips.css joins #498's no-fade and ring guards (d16f514,
  mutation-checked: an alpha .val and a --panel-bg speaking rule in chips.css turn opacity.test.js red).
- bc5936d perf: + New session's paintButton memoised by what it draws (it rebuilt icon + label nodes on
  every read, now every 5 s with the dock on); the dock's wait note writes only when its text differs.
- Live (exe from before bc5936d, stage klepsydra-build-gauge421, .live/live3a.sh with real readings):
  header shots 1920/390 x dark/light; montages beside the mockup in
  fleet-briefing/shots/2026-11-19/klepsydra-421-header-{1920,390}-{dark,light}.png (README lines not yet
  added). Closing the wall to the tray sets document.hidden (visibilitychange hidden -> visible on reopen),
  so the reader drops to 60 s.
- CPU before bc5936d, wall idle main-thread s per 60 s: dock on 0.086 / 0.089, dock off (= main's 60 s
  pace) 0.041 / 0.036; layouts 16 vs 5 per minute.
- At 390 the live chips wrap by width (2 on the first row) where the mockup shows one per row: say so in the PR.
- Filed #505: desktop wall under ~450 px scrolls sideways (--card-min 420px, on main too).
- Browser runs (before bc5936d): phone 89/3, all 3 also fail on main (gh/branch < 44 px = #490, #266;
  main also fails 2 gauge cases that 3a fixes). Wall 450/3: 2 Ledger fails are on main (#363); the third,
  ledger_gives_auto_its_room ("a drag of the Ledger's separator ... measures Auto once"), passed once on
  main (2/0): check whether 3a causes it.

## Next (resume here) - Argos replacement, 11-20
0. #504: round 1 reported 01:38 (CI green dff1ee9); waiting on Heph's round 2. Its IMPL is on fix/fade-guard-498.
1. ✅ `ledger_gives_auto_its_room` with e94e6b1: 5 of 5 pass (drag measures 0, release 1). 📋 whole wall suite
   once (scratchpad wall-full.log), then rebuild stage klepsydra-build-gauge421.
2. 📋 `.live/live3a.sh start`, `openwall`, `flock -o /tmp/fleet-heavy.lock bash .live/cpu3a.sh`: dock-on number
   after bc5936d vs the before numbers above.
3. 📋 PR: base fix/fade-guard-498 (main after #504), assignee ajbarea, label enhancement, "Part of #421"; short
   top + details (live vs tested, CPU before/after, #505, the 390 wrap, the separator race). Shots README lines
   under 2026-11-19 with the PR link. Report to Heph; do not merge.
4. Then 3b (new branch off this one), per the Plan.
- Harvested the merged worktrees' live harnesses into .live/prev/ (live_opacity.py, ring_contrast.py, live_app.sh).

## Verify
- `node --test src/*.test.js` (590 pass); `npm run lint`; `(cd src-tauri && cargo fmt --all --check && cargo test -p klepsydra-fleet)`.
- Heavy (flock -o /tmp/fleet-heavy.lock): `uv run -q --no-project --with playwright python -I scripts/test_phone_browser.py`,
  same for test_wall_browser.py (one case: append its function name).
