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

## Round 1 verified (11-20)
- Clean: node passes; browser case `strip_words_keep_their_ink` 70 passed, 0 failed (after the filter-parser fix).
- Bypass matrix, each rule appended to src/style.css: all 13 (the 6 from #498 and round 1's 7: mix-blend-mode,
  filter: brightness(), mask-image, 8- and 4-digit hex, / 50.5%, --x-fade under full ink) turn node AND browser red.
- PR body records the matrix; reported to Heph for a fresh round 2.

## Next (resume here)
1. Wait for round 2 (Heph/Athena). Fix any finding here, push, rerun the matrix: append each rule to
   src/style.css, `node --test src/opacity.test.js`, the browser case, restore.
2. After #504 merges: 3a (feat/gauge-header-421) rebases with `git rebase --onto origin/main 632baba`.

## Verify
- `node --test src/*.test.js`; `npm run lint`; `uvx ruff check scripts/test_wall_browser.py`.
- `flock -o /tmp/fleet-heavy.lock timeout 900 uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py strip_words_keep_their_ink`
