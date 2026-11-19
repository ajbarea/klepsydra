# IMPL: #460 Debian Linux launch parity (PR #458, branch feat/linux-launch-parity)

Issue: https://github.com/ajbarea/klepsydra/issues/460. The Windows/WSL path must not change.

## Slice
Take PR #458 from "not clean" to clean: fix every finding of the Opus review, each with a test.

## Done
- `is_wsl` reads the kernel release through `proc_osrelease`, inside the shared "proc stat" block (identical in the fleet, launch and browser hooks); the launcher's `PROC_ROOT` is `KLEPSYDRA_PROC` like the fleet hook's.
- Linux cases in `hooks/test_launch.sh`: terminal order and none-found, `KLEPSYDRA_TERMINAL`, per-emulator command lines, failed and handed-off terminals, `xdotool` jump, folder and github verbs, WSL detected by kernel release.
- A terminal that exits non-zero fails the launch, undoes what it made and drops the pending stamp.
- Jump raises the window found by walking up from the session's own tmux client (hand-started tmux included).
- `folder` and `github` fail when `xdg-open` is missing or fails at once.
- `launch.rs`: Linux argv built by `linux_argv` / `linux_open_argv` (HOME unset or relative is refused); one `wait_child` shared with the Windows `run`; `run_open` for folder and github.
- `klepsydra-pane-died.sh`: tmux 3.8 prints an empty `#{pane_pid}` for a dead pane (format.c: `wp->fd != -1`, 3.8 only; 3.7c and Debian 13's 3.5a print the old pid). Comment fixed, fixture test with a stub tmux.
- `jump.rs`: `cfg_attr(not(windows), allow(dead_code))`; `fleet-queue.test.js`: the three linear-time tests skip without `process.threadCpuUsage` (no GC-thread fallback).

## Verified so far
`make test-launch` 281 passed, 0 failed (one #290 case failed once, then passed: flaky, not yet checked on main); `node --test src/*.test.js` and `statusline` pass. The remaining suites were running in the background (log: the session scratchpad suites.log) when RIT's window ran out: re-run any not yet green.

## Next
1. Re-run what is not green: hooks/test_fleet.sh (block parity tests), test_browser.sh, make test-fleet, shellcheck, clippy/cargo -p klepsydra-fleet, `KLEPSYDRA_STAGE=klepsydra-build-linux_458 bash scripts/build-windows.sh --check` (the only run that compiles launch.rs and its new tests; nothing has compiled it yet).
2. Rewrite the PR #458 body (short top, link #460, every suite run, Linux paths checked only in tests on WSL; AJ checks live on the Debian PC); push; one bounded wait for CI green. Do not merge.
3. Report to Heph, `fleet done`.

## Verify
As listed under Next 1, plus `make test-launch`.
