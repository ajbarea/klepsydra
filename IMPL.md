# IMPL: #533 show when an agent holds the shared browser (PR #556, branch feat/browser-in-use-533)

Issue #533. Opus redesign at the free-engine cap; spec: the smaller design in
https://github.com/ajbarea/klepsydra/pull/556#issuecomment-7182947522
Paused 11-27 (RIT weekly limit); resume from here.

## Slice
Card shows a **browser** chip while the session's file mark is "used" or
"open". Fleet hook (PostToolUse, `mcp__*playwright*__browser_*`) marks
"used"; `klepsydra-browser.sh` confirms "open" once it sees that claude's own
mcp-chrome Chrome, marks "closed" when it goes. `--pre-tool` never blocks:
when a confirmed window closed under the caller it adds a note (tell the
user) once, exit 0. No deny state, no state files.

## Done (head 5448859 + this commit)
- Fleet hook: "used" (keeps "open"); browser_close, SessionEnd, any start but
  a compaction and `mark_gone` drop it. Shared `host facts` block.
- `reconcile` decides every mark under the fleet hook's lock from the mark and
  /proc as they are then (modes sync, tell, close); moves written_at/turns_at.
- `--sync` (resume pass, this boot+distro only); `--pre-tool` (builtins, walks
  /proc only for a marked session); usage exits 1.
- `fleet install` registers `--pre-tool || true` once the copy is this
  checkout's; atomic write at the resolved path keeps symlink and mode.
- doctor = main's + holder name (fleet socket only) + per-account "browser hook".
- Rust `browser: bool` ("used"/"open", not when ended); chip = icon + "browser".
- Reviews: /code-review medium (10 findings) + readers r1, r2 (all fixed);
  round-3 reader ran on 5448859 (see PR comment / report for its result).

Consumers traced (readers r1-r2): fleet hook PostToolUse has no matcher (sees
every Playwright tool); resume pass runs `--sync` from the checkout with
KLEPSYDRA_DIR; doctor TSV columns line up; HOOK_COPIES installs the script;
Rust reads leniently, JS `=== true`; phone carries the bool; accounts-sync
copies the hook to ~/.claude-rit.

## Measured (tmpfs fake /proc, 3 browsers, 43 session files; fcd8d71 vs ac67195)
pre-tool 70.9 ms/28 execs -> 5.7 ms/1; unmarked 3.6 ms/1; sync 69.1 ms/26 ->
20.7 ms/3 (338 procs: 73.8 -> 5.5; 70.8 -> 23.5). Harness and outputs:
~/.local/state/fleet-orchestrator/reports/redesign-556/ (measure.sh NEW OLD
[EXTRA]; needs host boot in session files since r2). Not re-measured on 5448859.

## Next
1. Doctor shard: `#533: a pass marks the session holding a browser open`
   failed (null) on CI and locally, also at 7cf956e before the host check. The
   fixture now carries host boot+distro (`bsync`), but a second cause is open:
   `--sync` run by hand on the same fake /proc writes "open" (scratch repro
   works), so suspect the resume pass env (bash `VAR=x func` export? lib.sh?).
   Trace with `bash -x` inside the pass. Watcher "review 5" red on CI is a
   tmux paste-timing test outside this diff: rerun to confirm a flake.
2. Run (heavy lock, do not edit the suite while it runs): `make test-fleet`,
   cargo test/clippy/fmt, `test_wall_browser.py browser_chip chip_name`,
   re-measure with measure.sh, `make shellcheck`.
3. Fresh Opus reader (elenchus medium) until a round is clean, then a verify
   pass. Rewrite the PR body (still the old deny design), merge on clean + CI.
4. Live: `fleet install`; chip on a real card during a Playwright MCP call;
   `fleet doctor` "browser hook" ok on both accounts; registered command with
   an old script exits 0. Write reports/redesign-556.md; `fleet done`.

## Verify
`bash hooks/test_browser.sh` (92), `bash hooks/test_fleet.sh` (690),
`make test-fleet FLEET_SHARD=doctor`, `cargo test -p klepsydra-fleet` (473 on
ac67195), `node --test src/fleet-model.test.js`.
