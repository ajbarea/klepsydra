# IMPL

Slice: #68, the ledger checked against transcripts, and no loss while the app
is closed. Branch feat/ledger-verify, worktree `.claude/worktrees/ledger-verify`.
The issue and its comments (`gh api repos/ajbarea/klepsydra/issues/68/comments`)
are binding.

## Done
- `ledger-verify` binary (logic in `reconcile.rs`): ledger vs transcripts per
  session, exit 1 when more than 2% low on cache_read or cache_creation, or
  when a session missing from the ledger ran during a receiver gap
  (`ledger::read_gaps` reads them from state.json; "receiver down"). Other
  missing sessions are "sent no telemetry" and exit 0; unreadable state is 2.
- Day file `models`: tokens and cost per session per model (16 max, rest under
  `(other)`); the drawer's "Tokens by model" table.
- `alive` stamp every 60 s and receiver gaps (`note_listening`).
- Cost wording says list-price estimate and names the billing record.
- Cumulative temporality: per-series diffs, baselines in state.json. Tests
  cover a gap restored by one export, a receiver restart, midnight, delta and
  cumulative side by side.
- `State.cumulative_at` marks only a cumulative point that advanced its
  baseline, at arrival time; `Ledger::lost_in_gap` feeds `ledger_partial`.
  A pre-gap point retried after the gap leaves the session partial.
- Unreadable state.json: sessions in any day file only seed their baselines
  (`Tally.seeded`, saved by the receiver), stay partial, and a gap 0..open
  is recorded. `save` writes state before the day file. Negative or NaN
  values are ignored before they touch a baseline.
- README: the cumulative env var, the partial rule and its resumed-process
  limit, unreadable state, receiver-down in `ledger-verify`, midnight gaps.

## Next
- Push the review fixes to PR #72 and get an independent re-review.
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
