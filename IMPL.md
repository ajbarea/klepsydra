# IMPL

Slice: #52 Fleet on the phone (read-only wall over Tailscale Serve). Branch
feat/phone-wall, worktree `.claude/worktrees/phone-wall`, PR #91 (part of
#52; rebased onto #82 and #83).

## Done
- `fleet::phone`: hyper server on `127.0.0.1:8318`, GET/HEAD only, Host
  loopback or `*.ts.net`, same-origin `Origin`, no Funnel; the wall's files
  by allow-list, `/fleet.json`, `/events` (SSE, 15 s heartbeat, 8 streams).
  Sessions cut to the wall's fields, now with `wrapup`, `turn_at`,
  `asked_after_turn` and the snapshot's `wrapup` request (display only).
- Assets: `exact_assets` holds Tauri's resolver to the bundle's own keys
  (`asset_resolver().iter()`), since `get_asset` falls back to `<path>.html`,
  `<path>/index.html`, then `index.html`. The test stub mimics that fallback.
  `# research(2026-10)`: tauri 2.12.2 `src/manager/mod.rs` `get_asset`
  (read in ~/.cargo/registry; the mime type is parsed from the requested
  path, so a mime check would not catch the fallback).
- `/wall.html` answers 308 to `/`: the page's one address, so `feedKind`'s
  root-path rule cannot load dev mode from the phone server.
- `followServed`: a stream the browser closed for good (readyState CLOSED,
  e.g. 503 at the cap, Serve's 502 during a restart) is reopened after 1 s
  doubling to 30 s, reset on open. `# research(2026-10)`: WHATWG HTML
  server-sent events, "fail the connection" on a non-200 or wrong type sets
  CLOSED and the UA "does not attempt to reconnect"; the spec suggests
  exponential backoff.
- Hook: the awk prefilter takes "Remote Control disconnected" only from a
  `"type":"system"` line's `"content":"...` field.
- Browser suite: wrap-up bar and answers, empty state (ended only, none)
  with no desktop control, `/wall.html` redirect, stream refused at the cap
  then reopened. README: tailnet visibility sentence.

## Next
- Round 2 independent review of the fixes; merge after #88.
- AJ: the live iPhone check over the tailnet (Tailscale not installed
  here), a tap on "Open in Claude" opening the Claude app, and 390x844
  screenshots.

## AJ decides
- Whether the server should also require Tailscale identity headers
  (`Tailscale-User-Login`) and an allow-listed login, beyond the ACLs.

## Verify
- `node --test src/*.test.js`
- `cd src-tauri && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings && cargo test -p klepsydra-fleet`
- every `hooks/test_*.sh`, `statusline/test_statusline.sh`, `scripts/test_*.sh`
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py`
- `uv run -q --no-project --with playwright python -I scripts/test_phone_browser.py`
- `KLEPSYDRA_STAGE=klepsydra-build-phone_wall bash scripts/build-windows.sh --check`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
