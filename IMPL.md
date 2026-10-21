# IMPL

Current slice: #56 Slice 2, the ledger on the wall (receipt line, guardrail
chip, ledger drawer). Branch feat/ledger-ui, worktree
`.claude/worktrees/ledger-ui`. Slice 1 (#57) and compact cards (#55) are on
main. The issue body (`gh api repos/ajbarea/klepsydra/issues/56 -q .body`)
and its Slice 2 "Done when" are binding.

## Done
- Read #56, the #55 and #57 diffs, `.claude/skill-context.md`, and the wall
  (wall.html, wall.js, model.js, wall.css, feed.js), plus ledger.rs, otel.rs,
  watch.rs and src-tauri/src/fleet.rs. No code is written yet.

## Facts found
- `session.ledger` on each snapshot session holds lifetime `Totals`
  (ledger.rs: tokens.{input,output,cache_read,cache_creation},
  cost_usd_estimate_micros, lines_added/removed, commits, pull_requests,
  active.{user_ms,cli_ms}, api_errors, api_refusals, guardrail_rejects).
  `snapshot.receiver` = {addr, listening, error}.
- Today's `Day` (sessions map plus guardrails [{at, session_id, tool_name,
  source}]) has no IPC path yet. Slice 1 records NO skill/plugin/MCP
  attribution (the recorded fixtures carry none), so the ledger must add it.
- Fit budget: compact cards are 205.6 px; fit bottoms are 931 (1920x1000)
  and 952 (945x1000). There is no room for a new row.
- A guard test forbids a shell or opener plugin, so the README link in the
  empty state cannot open a browser from the app. Decide how to handle it.

## Plan (next, in order)
1. ledger.rs: `Day.attribution: BTreeMap<session, {skills, plugins,
   mcp_servers: BTreeMap<name, tokens>}>` from token.usage's `skill.name`,
   `plugin.name` and `mcp_server.name` (first check the names on
   code.claude.com/docs/en/monitoring-usage). Cap the names per kind, and
   drop a session's entry when cap_sessions drops it. Add
   `Ledger::today(now)`, which returns an empty Day when the day rolled
   with no export. Write the tests first.
2. src-tauri/src/fleet.rs: `app.manage(LedgerState(shared))` in start(), and
   a `ledger_today(session: Option<String>)` command that returns {day,
   receiver, guardrails newest first capped at 200, guardrails_total}.
   Register it in main.rs.
3. src/fleet/ledger.js (DOM-free): compactNumber (1.2M, 34k, 999950 to 1M),
   cacheShare = cache_read / (input + cache_read + cache_creation), with the
   formula in a comment, receipt parts with zeros hidden, the compact pick
   (top 3 by PR, commits, lines, tokens, shown in canonical order), and the
   chip label "N tool call(s) blocked by guardrails".
4. Card: a `.ledger-line` (receipt plus chip button) above the footer when
   comfortable. In compact it goes in the existing foot slot (grid-area
   note, justify-self start; hidden while a note shows; shares the slot with
   .why). Short text is aria-hidden; the full text is visually hidden.
5. Drawer: a native `<dialog>` with showModal, a header "Ledger" button,
   Esc to close, and explicit focus return. It holds totals, tokens per
   character as accent bars plus a visually hidden table, top-N attribution,
   the guardrail log, errors and refusals, one dim "≈ $X API-equivalent
   (estimate, not your bill)" line, the port-taken notice and the empty
   state. It refetches on each snapshot while open. Load the `dataviz` skill
   first, and use the Okabe-Ito tokens.
6. Demo: `scripts/fixtures/ledger-demo.json` (served only with ?demo,
   shifted like the fleet demo) and receipts on the demo sessions' `ledger`,
   one with 3 blocks.
7. Tests: node unit tests for step 3, guards, and Playwright cases in
   scripts/test_wall_browser.py (drawer open/Esc/focus return, the table
   equivalents, the empty and port-taken states, the chip name, fit).

## Verify
- The whole audit list in skill-context, plus
  `KLEPSYDRA_STAGE=klepsydra-build-ledgerui bash scripts/build-windows.sh --check`.
- Fit test: 8 cards at 945x1000 and 16 at 1920x1000, compact, no scrollbar.
- Renders to the scratchpad `ledger/` folder: both widths, the drawer open,
  and a 2x crop of a card. Then open a PR with "Closes #56", label
  enhancement, assignee ajbarea. Do not merge.
