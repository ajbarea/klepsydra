# IMPL: docsync 11-18 (branch docs/docsync-1118)

Task: full docsync of klepsydra against main (f77deb4). Open PRs #454, #457, #458 are not described.

## Slice
README.md (two halves audited by opus subagents), AGENTS.md, ROADMAP.md, docs/engines.md, docs/headless.md,
docs/characters, fleet/*.md, hooks/*.md, .claude/skill-context.md, CITATION.cff, GitHub About.
No docs site (no zensical.toml): docs-site checks are N/A.

## Done
- AGENTS.md, skill-context.md (test-engine, test_browser, docs/ tree), CITATION.cff, docs/engines.md (delegate ls/read, hook map), ROADMAP Completed entries.
- docs/headless.md, portrait-briefs.md, fleet/headless-rules.md, brief-tail.md, hooks md: checked, no drift.

## Next
Apply README fixes from the subagent reports, update GitHub About, run `npm run lint` and `make shellcheck`, open PR, rebase on origin/main.
