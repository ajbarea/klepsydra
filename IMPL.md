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
- (fill as steps land)

## Next
- Rust module + tests, then JS model + tests, then the DOM, then browser test and shots.

## Verify
- `cargo test -p klepsydra-fleet needs`, `node --test src/fleet-rooms.test.js src/guards.test.js`,
  browser test `scripts/test_rooms_browser.py` under the heavy lock, `build-windows.sh --check`.
