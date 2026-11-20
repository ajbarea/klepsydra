# IMPL: klepsydra#511, fleet cleanup enforced in code (PR #514)

Branch feat/fleet-cleanup-511 (worktree .claude/worktrees/cleanup-511). Refs #349 (the roll now
deletes; `fleet done` line moves stay open there). Needs techne#394 (`_shared/cleanup.py`).
Rule (AJ 11-20): finished work lives only in git + GitHub; nothing else keeps a done list.

## Slice
- `fleet/tidy.py` (`fleet tidy [--apply] [PART...]`, dry run by default): heph (head + START HERE
  + 48 h; every date guess errs toward keeping; refuses no START HERE, backwards dates, a write
  in the last 2 min, another holder; dropped lines copied to archive/ for 7 days; keeps the file
  time for recover.sh), briefs, archive (archive/briefs/ per file), queue (Done lines before this
  Monday, under the briefing lock), done, expired (git rm under .git/fleet-sync.lock, restores
  only what it removed). `--report FILE`: prune_shots --apply then a report (error and
  briefing: null fields on failure).
- fleet-cleanup.service/.timer every 6 h; doctor `cleanup` line reads the report.
- brief-tail: evidence by commit permalink; workers delete their own transient files.
- ✅ Reader round 1 (1 Blocking + 3 Should-fix + minors) fixed in 7bde675; Heph's CI red (doctor
  lists every warn; cut-over expects fleet-cleanup.timer) fixed there too. Pushed for relaunch.
- ✅ test_tidy.py 33 pass locally (TECHNE_CLEANUP=<techne worktree cleanup-390>/plugins/techne/_shared/cleanup.py).

## Next
- ✅ Orchestrator rounds r1-r3 and 13 verify passes fixed. r3 changed the spec: HEPH.md keeps its
  last FLEET_HEPH_KEEP lines (600) by position, no clock; the first-seen record is gone
  (f687f3f). Verify round 14 (cut from line 0, undated sections by heading text alone, refusal
  names times + touch) fixed after it. --apply drops only what the saved dry-run list shows.
1. 📋 Fresh verify pass, then Heph's review r4.
2. 📋 After techne#394 merges: repin ci.yml's techne ref to its merge SHA, then #514.
3. 📋 Skill fix (own techne PR): bug-classes.md learned class "test child reaches a live
   default" (env restored after import; a subprocess falls back to the live path).
