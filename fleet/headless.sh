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
# The prompt is headless-rules.md, then the brief: foreground only, every tool
# call under 9 minutes, the heavy lock per command, and a final message that
# starts with `FINAL REPORT:`. A run whose last message lacks it (or says it is
# waiting) is resumed (`claude -p --resume`) up to FLEET_HEADLESS_RESUMES times
# (4) within the budget, and then the job reads stalled. After every run, what
# claude left behind in the job's scope or its session is stopped (#260, 11-13).
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

# The job's preamble (headless-rules.md) and its end: a job is done only when
# its last message starts with MARK (#260, 11-13: a run whose turn ended on a
# background wait, or on a call Claude Code moved to the background at its tool
# timeout, ended the job half done).
RULES=$here/headless-rules.md
MARK='FINAL REPORT:'
# A first-person line that says the job goes on later, in a report's last
# lines: such a report is resumed once ("Merge it once review is done" is not
# one).
Q="(?:'|’)"
WAIT_RE="\\b(I${Q}ll|I will|I${Q}m going to|I am going to|I${Q}d|let me|I need to|I have to) (now |then |just )?(continue|resume|check back|report back|come back|wait|pick (it|this|that) (back )?up|follow up|finish (it|this|the rest) (once|when|after))|\\b(I${Q}m|I am) (now |still )?(waiting|polling)"
# The resumes need a session's cost to carry across runs, which claude -p does
# from 2.1.277 (code.claude.com/docs/en/agent-sdk/cost-tracking); before it,
# each resume would start the budget over.
RESUME_MIN_VERSION=2.1.277
CONTINUE="Your last turn ended before the job was done: its message did not start with \`$MARK\`, or it said it was waiting. Nothing wakes a headless run, so continue the job to the end now, in the foreground only: no background jobs, watchers or monitors, each command under 8 minutes, the heavy lock per command (\`flock -o -E 75 -w 420 /tmp/fleet-heavy.lock timeout 480 <one command>\`, issued again on exit 75). A command from before may have been stopped or lost: check its result and run it again in the foreground if needed. When the whole job is done, your final message starts with \`$MARK\`."

