# IMPL: klepsydra#498: the no-fade and speaking-ring guards hold by every route

Branch fix/fade-guard-498 (worktree .claude/worktrees/fade-guard-498), off main after #487 (5dfdff5).
Push only with `git push --force-with-lease origin HEAD:refs/heads/fix/fade-guard-498`. Never push to main.
Then step 3a of #421 resumes on feat/gauge-header-421 (its own IMPL.md); 3a's chips.css joins these guards
when it rebases on this.

## Done
- src/opacity.test.js: every rule that styles `.face.speaking` keeps the solid gap. No text colour or
  `-webkit-text-fill-color` carries alpha (slash alpha incl. decimal %, rgba/hsla, 4- and 8-digit hex,
  transparent, color-mix); every token a text colour reads, followed through var() to the end, is opaque
  wherever it is set; filters are only the halo's drop-shadow; no mask, no blend mode.
- scripts/test_wall_browser.py `strip_words_keep_their_ink`: multiplies what the page renders for every word
  on the floating strip (fill colour alpha x each ancestor's opacity x filter opacity()) and fails on any mask,
  blend mode or other filter on a word or above it (the halo drop-shadow on .mark/.pip/.face allowed); both
  layouts and schemes at 0/50/70/85/100%, asserting the ink each one wears (70 = dark full ink, review r1 SF1).
  A misspelt case name now exits 2 instead of passing by running nothing.
- CI runs that browser case (setup-uv v10.3.3, playwright 1.65.2); AGENTS.md says so.
- Strip ink tokens are set only in style.css (no runtime setter), so the theme-JSON nit does not reach it.

## Next (resume here) - stopped 11-19 night for capacity (Athena)
Review round 1 (~/.local/state/fleet-orchestrator/reports/guards-504-r1.md, 3 Should-fix) is fixed in code and
pushed; CI's new browser step runs the clean case. Not yet done:
1. Local clean browser run after the filter-parser fix (the first clean run failed only on the parser counting
   rgb()/rgba() inside the halo drop-shadow; fixed with topFunctions, unit-checked in node, not yet in a browser).
2. Mutation matrix: `flock -o /tmp/fleet-heavy.lock bash <scratchpad>/mut504.sh` (13 bypasses: the 6 from #498
   plus mix-blend-mode, filter: brightness(), mask-image, 8- and 4-digit hex, / 50.5%, an --x-fade token under
   full ink). Node verdicts: node passes clean; mutations not yet run. Record each node/browser verdict here
   and in the PR's details. The script is in the session scratchpad; if it is gone, append each rule to
   src/style.css, run node --test src/opacity.test.js and the browser case, restore.
3. PR body: drop the overclaim ("every ... ink token is opaque" -> what the node guard reads as CSS text, and
   that CI now runs the browser case), add the matrix table.
4. CI green -> report to Heph (`fleet send`, else inbox/gauge-421.md); fresh round 2 is Heph's/Athena's.

## Verify
- `node --test src/*.test.js`; `npm run lint`; `uvx ruff check scripts/test_wall_browser.py`.
- `flock -o /tmp/fleet-heavy.lock timeout 900 uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py strip_words_keep_their_ink`
