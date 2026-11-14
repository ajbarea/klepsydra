#!/usr/bin/env bash
# headless.sh (`fleet headless`): run one fleet job as a one-shot `claude -p` on
# the API credit (#260), never on the subscription and never interactive.
#   fleet headless NAME BRIEF [--budget USD] [--model MODEL] [--repo DIR] [--wait]
#   fleet headless --status
# NAME takes letters, digits, `.`, `_` and `-`, and is used once. BRIEF is a
# file (or - for stdin) whose text is the job's prompt. The job gets a fresh git
# worktree, <repo>/.claude/worktrees/headless-NAME on branch headless-NAME from
# the repo's default branch (--repo: default the git repo holding the current
# folder). claude runs there on the config folder FLEET_HEADLESS_CONFIG
# (~/.claude-api, whose apiKeyHelper prints the ant profile's token), with
# --max-budget-usd (default 10, at most FLEET_HEADLESS_MAX_USD, 50) and
# stream-json output, in the memory- and task-capped scope workers get (lib.sh),
# under a wall-clock limit (FLEET_HEADLESS_TIMEOUT seconds, 6 h). It refuses to
# start without an ant login for FLEET_HEADLESS_PROFILE (ldqis) and says the
# command that fixes it. It returns once the job has started, unless --wait.
# Each job keeps job.json, brief.md, stream.jsonl and stderr.log in
# $FLEET_STATE/headless/NAME/; when it ends, one line with its name, model,
# total_cost_usd, duration and exit goes to the fleet log and to
# $FLEET_STATE/headless/ledger.jsonl, which --status reads with the running jobs.
set -u
FLEET_TARGET=fleet::headless
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
HDIR=$FLEET_STATE/headless
LEDGER=$HDIR/ledger.jsonl
MAX_USD=${FLEET_HEADLESS_MAX_USD:-50}
USD_RE='^(0|[1-9][0-9]{0,5})(\.[0-9]{1,2})?$' # dollars: no sign, exponent or leading zero
NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
# Dollars as the status shows them: four places, or ? when the run left none.
USD_JQ='def usd: if type == "number" then (. * 10000 | round / 10000 | tostring) else "?" end;'
usage() { sed -n '3,4p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# The job's runner, inside its scope: claude, then the record.
run_job() { # NAME
  local name=$1 dir=$HDIR/$1
  local job model budget wt
  job=$(cat "$dir/job.json") || exit 1
  model=$(jq -r .model <<<"$job") budget=$(jq -r .budget_usd <<<"$job") wt=$(jq -r .worktree <<<"$job")
  # The pid file is the start's one owner (noclobber): a starter that gave up
  # waiting claims it first, and then this runner leaves the job alone.
  ( set -C; printf '%s\n' "$$" >"$dir/pid" ) 2>/dev/null || { err "the job $name was given up before its runner started"; exit 1; }
  # The child's environment: no credential that outranks the helper, nothing a
  # calling claude session hands its children (CLAUDE_CODE_*: its session id,
  # messaging socket, entrypoint), and the telemetry settings of the default
  # config folder, so the job reaches the ledger like any session.
  local -a envargs=(-u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_PROFILE -u CLAUDE_CODE_OAUTH_TOKEN
    -u CLAUDECODE -u KERYX_ENABLED -u KLEPSYDRA_WORKER)
  local v
  # Every other ANTHROPIC_* too: a base URL from the caller would send the
  # helper's token to another host.
  while IFS= read -r v; do [[ $v == CLAUDE_CODE_* || $v == ANTHROPIC_* ]] && envargs+=(-u "$v"); done < <(compgen -e)
  while IFS= read -r v; do [[ -n $v ]] && envargs+=("$v"); done < <(jq -r '(.env // {}) | to_entries[]
      | select(.key == "CLAUDE_CODE_ENABLE_TELEMETRY" or (.key | startswith("OTEL_"))) | "\(.key)=\(.value)"' \
      "$FLEET_DEFAULT_CONFIG/settings.json" 2>/dev/null)
  envargs+=("CLAUDE_CONFIG_DIR=$FLEET_HEADLESS_CONFIG" "BASH_ENV=$FLEET_OOM_TOOL" "KLEPSYDRA_AGENT=$name"
    KLEPSYDRA_HEADLESS=1 CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=2)
  local t0=$SECONDS rc
  # The OOM floor shell ranks claude last, as launch.sh does for workers.
  (
    cd -- "$wt" || exit 1
    # shellcheck disable=SC2016 # $@ is the inner shell's
    # shellcheck disable=SC2086 # FLEET_CLAUDE (tests) may be a command with words
    exec timeout -k 60 "${FLEET_HEADLESS_TIMEOUT:-21600}" bash -c '{ echo 0 >/proc/self/oom_score_adj; } 2>/dev/null; exec "$@"' fleet-oom \
      env "${envargs[@]}" ${FLEET_CLAUDE:-claude} -p --model "$model" --max-budget-usd "$budget" \
      --permission-mode bypassPermissions --permission-prompts none --output-format stream-json --verbose \
      <"$dir/brief.md" >"$dir/stream.jsonl" 2>"$dir/stderr.log"
  )
  rc=$?
  local secs=$((SECONDS - t0)) res
  # The stream's last result message: its cost, duration and kind of end.
  res=$(jq -cR 'fromjson? | select(type == "object" and .type == "result")
      | {total_cost_usd, duration_ms, num_turns, subtype, is_error}' "$dir/stream.jsonl" 2>/dev/null | tail -n 1)
  [[ -n $res ]] || res='{}'
  local rec
  rec=$(jq -c --argjson res "$res" --argjson exit "$rc" --argjson secs "$secs" --arg ended "$(date -u +%FT%TZ)" '
    . + {state: "finished", exit: $exit, secs: $secs, ended_at: $ended,
         total_cost_usd: ($res.total_cost_usd // null), duration_ms: ($res.duration_ms // null),
         num_turns: ($res.num_turns // null), result: ($res.subtype // (if $exit == 124 then "timeout" else "no result" end))}' <<<"$job")
  printf '%s\n' "$rec" >"$dir/job.json.tmp" && mv -f -- "$dir/job.json.tmp" "$dir/job.json"
  ( flock 9; printf '%s\n' "$(jq -c '{name, model, budget_usd, total_cost_usd, secs, exit, result, started_at, ended_at, worktree}' <<<"$rec")" >>"$LEDGER" ) 9>>"$HDIR/.lock"
  # The pid file stays: the claim is the runner's for good, so a starter that
  # gave up waiting can never claim it after the job ran.
  flog INFO "headless job ended" name="$name" model="$model" cost_usd="$(jq -r '.total_cost_usd // "unknown"' <<<"$rec")" \
    budget_usd="$budget" secs="$secs" exit="$rc" result="$(jq -r .result <<<"$rec")"
  return "$rc"
}

# A job's runner is alive when its pid file names a live headless runner.
job_alive() { # DIR
  local p
  p=$(cat "$1/pid" 2>/dev/null) && [[ $p =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null &&
    tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -qF "headless.sh --run ${1##*/} "
}

status() {
  local d any=0 now
  now=$(date +%s)
  printf 'Running:\n'
  for d in "$HDIR"/*/; do
    [[ -f $d/job.json ]] || continue
    d=${d%/}
    [[ $(jq -r .state "$d/job.json" 2>/dev/null) == running ]] || continue
    [[ $(cat "$d/pid" 2>/dev/null) == gave-up ]] && continue
    any=1
    if job_alive "$d" || { [[ ! -e $d/pid ]] && (( now - $(jq -r '.started_epoch // 0' "$d/job.json") < 60 )); }; then
      jq -r --argjson now "$now" '"  \(.name)  \(.model)  budget $\(.budget_usd)  running \((($now - .started_epoch) / 60) | floor) min  \(.worktree)"' "$d/job.json"
    else
      jq -r '"  \(.name)  \(.model)  budget $\(.budget_usd)  DIED without a record (see runner.log and stderr.log beside its job.json)"' "$d/job.json"
    fi
  done
  (( any )) || printf '  none\n'
  printf 'Finished (newest last):\n'
  if [[ -s $LEDGER ]]; then
    tail -n "${FLEET_HEADLESS_SHOW:-20}" "$LEDGER" | jq -r "$USD_JQ"'"  \(.ended_at[0:16])  \(.name)  \(.model)  $\(.total_cost_usd | usd) of $\(.budget_usd)  \(.secs)s  exit \(.exit)  \(.result)"'
    jq -rs "$USD_JQ"'"Total: $\(map(.total_cost_usd // 0) | add | usd) over \(length) job\(if length == 1 then "" else "s" end)"' "$LEDGER"
  else
    printf '  none\n'
  fi
}

case ${1:-} in
  --status) status; exit 0 ;;
  --run)
    # Only a job this command just set up: a valid name, still running. Its pid
    # file (claimed in run_job) admits one runner, never after a starter gave up.
    [[ ${2:-} =~ $NAME_RE && -f $HDIR/$2/job.json ]] &&
      [[ $(jq -r .state "$HDIR/$2/job.json" 2>/dev/null) == running ]] || { err "--run takes a job fleet headless has just set up"; exit 2; }
    run_job "$2"; exit ;;
  ''|-h|--help) usage ;;
esac

name=$1 brief=${2:-}
shift 2 2>/dev/null || usage
budget=10 model=claude-opus-5-5 repo="" wait=0
while (( $# )); do
  case $1 in
    --budget) budget=${2:-}; shift 2 || usage ;;
    --model) model=${2:-}; shift 2 || usage ;;
    --repo) repo=${2:-}; shift 2 || usage ;;
    --wait) wait=1; shift ;;
    *) err "unknown option: $1"; usage ;;
  esac
done
[[ $name =~ $NAME_RE ]] || { err "NAME takes letters, digits, . _ and - (at most 64)"; exit 2; }
# Every job runs under a hard cap (default 10): a positive amount in dollars, at
# most MAX_USD, so a typo cannot lift it. A MAX_USD that is no amount refuses
# every job rather than comparing as text.
[[ $MAX_USD =~ $USD_RE ]] || { err "FLEET_HEADLESS_MAX_USD is not an amount in dollars: $MAX_USD"; exit 2; }
if ! [[ $budget =~ $USD_RE ]] || awk -v b="$budget" -v m="$MAX_USD" 'BEGIN { exit !(b <= 0 || b > m) }'; then
  err "--budget takes dollars above 0 and at most $MAX_USD (FLEET_HEADLESS_MAX_USD), such as 10 or 2.50"
  exit 2
fi
[[ $model =~ ^[A-Za-z0-9._-]+$ ]] || { err "--model takes a model name, such as claude-opus-5-5"; exit 2; }
repo=${repo:-.}
repo=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || { err "--repo is not a git repository"; exit 2; }
# A worktree's own checkout makes a worktree of its main repository.
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && [[ $common == */.git ]] && repo=${common%/.git}
if [[ $brief == - ]]; then text=$(cat); else [[ -r $brief && -f $brief ]] || { err "no brief at $brief"; exit 2; }; text=$(cat -- "$brief"); fi
[[ -n ${text//[[:space:]]/} ]] || { err "the brief is empty"; exit 2; }

# The credit's login and helper, before anything is made.
if ! command -v "${FLEET_ANT:-ant}" >/dev/null; then
  err "the ant CLI is not installed (github.com/anthropics/anthropic-cli); headless jobs need it"
  exit 2
fi
if ! headless_login; then
  err "no ant login for profile $FLEET_HEADLESS_PROFILE; run: ant --profile $FLEET_HEADLESS_PROFILE auth login"
  flog WARN "headless job refused: no ant login" name="$name" profile="$FLEET_HEADLESS_PROFILE"
  exit 2
fi
if ! jq -e '.apiKeyHelper // "" | length > 0' "$FLEET_HEADLESS_CONFIG/settings.json" >/dev/null 2>&1; then
  err "$(tilde "$FLEET_HEADLESS_CONFIG")/settings.json has no apiKeyHelper; see docs/headless.md"
  exit 2
fi

# The name is claimed by making its folder, so two starts cannot share it.
mkdir -p -- "$HDIR"
dir=$HDIR/$name
mkdir -- "$dir" 2>/dev/null || { err "a job named $name exists ($(tilde "$dir")); pick another name"; exit 2; }
release() { rm -rf -- "${dir:?}"; }
wt=$repo/.claude/worktrees/headless-$name
branch=headless-$name
fetched=1
if git -C "$repo" remote get-url origin >/dev/null 2>&1 && ! timeout 60 git -C "$repo" fetch -q origin 2>/dev/null; then
  fetched=0
  flog WARN "headless: fetch failed; the worktree starts from the last fetched default branch" name="$name"
fi
# The default branch: origin's HEAD, set from the remote when unset, else
# origin/main or origin/master; with no origin at all, the local main. Never
# the main checkout's current branch.
base=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) ||
  { (( fetched )) && git -C "$repo" remote get-url origin >/dev/null 2>&1 && timeout 30 git -C "$repo" remote set-head origin -a >/dev/null 2>&1 && base=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null); } ||
  { git -C "$repo" rev-parse -q --verify origin/main >/dev/null && base=origin/main; } ||
  { git -C "$repo" rev-parse -q --verify origin/master >/dev/null && base=origin/master; } ||
  { ! git -C "$repo" remote get-url origin >/dev/null 2>&1 && git -C "$repo" rev-parse -q --verify refs/heads/main >/dev/null && base=main; } ||
  { release; err "$(tilde "$repo") has no default branch to start the job from (origin's HEAD, origin/main or origin/master; with no origin, a local main)"; exit 1; }
if ! out=$(git -C "$repo" worktree add -q -b "$branch" "$wt" "$base" 2>&1); then
  release
  err "could not make the worktree $(tilde "$wt"): $out"
  exit 1
fi
printf '%s\n' "$text" >"$dir/brief.md"
jq -nc --arg name "$name" --arg model "$model" --argjson budget "$budget" --arg repo "$repo" --arg wt "$wt" \
  --arg branch "$branch" --arg at "$(date -u +%FT%TZ)" --argjson epoch "$(date +%s)" \
  '{name: $name, model: $model, budget_usd: $budget, repo: $repo, worktree: $wt, branch: $branch,
    state: "running", started_at: $at, started_epoch: $epoch}' >"$dir/job.json"

runner=(bash "$here/headless.sh" --run "$name")
if [[ ${FLEET_SCOPE:-1} != 0 ]]; then
  tasks=""
  tmax=$(fleet_tasks_max) && tasks="-p TasksMax=$tmax"
  # shellcheck disable=SC2206,SC2207 # the options are words
  runner=(${FLEET_SYSTEMD_RUN:-systemd-run} --user --scope --collect --quiet --unit="fleet-headless-$name-$(date +%s)"
    $(fleet_slice_opts worker) -p "MemoryMax=${MEM_MAX:-5G}" -p "MemorySwapMax=${MEM_SWAP:-1G}" $tasks "${runner[@]}")
fi
flog INFO "headless job started" name="$name" model="$model" budget_usd="$budget" worktree="$wt"
# A runner that never wrote its record: the job reads failed, with the reason.
failed_start() { # RC [REASON]
  # A number in the pid file: the runner started and died before its record,
  # so what it spent is unknown; otherwise it never started.
  local what="runner did not start"
  [[ $(cat "$dir/pid" 2>/dev/null) =~ ^[0-9]+$ ]] && what="runner died before its record"
  jq -c --argjson rc "$1" --arg what "$what" '. + {state: "failed", exit: $rc, result: $what, total_cost_usd: null}' "$dir/job.json" >"$dir/job.json.tmp" &&
    mv -f -- "$dir/job.json.tmp" "$dir/job.json"
  ( flock 9; jq -c '{name, model, budget_usd, total_cost_usd, secs: 0, exit, result, started_at, ended_at: (now | todate), worktree}' "$dir/job.json" >>"$LEDGER" ) 9>>"$HDIR/.lock"
  flog ERROR "headless job did not start" name="$name" said="$(head -c 300 "$dir/runner.log" 2>/dev/null)"
  err "the job failed: $what (exit $1)${2:+: $2}; its log: $(tilde "$dir")/runner.log"
}
if (( wait )); then
  "${runner[@]}" </dev/null 2> >(tee -a "$dir/runner.log" >&2)
  rc=$?
  [[ $(jq -r .state "$dir/job.json") == finished ]] || { failed_start "$rc"; exit "$(( rc ? rc : 1 ))"; }
  jq -r "$USD_JQ"'"\(.name): exit \(.exit), $\(.total_cost_usd | usd) of $\(.budget_usd), \(.secs)s, \(.result)"' "$dir/job.json"
  exit "$rc"
fi
setsid -f "${runner[@]}" </dev/null >>"$dir/runner.log" 2>&1
# The runner writes its pid once claude is about to start; a scope that could
# not be made never does.
for _ in $(seq "$(( ${FLEET_HEADLESS_START_WAIT:-15} * 5 ))"); do
  [[ -e $dir/pid || $(jq -r .state "$dir/job.json") != running ]] && break
  sleep 0.2
done
# Still no runner: claim the start so a late one cannot run after this says it
# failed. A runner that claimed it first has started after all (it never gives
# its claim back).
if ( set -C; echo gave-up >"$dir/pid" ) 2>/dev/null; then
  failed_start 1 "$(head -n 1 "$dir/runner.log" 2>/dev/null)"
  exit 1
fi
echo "started $name: $(tilde "$wt"), budget \$$budget, model $model; fleet headless --status shows it"