# How a final message ends the job: 0 done, 1 no report, 2 a report whose last
# lines say it waits. The marker may be bold, a heading or in any case.
job_done() { # TEXT
  local text=$1 head
  text=${text#"${text%%[![:space:]]*}"}
  head=${text:0:40}
  while [[ $head == [#*_\ ]* ]]; do head=${head:1}; done
  [[ ${head^^} == "$MARK"* || ${head^^} == "${MARK%:}"'**:'* ]] || return 1
  tail -n 6 <<<"$text" | grep -Piq -- "$WAIT_RE" && return 2
  return 0
}

# Whether claude's version keeps a session's cost across resumes.
resumable_claude() {
  local v
  # shellcheck disable=SC2086 # FLEET_CLAUDE (tests) may be a command with words
  v=$(timeout 30 ${FLEET_CLAUDE:-claude} --version </dev/null 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
  [[ -n $v ]] && [[ $(printf '%s\n' "$RESUME_MIN_VERSION" "$v" | sort -V | head -n 1) == "$RESUME_MIN_VERSION" ]]
}

# Stop every process the job left (#260, 11-13: a sleep a job wrapped the heavy
# lock around outlived it and held the lock for 30 minutes). Three nets, each
# the job's alone, and only processes started since this runner (no reused
# pid): the other processes of its own scope, when this runner runs in the
# unit headless.sh made for this job (never a cgroup it shares with its
# caller); every process carrying this job's KLEPSYDRA_AGENT with
# KLEPSYDRA_HEADLESS=1, which claude hands everything it starts (Claude Code
# puts each Bash command in a session of its own); and claude's session SID.
# TERM, then KILL what is left after FLEET_HEADLESS_REAP_S. Sets REAPED to the
# count it found.
REAPED=0
reap() { # SID UNIT (job.json's, or empty)
  local sid=$1 unit=$2 cg="" p f round sig alive mine env
  local -A seen=()
  local -a left st
  if [[ -n $unit ]] && cg=$(proc_cgroup "$$") && [[ ${cg##*/} == "$unit.scope" ]]; then
    cg=${FLEET_CGROUP_ROOT:-/sys/fs/cgroup}$cg
  else
    cg=""
  fi
  local reap_s=${FLEET_HEADLESS_REAP_S:-5}
  [[ $reap_s =~ ^[0-9]{1,3}$ ]] || reap_s=5
  for round in 1 2 3; do
    left=()
    if [[ -n $cg && -r $cg/cgroup.procs ]]; then
      while read -r p; do [[ $p =~ ^[0-9]+$ && $p != "$$" && $p != "$BASHPID" ]] && left+=("$p"); done <"$cg/cgroup.procs"
    fi
    for f in /proc/[0-9]*/stat; do
      p=${f#/proc/} p=${p%/stat}
      [[ $p == "$$" ]] && continue
      { read -r mine <"$f"; } 2>/dev/null || continue
      # After the name: state ppid pgrp session ... starttime (the 20th).
      read -r -a st <<<"${mine##*) }"
      (( ${st[19]:-0} >= RUNNER_START )) || continue
      if [[ $sid =~ ^[1-9][0-9]*$ && ${st[3]} == "$sid" ]]; then left+=("$p"); continue; fi
      env=$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null) || continue
      [[ $'\n'$env$'\n' == *$'\nKLEPSYDRA_HEADLESS=1\n'* && $'\n'$env$'\n' == *$'\nKLEPSYDRA_AGENT='"$JOB_NAME"$'\n'* ]] && left+=("$p")
    done
    (( ${#left[@]} )) || break
    for p in "${left[@]}"; do seen[$p]=1; done
    sig=TERM; (( round == 3 )) && sig=KILL
    kill -s "$sig" -- "${left[@]}" 2>/dev/null
    (( round < 3 )) && for _ in $(seq "$(( reap_s * 5 ))"); do
      alive=0
      for p in "${left[@]}"; do kill -0 "$p" 2>/dev/null && { alive=1; break; }; done
      (( alive )) || break
      sleep 0.2
    done
  done
  REAPED=${#seen[@]}
}

# The job's runner, inside its scope: claude, resumed until it ends with its
# report (at most FLEET_HEADLESS_RESUMES times, within the budget and the job's
# wall-clock limit), then the reaper and the record.
run_job() { # NAME
  local name=$1
  dir=$HDIR/$1 JOB_NAME=$1
  local job model budget wt unit mine
  job=$(cat "$dir/job.json") || exit 1
  model=$(jq -r .model <<<"$job") budget=$(jq -r .budget_usd <<<"$job") wt=$(jq -r .worktree <<<"$job") unit=$(jq -r '.unit // ""' <<<"$job")
  # The pid file is the start's one owner (noclobber): a starter that gave up
  # waiting claims it first, and then this runner leaves the job alone.
  ( set -C; printf '%s\n' "$$" >"$dir/pid" ) 2>/dev/null || { err "the job $name was given up before its runner started"; exit 1; }
  read -r mine <"/proc/$$/stat"; read -r -a mine <<<"${mine##*) }"; RUNNER_START=${mine[19]}
  # The child's environment: no credential that outranks the helper, nothing a
  # calling claude session hands its children (CLAUDE_CODE_*: its session id,
  # messaging socket, entrypoint), and the telemetry settings of the default
  # config folder, so the job reaches the ledger like any session.
  local -a envargs=(-u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_PROFILE -u CLAUDE_CODE_OAUTH_TOKEN
    -u CLAUDECODE -u KERYX_ENABLED -u KLEPSYDRA_WORKER -u BASH_DEFAULT_TIMEOUT_MS -u BASH_MAX_TIMEOUT_MS)
  local v
  # Every other ANTHROPIC_* too: a base URL from the caller would send the
  # helper's token to another host.
  while IFS= read -r v; do [[ $v == CLAUDE_CODE_* || $v == ANTHROPIC_* ]] && envargs+=(-u "$v"); done < <(compgen -e)
  while IFS= read -r v; do [[ -n $v ]] && envargs+=("$v"); done < <(jq -r '(.env // {}) | to_entries[]
      | select(.key == "CLAUDE_CODE_ENABLE_TELEMETRY" or (.key | startswith("OTEL_"))) | "\(.key)=\(.value)"' \
      "$FLEET_DEFAULT_CONFIG/settings.json" 2>/dev/null)
  # No background work (code.claude.com/docs/en/env-vars, tools-reference): a
  # command at its tool timeout stops instead of moving to the background,
  # where the run would end without it, and no background session; Monitor,
  # which still runs in the background, and wakeups are not offered. The tool
  # timeout is 16 minutes, so a 7-minute wait on the heavy lock and an 8-minute
  # run fit in one call (headless-rules.md); Claude Code's own default is 2.
  envargs+=("CLAUDE_CONFIG_DIR=$FLEET_HEADLESS_CONFIG" "BASH_ENV=$FLEET_OOM_TOOL" "KLEPSYDRA_AGENT=$name"
    KLEPSYDRA_HEADLESS=1 CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=2 CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1
    CLAUDE_CODE_DISABLE_AGENT_VIEW=1 BASH_DEFAULT_TIMEOUT_MS=960000 BASH_MAX_TIMEOUT_MS=960000)
  local t0=$SECONDS deadline=$((SECONDS + ${FLEET_HEADLESS_TIMEOUT:-21600}))
  local max_resumes=${FLEET_HEADLESS_RESUMES:-4}
  [[ $max_resumes =~ ^[0-9]{1,3}$ ]] && max_resumes=$((10#$max_resumes)) || max_resumes=4
  local rc=0 resumes=0 waits=0 spent=null sid="" outcome="" res="" last_res="" partial=false lines left rem input text why=""
  local -a args
  stopping=0 cpid=""
  # A stop (systemctl stop, Ctrl-C under --wait) ends claude, then the record
  # and the reaper still run.
  trap 'stopping=1; [[ -n $cpid ]] && kill -TERM -- "$cpid" 2>/dev/null' TERM INT HUP
  : >"$dir/stream.jsonl"; : >"$dir/stderr.log"
  printf '%s\n' "$CONTINUE" >"$dir/continue.md"
  while :; do
    (( stopping )) && { outcome=stopped; break; }
    left=$((deadline - SECONDS))
    (( left > 0 )) || { rc=124; outcome=timeout; break; }
    args=(-p --model "$model" --max-budget-usd "$budget")
    input=$dir/brief.md
    if [[ -n $sid ]]; then
      args=(-p --resume "$sid" --model "$model" --max-budget-usd "$rem")
      input=$dir/continue.md
    fi
    lines=$(wc -l <"$dir/stream.jsonl")
    # The OOM floor shell ranks claude last, as launch.sh does for workers.
    # claude starts a session of its own (this subshell leads no process
    # group, so setsid does not fork): one of the reaper's handles.
    (
      cd -- "$wt" || exit 1
      # shellcheck disable=SC2016 # $@ is the inner shell's
      # shellcheck disable=SC2086 # FLEET_CLAUDE (tests) may be a command with words
      exec setsid timeout -k 60 "$left" bash -c '{ echo 0 >/proc/self/oom_score_adj; } 2>/dev/null; exec "$@"' fleet-oom \
        env "${envargs[@]}" ${FLEET_CLAUDE:-claude} "${args[@]}" \
        --permission-mode bypassPermissions --permission-prompts none --disallowedTools Monitor,ScheduleWakeup,CronCreate \
        --output-format stream-json --verbose <"$input" >>"$dir/stream.jsonl" 2>>"$dir/stderr.log"
    ) &
    cpid=$!
    while :; do
      wait "$cpid"; rc=$?
      kill -0 "$cpid" 2>/dev/null || break # a trapped signal ended the wait, not claude
    done
    # What claude left goes with it, before any resume.
    reap "$cpid" "$unit"
    REAPED_ALL=$(( ${REAPED_ALL:-0} + REAPED ))
    cpid=""
    # This run's last result message: its kind of end, cost (the session's
    # whole spend: a resumed run counts the earlier runs too), session and text.
    res=$(tail -n "+$((lines + 1))" "$dir/stream.jsonl" | jq -cR 'fromjson? | select(type == "object" and .type == "result")
        | {total_cost_usd, duration_ms, num_turns, subtype, is_error, session_id, result}' 2>/dev/null | tail -n 1)
    # The session's spend only grows: a crash's result may carry it as 0.
    [[ -n $res ]] && spent=$(jq -c --argjson prev "$spent" '[.total_cost_usd, $prev] | map(select(type == "number")) | max' <<<"$res")
    if [[ -z $res ]]; then
      # A resumed run that left no result spent something unknown on top.
      (( resumes )) && partial=true
      res=$last_res
      if (( stopping )); then outcome=stopped; elif (( rc == 124 )); then outcome=timeout; else outcome="no result"; fi
      break
    fi
    (( stopping )) && { outcome=stopped; break; }
    last_res=$res
    outcome=$(jq -r '.subtype // "no result"' <<<"$res")
    [[ $outcome == success ]] || break
    text=$(jq -r '.result // "" | tostring' <<<"$res")
    job_done "$text"
    case $? in
      0) break ;;
      2) (( waits )) && break; waits=1; why="its report said it was waiting" ;;
      *) why="its turn ended without $MARK" ;;
    esac
    # No report yet: resume the same session, while resumes are left, the
    # budget leaves at least a cent of a known spend, and claude keeps that
    # spend across resumes.
    outcome=stalled
    sid=$(jq -r '.session_id // "" | tostring' <<<"$res")
    if (( resumes >= max_resumes )); then break
    elif ! [[ $sid =~ ^[A-Za-z0-9-]+$ ]]; then flog WARN "headless job not resumed: no session id" name="$name"; break
    elif [[ $spent == null ]]; then flog WARN "headless job not resumed: its cost is unknown" name="$name"; break
    elif (( ! resumes )) && ! resumable_claude; then
      flog WARN "headless job not resumed: claude is older than $RESUME_MIN_VERSION, so a resume would start the budget over" name="$name"; break
    fi
    rem=$(awk -v b="$budget" -v s="$spent" 'BEGIN { r = int((b - s) * 100) / 100; if (r < 0) r = 0; printf "%.2f", r }')
    awk -v r="$rem" 'BEGIN { exit !(r < 0.01) }' && break
    resumes=$((resumes + 1))
    jq -c --argjson n "$resumes" '. + {resumes: $n}' "$dir/job.json" >"$dir/job.json.tmp" && mv -f -- "$dir/job.json.tmp" "$dir/job.json"
    flog WARN "headless job resumed: $why" name="$name" resume="$resumes/$max_resumes" \
      cost_usd="$spent" budget_left_usd="$rem" said="$(tail -c 200 <<<"$text" | tr '\n' ' ')"
  done
  trap - TERM INT HUP
  local secs=$((SECONDS - t0)) last rec
  last=${res:-'{}'}
  rec=$(jq -c --argjson res "$last" --argjson exit "$rc" --argjson secs "$secs" --arg ended "$(date -u +%FT%TZ)" \
    --arg outcome "$outcome" --argjson spent "$spent" --argjson resumes "$resumes" --argjson reaped "${REAPED_ALL:-0}" \
    --argjson partial "$partial" '
    . + {state: "finished", exit: $exit, secs: $secs, ended_at: $ended,
         total_cost_usd: $spent, duration_ms: ($res.duration_ms // null),
         num_turns: ($res.num_turns // null), result: $outcome, resumes: $resumes, reaped: $reaped}
      + (if $partial then {cost_partial: true} else {} end)' "$dir/job.json")
  printf '%s\n' "$rec" >"$dir/job.json.tmp" && mv -f -- "$dir/job.json.tmp" "$dir/job.json"
  ( flock 9; printf '%s\n' "$(jq -c '{name, model, budget_usd, total_cost_usd, cost_partial, secs, exit, result, resumes, reaped, started_at, ended_at, worktree} | with_entries(select(.key != "cost_partial" or .value))' <<<"$rec")" >>"$LEDGER" ) 9>>"$HDIR/.lock"
  # The pid file stays: the claim is the runner's for good, so a starter that
  # gave up waiting can never claim it after the job ran.
  local level=INFO
  [[ $outcome == stalled ]] && level=WARN
  flog "$level" "headless job ended" name="$name" model="$model" cost_usd="$(jq -r '.total_cost_usd // "unknown"' <<<"$rec")" \
    budget_usd="$budget" secs="$secs" exit="$rc" result="$outcome" resumes="$resumes" reaped="${REAPED_ALL:-0}"
  # A stalled job did not finish, whatever its last run's exit.
  [[ $outcome == stalled ]] && (( rc == 0 )) && rc=1
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
      jq -r --argjson now "$now" '"  \(.name)  \(.model)  budget $\(.budget_usd)  running \((($now - .started_epoch) / 60) | floor) min\(if (.resumes // 0) > 0 then ", resumed \(.resumes)x" else "" end)  \(.worktree)"' "$d/job.json"
    else
      jq -r '"  \(.name)  \(.model)  budget $\(.budget_usd)  DIED without a record (see runner.log and stderr.log beside its job.json)"' "$d/job.json"
    fi
  done
  (( any )) || printf '  none\n'
  printf 'Finished (newest last):\n'
  if [[ -s $LEDGER ]]; then
    tail -n "${FLEET_HEADLESS_SHOW:-20}" "$LEDGER" | jq -r "$USD_JQ"'"  \(.ended_at[0:16])  \(.name)  \(.model)  $\(.total_cost_usd | usd)\(if .cost_partial then "+" else "" end) of $\(.budget_usd)  \(.secs)s  exit \(.exit)  \(.result)\(if (.resumes // 0) > 0 then " after \(.resumes) resume\(if .resumes == 1 then "" else "s" end)" else "" end)\(if .result == "stalled" then ": STALLED, no FINAL REPORT (see stream.jsonl)" else "" end)\(if (.reaped // 0) > 0 then ", \(.reaped) leftover process\(if .reaped == 1 then "" else "es" end) stopped" else "" end)"'
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
[[ -r $RULES && -s $RULES ]] || { err "the headless rules are missing: $(tilde "$RULES")"; exit 2; }

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
# The prompt: the headless rules, then the brief.
{ cat -- "$RULES" && printf '\n%s\n' "$text"; } >"$dir/brief.md"
# The job's scope, named here so its runner can tell it from a caller's cgroup.
unit=""
[[ ${FLEET_SCOPE:-1} != 0 ]] && unit="fleet-headless-$name-$(date +%s)"
jq -nc --arg name "$name" --arg model "$model" --argjson budget "$budget" --arg repo "$repo" --arg wt "$wt" \
  --arg branch "$branch" --arg at "$(date -u +%FT%TZ)" --argjson epoch "$(date +%s)" --arg unit "$unit" \
  '{name: $name, model: $model, budget_usd: $budget, repo: $repo, worktree: $wt, branch: $branch,
    state: "running", started_at: $at, started_epoch: $epoch} + (if $unit == "" then {} else {unit: $unit} end)' >"$dir/job.json"

runner=(bash "$here/headless.sh" --run "$name")
if [[ ${FLEET_SCOPE:-1} != 0 ]]; then
  tasks=""
  tmax=$(fleet_tasks_max) && tasks="-p TasksMax=$tmax"
  # shellcheck disable=SC2206,SC2207 # the options are words
  runner=(${FLEET_SYSTEMD_RUN:-systemd-run} --user --scope --collect --quiet --unit="$unit"
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
