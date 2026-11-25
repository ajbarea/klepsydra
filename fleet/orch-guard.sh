#!/usr/bin/env bash
# orch-guard.sh: a PreToolUse hook (Bash, Edit, Write) that refuses, in the
# orchestrator's session only, the mistakes HEPH.md records (#264). Its
# run-time half, orch-tmux.sh, checks every tmux send on the orchestrator's
# PATH; this half refuses what can be judged before a call runs:
#   bypass     a tmux call that would skip orch-tmux.sh (a path, a new PATH)
#   api-key    an interactive session on an API key (#260: keys are for headless
#              jobs), or a headless one with no balance check logged today
#   registry   writing panes.tsv while a launch or chain loop runs, which reads
#              it to see its pane exit
# A refusal is a JSON "deny", which holds under bypass permissions; anything the
# guard cannot work out lets the call through (exit 0, no output) and is logged.
# ORCH_GUARD_ALLOW=registry in a command lets that guard pass, when AJ asked
# for it; the pass is logged. Every other session leaves at once, in bash
# alone: this runs on every call. Bypass detection is best effort: the tmux
# guard acts on whatever tmux the session's PATH reaches.
# Settings (each config folder): PreToolUse, matcher "Bash|Edit|Write", command
# "bash ~/.local/state/fleet-orchestrator/orch-guard.sh".
set -u
payload=$(cat)
state=${FLEET_STATE:-$HOME/.local/state/fleet-orchestrator}
[[ $payload =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] || exit 0
osid=""
{ read -r osid <"$state/orchestrator.session"; } 2>/dev/null
[[ -n $osid && ${BASH_REMATCH[1]} == "$osid" ]] || exit 0

tool=$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null) || exit 0
case $tool in
  Bash) cmd=$(jq -r '.tool_input.command // ""' <<<"$payload") file="" cwd=$(jq -r '.cwd // ""' <<<"$payload") ;;
  Edit | Write) cmd="" file=$(jq -r '.tool_input.file_path // ""' <<<"$payload") ;;
  *) exit 0 ;;
esac
if [[ $tool == Bash ]]; then
  [[ $cmd == *tmux* || $cmd == *panes.tsv* || $cmd == *REGISTRY* || $cmd == *claude* ||
    $cmd == *launch.sh* || $cmd == *fresh-now.sh* ]] || exit 0
else
  [[ ${file##*/} == panes.tsv ]] || exit 0
fi

FLEET_TARGET=fleet::orch-guard
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
now=$(clock)
glog() { flog "$@" 2>/dev/null; }
deny() { # GUARD REASON [KEY=VALUE...]
  local g=$1 r=$2
  shift 2
  glog WARN "orchestrator guard refused a call" guard="$g" tool="$tool" "$@" command="${cmd:0:300}" file="$file"
  jq -nc --arg r "orch-guard ($g): $r" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}
allowed() { [[ $cmd == *"ORCH_GUARD_ALLOW=$1"* ]]; }

# The launch, relaunch, recover and chain loops running now, one "PID COMMAND"
# each: a process whose program is such a script, or a shell running one (as a
# file, or in its -c script). A process that only names one (an editor, a
# linter, a test suite reading it) is none.
loop_script='(launch|relaunch-fresh|fresh-now|recover)\.sh|[A-Za-z0-9_.-]*[A-Za-z0-9_]-chain(\.sh)?'
loops() {
  local f c a
  local -a argv
  shopt -s nullglob
  for f in "${FLEET_PROC:-/proc}"/[0-9]*/cmdline; do
    mapfile -d '' -t argv <"$f" 2>/dev/null || continue
    (( ${#argv[@]} )) || continue
    a=${argv[0]##*/}
    if [[ $a =~ ^($loop_script)$ ]]; then
      :
    elif [[ $a =~ ^(bash|sh|dash|zsh)$ ]] && (( ${#argv[@]} > 1 )); then
      if [[ ${argv[1]} == -c ]]; then
        [[ ${argv[2]:-} =~ (^|[/ \;\&\'\"])($loop_script)([ \;\&\'\"]|$) ]] || continue
      else
        [[ ${argv[1]##*/} =~ ^($loop_script)$ ]] || continue
      fi
    else
      continue
    fi
    c=${argv[*]}
    f=${f%/cmdline}
    printf '%s %s\n' "${f##*/}" "${c:0:120}"
  done
}

registry_guard() { # WHAT
  local running how="If AJ asked for this edit now, add ORCH_GUARD_ALLOW=registry to the command."
  [[ $tool == Bash ]] || how="If AJ asked for this edit now, make it in Bash with ORCH_GUARD_ALLOW=registry in the command."
  running=$(loops | head -3)
  if [[ -z $running ]]; then
    glog INFO "orchestrator guard: registry write, no loop running" guard=registry writer="$1"
    return
  fi
  if allowed registry; then
    glog WARN "orchestrator guard: registry write while a loop runs, allowed by ORCH_GUARD_ALLOW" guard=registry writer="$1" loops="${running//$'\n'/; }"
    return
  fi
  deny registry "panes.tsv is the registry that a running launch or chain loop reads to see its pane exit (${running//$'\n'/; }). Editing it now can leave that loop spinning for hours (11-01 11:31). Wait until it ends, or stop it first, then edit; reading it with cat, grep, cut or column is fine. $how" \
    writer="$1" loops="${running//$'\n'/; }"
}

if [[ $tool != Bash ]]; then
  registry_guard "$tool"
  exit 0
fi

findings=$(printf '%s' "$cmd" | ORCH_ACCOUNTS=$FLEET_ACCOUNTS ORCH_CWD=$cwd python3 -I "$here/orch_guard_parse.py" 2>/dev/null) || {
  glog WARN "orchestrator guard: the command parser failed; call let through" command="${cmd:0:300}"
  exit 0
}
[[ -n $findings ]] || exit 0

balance_log=$state/api-balance.log
while IFS=$'\t' read -r kind a b; do
  case $kind in
    BYPASS)
      deny bypass "this calls tmux in a way that skips the guard's tmux ($a), which checks every send to a pane at the moment it is made. Call it as plain tmux, on the PATH the session started with." \
        how="$a"
      ;;
    REGISTRY) registry_guard "$a" ;;
    CLAUDE)
      if [[ $a == interactive ]]; then
        deny api-key "this starts an interactive Claude Code session on an API key ($b). Interactive sessions run on the subscription; API keys are only for headless jobs (claude -p, the Agent SDK), since an interactive session on a key bills per token (11-01: \$22.85 on AJ's card). Start it without the key." \
          signal="$b"
      fi
      today=$(date -d "@$now" +%F)
      if ! line=$(grep "^$today " "$balance_log" 2>/dev/null | tail -1) || [[ -z $line ]]; then
        deny api-key "this runs a headless job on an API key ($b), and no balance check is logged today. Check the key's organization balance in the Console (platform.claude.com, Billing), log it with: fleet balance ORG AMOUNT, then run this again." \
          signal="$b" log="$balance_log"
      fi
      glog INFO "orchestrator guard: headless API-key job, balance checked today" guard=api-key signal="$b" balance="$line"
      ;;
  esac
done <<<"$findings"
exit 0
