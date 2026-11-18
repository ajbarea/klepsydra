# IMPL: docsync 11-18 (branch docs/docsync-1118)

Full docsync of klepsydra against main (f77deb4). PRs #454, #457, #458 are not described.

## Slice
README.md, AGENTS.md, ROADMAP.md, docs/engines.md, docs/headless.md, docs/characters, fleet/*.md, hooks/*.md,
.claude/skill-context.md, CITATION.cff, GitHub About. No docs site (no zensical.toml): docs-site checks N/A.

## Done
- README: both halves audited and fixed (Install, tray menu, wall bar, card density, CI watch, Fleet engine table, Tests).
- Silent surfaces added: agy sessions and menu, subscription-only launch, engine badge, gauge groups and Route badge, timers.
- AGENTS.md, skill-context.md, CITATION.cff, engines.md, ROADMAP Completed log updated.
- doctor.sh hint now names the real README section. GitHub description and topics updated.
- headless.md, portrait-briefs.md, fleet and hooks md files: checked, no drift.
- node lint, link check, hooks/test_fleet.sh (606 pass), shellcheck on fleet/doctor.sh pass. Whole-tree `make shellcheck` was killed (137) twice under the memory cap; CI runs it.

## Next
Review the PR; unresolved items are listed in the PR details. `make test-engine` is not run by CI.
