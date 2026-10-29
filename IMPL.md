# IMPL: feat/ci-watch (klepsydra#162), 2026-10-28 23:2x

AJ's order (10-28): #159 (done, deployed da83e7b) -> techne#227 -> #162 -> rest of
task-fleet-module.src (PR #161 draft with review findings in its IMPL.md; WIP
feat/two-accounts).

## Done on this branch
- fleet/ci_watch.py: polls active sisters every 2 min with ETags (304s free,
  x-poll-interval honoured); counts the newest completed run per workflow+branch
  on the default branch or an open PR head; red = failure/timed_out/startup_failure;
  new red (not Dependabot) -> failing step, one ci-audit report-mode triage
  (techne#227's report.sh), one "Needs you" line (idempotent marker); Dependabot reds
  kept for the morning; daily green sweep; ci.json in the app data dir; JSON-lines
  log at <state>/log/ci.log (rotating). Live --once pass: 14 repos, 0 red, 2 Dependabot.
- fleet/test_ci_watch.py: 8 cases (fake GitHub + a local 304 server); CI step.

## Next (part 2, same issue)
1. Wall + phone: fleet crate reads <data>/ci.json each poll and adds `ci` to the
   snapshot (phone.rs Feed parts like `usage`); wall summary bar CI badge (red count,
   popover: repo, workflow, branch, failing step, cause, file:line, link); phone same.
   Browser tests + shots (demo data).
2. Phone push for a new red: research first. Web Push to the phone wall PWA over
   Tailscale Serve (iOS 16.4+ home-screen PWAs; VAPID; payload encrypted end to end)
   vs anything that sends repo names to a third party (private repos: avoid).
3. Install as a user unit with the fleet engine (#161 install.sh) once that merges.
4. Opus review of this branch before merge.
