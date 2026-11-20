# IMPL: klepsydra#511, fleet cleanup enforced in code

Branch feat/fleet-cleanup-511 (worktree .claude/worktrees/cleanup-511), from origin/main 7ed5e88.
Rule (AJ 11-20): finished work lives only in git + GitHub; nothing else keeps a growing done list.
Depends on techne#394 (`_shared/cleanup.py`: `transient_status`, `done_sections`, `Config`).

## Slice
- ✅ `fleet/tidy.py` (`fleet tidy [--apply] [PART...]`, dry run by default): heph (head + START HERE
  + 48 h of log; refuses an undated log, no START HERE, a future date, a write in the last 2 min,
  another process holding it; keeps HEPH.md's time for recover.sh's heph_asks), briefs (agents in
  no panes/paused row, not finished or unpaused in 7 days, file older than 7 days), archive (7 days,
  newest time inside), queue (Done lines before this Monday), done, expired (git rm under
  `.git/fleet-sync.lock`, as prune_shots does). `--report FILE` runs prune_shots --apply, then
  writes what is left.
- ✅ `fleet-cleanup.service/.timer` (every 6 h, Persistent, RandomizedDelaySec, Nice 19, idle I/O);
  cutover.sh enables it; install links tidy.py.
- ✅ doctor `cleanup` check reads the report (no 9P walk every 5 min), names the fleet command.
- ✅ brief-tail: PR evidence by commit permalink; workers delete their own transient files.
- ✅ Tests: fleet/test_tidy.py (20 cases), doctor cases in test_fleet.sh (#511 lines).
- 📋 Next: hand mutation pass result, doctor-section run, PR (Closes #511, #349), elenchus.
- 📋 After techne#394 merges: pin ci.yml's techne checkout to its merge SHA.
- Live dry run 11-20: HEPH.md 1467 -> 265 lines; 175 stale briefs; 30 archive entries; 2 queue lines.

## Verify
- `TECHNE_CLEANUP=<techne>/plugins/techne/_shared/cleanup.py python3 -I fleet/test_tidy.py`
- doctor section: lines 1-91 + the doctor section of fleet/test_fleet.sh, under the heavy lock.
- `fleet tidy` (dry run) on the live state; never `--apply heph` on the live file (Heph runs it).
