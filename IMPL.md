# IMPL

Slice: #68, the ledger checked against transcripts, and no loss while the app
is closed. Branch feat/ledger-verify, worktree `.claude/worktrees/ledger-verify`.
The issue and its comments (`gh api repos/ajbarea/klepsydra/issues/68/comments`)
are binding.

## Done
- `ledger-verify` binary (logic in `reconcile.rs`): ledger vs transcripts per
  session, exit 1 when more than 2% low on cache_read or cache_creation.
- Day file `models`: tokens and cost per session per model (16 max, rest under
  `(other)`); the drawer's "Tokens by model" table.
- `alive` stamp every 60 s and receiver gaps (`note_listening`).
- Cost wording says list-price estimate and names the billing record.
- Cumulative temporality: `record_metrics` already diffs per series and keeps
  baselines in state.json. Tests cover a gap restored by one export, a
  receiver restart, midnight, delta and cumulative side by side, and the
  receiver saving on each counted or repeated export.
- `State.cumulative_at` per session (capped at MAX_SESSIONS, pruned by
  retention) and `Ledger::lost_in_gap`; watch.rs uses it for `ledger_partial`,
  so a session restored by a post-gap cumulative export is not partial.
- README: the cumulative env var, what it restores, the partial rule.

## Next
- Push, open the PR (Refs #68), independent review (`/techne:elenchus`), CI.
- Merge, deploy, then set `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE`
  in both accounts' settings.json (back up first; AJ's step) and run
  `ledger-verify` on a live day after sessions restart.

## Facts
- `hooks/test_launch.sh` failed at "at: unbound variable" on an earlier base
  too; check before blaming this branch.
- node is at `~/.nvm/versions/node/v24.18.0/bin`.

## Verify
- `cd src-tauri && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings && cargo test -p klepsydra-fleet`
- `node --test src/*.test.js`, the shell suites, shellcheck, `scripts/test_wall_browser.py`,
  `KLEPSYDRA_STAGE=klepsydra-build-ledger_verify bash scripts/build-windows.sh --check`.
