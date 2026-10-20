# IMPL

Current slice: start sessions from the wall as tmux windows in one terminal
tab, with Clear, gone and the redesigned card wall (branch feat/fleet-launch).
Design: `docs/superpowers/specs/2026-10-20-fleet-launch-design.md` and
`2026-10-20-fleet-wall-redesign.md`.

## Done
- ✅ `hooks/klepsydra-launch.sh`: `new` starts `claude` as a window of tmux
  session `fleet` (socket `klepsydra`) under a `flock`, and opens one
  Windows Terminal tab only when no client is attached. `jump` selects a
  pane's window after checking the Claude process (pid and start time) is
  still in it.
- ✅ `src-tauri/src/launch.rs`: the one file that starts a process (`wsl.exe`,
  fixed path, from a click, one call at a time). `src/guards.test.js` asserts
  that exemption.
- ✅ Jump: tmux first, then the fixed "klepsydra fleet" tab title for the
  fleet socket; hand-opened tabs keep the session-title match.
- ✅ Clear (`clear_session`): ended or silent cards only, regular files inside
  `fleet/` only.
- ✅ Gone: the hook records `tmux` and `host` and marks a session ended with
  reason `gone` at the next `SessionStart` after a reboot or a dead pid.
- ✅ Wall redesign: water-clock arc, status pill, ask line, tone edge, summary
  bar with **+ New session**, Open terminal, grid of 420 px columns.
- ✅ `KLEPSYDRA_STAGE` names the Windows build folder; `?demo` loads
  `scripts/fixtures/fleet-demo.json`.
- ✅ README: install, Starting sessions, Clear, gone, the wall, the live check.

## Verified
- ✅ node 145, `hooks/test_fleet.sh` 221, `hooks/test_launch.sh` 79,
  `cargo test -p klepsydra-fleet` 94, all passing.
- 📋 Live check on Windows (README, Releasing, step 2.7): **+** three times,
  Jump between windows, close the tab and **+**, Clear, gone after
  `wsl --shutdown`. `build-windows.sh --check` runs in CI and on Windows only.

## Next
- 📋 #32: an optional split mode for the fleet tab.
- 📋 #22: interrupt and exit from a card; the recorded `tmux.pane` makes it a
  `send-keys` to a known pane.

## Open
- The tray icon still draws a bar in either layout.
- The default display name (`my-app-3f`) reaches no hook, so such a session
  is named by its folder.
- Some turns end with no hook (Esc on a need, an interrupt): the card keeps
  its state until the next prompt, or "working?" at 10 minutes.

## Verify
    node --test src/*.test.js
    bash statusline/test_statusline.sh && bash hooks/test_fleet.sh && bash hooks/test_launch.sh
    bash scripts/test_measure_memory.sh
    (cd src-tauri && cargo test -p klepsydra-fleet && cargo clippy -p klepsydra-fleet --all-targets -- -D warnings)
    bash scripts/build-windows.sh --check
    bash scripts/visual-check.sh
