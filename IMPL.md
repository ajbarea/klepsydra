# IMPL: klepsydra#405 preserve vibrant alert red on 100% capped quota rings

Brief: `https://github.com/ajbarea/klepsydra/issues/405`
PR: `https://github.com/ajbarea/klepsydra/pull/406`

## Slice
Prevent the grayscale CSS filter from desaturating the alert red SVG ring stroke to gray-brown on 100% capped limits.

## Planned Architecture
1. In `src/style.css` and `src/fleet/wall.css`:
   - Replace container-level `.entry[data-capped="true"] { filter: grayscale(0.85); color: var(--text-dim); }`.
   - Scope dimming strictly to `.entry[data-capped="true"] .label` and `.entry[data-capped="true"] .sub`.
   - Leave the SVG ring stroke `#ef4444` fully saturated at 100%.
2. Verify all 501 Node unit tests pass.
3. Verify live Windows binary rendering.

## Done
- Created worktree `.claude/worktrees/gauge-red-ring-405` on `fix/gauge-red-ring-405`.
- Updated `src/style.css` and `src/fleet/wall.css`.
- Verified all 501 tests in `node --test src/*.test.js` pass cleanly.
- Rebuilt Windows binary and deployed to `C:\Users\ajbar\AppData\Local\klepsydra\klepsydra.exe`.
- Committed `97687db` and pushed `fix/gauge-red-ring-405`.
- Opened PR #406 assigned to `ajbarea`.

## Next
- Monitor PR #406 CI.
- Squash-merge to `main`, pull `main`, and prune worktree.
