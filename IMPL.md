# IMPL: klepsydra#498: the no-fade and speaking-ring guards hold by every route

Branch fix/fade-guard-498 (worktree .claude/worktrees/fade-guard-498), off main after #487 (5dfdff5).
Push only with `git push --force-with-lease origin HEAD:refs/heads/fix/fade-guard-498`. Never push to main.
Then step 3a of #421 resumes on feat/gauge-header-421 (its own IMPL.md); 3a's chips.css joins these guards
when it rebases on this.

## Done
- src/opacity.test.js: every rule that styles `.face.speaking` keeps the solid gap; no text colour,
  `-webkit-text-fill-color` or ink token (--text, --text-dim, --route) carries alpha; no filter: opacity().
  Mutation-checked: each bypass in #498 (rgb / .5, filter: opacity(.5), color-mix with transparent, a later
  speaking rule with --panel-bg) plus an alpha ink token and an alpha fill colour turns it red.
- scripts/test_wall_browser.py `strip_words_keep_their_ink`: multiplies what the page renders for every word
  on the floating strip (fill colour alpha x each ancestor's opacity x filter opacity()), both layouts, both
  schemes, 0/50/85/100%, fresh + stale + spent-week + placeholder chips; the speaking ring's rendered gap
  equals the panel's solid colour.
- PR #487's body already justifies the placeholder icon's 0.7 (no edit needed).

## Next (resume here)
1. ✅ Browser case 40/40 clean; 6 of 6 bypasses turn it red (scratchpad mut498.sh).
   `flock -o /tmp/fleet-heavy.lock timeout 900 uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py strip_words_keep_their_ink`
2. PR #504 open (Closes #498). When CI is green, report to Heph. Do not merge.

## Verify
- `node --test src/*.test.js`; `npm run lint`.
