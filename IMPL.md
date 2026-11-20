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
- ✅ Hand mutation: 31 guards killed (6bbdb50). ✅ Reader round 2: 4 Should-fix fixed in 158d43e
  (brief --refresh keeps the file time; unreadable or locked registry refuses; a newer later
  START HERE refuses; STANDING/PERMANENT/binding lines stay); 6 new guards hand-mutated, all red.
  Minors left for the PR body: no registry lock in done.sh race (now locked), queue date takes
  the first MM-DD, done/expired dry run prints counts, BriefingLock duplicates prune_shots's.
1. ✅ Verify passes: 9df86e3 fixed the case-sensitive standing match; final verify clean.
   📋 CI green on the head, then Heph reviews and merges (deferred minors are in the PR body).
2. 📋 Pin ci.yml's techne ref to #394's merge SHA once merged.
- Live dry run 11-20: HEPH.md 1476 → 429 lines; 175 stale briefs; archive entries; 2 queue lines.
- Never `--apply heph` on the live file yourself; the orchestrator runs it after the dry run.
