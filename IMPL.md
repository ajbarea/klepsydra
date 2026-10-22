# IMPL

Slice: Linux parity: native audio ping via libcanberra and Linux launcher path.
Branch: feat/linux-parity, worktree `.claude/worktrees/linux-parity`.

## Done
- In-process native audio ping on Linux via dynamic `dlopen`/`dlsym` of `libcanberra.so.0`, avoiding external audio processes and keeping within guards.
- Linux X11 full-screen detection via `x11rb` (`_NET_ACTIVE_WINDOW` and `_NET_WM_STATE_FULLSCREEN`).
- Tray menu "Ping" and cue generation enabled on Linux (`src-tauri/src/main.rs`, `src-tauri/src/fleet.rs`).
- Linux launcher path in `src-tauri/src/launch.rs` calling `/bin/bash` directly.
- `hooks/klepsydra-launch.sh` adapted to detect Linux terminals (`find_linux_terminal` checking `$KLEPSYDRA_TERMINAL`, `xfce4-terminal`, `x-terminal-emulator`, `gnome-terminal`, `kitty`, `alacritty`, `wezterm`, `foot`) when outside WSL.
- `src/guards.test.js` updated to assert `Command::new` uses `["WSL_EXE", "BASH_EXE"]`.
- Built release Debian package `src-tauri/target/release/bundle/deb/klepsydra_0.1.0_amd64.deb` (3.92 MiB).
- Full verification suite green across Rust, JS, statusline, and fleet hooks.

## Next
- Open pull request for `feat/linux-parity`.
- Create GitHub Issues for remaining Linux parity slices:
  1. Linux Window Activation (`jump.rs` `_NET_ACTIVE_WINDOW` via x11rb).
  2. Linux launcher mock/matrix test suite in `hooks/test_launch.sh`.
  3. Linux host prerequisites & setup guide (`tmux`, `libcanberra`, hooks).

## Verify
- `cd src-tauri && cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test`
- `node --test src/*.test.js`
- `bash statusline/test_statusline.sh`
- `bash hooks/test_fleet.sh`
- `bash scripts/build-linux.sh`
