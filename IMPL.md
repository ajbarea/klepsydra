# IMPL: Needs you and Agents as two experiences, three layouts (#386, PR #571)

Branch feat/needs-you-rooms-386, worktree .claude/worktrees/agy-386. Opus authors the fix
rounds (free-engine rounds used up). IMPL-agy.md beside this file is a private spec
(gitignored): never commit it or copy its text.

## Slice: review to clean, then merge
Round-1 review (PR comment 7177426430): all six Blocking fixed through the real wiring
(verified by an independent reader on f9bfec7). Review round 2 (reader + /code-review medium)
found Should-fix items, now fixed:
- Done takes the item's start line; Rust removes only that whole item (twins, a longer item's
  first line, lone CR); Done and Undo return the written file, shown at once (quick E then U).
- Blocked means needs_you everywhere; error cards get an Errors lane.
- Due-date patterns tightened; rows rebuild on a new day; links that would not open copy.
- File permissions kept on replace; shot scrubber holds marks in plane 15.
- Wall suite back to green (queue fold spacing, bar-right at the bar's foot), phone wall with
  no lanes, queue-file browser tests ported, problem line outside the fold, dead CSS gone.

Round 3 (fresh Opus reader) found 3 Should-fix, fixed in 901d029: Rust no longer models where
an item ends (JS sends `seen`, the file it rendered; Done edits only while the file is still
that text), Undo of the first twin, an empty item no longer throws (room shows a problem line);
minors: two-digit dates, COM before ShellExecuteW, temp file mode at create, 7-hash scrub;
plus a lone-CR seam that swallowed a blank line.

## Next
- Review round 4: fresh Opus reader on origin/main...HEAD + round 3 findings (running 11-26).
- Retake shots per layout at 1920/390 on the final head (`test_rooms_browser.py --shots DIR
  --needs <file>` scrubs it) into fleet-briefing shots/2026-11-25, README line exists.
- PR body rewrite (live vs tested), push, CI (flakes #471, #573: rerun once), merge,
  fleet install, Windows build, one live 1920 shot.

## Verify
- `cargo test -p klepsydra-fleet needs::`, `node --test src/*.test.js`,
  `python3 -I scripts/test_needs_scrub.py`, browser suites under the heavy lock:
  rooms, wall (main 490/0), phone (5 failures also on main: #490, gauge text).
