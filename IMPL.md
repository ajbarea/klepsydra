# IMPL: klepsydra card design C (#247 + #248), resume state 2026-11-02 18:15 (parked by Heph)

Brief: `~/.local/state/fleet-orchestrator/task-card-design.src`. Resume from this file, `git log`, and the comments on fleet-briefing #4 and PRs #253 and #226 (read them again first).

## Slice
AJ's pick (fleet-briefing #4, 11-02): design **C**, keeping A's Open terminal button (the character-colour slice on its edge, not a filled button). Athena is redrawn in flesh: AJ iterates in Gemini and Heph brings the pick.

## Done
- ✅ Steps 1, 2 and 4: kourai #301 and klepsydra #255 merged, staging folder removed after the hash check. #253 (kits + canon) is review-clean and merges after #226 and kourai #300.
- ✅ C built on this branch (f941a9e): character colour, slim done cards, one line per card, the gear menu, the figure 52 px over the frame. The Open terminal button is unchanged from main (`.jump[data-kind="accent"]`).
- ✅ Parking commit: browser tests open the gear before each density or theme pick (`pick()`, `open_gear()`). Ledger-line test: a line shows exactly on cards with a mark (chip or partial). Slim cards put the pill in the header grid (`"name pill" "task task"`), so a name ellipsizes before the pill and the pill keeps its corner (probe: right edges unchanged). `scripts/perf/measure_ba.py` measures main against this branch.
- Node 484/484, Biome and `ruff check` clean before the parking edits. The full browser run before them: 3 FAILs (ledger lines, band clear x2) and a crash at `wrapup_cards_and_bar` (`page.check` on the hidden density input). All four are fixed in the parking commit but **not yet rerun**.

## Next (in order)
1. Rerun the three cases: `flock -o /tmp/fleet-heavy.lock timeout 600 uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py ledger_line_clear_of_text band_clear wrapup_cards_and_bar`, then the whole browser suite (the second half never ran: expect more gear-related fixes) and `test_phone_browser.py`.
2. Merge origin/main (4 commits, #255 portraits among them: kourai.json, cupid-figure.webp and README may conflict; keep main's new portraits and head boxes, this branch's Cupid wide cut). Then run every suite in AGENTS.md again.
3. Measure: copy `src/dev-fleet.json` from design-247 (gitignored), make a detached origin/main worktree, `flock -o /tmp/fleet-heavy.lock uv run -q --no-project --with playwright python scripts/perf/measure_ba.py <main wt> . docs/perf/2026-11-02/cards-247`. For comparison, the prototype read C at 14.8 ms refresh and 1.92 ms/s idle (16 cards). The Windows WebView2 run (`scripts/perf/run.ps1`) needs AJ's build: put that ask in needs-you.md, not the PR.
4. Fresh shots of C at 1920 (Comfortable + Compact) into fleet-briefing `shots/2026-11-02/klepsydra-247-built-*` + README line.
5. PR (assignee ajbarea, label, closes #247 #248, short top + details). Then the review: `/code-review medium` plus an independent opus reader, until a round comes back clean. Delete the design-247 prototype branch after merge.
6. Athena: when Heph brings AJ's pick, run the step-1 asset flow (kourai originals + prompts, klepsydra crops, theme head box, theme tests).

## Notes
- The suite takes case names as arguments (`only = sys.argv[1:]`).
- `ruff format --check` fails on main's copy of test_wall_browser.py too; AGENTS.md gates on `ruff check` only.
