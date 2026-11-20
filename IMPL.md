# IMPL: fix(fleet): agy 1.5.12 idle and busy screens (#488)

Branch `fix/agy-footer-488` (worktree `.claude/worktrees/agy-488`).
Push only with explicit refspec: `git push -u origin fix/agy-footer-488:fix/agy-footer-488`. Never push to main.

## Status: Paused for PC Restart
Stopped at a clean commit point on `fix/agy-footer-488`. Working tree is clean. B1, S1, S2, and S3 are committed.

## Done
- Round 1 items (committed & rebased):
  - Added support for agy 1.5.12+ status line footer (`· ctx `).
  - Captured initial real fixtures (`agy-1.5.12-idle.txt`, `agy-1.5.12-busy.txt`, etc.).
  - Added version class guard to `fleet/doctor.sh`.
- Round 2 items (committed):
  - Detected task row ending in `running` as busy; debounced idle detection in `cmd_watch` (3 polls). (Commit `6d1fb49`)
  - Matched braille block U+2800-U+28FF and added `Loading...`. (Commit `4215da2`)
  - Mapped agy folder-trust dialog to `trust` state. (Commit `c3e89eb`)
  - Added dedicated indicators fixtures (`agy-busy-spinner-only.txt`, `agy-busy-phrase-only.txt`, `agy-busy-task-only.txt`). (Commit `d931343`)
  - Wrapped `agy --version` in timeout and parsed CLI version. (Commit `5b9fd73`)
  - Renamed quota screen to `agy-1.5.13-limit.txt` and captured real 1.5.13 busy screen. (Commit `18104f8`)
- Round 3 items (completed & committed):
  - B1 (`5096d87`): Matched braille block by bytes locale-proof with `LC_ALL=C /usr/bin/grep -aqP '\xe2[\xa0-\xa3][\x80-\xbf]|(Generating|Thinking|Running command|Planning|Loading)\.\.\.'`. Added LC_ALL=C test; passes 180/180.
  - S1 (`5080fd5`): Restored main's behavior where unknown footers check `$recent` for auth and limit messages. Added tests for synthetic login (`auth`), quota crash (`limit`), and Copilot with odd footer (`limit`).
  - S2 (`dbc4164`): Anchored task row check to rows below the input box's bottom rule (`below_box`). Tested that an answer ending with `● nginx.service running` reads `idle`, while `agy-1.5.13-bg-running.txt` reads `busy`.
  - S3 (`62bea85`): Added tests for the watcher 3-poll debounce rule (`cmd_watch`), proving single idle between busy polls does not end the turn (kills mutant `idle_count >= 1`) and 3 idle polls end the turn.

## What is Next (Post-Restart Resume)
1. Complete NITS in `fleet/doctor.sh`:
   - A non-zero exit from `agy --version` must warn, not report ok (`elif (( rc != 0 )); then report warn ...`).
   - Make version sed case-insensitive (`[Aa][Gg][Yy]|[Cc][Ll][Ii]`) so "AGY 1.5.13" parses.
   - Take only first line of multi-line banner (`head -1 <<<"$raw_ver"`).
   - Add tests in `fleet/test_delegate.sh` for non-zero exit warning and case-insensitive parsing.
   - Commit: `fix(fleet): doctor warns on non-zero exit and parses case-insensitive version (#488)`.
2. Run test suites:
   - `bash fleet/test_delegate.sh > /tmp/t488.log 2>&1; echo $? > /tmp/t488.exit`
   - `LC_ALL=C bash fleet/test_delegate.sh > /tmp/t488_c.log 2>&1; echo $? > /tmp/t488_c.exit`
   - `uvx --from shellcheck-py shellcheck -x fleet/engines.sh fleet/doctor.sh fleet/delegate.sh fleet/test_delegate.sh`
3. Push branch with explicit refspec:
   - `git push -u origin fix/agy-footer-488:fix/agy-footer-488`
4. Update PR #507 body with Round 3 fixes.
5. Wait for `gh pr checks 507` ("Gauge logic + statusLine hook") to pass.
6. Update `~/.local/state/fleet-orchestrator/reports/agy-488.md` and send to orchestrator pane (`%61`).

## Rerun Commands for Fresh Session
```bash
cd /home/ajbar/ajsoftworks/klepsydra/.claude/worktrees/agy-488
git status
# Finish NITS in fleet/doctor.sh & fleet/test_delegate.sh
bash fleet/test_delegate.sh
LC_ALL=C bash fleet/test_delegate.sh
uvx --from shellcheck-py shellcheck -x fleet/engines.sh fleet/doctor.sh fleet/delegate.sh fleet/test_delegate.sh
git push -u origin fix/agy-footer-488:fix/agy-footer-488
```
