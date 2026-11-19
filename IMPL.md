# IMPL: klepsydra#421 + #438: gauge strip, variant A with docked faces

Branch feat/gauge-strip-a-421-v2 (worktree .claude/worktrees/gauge-421-v2), cut with `--no-track` from 797336e.
It replaces feat/gauge-strip-a-421, whose two commits reached main by accident and were reverted (#480).
Push only with an explicit refspec: `git push -u origin HEAD:refs/heads/feat/gauge-strip-a-421-v2`. Never push to main.
Decision: PR #459 last comment (AJ 11-18). Mockups: branch design/mockups-1118, docs/mockups/2026-11-18.
Untracked helpers in `.live/` (excluded): live_strip.py (browser shots from real readings + live fleet at
127.0.0.1:8318), live_app.sh (test copy of a branch klepsydra.exe beside AJ's, own KLEPSYDRA_DIR, backs up and
restores the shared %APPDATA% .window-state.json, stops only its own PID), readings.json + fleet.json (frozen
real data for perf). Fix SP= in live_app.sh to the session's scratchpad before running.

## Plan: one PR per step
1. **PR 1 (this branch): floating strip as variant A.** Code + review fixes committed; PR not yet open.
2. **PR 2: #438 opacity** 0-100 step 5 in prefs.json, live. Copy the theme pattern (`set_theme` + Hub publish +
   `theme_subscribe`, src-tauri/src/theme.rs) as `set_gauge_opacity` / `gauge_subscribe`; slider in the wall's gear.
   Halo below 60% (dark) / 50% (light), full ink below 70% (mockup mock.css `.panel.halo/.thin`).
3. **PR 3: docked gauges in the wall header** + floating strip hidden while the wall has focus + Settings › Gauges
   rows (+ #479 double). Phone: usage ids are anonymised (a1..) by usage.rs but sessions keep real account ids,
   so dockKey needs a mapping there. Also the tap/keyboard detail card (see Open).
4. **PR 4: System chip** (off by default), only after 1-3.

## Done (PR 1)
- Chips model/view, dock, icons, README (845969e). Opus review round 1: 1 blocking, 3 should-fix, nits; all
  fixed in 21d2dc8 (per-window age, stacked tray colour, waiting fade, 30-min age text, stacked columns,
  Intl formatters, boundary guards, phone/wall spent-week rule). 15 mutations on the new guards: all killed.
- Unit tests and lint clean (see Verify). Live in Chromium on real readings + live fleet: no errors, faces docked.
- CPU (headless Chromium, 3 x 120 s, median): 797336e 0.086 % vs 845969e 0.097 %; after 21d2dc8,
  797336e 0.081 % vs 0.075 %. Live exe (stage klepsydra-build-gauge421): chips on the taskbar beside AJ's
  main build, faces docked, native title hover shows in the unfocused window.
- Round 2 (fresh Opus): 1-11 fixed; new N1 (waiting fade un-hid #zoom), N2 (Intl throws past Date range),
  N3 (phone spent-week only source-tested), N4-N5 wording; all fixed (af75c1d).
- Round 3 (fresh Opus): N1-N5 confirmed; new: #grip's own transition cancelled its fade, "resets null" for a
  live window past Date's range, clockAt(null) read as 1970, no committed guard for the fade; all fixed + guarded.
- PR #482 open. Browser suites vs main (ab00893): phone 88 pass / the same 5 reds as main (#266; "Play again"
  intermittent); wall: 4 Ledger reds on the branch, main's run hit the same 2 then timed out before the other 2.

## Open
- Hover detail is the native `title` tooltip: shown live in the unfocused window, but no tap or keyboard.
  A toggletip card needs the window to grow from its docked edge: #481, planned with PR 3.

## Next
1. Round 4 (fresh Opus) CLEAN on 8016ef6; its nits: #content transition folded in, body round count. Known limit: the fade test reads CSS text, not the cascade.
2. CI green, then report to Heph (`fleet send`), queue line; do not merge. Then PR 2 (#438) on a new branch.

## Verify
- `node --test src/*.test.js`; `npm run lint`.
