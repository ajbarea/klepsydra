# IMPL

Slice: #56 Slice 2, the ledger on the wall (receipt line, guardrail chip,
ledger drawer). Branch feat/ledger-ui, worktree `.claude/worktrees/ledger-ui`.
The issue body (`gh api repos/ajbarea/klepsydra/issues/56 -q .body`) and its
Slice 2 "Done when" are binding.

## Done (all committed locally, nothing pushed)
- Rust: `Day.attribution` and `ledger_today` (TodayView), registered in main.rs.
- `src/fleet/ledger.js` (DOM-free, `src/fleet-ledger.test.js`): compactNumber,
  cacheShare, receipt parts, compact pick, chip label, drawer figures,
  attribution labels (redacted names say so), cost line.
- Card: `.ledger-line` (receipt + chip) above the footer; in compact it takes
  the foot slot and gives way to a note or Open terminal's reason.
- Drawer: `src/fleet/drawer.js`, a native `<dialog>` in wall.html opened by the
  Ledger button (in `.lead`, beside the ring key) or a chip (filtered to that
  session). Totals, tokens by character as one table plus aria-hidden bars,
  attribution tables, blocked log, errors, one dim cost line, port-taken
  notice, empty state naming README "The ledger". Refetches on each snapshot.
- Demo: `scripts/fixtures/ledger-demo.json` (only with ?demo, via
  `demoLedgerUrl`/`todayLedger` in feed.js) and `ledger` on the demo sessions.
- Tests: guards (demo unreachable in the app, dialog shape, no links), style
  tests (slot parity, 24 px chip target, contrast), 7 Playwright cases.
- README "The ledger" describes the wall's receipt, chip and drawer.

## Facts
- The wall has no light theme, so the drawer uses the wall's dark tokens only.
- The Ledger button sits with the tally and ring key: beside the density
  choice it made the 945 px bar wrap the tally and the fit test scroll.
- `hooks/test_launch.sh` fails at line 256 ("at: unbound variable") on the
  base commit too (no tab-pending stamp in this environment); untouched here.

## Next
- Open the PR ("Closes #56", label enhancement, assignee ajbarea) once AJ
  says; do not merge. Live check in the Windows app with real telemetry.

## Verify
- `node --test src/*.test.js`, the shell suites and shellcheck, the fleet
  crate's fmt/clippy/test, `scripts/test_wall_browser.py`, and
  `KLEPSYDRA_STAGE=klepsydra-build-ledgerui bash scripts/build-windows.sh --check`.
- Renders: scratchpad `ledger/` (both widths, both densities, the drawer,
  filtered drawer, 2x card).
