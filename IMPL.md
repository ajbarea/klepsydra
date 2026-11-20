# IMPL: CI best practice, klepsydra (#494, PR #502)

Branch ci/best-practice, worktree .claude/worktrees/ci-best. Push only
`git push origin HEAD:refs/heads/ci/best-practice`. Do not merge: Heph reviews and merges.
Fleet worker close-menu; the techne half is techne#386 (its own IMPL.md on techne ci/best-practice).

## Done
- ci.yml: `make test-fleet` runs in its own `Fleet engine tests` job beside `Hooks, lints and the other
  suites` (timeout 30); a gate job keeps the required name `Gauge logic + statusLine hook`, `needs` both,
  `if: always()` (GitHub counts a skipped required job as success, so !cancelled() let a cancelled run pass).
- ci_watch.get closes the HTTPError it handles: 0 ResourceWarnings on 3.14 -X dev (main: 1); 66 tests pass.
- zizmor 1.32.0: no findings.
- 9e59a38: skill-context's fleet-job line names the suite, not `make test-fleet`, so the #291 review 3
  doc-count check (fleet/test_fleet.sh ~1048, wants `0 1 2 3`) holds; counts re-run locally: 0 1 2 3.

## Next
1. 📋 CI on 9e59a38 (PR #502) green: all four jobs; check the fleet job's wall time vs 38 min serial.
2. 📋 Report to Heph (`fleet send "$(cat ~/.local/state/fleet-orchestrator/orchestrator.pane)" -`), queue line.
3. Follow-up, not this PR: #495 shard the fleet suite; #503 shellcheck memory on test_fleet.sh.
