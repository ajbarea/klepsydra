# IMPL: #533 show when an agent holds the shared browser (PR #556, branch feat/browser-in-use-533)

Issue: https://github.com/ajbarea/klepsydra/issues/533. Opus redesign at the
free-engine cap; spec: the smaller design in
https://github.com/ajbarea/klepsydra/pull/556#issuecomment-7182947522

## Slice
A session's file holds `"browser": "open"` while its claude has the shared
Playwright browser open; its card shows a **browser** chip. `--pre-tool`
never blocks: when the caller's own window closed, it adds a note for Claude
(tell the user) once and exits 0. No deny state, no state files.

## Done (11-27)
- Fleet hook: PostToolUse of `mcp__*playwright*__browser_*` marks "used"
  (keeps "open"); `browser_close`, SessionEnd and any start but a compaction
  drop it (under its lock).
- `klepsydra-browser.sh --sync` (each resume pass, this boot and distro's
  sessions only, shared `host facts` block): "open" for a live session whose
  claude holds its mcp-chrome browser, "closed" when a confirmed one goes,
  none for an unconfirmed "used" or a dead claude. Writes under the fleet
  hook's lock (shared lock dir block), rechecking the mark under it.
- `--pre-tool`: builtins on the payload and the session's own file; walks
  /proc (task children, full scan fallback) only for a marked session;
  confirms "used", drops the mark at browser_close, notes a confirmed close.
- Usage exits 1. `fleet install` registers `--pre-tool || true` only once
  the copy is this checkout's, replacing older entries; atomic write at the
  resolved path keeps a symlink and the file's mode.
- doctor.sh is main's plus: the holder's name in "MCP browsers", and a
  "browser hook" check over every account's settings.
- Rust: `browser: bool` (true for "used" or "open"), lenient; wall chip is an
  icon + the word "browser" with a tooltip.
- Tests: hooks/test_browser.sh (sync, pre-tool, lock, registered command,
  mutants), hooks/test_fleet.sh (#533 cases), fleet/test_fleet.sh (install,
  doctor, resume pass), scripts/test_wall_browser.py `browser_chip`.

## Next
- Measure pre-tool and sync on a tmpfs fake /proc (3 browsers, 43 files).
- Full suites, elenchus rounds until clean, PR body, merge, `fleet install`,
  live chip + `fleet doctor` on both accounts; reports/redesign-556.md.

## Verify
`bash hooks/test_browser.sh`; `bash hooks/test_fleet.sh`;
`make test-fleet FLEET_SHARD=doctor` (and resume, misc);
`cargo test -p klepsydra-fleet`; `node --test src/`;
`scripts/test_wall_browser.py browser_chip` under the heavy lock.
