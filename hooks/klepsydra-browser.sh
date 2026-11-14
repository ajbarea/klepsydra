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
# --- end proc stat ---

# Whether `pid` is Claude Code: by name, or an npm install's
# `node .../@anthropic-ai/claude-code/cli.js`, as keryx decides.
is_claude() { # pid
  local comm="" arg part
  local -a argv=() parts=()
  { IFS= read -r comm <"$PROC_ROOT/$1/comm"; } 2>/dev/null
  [[ $comm == claude || $comm == claude-code ]] && return 0
  { mapfile -d '' -t -n 2 argv <"$PROC_ROOT/$1/cmdline"; } 2>/dev/null || return 1
  for arg in "${argv[@]}"; do
    IFS=/ read -r -a parts <<<"$arg"
    for part in "${parts[@]}"; do
      [[ $part == claude || $part == claude-code ]] && return 0
    done
  done
  return 1
}

# The MCP profile of `pid` into `profile` when it is an MCP browser's main
# process: one argument exactly --user-data-dir=<...>/ms-playwright-mcp/mcp-chrome-<hash>
# (or the older .../ms-playwright/mcp-chrome-<hash>), and no --type= (Chrome's
# renderers, zygote and GPU process carry one).
mcp_browser() { # pid
  local arg dir="" main=1
  local -a argv=()
  profile=""
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
    # SessionEnd: the hook runs under this session's Claude Code process.
    cat >/dev/null 2>&1
    me="" p=${KLEPSYDRA_PPID:-$PPID} # tests start from a fake parent
    declare -a stat=()
    for ((i = 0; i < 32 && p > 1; i++)); do
      is_claude "$p" && { me=$p; break; }
      proc_stat "$p" || break
      p=${stat[1]}
    done
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
