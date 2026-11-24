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
- Delta review r1 (Heph, 11-23, `reports/linux-458-delta-r1.md`): S1, the wall lost the platform and offered End/Interrupt, a typed wrap-up and an unnamed Jump to a null-distro session on Windows. The app now adds `native` (launch.rs `NATIVE`) to the wall's snapshot (fleet.rs `for_wall`; the phone gets none), and `paneKnown(s, native)` needs `str(s.distro) || native`. N1: `session_distro(s, native)` is the one reader for `target_on`, `folder_of`, `github_of`, so Folder/GitHub on Windows say again that klepsydra does not know the folder/page. N2: `managed_window` falls back to the visible-only search when no window reports WM_STATE. Six JS mutants killed.
- Delta review r2 (Heph, 11-23, `reports/linux-458-delta-r2.md`): S1, `jumpStyle` read jumpability again without `native`, so an unnamed native session's Open terminal lost its needs fill and accent marker; it now takes the card's `jump`. S2, the flag's path was unpinned: `hand_out` (fleet.rs) gives the phone the bare snapshot and the windows `for_wall`'s; `folder_request` / `github_request` (launch.rs) read the snapshot for Folder/GitHub as this build does; a browser case feeds a null-distro snapshot with `native: true` and without it. N1: `wrapupLine` takes the flag too.

## Verified
Live, Debian 13 XFCE X11: + New session (cold and warm), Open terminal (switches tmux window; restores a minimized terminal), `KLEPSYDRA_TERMINAL=nope` (error on + and on Open terminal, nothing created). Suites: cargo fmt/clippy/test workspace, node 508, test-launch 285, test_fleet 599, test-headless 125, statusline, shellcheck, Biome.

Merged main (15 commits) at 1619197; IMPL.md kept as the branch's. On the merged tree: cargo 113+439+7, node 584, test-launch 321, test_fleet 599, test-headless 125, statusline 143, browser 33, shellcheck, Biome; live after a reboot: + New session twice from cold, Open terminal restores a minimized terminal.

## Next
1. ✅ Delta r1 fixes (S1, N1, N2) pushed.
2. 📋 Delta r2 fixes (S1, S2, N1): suites, mutants, push, CI.
3. 📋 Heph runs round 3 and merges; do not merge here.
4. Not done live: End, Interrupt, wrap-up typing, unnamed Jump style, Folder, GitHub on native Linux (tests only; AJ's next Debian session, needs-you).
5. Follow-ups filed, not in this PR: #527 deb dependencies, #528 "wsl" log lines on Linux, #529 multi-window terminal, #530 xdotool BadWindow, #531 hardcoded fleet-briefing path.
