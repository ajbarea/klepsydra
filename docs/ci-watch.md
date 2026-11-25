# CI watch

<!-- budget: none -->
The full account of `fleet/ci_watch.py`. The README has the short version.

`fleet/ci_watch.py` watches GitHub Actions on every active repo in
`~/.claude/techne.toml`. It polls every 2 minutes, or longer when GitHub's
`x-poll-interval` asks, with conditional requests: an unchanged answer is a
304, which costs no rate limit. A run counts when it is on the repo's default
branch or at the head of an open pull request. The newest completed run per
workflow and branch that succeeded or failed decides (a cancelled, skipped or
neutral run decides nothing): `failure`, `timed_out` or `startup_failure` is
red, and a later green run clears it. The default branch and each open PR's
head are asked for on their own. A red run that pages out of the newest runs
stays red until a newer run of its workflow in the same place decides, its PR
closes, its workflow is deleted, or a month passes.

Each new red run gets one unattended, read-only triage by techne ci-audit's
report mode (`report.sh`, from the installed techne plugin or
`TECHNE_CI_REPORT`): the failing step, its cause and its file:line. The triage
runs on the first account with room, in the fleet's order, then on each other logged-in account
when one is at its usage limit. If any account was at its limit, the triage
waits and is tried again every 10 minutes, for up to a day, and the red is
routed once it has its cause or has waited 30 minutes. If a live fleet
agent works on that PR's branch, the red goes to that agent's inbox
(`inbox/NAME/` in the state folder), and the resume service types it in at the
agent's next idle prompt. Otherwise it goes to Heph as a line in
`ci/alerts.jsonl`, which wakes his pane watcher. A run still red 30 minutes
after routing (`CI_ESCALATE_S`, 1800) wakes Heph once more and gets one line
under "Needs you" in the file `FLEET_QUEUE` names (default
`$FLEET_BRIEFING/needs-you.md`). Dependabot's reds are kept
for the morning instead. Once a day (after `CI_SWEEP_HOUR`) the
latest green run on each default branch is read for warnings. The script's
default is 6; the installed unit sets 99, which turns the sweep off, unless
`CI_SWEEP_HOUR` is set when you run `make install-fleet`. The watcher
pushes, merges and re-runs nothing. No error stops it: a repo that cannot be
read is skipped for the pass and logged, and each triage is saved as soon as it
is done, so a restart triages nothing twice. Its triage folders are removed after
two weeks.

It writes `ci.json` to the app data folder, which the wall and the phone show
as a **CI** button in the bar: hidden without a CI watch and while every
repo is green with nothing to note, `CI ok` when green with Dependabot runs
kept for the morning or repos not read, red with a count when a run is red, and `CI ?` when the watch
has not reported for 15 minutes. It opens a list of the red runs: repo,
workflow, branch or PR, the failing step, the triaged cause with its
file:line, and the run on GitHub: a link on the phone, its address as a
tooltip on the desktop until the app can open links (#149). On the phone the
button is a full 44 px touch target. The app reads the file capped, cuts each text to 300
characters and keeps a link only when it is a GitHub Actions run, so a
local path never reaches the phone.

The watcher logs
one JSON line per decision to `log/ci.log` in the fleet's state folder (rotated
past 1 MiB, four kept). `make install-fleet` installs it as the
`fleet-ci-watch.service` user unit, and `fleet cutover` starts it. Run
`python3 -I fleet/ci_watch.py --once` for one pass by hand.
