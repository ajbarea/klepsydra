# IMPL: #460 Debian Linux launch parity (PR #458, branch feat/linux-launch-parity)

Issue: https://github.com/ajbarea/klepsydra/issues/460. The Windows/WSL path must not change.

## Slice
Live check on the Debian 13 / XFCE PC (RIT), and fix what it finds.

## Done
- Earlier: review fixes for the Linux launcher, `launch.rs` Linux argv, xdg-open verbs, pane-died on tmux 3.8 (see `git log`).
- Live check found every card action dead on native Linux: the hook records `"distro": null` there, and five readers (Rust `launch::target`, `folder_of`, `github_of`; JS `jumpable`, `inFleet`) required one. Now one Rust helper, `distro_words(distro, native)`, needs a distro only through wsl.exe; `recorded_distro` is the one reader; JS shares `paneKnown` (end.js). On Windows a record without a distro still gets no pane target (`target_on`), as before.
- Open terminal did not restore a minimized terminal: xfwm4 unmaps it, so `xdotool search --onlyvisible` missed it. `managed_window` picks the window with WM_STATE (xprop); without xprop, the old visible-only search.
- A missing `KLEPSYDRA_TERMINAL` is named in the error (`no_terminal`).
- README Linux: the wall buttons' tools and terminal order.
- Each fix has a test that fails without it (mutation-checked: 4 Rust, 2 JS, 1 shell, plus the Windows arm).

## Verified
Live, Debian 13 XFCE X11: + New session (cold and warm), Open terminal (switches tmux window; restores a minimized terminal), `KLEPSYDRA_TERMINAL=nope` (error on + and on Open terminal, nothing created). Suites: cargo fmt/clippy/test workspace, node 508, test-launch 285, test_fleet 599, test-headless 125, statusline, shellcheck, Biome.

## Next
1. CI green on push (ubuntu and windows-latest cargo test).
2. Not done live: End, Interrupt, Folder, GitHub on Linux (covered by tests only).
3. Follow-ups, not in this PR: the deb declares no tmux/xdotool/xdg-utils/x11-utils; launch log lines say "wsl" on Linux; `managed_window` takes the first managed window of a multi-window terminal process.
