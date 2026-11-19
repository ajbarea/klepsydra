# IMPL: PR #477 round 2 (ns477): + New session wired to the real app (#440)

Brief: ~/.local/state/fleet-orchestrator/briefs (ns477). PR #477, branch feat/new-session-split-440
(local branch `ns477` in .claude/worktrees/ns477 pushes there). Decision: Variant A (PR #459).

## Design (decided 11-19)
- Launcher (`hooks/klepsydra-launch.sh`): `new DIR claude ACCOUNT [MODEL]` finds the config folder
  whose login is ACCOUNT (never by folder name: on AJ's PC ~/.claude is RIT, ~/.claude-rit is
  Personal); `new DIR copilot [MODEL]` starts Copilot locked like `fleet delegate`;
  `new DIR agy MODEL` refuses a model whose quota group is spent (fresh `agy -p /quota`);
  `models` adds each model's quota group from `/quota`; `engines` prints what is installed and
  which Claude accounts have a login here.
- Rust (`launch.rs`): launch_session takes engine, account, model; refuses an account whose
  newest reading has a live window at 100% (`usage::spent_until`, fleet crate); writes
  `new_session_last` to prefs.json on a launch that started. New commands: `engines_status`,
  `new_session_prefs`, `set_new_session_default`.
- Wall: usage from `read_usage` through `toRows` (desktop snapshot has none); menu built only on
  open and on user actions, focus kept by stable key; Escape returns to the caret; no data
  through innerHTML; native radios; Recommended first; install/sign-in step shown inline.
- Follow-up issue (PR says Refs #440): Fable's own allowance (not in statusLine JSON,
  anthropics/claude-code#73770), Copilot model list and sign-in state (no CLI command for
  either), Claude & GPT weekly bucket in readings.

## Done
- ae4e66a launcher: claude ACCOUNT [MODEL] by login, copilot locked + config guard, agy spent-group
  refusal, models with groups, engines. test_launch 271/271.
- d6ba8b1 app + wall: launch_session engine/account/model, spent-account refusal, prefs keys,
  engines_status; newsession.js on toRows; focus kept; no data innerHTML. Windows clippy+tests ok
  (app crate 114, fleet 423); node 527/527; browser case new_session_menu 35/35.
- e7ec82c docs (README Starting sessions, docs/engines.md lock).
- Follow-up issue #478 (Fable allowance, Copilot models + sign-in state, 3p weekly bucket).
- Live (scratch bridge, scratchpad/live_wall.py): real snapshot, readings, launcher; shots taken.

## Next
1. Full browser suite after the narrow-label + harness changes; fold in the reviewer's findings.
2. Live launches: one throwaway per engine (Claude Personal, Claude RIT, agy, Copilot), confirm the
   account, close each; final live shots 1920/390 dark/light closed/open.
3. Push, PR body (Refs #440, #478), shots to fleet-briefing, report to Heph, fleet done.

## Verify
- node --test src/*.test.js; make test-launch; cargo test -p klepsydra-fleet;
  KLEPSYDRA_STAGE=klepsydra-build-ns477 scripts/build-windows.sh --check;
  scripts/test_wall_browser.py (drawer_tables, cast_pick_outlives_its_card also fail on main).
