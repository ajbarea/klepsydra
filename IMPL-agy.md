# agy-533: show when an agent is using the shared browser (klepsydra#533)

## Issue
ajbarea/klepsydra#533: Shared Playwright browser: show when an agent is using it, so closing the window doesn't cut a run.

## State
- Holder lookup implemented: `hooks/klepsydra-browser.sh` (`--holder`, `--holder-of`, `--holders`, `--sync-holders`, `--pre-tool`).
- `fleet doctor` reports MCP browsers: "held by <agent> for N min" (warns if idle past threshold or server gone).
- If the browser was closed while held, `fleet doctor` reports "warn MCP browsers: browser closed while <agent> held it" and pre-tool denies subsequent browser tool calls until cleared or `browser_close` is invoked.
- Wall UI: cards display `.browser-chip` inside `.meta .where` showing `browser: <agent>` styled identically to `.branch` and `.acct`.
- Backend/models: `SessionFile` and `View` in `src-tauri/fleet` include `browser: Option<String>` and pass through JSON and phone payloads.
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
