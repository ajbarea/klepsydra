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
  readings, reconciled per window as gauge.js does, have a live window at 100%
  (`usage::spent_until`, fleet crate); writes
  `new_session_last` to prefs.json on a launch that started. New commands: `engines_status`,
  `new_session_prefs`, `set_new_session_default`.
- Wall: usage from `read_usage` through `toRows` (desktop snapshot has none); menu built only on
  open and on user actions, focus kept by stable key; Escape returns to the caret; no data
  through innerHTML; native radios; Recommended first; install/sign-in step shown inline.
- Follow-up issue (PR says Refs #440): Fable's own allowance (not in statusLine JSON,
  anthropics/claude-code#73770), Copilot model list and sign-in state (no CLI command for
  either), Claude & GPT weekly bucket in readings.

## Done
- ae4e66a launcher; d6ba8b1 app + wall; e7ec82c docs; 3d33f60 review round 1; 55e9029 verify round
  (ready gate through dom.js refresh, spent_until per window, KLEPSYDRA_CLAUDE kept out of a new
  tmux server). Verify pass on 55e9029: clean (3 unreachable nits, listed in the PR).
- Follow-up issue #478. Live: four throwaway launches (Claude Personal, Claude RIT Sonnet, agy
  Gemini Low, Copilot), each on the right account and model, each ended at rest.
- Shots: fleet-briefing/shots/2026-11-19/klepsydra-477-live-*.png, README line added.

## Next
- Heph's fresh Opus review; fix what it finds. Do not merge.
- The running fleet tmux server still holds KLEPSYDRA_CLAUDE (Heph's 11-16 command) in its global
  environment until it restarts (`tmux -L klepsydra set-environment -gu KLEPSYDRA_CLAUDE` clears it).

## Verify
- node --test src/*.test.js 529; make test-launch 278; cargo test -p klepsydra-fleet 435;
  KLEPSYDRA_STAGE=klepsydra-build-ns477 scripts/build-windows.sh --check;
  scripts/test_wall_browser.py: 444 pass; drawer_tables, cast_pick_outlives_its_card and
  reply_buttons fail on main too (reply_buttons raises and stops the run: run the rest by name).
