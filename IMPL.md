# IMPL

Current slice: keep the kourai cast while keryx is muted (#19). A muted keryx
holds no new terminal, so every new session fell back to a Lorelei face just
when keryx was off.

## Done
- ✅ `hooks/klepsydra-fleet.sh`: with no hold, the session takes its repo's
  voice from `homes` in keryx's `voices.json` (read only) while keryx still
  remembers it (90 days, as keryx's `assign` hands it out), and records
  `voice_from` ("hold" or "home"). A home applies only to a session with no
  voice yet; a file from before `voice_from` counts as held. The repo is
  named from the cwd as keryx's `source_name` does, now including a `.git`
  file saved with CRLF.
- ✅ `src-tauri/fleet`: `SessionFile` reads `started_at` and `voice_from`;
  `snapshot` shows a shared voice's face by claim: live before ended or
  silent, then hold before home, then the earlier start, then the lower
  session id; the others fall back, except a live hold.
- ✅ README (faces), the spec's addendum (the ruling), ROADMAP.

## Verified, not inferred
- ✅ Hook suite 186 (11 new: home, a forgotten home at 90 days and one
  second, a hold beside a home, hold then home, home then hold, home then
  home, another repo, a file from before `voice_from`, a CRLF `.git` file
  named as keryx names it).
- ✅ Fleet crate 80 (8 new, among them `/clear` with an ended predecessor and
  a silent hold beside a live home) with clippy clean; node 119.
- ✅ Independent review, round 1: two bugs (ended or silent sessions out-
  claimed live ones; a home replaced a home, so a face followed the cwd), a
  wrong window (14 days, where keryx forgets at 90) and a CRLF parity gap,
  all fixed here.
- ✅ Live (hook only, keryx muted): a new session in `ajsoftworks` got
  `am_michael` from its home and showed Hephaestus. A done session held the
  same voice, so the installed reader showed two; the new reader drops the
  home one (deploy after the 8-hour memory reading).

## Open
- The tray icon still draws a bar in either layout.
- The default display name (`my-app-3f`) reaches no hook and no status line,
  so a session with no voice and no name is named by its launch folder. The
  hooks docs confirm it: `session_title` carries only a name set with
  `--name`, `/rename` or a hook, never a generated title.
- Some turns end with no hook at all, so the card keeps its last state until
  the next prompt: a need dismissed with Esc keeps "needs you", its age
  showing, and an interrupted turn reads "working" until "working?" at 10
  minutes. The hooks docs say Stop skips user interrupts and
  `PermissionDenied` fires only in auto mode. In a probe (2026-10-19, Claude
  Code 2.1.301), a turn stopped by the safety classifier and then interrupted
  with Esc left the session file "working" for 130 s, with no `idle_prompt`
  to correct it. The transcript records such ends, but in internal record
  types, so the card waits for a hook rather than guess.

## Verify
    node --test src/*.test.js
    bash statusline/test_statusline.sh && bash hooks/test_fleet.sh
    bash scripts/test_measure_memory.sh
    (cd src-tauri && cargo test -p klepsydra-fleet && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings)
    bash scripts/build-windows.sh --check
    bash scripts/visual-check.sh
