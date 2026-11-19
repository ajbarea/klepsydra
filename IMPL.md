# IMPL: docsync 11-18 (branch docs/docsync-1118)

Full docsync of klepsydra against main (7a5c161). PRs #454, #457, #458 are not described.

## Slice
README.md, AGENTS.md, ROADMAP.md, docs/*.md, docs/characters, fleet/*.md, hooks/*.md,
.claude/skill-context.md, CITATION.cff, GitHub About. No docs site (no zensical.toml).

## Done
- Docsync of every file (commits a497e72, b819f2e); PR #465 closes #464.
- README Fleet engine and CI watch detail moved to docs/fleet.md and docs/ci-watch.md; both sections under budget.
- Heph review round 1 (not clean, no Blocking): all 7 items fixed in one commit. Dead delegate chip reader filed as #469.
- Rebased on origin/main 7a5c161.

## Verify
lint, link check (21 files), shellcheck on fleet/fleet, fleet/install.sh pass. Whole-tree `make shellcheck`
OOM-killed (137) again; CI runs it. CI on the pushed head: `gh pr checks 465`.

## Next
Round 2 verify CLEAN; three optional nits folded in one commit. When CI is green: report to Heph, `fleet done`. Heph merges. Do not merge. Docs cap: 3 review rounds.
