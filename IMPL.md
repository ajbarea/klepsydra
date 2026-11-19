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
- (nothing committed yet this round)

## Next
1. Launcher + test_launch.sh cases.
2. fleet crate spent_until + tests; launch.rs args + prefs commands + tests.
3. newsession.js rewrite + unit tests on the real reading shape.
4. wall.js/html/css; browser test (shots under shots/<date>/).
5. Live: serve wall with a bridge to the real snapshot, readings and launcher; shots 1920/390
   dark/light; launch one throwaway session per engine and close it.

## Verify
- node --test src/*.test.js; make test-launch; cargo test -p klepsydra-fleet;
  scripts/test_wall_browser.py agy_menu; npm run lint; CI for the app crate.
