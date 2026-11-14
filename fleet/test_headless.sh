#!/usr/bin/env bash
# Tests for `fleet headless` (#260) and the subscription-only rule for
# interactive launches, against stub claude, ant and systemd-run binaries and a
# scratch git repo. Starts no tmux server, so it runs without the heavy lock.
# Run: bash fleet/test_headless.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
cleanup() { rm -rf -- "${work:?}"; }
trap cleanup EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

pass=0 fail=0
check() { # NAME GOT WANT
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$3" "$2"; fi
}
has() { grep -q -- "$2" <<<"$1" && echo yes || echo no; } # TEXT PATTERN

mkdir -p "$work/bin" "$work/state" "$work/rec" "$work/home" "$work/api" "$work/sub"
# A headless job may run this suite: its own job's variables stay out.
unset CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_PROFILE KLEPSYDRA_HEADLESS KLEPSYDRA_AGENT
export HOME="$work/home" FLEET_STATE="$work/state" FLEET_SOCK="hl-test-$$" FLEET_SCOPE=0
export FLEET_ANT="$work/bin/ant" FLEET_CLAUDE="$work/bin/claude" FLEET_HEADLESS_CONFIG="$work/api"
export FLEET_DEFAULT_CONFIG="$work/sub" FLEET_ACCOUNTS="$work/sub" REC="$work/rec"
printf '{"apiKeyHelper": "ant --profile ldqis auth print-credentials --access-token"}\n' >"$work/api/settings.json"
printf '{"env": {"OTEL_METRICS_EXPORTER": "otlp", "CLAUDE_CODE_ENABLE_TELEMETRY": "1", "UNRELATED": "x"}}\n' >"$work/sub/settings.json"

# ant: logged in unless $REC/ant-out says otherwise. Its status also prints a
# token-like string, which must never reach the runner's output.
cat >"$work/bin/ant" <<'EOF'
#!/usr/bin/env bash
if [[ -f $REC/ant-out ]]; then echo '  (profile "ldqis" not configured — run `ant auth login` to set it up)'; exit 0; fi
printf 'Credentials\n  Logged in to LDQIS as someone@example.org\n  (active) * Profile (user_oauth) sk-ant-oat01-SECRETSECRET\n'
EOF
# claude: records how it was started (each start's argv also appended to
# $REC/calls, one line); $REC/mode says how it ends.
cat >"$work/bin/claude" <<'EOF'
#!/usr/bin/env bash
[[ $1 == --version ]] && { echo "${STUB_VERSION:-2.1.316} (Claude Code)"; exit 0; }
printf '%s\n' "$@" >"$REC/argv"
echo "$*" >>"$REC/calls"
env | sort >"$REC/env"
pwd >"$REC/cwd"
cat >"$REC/stdin"
resumed=no; [[ " $* " == *" --resume "* ]] && resumed=yes
res() { # SUBTYPE COST TEXT
  jq -nc --arg st "$1" --argjson c "$2" --arg t "$3" '{type: "result", subtype: $st, is_error: false, total_cost_usd: $c, duration_ms: 1000, num_turns: 2, session_id: "sess-1", result: $t}'
}
case $(cat "$REC/mode" 2>/dev/null || echo ok) in
  ok) printf '%s\n' '{"type":"system","subtype":"init"}' 'not json' \
        '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.4213,"duration_ms":5000,"num_turns":3,"session_id":"sess-1","result":"FINAL REPORT: done."}' ;;
  # Ends its first turn on a background wait, as cards-247 did on 11-13; a
  # resume finishes. The session's cost accumulates across runs.
  early) if [[ $resumed == no ]]; then res success 1.25 $'Started the browser suite in the background.\nI\'ll continue once it finishes.'
         else res success 1.5 $'FINAL REPORT: suite green, PR opened.'; fi ;;
  # Marked, but its last lines say it waits on a background run.
  waits) if [[ $resumed == no ]]; then res success 0.5 $'FINAL REPORT: so far so good.\nI\'m still waiting for the tests in the background.'
         else res success 0.6 'FINAL REPORT: all done.'; fi ;;
  # Says it waits every time: resumed once, then taken as final.
  waits2) res success 0.5 $'FINAL REPORT: so far.\nI\'ll continue once the suite finishes.' ;;
  # The text in $REC/text, marked or not.
  text) res success 0.3 "$(cat "$REC/text")" ;;
  # Spends, then its resume crashes with a zeroed cost.
  crashlate) if [[ $resumed == no ]]; then res success 6 'Working.'
             else jq -nc '{type: "result", subtype: "error_during_execution", is_error: true, total_cost_usd: 0, session_id: "sess-1"}'; exit 1; fi ;;
  # Spends, then its resume dies with no result at all.
  dielate) if [[ $resumed == no ]]; then res success 1 'Working.'; else exit 3; fi ;;
  # A result with no cost.
  nocost) jq -nc '{type: "result", subtype: "success", session_id: "sess-1", result: "Working."}' ;;
  # Slow and never reports: the job's deadline ends it.
  slownever) sleep 2; res success 0.1 'Working.' ;;
  # Never reports: each run adds 0.5 to the session's spend.
  never) n=$(wc -l <"$REC/calls"); res success "$(awk -v n="$n" 'BEGIN { print n * 0.5 }')" 'Still working on it.' ;;
  # Leaves a child that holds a file open, then reports.
  leaver) nohup sleep 300 >/dev/null 2>&1 & echo $! >"$REC/leftover"
          res success 0.1 'FINAL REPORT: done, left a sleep.' ;;
  # Leaves a child in a session of its own, as Claude Code runs each Bash
  # command: the job's variables find it.
  escaper) setsid -f bash -c 'echo $$ >"$REC/leftover"; exec sleep 300' >/dev/null 2>&1
           for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s $REC/leftover ]] && break; sleep 0.1; done
           res success 0.1 'FINAL REPORT: done, left an escaped sleep.' ;;
  # Leaves a child with no environment in claude's session: the session finds it.
  envclear) env -i nohup sleep 300 >/dev/null 2>&1 & echo $! >"$REC/leftover"
            res success 0.1 'FINAL REPORT: done, left a bare sleep.' ;;
  # Both: only the job's scope finds it.
  ghost) setsid -f env -i bash -c 'echo $$ >"$1"; exec sleep 300' _ "$REC/leftover" >/dev/null 2>&1
         for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s $REC/leftover ]] && break; sleep 0.1; done
         res success 0.1 'FINAL REPORT: done, left a ghost.' ;;
  budget) printf '%s\n' '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":2.51,"duration_ms":9000,"num_turns":9}'; exit 1 ;;
  crash) echo boom >&2; exit 3 ;;
  slow) sleep 2; printf '%s\n' '{"type":"result","subtype":"success","total_cost_usd":0.01,"duration_ms":2000}' ;;
