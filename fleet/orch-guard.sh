#!/usr/bin/env bash
# orch-guard.sh: a PreToolUse hook (Bash, Edit, Write) that refuses, in the
# orchestrator's session only, the mistakes HEPH.md records (#264):
#   cold-limit     typing into a pane that stopped at a usage limit FRESH_AFTER_S
#                  ago or more: its prompt cache expired, so a nudge re-caches its
#                  whole transcript (fresh-now.sh relaunches it from its brief)
#   pending-input  typing into a pane whose input line holds text the orchestrator
#                  did not type there (AJ's line, a worker's report)
#   api-key        an interactive session on an API key (#260: keys are for headless
#                  jobs), or a headless one with no balance check logged today
#   registry       writing panes.tsv while a launch or chain loop runs, which reads
#                  it to see its pane exit
#   target         a send whose pane the guard cannot read before it runs
# A refusal is a JSON "deny", which holds under bypass permissions; anything the
# guard cannot work out lets the call through (exit 0, no output) and is logged.
# ORCH_GUARD_ALLOW=pending-input or ORCH_GUARD_ALLOW=registry anywhere in a
# command lets that guard pass, when AJ asked for it; the pass is logged.
# Every other session leaves at once, in bash alone: this runs on every call.
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
  Bash) cmd=$(jq -r '.tool_input.command // ""' <<<"$payload") file="" ;;
  Edit | Write) cmd="" file=$(jq -r '.tool_input.file_path // ""' <<<"$payload") ;;
  *) exit 0 ;;
esac
if [[ $tool == Bash ]]; then
  [[ $cmd == *send* || $cmd == *paste* || $cmd == *panes.tsv* || $cmd == *claude* || $cmd == *launch.sh* || $cmd == *fresh-now.sh* ]] || exit 0
else
  [[ ${file##*/} == panes.tsv ]] || exit 0
fi

FLEET_TARGET=fleet::orch-guard
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
OWN_S=${ORCH_GUARD_OWN_S:-120} # an orchestrator's own typing is still its own this long
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

# The launch, relaunch, recover and chain loops running now, one "PID COMMAND" each.
loops() {
  local f c
  shopt -s nullglob
  for f in "${FLEET_PROC:-/proc}"/[0-9]*/cmdline; do
    c=$(tr '\0' ' ' <"$f" 2>/dev/null) || continue
    [[ $c =~ (^|[/ \;\&\'\"])(launch|relaunch-fresh|fresh-now|recover)\.sh([ \;\&\'\"]|$) || $c =~ [A-Za-z0-9]-chain(\.sh)?([ \;\&\'\"]|$) ]] || continue
    f=${f%/cmdline}
    printf '%s %s\n' "${f##*/}" "${c:0:120}"
  done
}

registry_guard() { # WHAT
  local running
  running=$(loops | head -3)
  if [[ -z $running ]]; then
    glog INFO "orchestrator guard: registry write, no loop running" guard=registry writer="$1"
    return
  fi
  if allowed registry; then
    glog WARN "orchestrator guard: registry write while a loop runs, allowed by ORCH_GUARD_ALLOW" guard=registry writer="$1" loops="${running//$'\n'/; }"
    return
  fi
  deny registry "panes.tsv is the registry that a running launch or chain loop reads to see its pane exit (${running//$'\n'/; }). Editing it now can leave that loop spinning for hours (11-01 11:31). Wait until it ends, or stop it first, then edit. If AJ asked for this edit now, add ORCH_GUARD_ALLOW=registry to the command." \
    writer="$1" loops="${running//$'\n'/; }"
}

if [[ $tool != Bash ]]; then
  registry_guard "$tool"
  exit 0
fi

findings=$(printf '%s' "$cmd" | python3 -I "$here/orch_guard_parse.py" 2>/dev/null) || {
  glog WARN "orchestrator guard: the command parser failed; call let through" command="${cmd:0:300}"
  exit 0
}
[[ -n $findings ]] || exit 0
if [[ $findings == UNPARSED ]]; then
  glog INFO "orchestrator guard: the command does not split (an unclosed quote); call let through" command="${cmd:0:300}"
  exit 0
fi

orch=$(orchestrator)
balance_log=$state/api-balance.log
typed=() # panes this command types into with an empty box: its own text, once sent
while IFS=$'\t' read -r kind a b; do
  case $kind in
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
    UNRESOLVED)
      deny target "this sends keys to $a, which the command does not set, so the guard cannot read that pane first. Name the pane (tmux send-keys -t %N ...), or set it in the same command (p=%N; ... or for p in %N %M; do ...)." \
        target="$a"
      ;;
    SEND)
      case $a in
        "-L "* | "-S "*) TM=("${a%% *}" "${a#* }") ;;
        t) TM=(-L "$FLEET_SOCK") ;;
        *) if [[ -n ${TMUX:-} ]]; then TM=(); else TM=(-L "$FLEET_SOCK"); fi ;;
      esac
      t() { tmux "${TM[@]}" "$@"; }
      if ! p=$(t display-message -p -t "$b" '#{pane_id}' 2>/dev/null) || [[ -z $p ]]; then
        glog INFO "orchestrator guard: the target is no pane tmux knows; call let through" target="$b" socket="${TM[*]:-env}"
        continue
      fi
      [[ $p == "$orch" ]] && continue
      s=$(screen "$p")
      if lim=$(limit_line "$s"); then
        idle=$((now - $(stopped_at "$p" "$(plain <<<"$s")")))
        if (( idle >= FRESH_AFTER_S )); then
          deny cold-limit "pane $p stopped at a usage limit $((idle / 60)) min ago (\"${lim#"${lim%%[![:space:]]*}"}\"). Its prompt cache lives an hour, so typing into it now re-caches its whole transcript: five such nudges took 38% of a five-hour window on 11-02. Relaunch it fresh from its brief instead: bash $state/fresh-now.sh $p" \
            pane="$p" idle_min="$((idle / 60))" limit="$lim"
        fi
      fi
      box=$(input_text "$s")
      if [[ -n $box ]]; then
        own=""
        { read -r own <"$state/guard/typed-${p#%}"; } 2>/dev/null
        if [[ $own =~ ^[0-9]+$ ]] && (( now - own <= OWN_S )); then
          glog INFO "orchestrator guard: send to a box holding the orchestrator's own text" guard=pending-input pane="$p" typed_s_ago="$((now - own))"
        elif allowed pending-input; then
          glog WARN "orchestrator guard: send to a box holding text, allowed by ORCH_GUARD_ALLOW" guard=pending-input pane="$p" box="${box:0:200}"
        else
          deny pending-input "pane $p's input line already holds text (\"${box:0:80}\"), typed by AJ (phone or terminal) or a report. Typing now merges your text into it (11-01 07:30). Wait until it is sent or cleared, then try again. If AJ asked you to replace it, add ORCH_GUARD_ALLOW=pending-input to the command." \
            pane="$p" box="${box:0:200}"
        fi
      else
        typed+=("$p")
      fi
      glog INFO "orchestrator guard: send checked" pane="$p" limit="${lim:+yes}" idle_min="${idle:+$((idle / 60))}" box_chars="${#box}"
      unset lim idle
      ;;
  esac
done <<<"$findings"

# Every check passed: the text this command types into an empty box is the
# orchestrator's own, so its own follow-up Enter is no collision.
if (( ${#typed[@]} )) && mkdir -p -- "$state/guard" 2>/dev/null; then
  for p in "${typed[@]}"; do printf '%s\n' "$now" >"$state/guard/typed-${p#%}"; done
fi
exit 0
