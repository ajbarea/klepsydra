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
- ✅ Own review: 2 reader rounds + 2 verify passes (to 9df86e3).
- ✅ Heph independent r1 (reports/fleet-tidy-514-r1.md: B1 + S1-S3 + nits) fixed in ebeb330:
  latest_times bounds each HEPH line by the next date below (+2 d) or the file time, so the
  newest never go; task briefs go only when finished > 7 d, removed briefs shelved to
  archive/briefs/; dry runs write every item to STATE/tidy-preview.md; every guard hand-mutated
  red (51 tests). Live copy: HEPH.md 1507 → 551.
1. 📋 Fresh verify pass on ebeb330 (running); then update the PR body; Heph reviews again.
2. 📋 After techne#394 merges: repin ci.yml's techne ref to its merge SHA, then #514.
- Live dry run 11-20: HEPH.md 1476 → 429 lines; 175 stale briefs; archive entries; 2 queue lines.
- Never `--apply heph` on the live file yourself; the orchestrator runs it after the dry run.
