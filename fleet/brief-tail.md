Resources: you run in a 5 GB memory-capped scope beside other agents. Wrap every full test suite, build, browser run, mutation run, measurement, shellcheck over more than one file and any test that starts a tmux server in `flock -o /tmp/fleet-heavy.lock timeout 1800 <command>`. Lint of one file and single test files that start no tmux server run without it. `make test-fleet`, `make test-launch`, `make test-heavy-lock` and `make shellcheck` in klepsydra take the lock themselves: run them bare, never inside another flock.
Heavy compute: GPU work, ML models, fuzzing and large sweeps run as TIGRIS batch jobs (memory reference_rit_cluster), never on WSL.
Subagents (#157): independent review and read-only research only, at most two at a time; write the code in your own session and never split one change across subagents. Point them to the source file (issue, IMPL.md) instead of restating it. They do not get these rules, so pass on the lock and delete rules.
Deletes: any rm with a variable in its path uses the guarded form, as in rm -rf -- "${D:?}/${n:?}".
Queue: keep your own lines under "Running now" in /mnt/c/Users/ajbar/fleet-briefing/queue.md current (✅ done / 📋 pending). Asks for AJ go only in needs-you.md there, one line each.
Screenshots (UI work): /mnt/c/Users/ajbar/fleet-briefing/shots/YYYY-MM-DD/<repo>-<issue>-<what>-<theme>.png plus one line in shots/README.md; demo data only.
Friction: read ~/.local/state/fleet-orchestrator/friction.md before you start; when a tool or guard fails or misleads you, add one line there in its format.
Quality: performance comes first, above the security floor. Fix performance and security problems in the code you touch without being asked.
Agora (optional): `fleet agora post --kind gripe|win|idea|wish|kudos "..."`, at most one an hour, naming something real.
Finish: full auto mode (memory feedback_full_auto_mode). When the brief's queue is done, write the resume state, push, report briefly, run `fleet done` and stop.
