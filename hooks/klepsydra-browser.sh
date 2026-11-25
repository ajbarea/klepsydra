#!/usr/bin/env bash
# klepsydra-browser.sh: the browsers the Playwright MCP server opens (#379).
# The server (node .../playwright-mcp, started by a Claude Code session) runs
# Chrome as its own child, with the persistent profile
# ~/.cache/ms-playwright-mcp/mcp-chrome-<hash> (~/.cache/ms-playwright/ in
# older releases). Chrome stays open after an agent's last browser step, and a
# server killed with SIGKILL leaves it running with no parent (playwright-mcp
# #1568, playwright #43618). Only a browser's main process with such a profile
# (an exact --user-data-dir= argument, no --type=) is ever matched: AJ's own
# Chrome and Edge never are.
#
#   klepsydra-browser.sh            SessionEnd hook: close the browsers this
#                                   session's MCP server opened (TERM, then
#                                   KILL after KLEPSYDRA_BROWSER_WAIT_S, 1).
#   klepsydra-browser.sh --list     one line per open MCP browser: pid, MCP
#                                   server pid, Claude Code pid (- for none),
#                                   seconds since its profile last changed, profile.
#   klepsydra-browser.sh --reap STATE
#                                   orphans (no live MCP server, reparented to
#                                   init) get TERM, and KILL at a later call
#                                   once KLEPSYDRA_BROWSER_GRACE_S (10) have
#                                   passed; STATE keeps "pid start termed-at".
#                                   One line per action: term|kill|closed, pid,
#                                   profile, seconds since the TERM.
# Tests point KLEPSYDRA_PROC at a fake /proc, KLEPSYDRA_KILL at a fake kill
# and KLEPSYDRA_NOW at a fixed clock; KLEPSYDRA_PPID stands in for the hook's parent.
set -u
PROC_ROOT=${KLEPSYDRA_PROC:-/proc}
KILL=${KLEPSYDRA_KILL:-kill}
WAIT_S=${KLEPSYDRA_BROWSER_WAIT_S:-1}
GRACE_S=${KLEPSYDRA_BROWSER_GRACE_S:-10}
now() { printf '%s' "${KLEPSYDRA_NOW:-$(printf '%(%s)T' -1)}"; }

