# IMPL: #533 Shared Playwright browser: show when an agent is using it (feat/browser-in-use-533)

Issue: https://github.com/ajbarea/klepsydra/issues/533

## Slice
Show when an agent is using the shared Playwright profile (`~/.cache/ms-playwright-mcp/mcp-chrome-c35bcf5`) so closing the window does not cut a run.
Expose holder in `fleet doctor` ("held by <agent> for N min") and wall UI (`browser: <agent>` chip). Report if closed while held and deny unhandled tool calls until reset or closed.

## Done
- Holder mapping in `hooks/klepsydra-browser.sh`: `--holder`, `--holder-of`, `--holders`, `--sync-holders`, `--pre-tool`. Maps Chrome process trees with `--user-data-dir` matching Playwright MCP profiles to Claude sessions / fleet agents using `/proc`, `fleet/*.json`, and `panes.tsv`.
- `fleet doctor`: reports `held by <agent> for N min` (warns if idle past threshold or server gone). If closed while held, reports `warn MCP browsers: browser closed while <agent> held it`.
- Hook PreToolUse handling: denies browser tool calls when closed while held until `browser_close` resets the state.
- Wall UI: cards display `.browser-chip` inside `.where` with browser icon and `browser: <agent>`.
- Models & Backend: `SessionFile` and `View` in `src-tauri/fleet` serde `browser: Option<String>`.

## Verified
- Live proof:
  - 1920-wide screenshot captured at `docs/proof-533-chip.png` showing `browser: agy-533` chip.
  - Doctor output verified: `warn MCP browsers: browser closed while agy-533 held it`.
- Suites verified:
  - `node --test src/*.test.js` (592 tests passed)
  - `bash hooks/test_browser.sh` (43 tests passed)
  - `bash fleet/test_fleet.sh` / `make test-fleet` (1047 tests passed)
  - `bash statusline/test_statusline.sh` (143 passed)
  - `bash hooks/test_fleet.sh` (125 passed)
  - `bash scripts/test_measure_memory.sh`
  - `bash scripts/test_build_windows.sh`
  - `make test-headless`
  - `make test-engine`
  - `make test-launch`
  - `make test-delegate`
  - `make test-heavy-lock`
  - `make test-slice`
  - `make shellcheck`
  - Biome lint (`npm run lint`) & `uvx ruff check`
  - `cargo fmt --all --check` & `cargo clippy -p klepsydra-fleet --all-targets -- -D warnings` & `cargo test -p klepsydra-fleet` (447 tests passed)
- Windows build check (`scripts/build-windows.sh --check`):
  - Rerun with `timeout 40m bash scripts/build-windows.sh --check`.
  - PowerShell invocation via WSL interop hung at `/init /mnt/c/WINDOWS/System32/WindowsPowerShell/v1.0/powershell.exe` with no `cargo` or `rustc` running underneath it (0:00 CPU time). Stopped per orchestrator instructions.

## Next
1. Commit, push branch, open PR.
2. Verify CI checks.
