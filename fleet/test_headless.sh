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
unset CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_PROFILE
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
# claude: records how it was started; $REC/mode says how it ends.
cat >"$work/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$REC/argv"
env | sort >"$REC/env"
pwd >"$REC/cwd"
cat >"$REC/stdin"
case $(cat "$REC/mode" 2>/dev/null || echo ok) in
  ok) printf '%s\n' '{"type":"system","subtype":"init"}' 'not json' \
        '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.4213,"duration_ms":5000,"num_turns":3}' ;;
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
check "claude -p with the default budget and model" "$argv" "-p --model claude-opus-5-5 --max-budget-usd 10 --permission-mode bypassPermissions --permission-prompts none --output-format stream-json --verbose "
check "it starts from main, not the checkout's branch" "$(git -C "$repo" rev-parse headless-job1)" "$(git -C "$repo" rev-parse main)"
check "the brief is its prompt" "$(cat "$work/rec/stdin")" "$(cat "$work/brief.md")"
env=$(cat "$work/rec/env")
check "no key, token or profile reaches the child" "$(grep -cE '^(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_PROFILE|CLAUDE_CODE_OAUTH_TOKEN|CLAUDE_CODE_SESSION_ID|ANTHROPIC_BASE_URL)=' <<<"$env")" "0"
check "it runs on the credit's config folder" "$(grep '^CLAUDE_CONFIG_DIR=' <<<"$env")" "CLAUDE_CONFIG_DIR=$work/api"
check "the default folder's telemetry, and only that, is passed on" "$(grep -cE '^(OTEL_METRICS_EXPORTER=otlp|CLAUDE_CODE_ENABLE_TELEMETRY=1)$' <<<"$env") $(grep -c '^UNRELATED=' <<<"$env")" "2 0"
check "the subagent cap is set" "$(grep -c '^CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=2$' <<<"$env")" "1"
check "no token reaches the output" "$(has "$out" SECRET)" "no"
job=$work/state/headless/job1/job.json
check "the record: finished, cost, exit, result" "$(jq -r '[.state, .total_cost_usd, .exit, .result] | join(" ")' "$job")" "finished 0.4213 0 success"
check "the ledger has one line" "$(jq -r '[.name, .model, .total_cost_usd, .exit] | join(" ")' "$work/state/headless/ledger.jsonl")" "job1 claude-opus-5-5 0.4213 0"
check "the fleet log has the end line" "$(jq -r 'select(.message == "headless job ended") | [.name, .model, .cost_usd, .exit] | join(" ")' "$work/state/log/fleet.log")" "job1 claude-opus-5-5 0.4213 0"
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

echo "the tray's launcher drops the same variables as launch.sh"
list=$(bash -c ". '$here/lib.sh' && printf %s \"\$NO_KEY_ENV\"")
check "klepsydra-launch.sh starts claude without them" "$(grep -cF "cmd=\"env ${list}\$cmd\"" "$here/../hooks/klepsydra-launch.sh")" "1"

check "both hold the same settings filter" "$(grep -cF "key_jq='$(bash -c ". '$here/lib.sh' && printf %s \"\$KEY_JQ\"")'" "$here/../hooks/klepsydra-launch.sh")" "1"
mkdir -p "$work/tray/.claude"
printf '{"apiKeyHelper": "x"}\n' >"$work/tray/.claude/settings.local.json"
out=$(KLEPSYDRA_CLAUDE=true KLEPSYDRA_TMUX_SOCKET="hl-tray-$$" bash "$here/../hooks/klepsydra-launch.sh" new "$work/tray" 2>&1); rc=$?
check "the tray refuses a folder whose settings set a key" "$rc $(has "$out" 'Not started: .*settings.local.json')" "1 yes"
check "and started no tmux server" "$(tmux -L "hl-tray-$$" ls >/dev/null 2>&1 && echo started || echo none)" "none"

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
