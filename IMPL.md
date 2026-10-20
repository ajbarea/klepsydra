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
  (resource, scope, name, session, sequence, time). Keys expire by when they
  were counted; points over `MAX_AHEAD` (5 min) ahead are dropped. Day file
  per local day (jiff, `TimeZone::system()`) plus
  `state.json` (lifetime totals, keys, baselines), atomic writes, unreadable
  files set aside as `.bad`, `RETENTION_DAYS` = 30 prune by exact name only.
- `fleet/src/receiver.rs`: hyper 1 http1 server on a current-thread tokio
  runtime, `127.0.0.1:4318`, `MAX_BODY` 4 MiB (Content-Length and streamed),
  403 for a foreign Host or any Origin (DNS rebinding), 404/405/415/413/400,
  408 past `LIMITS.body`; `LIMITS` 10 s header, 10 s body, 32 connections.
  socket2 bind: SO_EXCLUSIVEADDRUSE plus a dropped exclusive wildcard probe
  on Windows (a loopback bind beside a same-user wildcard listener otherwise
  succeeds, per Microsoft's bind table); SO_REUSEADDR kept on Unix (Linux
  refuses a second listener anyway; it only allows TIME_WAIT rebinds).
- Caps: `MAX_SESSIONS` 512 per map (least recently updated goes),
  `MAX_ATTR_CHARS` 256; `Day.no_session` counts points with no session.
- `Snapshot.receiver` reports a taken port; the app retries every 30 s.
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
- Slice 2 on the wall: receipt line, guardrail chip, ledger drawer,
  `receiver` state.
