# IMPL

Slice: #52 Fleet on the phone (read-only wall over Tailscale Serve). Branch
feat/phone-wall, worktree `.claude/worktrees/phone-wall`. PRs #82 (wrap-up)
and #83 (empty state) merge first; rebase onto them, then open the PR.

## Done
- `fleet::phone`: hyper server on `127.0.0.1:8318` (IANA-unassigned, below
  Windows' dynamic range, clear of 4317/4318). GET/HEAD only (405 + Allow);
  Host loopback or `*.ts.net`; same-origin `Origin` only; a
  `Tailscale-Funnel-Request` is refused. Routes: `/` (wall.html), the wall's
  files by allow-list, `/fleet.json` (503 before the first snapshot),
  `/events` (SSE, 15 s heartbeat, 8 streams). Sessions cut to the wall's
  fields (no tmux, claude, distro, receiver; launch_dir as its basename).
  `Server::stop`/drop closes the port and every stream. Shares `bind`,
  `our_host`, `backoff` with the OTLP receiver.
- App: tray "Phone wall" (pref `phone_wall`, off by default), `src-tauri/src/phone.rs`
  serves the bundle through `asset_resolver`; `fleet::start` publishes to it.
- `remote_url`: the hook tails 1 MiB of `transcript_path` (awk, 4 lines of
  at most 8 KiB) for bridge_status / remote_session_change / "Remote Control
  disconnected"; newest since the process started wins; none in the tail
  keeps the stored link; fresh start and SessionEnd clear it. Off is
  `sendUserFileHint: false` (the attachment's url is null while attribution
  is off, as on AJ's machine). session.rs keeps only `https://claude.ai/code/<id>`.
- Page: `served` (root path, not app, not ?demo) follows `/events`; `.served`
  hides every button not marked `data-phone`; one column of compact cards,
  needs-you first, sticky tally, 44 px targets; "Open in Claude" link and
  card tap; a reconnecting note. Manifest, 180/192/512 icons
  (`scripts/make-phone-icons.py`), shell-only `sw.js`.
- README "Fleet on your phone", AGENTS rule, skill-context suite list.

## Next
- Gate (all suites), push. Rebase onto #82/#83 when they merge: the Wrap up
  button from #82 is hidden on the phone by the `data-phone` rule; check
  feed.js `subscribe` and wall.js `receive` merge cleanly.
- Independent review (opus, `/code-review high`), at most 3 rounds.
- AJ: the live iPhone check over the tailnet (Tailscale not installed here);
  confirm a tap on "Open in Claude" opens the Claude app.

## Verify
- `node --test src/*.test.js`
- `cd src-tauri && cargo fmt --all --check && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings && cargo test -p klepsydra-fleet`
- every `hooks/test_*.sh`, `statusline/test_statusline.sh`, `scripts/test_*.sh`
- `uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py`
- `uv run -q --no-project --with playwright python -I scripts/test_phone_browser.py`
- `KLEPSYDRA_STAGE=klepsydra-build-phone_wall bash scripts/build-windows.sh --check`
- All heavy commands under `flock /tmp/fleet-heavy.lock`.