# --- proc stat: identical in hooks/klepsydra-fleet.sh, hooks/klepsydra-launch.sh and hooks/klepsydra-browser.sh ---
# Fields of $PROC_ROOT/<pid>/stat after the command name, into the caller's
# `stat`: [0] is the state, [1] the parent pid, [19] the start time (field 22).
# The name sits in parentheses and may itself contain spaces or ")".
proc_stat() { # pid
  local raw=""
  { IFS= read -r raw <"$PROC_ROOT/$1/stat"; } 2>/dev/null
  [[ $raw == *") "* ]] || return 1
  read -r -a stat <<<"${raw##*") "}"
  (( ${#stat[@]} > 19 ))
}

# Whether `pid` runs with start time `start`: a zombie has exited, and a pid
# with another start time is a later process.
proc_is() { # pid start
  local -a stat=()
  [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] || return 1
  proc_stat "$1" && [[ ${stat[0]} != Z && ${stat[19]} == "$2" ]]
}

# The kernel's release string ("...microsoft-standard-WSL2" under WSL), into the
# caller's `osrelease`; fails when it cannot be read.
proc_osrelease() {
  osrelease=""
  { IFS= read -r osrelease <"$PROC_ROOT/sys/kernel/osrelease"; } 2>/dev/null
  [[ -n $osrelease ]]
}
# --- end proc stat ---

# Whether `pid` is Claude Code: by name, or an npm install's
# `node .../@anthropic-ai/claude-code/cli.js`, as keryx decides.
is_claude() { # pid
  local comm="" arg part
  local -a argv=() parts=()
  { IFS= read -r comm <"$PROC_ROOT/$1/comm"; } 2>/dev/null
  [[ $comm == claude || $comm == claude-code || $comm == agy || $comm == antigravity || $comm == antigravity-cli ]] && return 0
  { mapfile -d '' -t -n 2 argv <"$PROC_ROOT/$1/cmdline"; } 2>/dev/null || return 1
  for arg in "${argv[@]}"; do
    IFS=/ read -r -a parts <<<"$arg"
    for part in "${parts[@]}"; do
      [[ $part == claude || $part == claude-code || $part == agy || $part == antigravity || $part == antigravity-cli ]] && return 0
    done
  done
  return 1
}

# The MCP profile of `pid` into `profile` when it is an MCP browser's main
# process: one argument exactly --user-data-dir=<...>/ms-playwright-mcp/mcp-chrome-<hash>
# (or the older .../ms-playwright/mcp-chrome-<hash>), and no --type= (Chrome's
# renderers, zygote and GPU process carry one).
mcp_browser() { # pid
  local arg dir="" main=1 comm="" exe=""
  local -a argv=()
  profile=""
  # Match only a Chrome-family executable (comm/exe basename chrome, chromium, msedge, headless_shell)
  { IFS= read -r comm <"$PROC_ROOT/$1/comm"; } 2>/dev/null
  case ${comm##*/} in
    chrome | chromium | msedge | headless_shell) ;;
    *)
      exe=$(readlink "$PROC_ROOT/$1/exe" 2>/dev/null) || true
      case ${exe##*/} in
        chrome | chromium | msedge | headless_shell) ;;
        *) return 1 ;;
      esac
      ;;
  esac
  { mapfile -d '' -t argv <"$PROC_ROOT/$1/cmdline"; } 2>/dev/null || return 1
  for arg in "${argv[@]}"; do
    case $arg in
      --type=*) main=0 ;;
      --user-data-dir=*) dir=${arg#--user-data-dir=} ;;
    esac
  done
  (( main )) || return 1
  [[ $dir == /*/ms-playwright-mcp/mcp-chrome-* || $dir == /*/ms-playwright/mcp-chrome-* ]] || return 1
  [[ ${dir##*/} == mcp-chrome-* && $dir != *..* ]] || return 1
  profile=$dir
}

# Whether `pid` is a Playwright MCP server: an argument naming playwright-mcp
# or mcp-server-playwright (the old name), a path through @playwright/mcp, or
# playwright's own run-mcp-server.
is_mcp_server() { # pid
  local arg
  local -a argv=()
  { mapfile -d '' -t argv <"$PROC_ROOT/$1/cmdline"; } 2>/dev/null || return 1
  for arg in "${argv[@]}"; do
    case ${arg##*/} in playwright-mcp | mcp-server-playwright | run-mcp-server) return 0 ;; esac
    [[ $arg == @playwright/mcp || $arg == @playwright/mcp@* || $arg == */@playwright/mcp/* ]] && return 0
  done
  return 1
}

# Every MCP browser as "pid start ppid server claude profile" (server and
# claude: the nearest such ancestor, or -). One grep picks the candidates, so
# a pass reads only their files.
browsers() {
  local f pid start ppid server claude p i
  local -a stat=()
  while IFS= read -r f; do
    pid=${f#"$PROC_ROOT"/} pid=${pid%/cmdline}
    [[ $pid =~ ^[0-9]+$ ]] || continue
    mcp_browser "$pid" || continue
    proc_stat "$pid" && [[ ${stat[0]} != Z ]] || continue
    start=${stat[19]} ppid=${stat[1]} server=- claude=- p=$ppid
    for ((i = 0; i < 32 && p > 1; i++)); do
      if [[ $server == - ]] && is_mcp_server "$p"; then server=$p
      elif is_claude "$p"; then claude=$p; break; fi
      proc_stat "$p" || break
      p=${stat[1]}
    done
    printf '%s %s %s %s %s %s\n' "$pid" "$start" "$ppid" "$server" "$claude" "$profile"
  done < <(grep -lsaF -- 'mcp-chrome-' "$PROC_ROOT"/[0-9]*/cmdline 2>/dev/null)
}

# Whether `ppid` is what an orphan is reparented to: pid 1, or a subreaper
# named systemd or init (WSL's).
reparented() { # ppid
  local comm=""
  (( $1 <= 1 )) && return 0
  { IFS= read -r comm <"$PROC_ROOT/$1/comm"; } 2>/dev/null
  [[ $comm == systemd || $comm == init ]]
}

# Send SIG to `pid` only while it is still the MCP browser that started at `start`.
signal() { # SIG pid start
  local profile
  proc_is "$2" "$3" && mcp_browser "$2" || return 1
  "$KILL" "-$1" "$2" 2>/dev/null
}

FLEET_STATE=${FLEET_STATE:-${HOME:-}/.local/state/fleet-orchestrator}
REGISTRY=${REGISTRY:-$FLEET_STATE/panes.tsv}

if [[ -z "${KLEPSYDRA_DIR:-}" ]]; then
  proc_osrelease
  if [[ "$osrelease" == *[Mm]icrosoft* ]]; then
    if [[ -n "${USER:-}" ]]; then
      KLEPSYDRA_DIR="/mnt/c/Users/$USER/AppData/Local/dev.ajsoftworks.klepsydra"
    fi
  else
    data_home="${HOME:-}/.local/share"
    [[ "${XDG_DATA_HOME:-}" == /* ]] && data_home="$XDG_DATA_HOME"
    [[ "$data_home" == /* ]] && KLEPSYDRA_DIR="$data_home/dev.ajsoftworks.klepsydra"
  fi
fi

# Whether `child` is equal to or a descendant of `parent` (up to 32 levels).
is_descendant() { # child parent
  local p=$1 want=$2 i
  local -a stat=()
  for ((i = 0; i < 32 && p > 1; i++)); do
    [[ $p == "$want" ]] && return 0
    proc_stat "$p" || return 1
    p=${stat[1]}
  done
  [[ $p == "$want" ]]
}

# Map a Claude/engine PID to an agent name:
# 1. Look in $KLEPSYDRA_DIR/fleet/*.json for matching .claude.pid and .ended == null:
#    - .orchestrator == true -> "heph"
#    - .fleet_name -> fleet_name
#    - panes.tsv col 4 (session id) or col 1 (.tmux.pane) -> col 2 (name)
#    - orchestrator.pane -> "heph"
#    - .name -> name
#    - first 8 chars of session id
# 2. Look in tmux panes if running
# 3. Fallback: "claude <pid>"
agent_for_pid() { # claude_pid
  local cpid=$1 f sid="" agent="" pane=""
  [[ $cpid =~ ^[0-9]+$ ]] || { printf '%s' "no session"; return 0; }
  if [[ -n ${KLEPSYDRA_DIR:-} && -d $KLEPSYDRA_DIR/fleet ]]; then
    while IFS= read -r f; do
      [[ -f $f ]] || continue
      if jq -e --argjson p "$cpid" '.claude.pid == $p and .ended == null' "$f" >/dev/null 2>&1; then
        sid=$(basename "$f" .json)
        if jq -e '.orchestrator == true' "$f" >/dev/null 2>&1; then
          agent="heph"
          break
        fi
        agent=$(jq -r '.fleet_name // empty | strings' "$f" 2>/dev/null)
        if [[ -n $agent ]]; then break; fi
        pane=$(jq -r '.tmux.pane // empty | strings' "$f" 2>/dev/null)
        if [[ -r ${REGISTRY:-$FLEET_STATE/panes.tsv} ]]; then
          agent=$(awk -F'\t' -v s="$sid" -v p="$pane" '($4 == s || ($1 == p && p != "")) { print $2; exit }' "${REGISTRY:-$FLEET_STATE/panes.tsv}" 2>/dev/null)
          if [[ -n $agent ]]; then break; fi
        fi
        if [[ -n $pane && -r ${FLEET_STATE:-}/orchestrator.pane ]] && [[ $pane == "$(<"${FLEET_STATE}/orchestrator.pane")" ]]; then
          agent="heph"
          break
        fi
        agent=$(jq -r '.name // empty | strings' "$f" 2>/dev/null)
        if [[ -n $agent ]]; then break; fi
        agent=$(jq -r '.where.worktree // empty | strings' "$f" 2>/dev/null)
        if [[ -n $agent ]]; then break; fi
        agent=$(cut -c1-8 <<<"$sid")
        break
      fi
    done < <(grep -lE -- "\"pid\": *${cpid}([^0-9]|$)" "$KLEPSYDRA_DIR"/fleet/*.json 2>/dev/null)
  fi
  if [[ -z $agent ]] && command -v tmux >/dev/null 2>&1; then
    local t_sock=${FLEET_SOCK:-klepsydra}
    local p_id p_pid w_name
    while read -r p_id p_pid w_name; do
      [[ -n $p_id ]] || continue
      if [[ $cpid == "$p_pid" ]] || is_descendant "$cpid" "$p_pid"; then
        if [[ -r ${FLEET_STATE:-}/orchestrator.pane ]] && [[ $p_id == "$(<"${FLEET_STATE}/orchestrator.pane")" ]]; then
          agent="heph"
          break
        fi
        if [[ -r ${REGISTRY:-$FLEET_STATE/panes.tsv} ]]; then
          agent=$(awk -F'\t' -v p="$p_id" '$1 == p { print $2; exit }' "${REGISTRY:-$FLEET_STATE/panes.tsv}" 2>/dev/null)
          if [[ -n $agent ]]; then break; fi
        fi
        if [[ -n $w_name ]]; then
          agent=${w_name#✳ }
          agent=${agent%% *}
          break
        fi
      fi
    done < <(tmux -L "$t_sock" list-panes -a -F '#{pane_id} #{pane_pid} #{window_name}' 2>/dev/null)
  fi
  if [[ -n $agent ]]; then
    printf '%s' "$agent"
  elif is_claude "$cpid"; then
    printf 'claude %s' "$cpid"
  else
    printf '%s' ""
  fi
}

set_session_browser() { # sid_or_file agent
  local target=$1 agent=$2 f tmp cur
  if [[ -f $target ]]; then
    f=$target
  elif [[ -n $target && -n ${KLEPSYDRA_DIR:-} && -d $KLEPSYDRA_DIR/fleet ]]; then
    f=$KLEPSYDRA_DIR/fleet/$target.json
  else
    return 0
  fi
  [[ -f $f ]] || return 0
  cur=$(jq -r '.browser // ""' "$f" 2>/dev/null) || cur=""
  if [[ $cur == "$agent" ]]; then
    return 0
  fi
  tmp=$f.$$.tmp
  if [[ -n $agent ]]; then
    jq --arg b "$agent" '.browser = $b' "$f" >"$tmp" 2>/dev/null && mv -f "$tmp" "$f"
  else
    jq 'del(.browser)' "$f" >"$tmp" 2>/dev/null && mv -f "$tmp" "$f"
  fi
}

sync_holders() {
  local active_file=${FLEET_STATE:-}/browser-active
  local closed_file=${FLEET_STATE:-}/browser-closed
  local -A current=()
  local -a stat=()
  local pid start ppid server claude dir agent sid f claude_start
  mkdir -p "${FLEET_STATE:-}" 2>/dev/null

  local -A sess_agent=() sess_sid=()
  if [[ -n ${KLEPSYDRA_DIR:-} && -d $KLEPSYDRA_DIR/fleet ]]; then
    while IFS=$'\t' read -r cpid csid _cbrowser cagent; do
      [[ -n $cpid && $cpid =~ ^[0-9]+$ ]] || continue
      sess_sid[$cpid]=$csid
      sess_agent[$cpid]=$cagent
    done < <(jq -r 'input_filename as $fn | select(.ended == null and .claude.pid != null) | [(.claude.pid // -), ($fn | split("/") | .[-1] | rtrimstr(".json")), (.browser // ""), (.fleet_name // .name // "")] | @tsv' "$KLEPSYDRA_DIR"/fleet/*.json 2>/dev/null)
  fi

  while read -r pid start ppid server claude dir; do
    [[ -n $pid && -n $dir ]] || continue
    claude_start=0
    if [[ $claude =~ ^[0-9]+$ ]]; then
      proc_stat "$claude" && claude_start=${stat[19]}
    fi
    agent=${sess_agent[$claude]:-}
    if [[ -z $agent ]]; then
      agent=$(agent_for_pid "$claude")
    fi
    current[$dir]="$pid"$'\t'"$start"$'\t'"$claude"$'\t'"$agent"$'\t'"$dir"$'\t'"$claude_start"
    if [[ -n ${sess_sid[$claude]:-} ]]; then
      set_session_browser "${sess_sid[$claude]}" "$agent"
    fi
  done < <(browsers)

  if [[ -f $active_file ]]; then
    while IFS=$'\t' read -r old_pid _start old_claude old_agent old_dir old_cstart; do
      [[ -n $old_pid && -n $old_dir ]] || continue
      if [[ -z ${current[$old_dir]:-} ]]; then
        local still_alive=0
        if [[ $old_claude =~ ^[0-9]+$ ]] && is_claude "$old_claude"; then
          if proc_stat "$old_claude"; then
            local cur_cstart=${stat[19]}
            if [[ -z $old_cstart || $old_cstart -eq 0 || $cur_cstart == "$old_cstart" ]]; then
              still_alive=1
            fi
          fi
        fi
        if (( still_alive )) && [[ -n $old_agent && $old_agent != "no session" ]]; then
          if [[ -f $closed_file ]]; then
            sed -i "\#\t${old_dir}\t#d" "$closed_file" 2>/dev/null || true
          fi
          printf '%s\t%s\t%s\t%s\t%s\n' "$old_agent" "$old_dir" "$(now)" "$old_claude" "${old_cstart:-0}" >>"$closed_file"
        fi
        if [[ -n ${sess_sid[$old_claude]:-} ]]; then
          set_session_browser "${sess_sid[$old_claude]}" ""
        fi
      fi
    done <"$active_file"
  fi

  if (( ${#current[@]} )); then
    local tmp=$active_file.$$.tmp
    for d in "${!current[@]}"; do
      printf '%s\n' "${current[$d]}"
      if [[ -f $closed_file ]]; then
        sed -i "\#\t${d}\t#d" "$closed_file" 2>/dev/null || true
        [[ -s $closed_file ]] || rm -f "$closed_file"
      fi
    done >"$tmp" && mv -f "$tmp" "$active_file"
  else
    rm -f "$active_file"
  fi
}

handle_pre_tool() {
  local payload=$1
  local tool
  tool=$(jq -r '.tool_name // .toolName // empty' <<<"$payload" 2>/dev/null)
  local closed_file=${FLEET_STATE:-}/browser-closed
  local active_file=${FLEET_STATE:-}/browser-active

  case $tool in
    *playwright* | browser_*) ;;
    *) exit 0 ;;
  esac

  local caller_pid=- caller_start=0 p c
  local -a stat=()
  p=${KLEPSYDRA_PPID:-$PPID}
  for ((c = 0; c < 16 && p > 1; c++)); do
    if is_claude "$p"; then
      caller_pid=$p
      if proc_stat "$p"; then
        caller_start=${stat[19]}
      fi
      break
    fi
    proc_stat "$p" || break
    p=${stat[1]}
  done

  if [[ $tool == *"browser_close"* ]]; then
    if [[ -n ${KLEPSYDRA_DIR:-} && -d $KLEPSYDRA_DIR/fleet && $caller_pid =~ ^[0-9]+$ ]]; then
      local f
      for f in "$KLEPSYDRA_DIR"/fleet/*.json; do
        [[ -f $f ]] || continue
        if jq -e --argjson p "$caller_pid" '.claude.pid == $p and .ended == null' "$f" >/dev/null 2>&1; then
          local sid
          sid=$(basename "$f" .json)
          set_session_browser "$sid" ""
        fi
      done
    fi
    if [[ -f $active_file ]]; then
      if [[ $caller_pid =~ ^[0-9]+$ && $caller_pid -gt 1 ]]; then
        sed -i "\#\t${caller_pid}\t#d" "$active_file" 2>/dev/null || true
        [[ -s $active_file ]] || rm -f "$active_file"
      else
        rm -f "$active_file"
      fi
    fi
    if [[ -f $closed_file ]]; then
      if [[ $caller_pid =~ ^[0-9]+$ && $caller_pid -gt 1 ]]; then
        sed -i "\#\t${caller_pid}\t#d" "$closed_file" 2>/dev/null || true
        [[ -s $closed_file ]] || rm -f "$closed_file"
      else
        rm -f "$closed_file"
      fi
    fi
    exit 0
  fi

  sync_holders

  if [[ -f $closed_file ]]; then
    local closed_agent="" hit=0
    # shellcheck disable=SC2034 # c_time absorbs timestamp column
    while IFS=$'\t' read -r c_agent c_dir c_time c_cpid c_cstart; do
      [[ -n $c_dir ]] || continue
      if [[ $caller_pid =~ ^[0-9]+$ && $caller_pid -gt 1 ]]; then
        if [[ $c_cpid == "$caller_pid" ]]; then
          if [[ $caller_start -eq 0 || -z $c_cstart || $c_cstart -eq 0 || $caller_start == "$c_cstart" ]]; then
            closed_agent=$c_agent
            hit=1
            break
          fi
        fi
      else
        closed_agent=$c_agent
        hit=1
        break
      fi
    done <"$closed_file"

    if (( hit )); then
      [[ -n $closed_agent ]] || closed_agent="an agent"
      jq -nc --arg reason "browser closed while $closed_agent held it" \
        '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": $reason}}'
      exit 0
    fi
  fi
  exit 0
}

case ${1:-} in
  --list)
    n=$(now)
    while read -r pid start ppid server claude dir; do
      idle=$(find "$dir" -maxdepth 2 -printf '%Ts\n' 2>/dev/null | sort -rn | head -1)
      [[ $idle =~ ^[0-9]+$ ]] && idle=$((n - idle)) || idle=-
      (( ${idle/-/0} < 0 )) && idle=0
      printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$server" "$claude" "$idle" "$dir"
    done < <(browsers)
    ;;
  --sync-holders)
    sync_holders
    ;;
  --holders)
    sync_holders
    declare -A seen_holders=()
    while read -r pid start ppid server claude dir; do
      [[ -n $dir ]] || continue
      [[ -z ${seen_holders[$dir]:-} ]] || continue
      seen_holders[$dir]=1
      agent=$(agent_for_pid "$claude")
      [[ -n $agent && $agent != "no session" ]] || continue
      printf '%s\t%s\n' "$dir" "$agent"
    done < <(browsers)
    ;;
  --holder)
    sync_holders
    target_dir=${2:-}
    found=0
    while read -r pid start ppid server claude dir; do
      if [[ -z $target_dir || $target_dir == "$dir" ]]; then
        agent=$(agent_for_pid "$claude")
        if [[ -n $target_dir ]]; then
          printf '%s\n' "$agent"
          found=1
          break
        else
          printf '%s\t%s\t%s\t%s\n' "$agent" "$pid" "$claude" "$dir"
        fi
      fi
    done < <(browsers)
    (( found )) || [[ -z $target_dir ]] || exit 1
    ;;
  --holder-of)
    agent_for_pid "${2:?--holder-of takes a pid}"
    printf '\n'
    ;;
  --pre-tool)
    payload=$(cat)
    handle_pre_tool "$payload"
    ;;
  --reap)
    state=${2:?--reap takes a state file}
    n=$(now)
    declare -A termed=()
    while read -r pid start at; do
      [[ $pid =~ ^[0-9]+$ && $start =~ ^[0-9]+$ && $at =~ ^[0-9]+$ ]] && termed[$pid:$start]=$at
    done 2>/dev/null <"$state"
    declare -A keep=()
    while read -r pid start ppid server claude dir; do
      [[ $server == - ]] || continue
      reparented "$ppid" || continue
      k=$pid:$start
      if [[ -n ${termed[$k]:-} ]]; then
        keep[$k]=${termed[$k]}
        if (( n - termed[$k] >= GRACE_S )) && signal KILL "$pid" "$start"; then
          printf 'kill\t%s\t%s\t%s\n' "$pid" "$dir" "$((n - termed[$k]))"
        fi
      elif signal TERM "$pid" "$start"; then
        keep[$k]=$n
        printf 'term\t%s\t%s\t0\n' "$pid" "$dir"
      fi
    done < <(browsers)
    for k in "${!termed[@]}"; do
      [[ -n ${keep[$k]:-} ]] || printf 'closed\t%s\t-\t%s\n' "${k%%:*}" "$((n - termed[$k]))"
    done
    tmp=$state.$$
    if (( ${#keep[@]} )); then
      for k in "${!keep[@]}"; do printf '%s %s %s\n' "${k%%:*}" "${k#*:}" "${keep[$k]}"; done >"$tmp" && mv -f -- "$tmp" "$state"
    else
      rm -f -- "${state:?}"
    fi
    ;;
  "")
    # PreToolUse or SessionEnd: Claude Code passes JSON payload on stdin.
    payload=""
    if [[ ! -t 0 ]]; then
      payload=$(cat 2>/dev/null)
    fi
    if [[ $payload == *'"hook_event_name":"PreToolUse"'* || $payload == *'"hookEventName":"PreToolUse"'* || $payload == *'"tool_name"'* || $payload == *'"toolName"'* ]]; then
      handle_pre_tool "$payload"
    fi
    # SessionEnd: the hook runs under this session's Claude Code process.
    me="" p=${KLEPSYDRA_PPID:-$PPID} # tests start from a fake parent
    declare -a stat=()
    for ((i = 0; i < 32 && p > 1; i++)); do
      is_claude "$p" && { me=$p; break; }
      proc_stat "$p" || break
      p=${stat[1]}
    done
    if [[ -n $me ]]; then
      if [[ -n ${KLEPSYDRA_DIR:-} && -d $KLEPSYDRA_DIR/fleet ]]; then
        while IFS= read -r f; do
          if jq -e --argjson p "$me" '.claude.pid == $p' "$f" >/dev/null 2>&1; then
            sid=$(basename "$f" .json)
            set_session_browser "$sid" ""
            break
          fi
        done < <(grep -lE -- "\"pid\": *${me}[,} ]" "$KLEPSYDRA_DIR"/fleet/*.json 2>/dev/null)
      fi
      active_file=${FLEET_STATE:-}/browser-active closed_file=${FLEET_STATE:-}/browser-closed
      if [[ -f $active_file ]]; then
        sed -i "\#\t${me}\t#d" "$active_file" 2>/dev/null || true
        [[ -s $active_file ]] || rm -f "$active_file"
      fi
      if [[ -f $closed_file ]]; then
        sed -i "\#\t${me}\t#d" "$closed_file" 2>/dev/null || true
        [[ -s $closed_file ]] || rm -f "$closed_file"
      fi
    fi
    [[ -n $me ]] || exit 0
    left=()
    while read -r pid start ppid server claude dir; do
      [[ $claude == "$me" && $server != - ]] || continue
      signal TERM "$pid" "$start" && left+=("$pid:$start")
    done < <(browsers)
    (( ${#left[@]} )) || exit 0
    # The browsers' exit, within the budget Claude Code gives SessionEnd hooks
    # (1.5 s shared, unless raised); a browser still up then gets KILL.
    deadline=$(( ${EPOCHREALTIME/./} + WAIT_S * 1000000 ))
    while :; do
      up=()
      for k in "${left[@]}"; do proc_is "${k%%:*}" "${k#*:}" && up+=("$k"); done
      (( ${#up[@]} )) || exit 0
      (( ${EPOCHREALTIME/./} < deadline )) || break
      sleep 0.1
    done
    for k in "${up[@]}"; do signal KILL "${k%%:*}" "${k#*:}"; done
    exit 0
    ;;
  *)
    echo "usage: klepsydra-browser.sh [--list | --reap STATE]" >&2
    exit 2
    ;;
esac
