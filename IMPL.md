# IMPL

Slice: #68, the ledger checked against transcripts, and no loss while the app
is closed. Branch feat/ledger-verify, worktree `.claude/worktrees/ledger-verify`.
The issue and its comments (`gh api repos/ajbarea/klepsydra/issues/68/comments`)
are binding.

## Done
- `ledger-verify` binary (logic in `reconcile.rs`): ledger vs transcripts per
  session, exit 1 when more than 2% low on cache_read or cache_creation, or
  when a session missing from the ledger has every transcript message within
  `GAP_SLACK` (`ALIVE_EVERY` + 60 s) of a receiver gap (`ledger::read_gaps`;
  "receiver down"). Other missing sessions are "sent no telemetry" and exit 0;
  unreadable state is 2. `Transcripts.times` keeps each message line's time.
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
- Unreadable state.json (parse, bad UTF-8 or other read error; moved or
  copied aside as `.bad`): the day files' sessions go in `State.reseed`
  (set-aside time, capped and pruned like the session maps), saved inside
  `open`. A reseeded session's series without a baseline only seed
  (`Tally.seeded`), and `lost_in_gap` is always true for it. A gap 0..open is
  recorded. `save` writes state before the day file. Negative or NaN values
  are ignored before they touch a baseline.
- README: the cumulative env var, the partial rule and its resumed-process
  limit, unreadable state and its low-reading new series, receiver-down in
  `ledger-verify`, midnight gaps.
- Round-2 review fixes pushed (no-telemetry vs gap, reseed persistence,
  read-error aside, README line).

## Next
- Independent re-review of the round-2 fixes on PR #72.
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