esac
EOF
# systemd-run: records its options, then runs the command after them.
cat >"$work/bin/sdrun" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$REC/sdrun"
while (( $# )) && [[ $1 != bash ]]; do shift; done
exec "$@"
EOF
chmod +x "$work/bin/"*

repo=$work/repo
git init -q -b main "$repo" && git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf 'Do the thing.\nSecond line.\n' >"$work/brief.md"
hl() { bash "$here/headless.sh" "$@"; }

echo "headless: refusals"
check "a bad budget word is refused" "$(hl j "$work/brief.md" --repo "$repo" --budget abc 2>&1 >/dev/null | head -c 20)" "error: --budget take"
for b in 0 0.00 -1 50.01 1e3 010 ''; do
  hl "b$RANDOM" "$work/brief.md" --repo "$repo" --budget "$b" >/dev/null 2>&1
  check "budget '$b' is refused" "$?" "2"
done
check "a ceiling that is no amount refuses every job" "$(FLEET_HEADLESS_MAX_USD=abc hl m1 "$work/brief.md" --repo "$repo" --budget 999999.99 >/dev/null 2>&1; echo $?)" "2"
check "no job was claimed by a refused budget" "$(find "$work/state" -name job.json | wc -l)" "0"
check "a bad name is refused" "$(hl '../x' "$work/brief.md" --repo "$repo" >/dev/null 2>&1; echo $?)" "2"
check "an empty brief is refused" "$(: >"$work/empty"; hl e1 "$work/empty" --repo "$repo" >/dev/null 2>&1; echo $?)" "2"
check "a folder outside git is refused" "$(hl g1 "$work/brief.md" --repo "$work/home" >/dev/null 2>&1; echo $?)" "2"
touch "$work/rec/ant-out"
out=$(hl nologin "$work/brief.md" --repo "$repo" --wait 2>&1); rc=$?
check "no ant login: refused" "$rc" "2"
check "no ant login: says the one command" "$(has "$out" 'run: ant --profile ldqis auth login')" "yes"
check "no ant login: no worktree, no job" "$(git -C "$repo" worktree list | wc -l) $([[ -e $work/state/headless/nologin ]] && echo job || echo none)" "1 none"
rm -f "$work/rec/ant-out"
mv "$work/api/settings.json" "$work/api/s.bak"
check "no apiKeyHelper: refused" "$(hl nohelper "$work/brief.md" --repo "$repo" >/dev/null 2>&1; echo $?)" "2"
mv "$work/api/s.bak" "$work/api/settings.json"

echo "headless: a job (--wait)"
rm -rf -- "${work:?}/state/headless"
# The main checkout sits on another branch: the job still starts from main.
git -C "$repo" checkout -q -b elsewhere && git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m elsewhere
out=$(ANTHROPIC_BASE_URL=https://elsewhere.example ANTHROPIC_API_KEY=sk-bad ANTHROPIC_AUTH_TOKEN=tok ANTHROPIC_PROFILE=p CLAUDE_CODE_OAUTH_TOKEN=o CLAUDE_CODE_SESSION_ID=parent \
  hl job1 "$work/brief.md" --repo "$repo" --wait 2>&1); rc=$?
check "the job exits as claude did" "$rc" "0"
check "it ran in a fresh worktree on its own branch" "$(cat "$work/rec/cwd") $(git -C "$repo" rev-parse --abbrev-ref headless-job1)" "$repo/.claude/worktrees/headless-job1 headless-job1"
argv=$(tr '\n' ' ' <"$work/rec/argv")
check "claude -p with the default budget and model, Monitor and wakeups off" "$argv" "-p --model claude-opus-5-5 --max-budget-usd 10 --permission-mode bypassPermissions --permission-prompts none --disallowedTools Monitor,ScheduleWakeup,CronCreate --output-format stream-json --verbose "
check "it starts from main, not the checkout's branch" "$(git -C "$repo" rev-parse headless-job1)" "$(git -C "$repo" rev-parse main)"
check "the prompt is the headless rules, then the brief" "$(head -n "$(wc -l <"$here/headless-rules.md")" "$work/rec/stdin" | cmp -s - "$here/headless-rules.md" && echo rules) $(tail -n 2 "$work/rec/stdin" | tr '\n' '|')" "rules Do the thing.|Second line.|"
# shellcheck disable=SC2016 # backticks are the text sought
check "the rules carry the marker, the foreground rule and the per-command lock" "$(grep -c 'starts with `FINAL REPORT:`' "$here/headless-rules.md") $(grep -c 'Never start a background job' "$here/headless-rules.md") $(grep -c 'flock -o -E 75 -w 420 /tmp/fleet-heavy.lock timeout 480 <one command>' "$here/headless-rules.md")" "1 1 1"
env=$(cat "$work/rec/env")
check "no key, token or profile reaches the child" "$(grep -cE '^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_PROFILE|CLAUDE_CODE_OAUTH_TOKEN|CLAUDE_CODE_SESSION_ID|ANTHROPIC_BASE_URL)=' <<<"$env")" "0"
check "it runs on the credit's config folder" "$(grep '^CLAUDE_CONFIG_DIR=' <<<"$env")" "CLAUDE_CONFIG_DIR=$work/api"
check "the default folder's telemetry, and only that, is passed on" "$(grep -cE '^(OTEL_METRICS_EXPORTER=otlp|CLAUDE_CODE_ENABLE_TELEMETRY=1)$' <<<"$env") $(grep -c '^UNRELATED=' <<<"$env")" "2 0"
check "the subagent cap is set" "$(grep -c '^CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=2$' <<<"$env")" "1"
check "no background tasks or sessions, and a 16-minute tool timeout" "$(grep -cE '^(CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1|CLAUDE_CODE_DISABLE_AGENT_VIEW=1|BASH_DEFAULT_TIMEOUT_MS=960000|BASH_MAX_TIMEOUT_MS=960000)$' <<<"$env")" "4"
check "no token reaches the output" "$(has "$out" SECRET)" "no"
job=$work/state/headless/job1/job.json
check "the record: finished, cost, exit, result, no resume" "$(jq -r '[.state, .total_cost_usd, .exit, .result, .resumes] | join(" ")' "$job")" "finished 0.4213 0 success 0"
check "a job that reports at once runs claude once" "$(wc -l <"$work/rec/calls")" "1"
check "the ledger has one line" "$(jq -r '[.name, .model, .total_cost_usd, .exit] | join(" ")' "$work/state/headless/ledger.jsonl")" "job1 claude-opus-5-5 0.4213 0"
check "the fleet log has the end line" "$(jq -r 'select(.message == "headless job ended") | [.name, .model, .cost_usd, .exit] | join(" ")' "$work/state/log/fleet.log")" "job1 claude-opus-5-5 0.4213 0"
check "a finished runner keeps its claim on the start" "$(grep -cE '^[0-9]+$' "$work/state/headless/job1/pid")" "1"
check "--run will not rerun a finished job" "$(hl --run job1 >/dev/null 2>&1; echo $?) $(wc -l <"$work/state/headless/ledger.jsonl")" "2 1"
check "--run takes no path" "$(hl --run ../../x >/dev/null 2>&1; echo $?)" "2"
check "the name is used once" "$(hl job1 "$work/brief.md" --repo "$repo" >/dev/null 2>&1; echo $?)" "2"

echo "headless: budget, failure, scope"
echo budget >"$work/rec/mode"
hl job2 "$work/brief.md" --repo "$repo" --budget 2.5 --model claude-sonnet-5-5 --wait >/dev/null 2>&1; rc=$?
check "the budget reaches claude" "$(grep -A1 -- --max-budget-usd "$work/rec/argv" | tail -1) $(grep -A1 -- --model "$work/rec/argv" | tail -1)" "2.5 claude-sonnet-5-5"
check "a job stopped at its budget says so" "$rc $(jq -r '[.result, .total_cost_usd] | join(" ")' "$work/state/headless/job2/job.json")" "1 error_max_budget_usd 2.51"
echo crash >"$work/rec/mode"
hl job3 "$work/brief.md" --repo "$repo" --wait >/dev/null 2>&1
check "a crash without a result is recorded" "$(jq -r '[.exit, .result, .total_cost_usd] | join(" ")' "$work/state/headless/job3/job.json")" "3 no result "
echo ok >"$work/rec/mode"
FLEET_SCOPE=1 FLEET_SYSTEMD_RUN="$work/bin/sdrun" FLEET_TASKS_MAX=99 hl job4 "$work/brief.md" --repo "$repo" --wait >/dev/null 2>&1
sd=$(tr '\n' ' ' <"$work/rec/sdrun")
check "the job runs in a capped scope in the workers' slice" "$(has "$sd" '--slice=fleet-workers.slice')$(has "$sd" 'MemoryMax=5G')$(has "$sd" 'TasksMax=99')$(has "$sd" 'OOMPolicy=continue')" "yesyesyesyes"

out=$(FLEET_SCOPE=1 FLEET_SYSTEMD_RUN=false FLEET_HEADLESS_START_WAIT=1 hl job6 "$work/brief.md" --repo "$repo" 2>&1); rc=$?
check "a runner that cannot start is an error, not 'started'" "$rc $(has "$out" 'did not start') $(has "$out" started\ job6)" "1 yes no"
check "and its job reads failed" "$(jq -r '[.state, .result] | join(" ")' "$work/state/headless/job6/job.json")" "failed runner did not start"
rm -rf -- "${work:?}/state/headless/job6"

echo "headless: in the background, and --status"
echo slow >"$work/rec/mode"
out=$(hl job5 "$work/brief.md" --repo "$repo" 2>&1)
check "it returns once started" "$(has "$out" 'started job5')" "yes"
st=$(bash "$here/headless.sh" --status)
check "status lists it running" "$(grep -c '^  job5 .*running' <<<"$st")" "1"
for _ in $(seq 50); do [[ $(jq -r .state "$work/state/headless/job5/job.json") == finished ]] && break; sleep 0.2; done
st=$(bash "$here/headless.sh" --status)
check "then finished, with its cost" "$(grep -cF "job5  claude-opus-5-5  \$0.01 of \$10" <<<"$st")" "1"
check "status sums the spend" "$(grep '^Total' <<<"$st")" "Total: \$3.3626 over 6 jobs"
echo '{"name":"ghost","model":"m","budget_usd":1,"state":"running","started_epoch":1}' >"$work/state/headless/job3/job.json"
check "a runner gone without a record reads DIED" "$(bash "$here/headless.sh" --status | grep -c 'ghost .*DIED')" "1"

mkdir -p "$work/state/headless/job8"
jq -n --arg wt "$repo" '{name: "job8", model: "m", budget_usd: 1, worktree: $wt, state: "running", started_epoch: 1}' >"$work/state/headless/job8/job.json"
: >"$work/state/headless/job8/brief.md"; echo gave-up >"$work/state/headless/job8/pid"; rm -f -- "$work/rec/argv"
check "a runner that finds the start claimed leaves the job alone" "$(hl --run job8 >/dev/null 2>&1; echo $?) $([[ -e $work/rec/argv ]] && echo ran || echo never)" "1 never"

echo "headless: the report, the resume loop and the reaper (#260, 11-13)"
echo ok >"$work/rec/mode"
runj() { # NAME [ARGS...]: a --wait job; prints its exit
  local n=$1; shift
  rm -f -- "$work/rec/calls"
  hl "$n" "$work/brief.md" --repo "$repo" --wait "$@" >/dev/null 2>&1; echo $?
}
rec() { jq -r "$2" "$work/state/headless/$1/job.json"; } # NAME FILTER
echo early >"$work/rec/mode"
check "a run that ends its turn without the report is resumed and finishes" "$(runj r1)" "0"
check "claude ran twice, the second time resuming its session" "$(wc -l <"$work/rec/calls") $(sed -n 2p "$work/rec/calls" | grep -c -- '--resume sess-1')" "2 1"
check "the resume gets what is left of the budget" "$(sed -n 2p "$work/rec/calls" | grep -o -- '--max-budget-usd [0-9.]*')" "--max-budget-usd 8.75"
# shellcheck disable=SC2016 # backticks are the text sought
check "and is told to continue in the foreground to the report" "$(grep -c 'continue the job to the end now, in the foreground only' "$work/rec/stdin") $(grep -c 'starts with `FINAL REPORT:`' "$work/rec/stdin")" "1 1"
check "its record: success after one resume, the session's whole cost" "$(rec r1 '[.result, .resumes, .total_cost_usd] | join(" ")')" "success 1 1.5"
check "the fleet log has the resume" "$(jq -r 'select(.message | startswith("headless job resumed")) | [.name, .resume] | join(" ")' "$work/state/log/fleet.log")" "r1 1/4"
echo waits >"$work/rec/mode"
check "a report whose last lines say it waits is resumed" "$(runj r2) $(wc -l <"$work/rec/calls") $(rec r2 '[.result, .resumes] | join(" ")')" "0 2 success 1"
echo waits2 >"$work/rec/mode"
check "a report that keeps saying it waits is resumed once, then taken" "$(runj r2b) $(wc -l <"$work/rec/calls") $(rec r2b '[.result, .resumes] | join(" ")')" "0 2 success 1"
echo text >"$work/rec/mode"
i=0
while IFS= read -r t; do
  i=$((i + 1)); printf '%b' "$t" >"$work/rec/text"
  check "final as written: $(head -n 1 <<<"${t//\\n/ / }" | cut -c1-50)" "$(runj "r3-$i") $(wc -l <"$work/rec/calls")" "0 1"
done <<'EOF'
FINAL REPORT: PR #9 opened.\nIt is waiting on review from the team.
FINAL REPORT: PR #12 opened. Merge it once the review is done.
FINAL REPORT: done.\nCI checks are still running in the background on GitHub.
FINAL REPORT: PR opened, waiting for the checks on GitHub.
**FINAL REPORT:** all green.
## Final report: all green.
EOF
echo never >"$work/rec/mode"
check "a job that never reports is resumed N times, then stalls" "$(FLEET_HEADLESS_RESUMES=2 runj r4) $(wc -l <"$work/rec/calls") $(rec r4 '[.result, .resumes, .exit] | join(" ")')" "1 3 stalled 2 0"
check "the ledger and the fleet log say stalled" "$(jq -r 'select(.name == "r4") | [.result, .resumes] | join(" ")' "$work/state/headless/ledger.jsonl") $(jq -r 'select(.message == "headless job ended" and .name == "r4") | [.level, .result] | join(" ")' "$work/state/log/fleet.log")" "stalled 2 WARN stalled"
check "--status says it stalled" "$(bash "$here/headless.sh" --status | grep -c 'r4 .*stalled after 2 resumes: STALLED, no FINAL REPORT')" "1"
check "the budget ends the resumes first" "$(runj r5 --budget 1) $(wc -l <"$work/rec/calls") $(rec r5 '[.result, .resumes, .total_cost_usd] | join(" ")')" "1 2 stalled 1 1"
check "FLEET_HEADLESS_RESUMES=0 never resumes" "$(FLEET_HEADLESS_RESUMES=0 runj r6) $(wc -l <"$work/rec/calls")" "1 1"
check "FLEET_HEADLESS_RESUMES=08 is eight, not unlimited" "$(FLEET_HEADLESS_RESUMES=08 runj r6b) $(wc -l <"$work/rec/calls")" "1 9"
check "a claude older than 2.1.277 is not resumed" "$(STUB_VERSION=2.1.200 runj r6c) $(wc -l <"$work/rec/calls") $(rec r6c '[.result, .resumes] | join(" ")')" "1 1 stalled 0"
echo nocost >"$work/rec/mode"
check "a run with no cost is not resumed" "$(runj r6d) $(wc -l <"$work/rec/calls") $(rec r6d .result)" "1 1 stalled"
echo crashlate >"$work/rec/mode"
check "a resume's crash with a zeroed cost keeps the session's spend" "$(runj r6e) $(rec r6e '[.result, .total_cost_usd] | join(" ")')" "1 error_during_execution 6"
echo dielate >"$work/rec/mode"
check "a resume that dies without a result marks the cost partial" "$(runj r6f) $(rec r6f '[.result, .total_cost_usd, .cost_partial] | join(" ")')" "3 no result 1 true"
# shellcheck disable=SC2016 # dollars, not variables
check "--status shows a partial cost with +" "$(bash "$here/headless.sh" --status | grep -cF '$1+ of $10')" "1"
echo slownever >"$work/rec/mode"
check "the job's deadline holds across resumes" "$(FLEET_HEADLESS_TIMEOUT=3 runj r6g) $(rec r6g '[.result, .resumes] | join(" ")')" "124 timeout 1"
echo ok >"$work/rec/mode"
KLEPSYDRA_HEADLESS=1 KLEPSYDRA_AGENT=r7e sleep 300 & before=$!
check "a process older than the job, though it carries its variables, is left alone" "$(runj r7e) $(kill -0 "$before" 2>/dev/null && echo alive || echo gone)" "0 alive"
kill "$before" 2>/dev/null; wait "$before" 2>/dev/null
gone() { kill -0 "$(cat "$work/rec/leftover" 2>/dev/null || echo 0)" 2>/dev/null && echo alive || echo gone; }
echo leaver >"$work/rec/mode"; rm -f -- "$work/rec/leftover"
# A process of the caller's own, beside the job: never the reaper's.
sleep 300 & mine=$!
check "a job's leftover child is stopped when it ends" "$(runj r7) $(gone) $(rec r7 .reaped)" "0 gone 1"
echo escaper >"$work/rec/mode"; rm -f -- "$work/rec/leftover"
check "with no scope, a leftover in a session of its own is stopped (the job's variables)" "$(runj r7c) $(gone)" "0 gone"
echo envclear >"$work/rec/mode"; rm -f -- "$work/rec/leftover"
check "with no scope, a leftover with no environment is stopped (claude's session)" "$(runj r7d) $(gone)" "0 gone"
echo leaver >"$work/rec/mode"
check "a runner with no scope of its own leaves its caller's processes alone" "$(kill -0 "$mine" 2>/dev/null && echo alive || echo gone)" "alive"
rm -f -- "$work/rec/leftover"
# A systemd-run that makes no scope: the runner shares its caller's cgroup,
# which the job's unit name does not match.
check "a runner outside the scope it was given leaves its caller's cgroup alone" "$(FLEET_SCOPE=1 FLEET_SYSTEMD_RUN="$work/bin/sdrun" runj r7b) $(gone) $(kill -0 "$mine" 2>/dev/null && echo alive || echo gone)" "0 gone alive"
kill "$mine" 2>/dev/null; wait "$mine" 2>/dev/null
echo slow >"$work/rec/mode"
hl r8 "$work/brief.md" --repo "$repo" >/dev/null 2>&1
for _ in $(seq 25); do [[ $(cat "$work/state/headless/r8/pid" 2>/dev/null) =~ ^[0-9]+$ ]] && break; sleep 0.2; done
sleep 0.5; kill -TERM "$(cat "$work/state/headless/r8/pid")"
for _ in $(seq 50); do [[ $(rec r8 .state) == finished ]] && break; sleep 0.2; done
check "a stopped runner still writes its record" "$(rec r8 '[.state, .result] | join(" ")')" "finished stopped"
if systemd-run --user --scope --quiet true 2>/dev/null; then
  echo ghost >"$work/rec/mode"; rm -f -- "$work/rec/leftover"
  check "in its scope, a leftover with neither session nor variables is stopped" "$(FLEET_SCOPE=1 runj r9) $(gone) $(rec r9 '.unit | test("^fleet-headless-r9-[0-9]+$")')" "0 gone true"
else
  echo "  skip the scope's reaper: no systemd user manager"
fi
echo ok >"$work/rec/mode"

echo "launch: interactive sessions never get a key (#260)"
cat >"$work/bin/launcher" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$KLEPSYDRA_CLAUDE" >"$REC/launch-cmd"
EOF
cat >"$work/bin/envdump" <<'EOF'
#!/usr/bin/env bash
env | sort >"$REC/launch-env"
EOF
chmod +x "$work/bin/launcher" "$work/bin/envdump"
launch() { FLEET_MIN_AVAIL_MB=0 FLEET_LAUNCHER="$work/bin/launcher" FLEET_DIR="$work" bash "$here/launch.sh" "$@" "$work/brief.md" 2>/dev/null; }
rm -f -- "$work/rec/launch-cmd"
ANTHROPIC_API_KEY=sk-bad ANTHROPIC_AUTH_TOKEN=tok ANTHROPIC_PROFILE=ldqis FLEET_CLAUDE="$work/bin/envdump" launch w1 >/dev/null
# The pane inherits the tmux server's environment, which may carry them too.
ANTHROPIC_API_KEY=sk-bad ANTHROPIC_AUTH_TOKEN=tok ANTHROPIC_PROFILE=ldqis bash -c "$(cat "$work/rec/launch-cmd")" </dev/null
check "the launched command drops every key, token and profile" "$(grep -cE '^ANTHROPIC_(API_KEY|AUTH_TOKEN|PROFILE)=' "$work/rec/launch-env")" "0"
check "and still starts claude" "$(grep -c '^KLEPSYDRA_AGENT=w1$' "$work/rec/launch-env")" "1"
rm -f -- "$work/rec/launch-cmd"
out=$(FLEET_ACCOUNT="$work/api" launch w2); rc=$?
check "a config folder with an API key helper is refused" "$rc $(has "$out" 'launch refused')" "2 yes"
check "and nothing was launched" "$([[ -e $work/rec/launch-cmd ]] && echo launched || echo none)" "none"
printf '{"env": {"ANTHROPIC_API_KEY": "sk"}}\n' >"$work/keyed.json"
check "worker settings with a key are refused" "$(FLEET_SETTINGS="$work/keyed.json" launch w3 >/dev/null; echo $?)" "2"
check "--settings FILE with a key is refused" "$(FLEET_MIN_AVAIL_MB=0 FLEET_LAUNCHER="$work/bin/launcher" bash "$here/launch.sh" w4 "$work/brief.md" --settings "$work/api/settings.json" >/dev/null 2>&1; echo $?)" "2"
check "--settings=JSON with a helper is refused" "$(FLEET_MIN_AVAIL_MB=0 FLEET_LAUNCHER="$work/bin/launcher" bash "$here/launch.sh" w5 "$work/brief.md" '--settings={"apiKeyHelper":"x"}' >/dev/null 2>&1; echo $?)" "2"
mkdir -p "$work/.claude"
printf '{"apiKeyHelper": "x"}\n' >"$work/.claude/settings.local.json"
check "a keyed project setting in the session's folder is refused" "$(launch w6 >/dev/null; echo $?)" "2"
rm -f -- "$work/.claude/settings.local.json"
cp "$work/keyed.json" "$work/.claude/rel.json"
check "a relative --settings is read from the session's folder" "$(cd "$work/home" && FLEET_MIN_AVAIL_MB=0 FLEET_LAUNCHER="$work/bin/launcher" FLEET_DIR="$work" bash "$here/launch.sh" w7 "$work/brief.md" --settings .claude/rel.json >/dev/null 2>&1; echo $?)" "2"
check "and none of them launched" "$([[ -e $work/rec/launch-cmd ]] && echo launched || echo none)" "none"

echo "doctor: the auth mode"
doc() { FLEET_SYSTEMCTL=false FLEET_CURL=false FLEET_TAILSCALE=false bash "$here/doctor.sh" 2>/dev/null | grep '^[a-zA-Z]* *auth mode:'; }
check "subscription + headless credit" "$(doc | cut -c1-46)" "ok   auth mode: subscription + headless credit"
touch "$work/rec/ant-out"
check "no ant login: subscription only, with the fix" "$(doc | grep -c '^warn auth mode: subscription only: .*ant --profile ldqis auth login')" "1"
check "no helper configured: subscription only" "$(FLEET_HEADLESS_CONFIG="$work/none" doc)" "ok   auth mode: subscription only (no headless credit configured in $work/none)"
check "a keyed interactive folder fails" "$(FLEET_ACCOUNTS="$work/sub $work/api" doc | cut -c1-15)" "FAIL auth mode:"

check "a keyed worker settings file fails" "$(FLEET_SETTINGS="$work/keyed.json" doc | cut -c1-15)" "FAIL auth mode:"

echo "doctor: the heavy lock's holder (#260, 11-13)"
lock=$work/heavy.lock
doclock() { FLEET_HEAVY_LOCK="$lock" FLEET_SYSTEMCTL=false FLEET_CURL=false FLEET_TAILSCALE=false bash "$here/doctor.sh" 2>/dev/null | grep '^[a-zA-Z]* *heavy lock:'; }
held() { for _ in $(seq 50); do flock -n "$lock" true || return 0; sleep 0.1; done; } # wait until it is taken
check "no lock file: free" "$(doclock)" "ok   heavy lock: free"
: >"$lock"; chmod 000 "$lock"
check "a lock file it cannot open is said, not read as held" "$(doclock | grep -c '^warn heavy lock: could not try ')" "1"
rm -f -- "$lock"
: >"$lock"
check "an untaken lock: free" "$(doclock)" "ok   heavy lock: free"
flock -o "$lock" timeout 30 tail -f /dev/null & h=$!; held
out=$(doclock)
check "a per-command holder is named, with its age and scope" "$(has "$out" "^ok   heavy lock: held by pid $h (flock -o $lock timeout 30 tail -f /dev/null), [0-9]* s, [^,]*")" "yes"
flock -o -w 20 "$lock" true & w=$!; sleep 0.3
check "a run queued on it is counted, not named a holder" "$(doclock | grep -o '; 1 queued$') $(has "$(doclock)" "pid $w ")" "; 1 queued no"
kill "$h" "$w" 2>/dev/null; wait "$h" "$w" 2>/dev/null
# heavy.sh's shape: a flock(1) on an inherited file takes it and exits, so
# /proc/locks hides the lock; and a second one queues through its own flock.
# shellcheck disable=SC2016 # the inner shells' own code
bash -c 'exec 9>>"$1"; flock 9; tail -f /dev/null' _ "$lock" & h=$!; held
# shellcheck disable=SC2016
bash -c 'exec 9>>"$1"; flock -w 20 9; true' _ "$lock" & w=$!; sleep 0.3
out=$(doclock)
check "a lock whose taker exited still reads held, by the shell that holds it" "$(has "$out" "^ok   heavy lock: held by pid $h (tail -f /dev/null)")" "yes"
check "a run queued through a child flock is neither holder nor free" "$(has "$out" "pid $w ") $(grep -o '; 1 queued$' <<<"$out")" "no ; 1 queued"
kill "$h" "$w" 2>/dev/null; wait "$h" "$w" 2>/dev/null
# The 11-13 shape: the lock wrapped around a sleep, held across commands.
flock "$lock" -c "exec sleep 30" & h=$!; held
s=""; for _ in $(seq 20); do s=$(pgrep -P "$h" -x sleep) && break; sleep 0.1; done
out=$(doclock)
check "a bare sleep holding it warns, naming the pid to stop" "$(cut -c1-37 <<<"$out") $(has "$out" "pid $s is a bare sleep (sleep 30, [0-9]* s[^)]*): kill $s")" "warn heavy lock: held for nobody: pid yes"
kill "$s" "$h" 2>/dev/null; wait "$h" 2>/dev/null
mkdir -p "$work/state/headless/oldjob"
echo '{"name":"oldjob","state":"finished"}' >"$work/state/headless/oldjob/job.json"
KLEPSYDRA_HEADLESS=1 KLEPSYDRA_AGENT=oldjob flock -o "$lock" timeout 30 tail -f /dev/null & h=$!; held
check "a holder whose headless job has ended warns" "$(has "$(doclock)" "^warn heavy lock: held for nobody: pid $h outlived its job oldjob (finished; ")" "yes"
echo '{"name":"oldjob","state":"running"}' >"$work/state/headless/oldjob/job.json"; echo "$$" >"$work/state/headless/oldjob/pid"
check "one whose job still runs is named with its job" "$(has "$(doclock)" "^ok   heavy lock: held by pid $h .*, job oldjob$")" "yes"
kill "$h" 2>/dev/null; wait "$h" 2>/dev/null

echo "the tray's launcher drops the same variables as launch.sh"
list=$(bash -c ". '$here/lib.sh' && printf %s \"\$NO_KEY_ENV\"")
check "klepsydra-launch.sh starts claude without them" "$(grep -cF "cmd=\"env ${list}\$cmd\"" "$here/../hooks/klepsydra-launch.sh")" "1"

check "both hold the same settings filter" "$(grep -cF "key_jq='$(bash -c ". '$here/lib.sh' && printf %s \"\$KEY_JQ\"")'" "$here/../hooks/klepsydra-launch.sh")" "1"
mkdir -p "$work/tray/.claude"
printf '{"apiKeyHelper": "x"}\n' >"$work/tray/.claude/settings.local.json"
out=$(KLEPSYDRA_WT="$work/no-wt" KLEPSYDRA_CLAUDE=true KLEPSYDRA_TMUX_SOCKET="hl-tray-$$" bash "$here/../hooks/klepsydra-launch.sh" new "$work/tray" 2>&1); rc=$?
check "the tray refuses a folder whose settings set a key" "$rc $(has "$out" 'Not started: .*settings.local.json')" "1 yes"
check "and started no tmux server" "$(tmux -L "hl-tray-$$" ls >/dev/null 2>&1 && echo started || echo none)" "none"
out=$(KLEPSYDRA_WT="$work/no-wt" CLAUDE_CONFIG_DIR="$work/api" KLEPSYDRA_CLAUDE=true KLEPSYDRA_TMUX_SOCKET="hl-tray-$$" bash "$here/../hooks/klepsydra-launch.sh" new "$work/home" 2>&1)
check "the tray refuses a session on a keyed config folder" "$(has "$out" "Not started: $work/api/settings.json")" "yes"
out=$(KLEPSYDRA_BACKGROUND=1 KLEPSYDRA_WT="$work/no-wt" CLAUDE_CONFIG_DIR="$work/api" KLEPSYDRA_CLAUDE=true KLEPSYDRA_TMUX_SOCKET="hl-tray-$$" bash "$here/../hooks/klepsydra-launch.sh" new "$work/home" 2>&1)
check "a fleet launch from a keyed caller is not judged by the caller's folder" "$(has "$out" 'Not started') $(has "$out" 'wt.exe was not found')" "no yes"

echo "headless: a slow runner loses the start to a starter that gave up"
# shellcheck disable=SC2016 # the stub's own code
printf '%s\n' '#!/usr/bin/env bash' 'sleep 2' 'while (( $# )) && [[ $1 != bash ]]; do shift; done' 'exec "$@"' >"$work/bin/sdslow"
chmod +x "$work/bin/sdslow"
echo ok >"$work/rec/mode"; rm -f -- "$work/rec/argv" "$work/rec/ant-out"
out=$(FLEET_SCOPE=1 FLEET_SYSTEMD_RUN="$work/bin/sdslow" FLEET_HEADLESS_START_WAIT=1 hl job7 "$work/brief.md" --repo "$repo" 2>&1); rc=$?
sleep 3
check "the starter says it failed, and claude never ran" "$rc $([[ -e $work/rec/argv ]] && echo ran || echo never)" "1 never"
check "the record stays failed, and status lists it" "$(jq -r .state "$work/state/headless/job7/job.json") $(bash "$here/headless.sh" --status | grep -c 'job7 .*runner did not start')" "failed 1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
