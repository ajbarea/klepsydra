# IMPL

Current slice: prune the readings the overlay can never draw again. The
statusline hook kept every session's reading forever (265 files on the WSL
station, 128 over a week old), and the overlay reads them all every refresh.

## Done
- ✅ Publish guard: a reading whose every window has ended is never
  published. Without it, an idle session whose file was pruned would
  republish its last response as new on its next render.
- ✅ Prune (`statusline/klepsydra-statusline.sh`): hourly, detached under a
  `flock` so a render never waits (the docs: a slow status line blocks
  updates, and a new update cancels the script in flight). It deletes a
  reading whose every window ended over a day ago unless it is its account's
  newest by the gauge's stamp; the newest goes once its stamp is past the
  gauge's 30-day drop. A file that does not parse as one object, holds a
  window with no numeric reset, or has no numeric stamp stays.
- ✅ The data-dir guard and the hourly runner are one block in both hooks
  ("prune helpers"), checked identical by both suites; the fleet's guard
  tests now cover the statusline prune.

## Verified, not inferred
- ✅ statusline suite 106 (24 new), fleet 186, shellcheck clean. The suite
  runs on a fixed clock now; the fixtures' resets are in the past.
- ✅ `toRows` before and after a prune agree, in the suite and on a copy of
  the WSL station's readings (265 files to 74, three rows unchanged). Two
  mutants of the rule and one of the link guards each fail the suite.
- ✅ A render that starts a prune returns in 22 ms; on /mnt/c the first prune
  took 1.6 s and a later one 0.35 s, all in the background.
- 📋 Live: deploy the hook and watch the status line render while the first
  prune runs.

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
