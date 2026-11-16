# IMPL: klepsydra#393 multi-harness usage dashboard

Brief: `https://github.com/ajbarea/klepsydra/issues/393`

## Slice
Transform the gauge bar into a multi-harness usage dashboard showing quota rings grouped by harness (Claude Code, Antigravity, Copilot CLI, API keys), with status thresholds (ready, warning, capped), route recommendation badge, and matching `fleet accounts` CLI table.

## Planned Architecture
1. **Harness Quota Model (`src/gauge.js`)**:
   - Parse multi-harness quota records:
     - Claude Code (Personal, RIT): `five_hour`, `seven_day`, `spend_limit`.
     - Antigravity: `gemini` (Flash/Pro), `claude_gpt` (Sonnet/GPT-4o with "ends Nov 18" notice).
     - Copilot: `ai_credits` (monthly AI credits & renewal).
     - API keys: Personal & LDQIS spend limits.
   - Calculate `state` (`ready`, `warning` >= 75%, `capped` at 100% / rate limited).
   - Tag the lowest-utilized uncapped harness as `route: true`.
2. **Bar & Dashboard Rendering (`src/fleet/wall.js`, `src/fleet/wall.css`, `src/wall.html`)**:
   - Group rings by harness.
   - Dim capped harness groups.
   - Render "Route" pill on the recommended harness.
   - Respect compact/comfortable density and mobile responsive layout.
3. **CLI Dashboard (`fleet/fleet accounts`)**:
   - Output formatted multi-harness table with harness, window, used%, left%, resets in, and route status.
4. **Tests**:
   - Unit tests in `src/gauge.test.js` and `src/fleet-model.test.js`.
   - CLI verification in `fleet/test_fleet.sh`.

## Done
- Initialized worktree on branch `feat/usage-dashboard-393`.
- Rust quota synchronization: updated `WINDOWS` in `src-tauri/fleet/src/usage.rs` to declare all 8 windows (`five_hour`, `seven_day`, `spend_limit`, `gemini`, `claude_gpt`, `ai_credits`, `personal`, `ldqis`).
- Pure gauge logic: implemented `WINDOW_ORDER`, `HARNESS_ORDER`, `HARNESS_LABELS`, `WINDOW_LABELS`, `WINDOW_SHORT`, `harnessOf`, `windowNote`, and bottleneck-aware `isBestRoute` tag in `src/gauge.js`.
- Grouping: implemented `harnessGroups()` in `src/gauge.js` for grouping rows by harness.
- Advisory notices: integrated `windowNote()` ("ends Nov 18" for `claude_gpt`) into `entryText()`.
- DOM & UI: implemented `route-badge` rendering and dataset tagging (`harness`, `capped`, `route`) in `src/gaugeview.js`.
- Responsive styling: added contrast-safe dimming (`filter: grayscale(0.85); color: var(--text-dim)`) and `.route-badge` pills to `src/style.css` and `src/fleet/wall.css`.
- CLI dashboard: updated `fleet/fleet accounts` to discover and format multi-harness account readings under `$KLEPSYDRA_DIR/accounts/`.
- Test verification:
  - 59 gauge unit tests passed in `src/gauge.test.js`.
  - 501 Node unit tests passed across `src/*.test.js`.
  - 429 Rust unit tests + 7 integration tests passed in `src-tauri/`.
  - Shellcheck clean on `fleet/fleet`.

## Next
1. Rebase onto latest `origin/main` after PR #396 lands.
2. Commit changes with conventional message (zero attribution trailers, zero em-dashes).
3. Push branch and open PR linking #393 with short visible top (<= 150 words).
4. Monitor CI and shepherd to merge.
