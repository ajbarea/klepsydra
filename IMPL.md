# IMPL: Needs you and Agents as two experiences, three layouts (#386, PR #571)

Branch feat/needs-you-rooms-386, worktree .claude/worktrees/agy-386. Fix round after the
11-25 review (PR #571 comment 7177426430): Opus authors. IMPL-agy.md beside this file is a
private spec (gitignored): never commit it or copy its text.

## Slice: the review's Blocking and Should-fix
1. Done writes the file: Rust `needs_done` / `needs_undo` (klepsydra-fleet `needs.rs`): remove
   the item's exact block (nested lines too) by text, atomic replace, re-read before the rename;
   undo reinserts that block only, after its old neighbour line.
2. Blocked rows built from `card()`; Answer jumps with `jump_to_terminal`.
3. Block/finish toast keyed by `session_id`; Enter on it focuses the card; E opens its panel once.
4. Text nodes only in rooms.js / needs.js; both in the queue-render guard.
5. Phone: the needs view hides the wall and the queue.
6. Shared: one parse drives pill, list and subtitle; tally says "blocked"; old drawer, edge tab
   and Ctrl+Alt+B gone (the queue file folds under the wall); keys skip modifiers, repeats,
   dialogs and focused controls; swipe must be horizontal; keyed repaint.
7. Layout pref in prefs.json (`needs_layout`), applied at load.

## Done
- 6444528: all 6 Blocking and the Should-fix list (see commit body). Rust needs.rs 16 tests;
  fleet-rooms.test.js 20; units 604/0; rooms browser test 73/0; build-windows --check exit 0.
- Fail-first on 05bee10: write_needs_file / set_needs_layout unregistered, toast keyed by s.id,
  Answer called request(), rooms.js innerHTML failed the guard.

## Next
- Full wall + phone browser suites green (they now count `#wall > .card`; lanes add heads).
- Shots per layout at 1920/390 from the real file scrubbed (`--needs`), README line.
- Push, PR body, elenchus rounds, CI, merge, fleet install, Windows build, live shot.

## Verify
- `cargo test -p klepsydra-fleet needs`, `node --test src/fleet-rooms.test.js src/guards.test.js`,
  browser test `scripts/test_rooms_browser.py` under the heavy lock, `build-windows.sh --check`.
