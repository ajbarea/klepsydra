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
1. CI on the pushed head (full fleet suite: test_fleet.sh doctor + cut-over cases).
2. Hand mutation of every guard: `TECHNE_CLEANUP=... flock -o /tmp/fleet-heavy.lock timeout 1800
   python3 ~/.local/state/fleet-orchestrator/reports/cleanup-ratchet/tidy-hand-mutation.py fleet
   <scratch dir>` (round-1 run before the fixes: 17/21 killed; the 4 survivors now have tests).
3. Fresh Opus reader round 2, then verify; pin ci.yml's techne ref to #394's merge SHA once merged.
- Live dry run 11-20: HEPH.md 1476 → 429 lines; 175 stale briefs; archive entries; 2 queue lines.
- Never `--apply heph` on the live file yourself; the orchestrator runs it after the dry run.
