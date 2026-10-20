# IMPL

Current slice: #56 Slice 1, branch feat/otel-ledger. A local OTLP/HTTP JSON
receiver and a ledger store in the fleet crate. Slice 2 (the wall's receipt
line, guardrail chip and ledger drawer) waits for #55.

## Done
- Recorded real exports first (`claude -p --model haiku`, delta and
  cumulative), redacted into `src-tauri/fleet/tests/fixtures/otel/`.
- `fleet/src/otel.rs`: parses sums (delta or cumulative, numeric or enum
  temporality, `asDouble`/`asInt`, string or number int64) and named log
  records. Unknown fields skipped; malformed parts dropped, never a panic.
  Series and dedupe keys are FNV-1a (stable across rebuilds).
- `fleet/src/ledger.rs`: per-session `Totals` (all `serde(default)`),
  integer units (`cost_usd_estimate_micros`, `active.*_ms`). Delta dedupe on
  (resource attrs, scope, metric, attribute set, start, end), kept
  `DEDUPE_WINDOW` (1 h); older points are stale. Cumulative: difference from
  the series' last point; new start time or a drop = reset. Events deduped on
  (resource, scope, name, session, sequence, time). Day file per UTC day plus
  `state.json` (lifetime totals, keys, baselines), atomic writes, unreadable
  files set aside as `.bad`, `RETENTION_DAYS` = 30 prune by exact name only.
- `fleet/src/receiver.rs`: hyper 1 http1 server on a current-thread tokio
  runtime, `127.0.0.1:4318`, `MAX_BODY` 4 MiB (Content-Length and streamed),
  404/405/415/413/400. Bind failure returns an error; the app logs it.
- `View.ledger: Option<Totals>` (omitted when None); `Reader::with_ledger`.
- App: `src/fleet.rs` opens `<dir>/ledger`, spawns the receiver, logs to
  `fleet.log`. main.rs untouched.
- `examples/receiver.rs` for live checks; README settings `env` + ledger section.

## Measured
- Live haiku session through the example receiver: ledger tokens (10 in,
  918 out, 213366 cache read, 36895 cache creation) equal the transcript's
  summed `usage`; +2 -1 lines; 1 guardrail (Bash, config).

## Next
- PR "Part of #56"; review; merge after #55 if they touch the same lines.
- Slice 2 on the wall. Open question: days are UTC, so "today" in the drawer
  needs the local offset or two files.
