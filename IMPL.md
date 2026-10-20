# IMPL

Current slice: start sessions from the wall as tmux windows in one terminal
tab, with Clear, gone and the redesigned card wall (branch feat/fleet-launch).
Design: `docs/superpowers/specs/2026-10-20-fleet-launch-design.md` and
`2026-10-20-fleet-wall-redesign.md`.

## Done
- ✅ `hooks/klepsydra-launch.sh`: `new` adds a `claude` window to tmux session
  `fleet` (socket `klepsydra`) under a `flock`, and opens one tab, by socket
  path, only when no client shows it and no tab is still starting (30 s
  stamp). `jump` checks the pane still holds the Claude process first.
- ✅ `src-tauri/src/launch.rs`: the one file that starts a process (`wsl.exe`,
  from a click, one call at a time, 45 s, output read 2 s past exit).
- ✅ Jump: tmux, then exactly "klepsydra fleet" for the fleet socket, else the
  session title. A failed fleet jump shows the launcher's line; only "no tab
  matched" after tmux reads as success.
- ✅ Clear, ended or silent cards only; gone after a reboot or a dead pid.
- ✅ Wall: arc (working from `active_at`), pill with the reason on ended and
  error cards, ask line, tone edge, summary bar with **+ New session**, Open
  terminal with its off reason shown, 420 px columns.
- ✅ README: install, Starting sessions, Clear, gone, the wall, the live check.

## Verified
- ✅ node 148, `hooks/test_fleet.sh` 226, `hooks/test_launch.sh` 94,
  `cargo test -p klepsydra-fleet` 97, all passing.
- ✅ `build-windows.sh --check`: clippy and `cargo test --workspace` on Windows.
- 📋 Live check on Windows (README, Releasing, step 2.7), pending the Windows
  run: **+** three times, Jump between windows, close the tab and **+**,
  Clear, gone after `wsl --shutdown`.

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
