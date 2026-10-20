#!/usr/bin/env bash
# klepsydra's launcher, run by the overlay as
#   wsl.exe -e bash -l .claude/klepsydra-launch.sh new DIR
#   wsl.exe -e bash .claude/klepsydra-launch.sh jump SOCKET PANE PID START
# `new` starts claude in DIR as a window of tmux session "fleet" (socket
# "klepsydra"); `jump` brings PANE's window to the front of its session, once
# PANE still hosts Claude process PID (START = /proc/PID/stat field 22). Both
# open a Windows Terminal tab (window "fleet", titled TAB_TITLE) only when no
# client shows the session and no tab opened in the last PENDING_FOR seconds is
# still starting. One line out: stdout on success, stderr on failure.
set -uo pipefail

SOCKET_NAME=${KLEPSYDRA_TMUX_SOCKET:-klepsydra} # default is FLEET_SOCKET in launch.rs
SESSION=fleet
TAB_TITLE="klepsydra sessions" # also FLEET_TAB in src-tauri/src/launch.rs
CONF=${KLEPSYDRA_TMUX_CONF:-$HOME/.claude/klepsydra-tmux.conf}
CLAUDE=${KLEPSYDRA_CLAUDE:-claude}
WT=${KLEPSYDRA_WT:-wt.exe}
UNDO=()
LOCK=${XDG_RUNTIME_DIR:-/tmp}/klepsydra-launch-$UID.lock
PROC_ROOT=/proc
# A tab opened but not yet attached: "EPOCH KEY", KEY its socket args and target.
PENDING=${XDG_RUNTIME_DIR:-/tmp}/klepsydra-tab-pending-$UID
PENDING_FOR=30
# A socket path safe to hand wt.exe, which splits its arguments at ";".
SOCKET_RE='^/[A-Za-z0-9._/-]{1,255}$'
ATTACHED=1 # cleared by open_tab until the tab's client shows up

fail() { printf '%s\n' "$*" >&2; exit 1; }
undo() { (( ${#UNDO[@]} )) && "${UNDO[@]}" >/dev/null 2>&1; } # what a failed launch created
need() { command -v "$1" >/dev/null 2>&1 || fail "$2"; }

has_client() { [[ -n $(tmux "${@:2}" list-clients -t "$1" -F x 2>/dev/null) ]]; } # target socket-args...

# Serialise launches: one tab per fleet even for back-to-back clicks.
take_lock() {
  { exec {LOCKFD}>>"$LOCK"; } 2>/dev/null || fail "Could not open $LOCK."
  flock -w 10 "$LOCKFD" || fail "Another launch is still running."
}

# Check a tab can be opened, before anything is created.
tab_preflight() {
  need "$WT" "wt.exe was not found, so no terminal tab could be opened."
  [[ ${WSL_DISTRO_NAME:-} =~ ^[A-Za-z0-9._-]{1,64}$ ]] ||
    fail "WSL_DISTRO_NAME is missing or not usable, so no tab could be opened."
}

# Set for the fleet's own tab: its title is fixed, so Jump can find it.
TITLE_ARGS=()

# Whether the stamp is ours to use: only our own regular file counts, since in
# the /tmp fallback another user could plant one, or a FIFO that would block
# its read under the lock. Anything else there is removed when it is ours.
stamp_usable() {
  [[ -f $PENDING && -O $PENDING && ! -L $PENDING ]] && return 0
  [[ -e $PENDING || -L $PENDING ]] && rm -f -- "$PENDING" 2>/dev/null
  return 1
}

# Whether a tab for `key` opened under PENDING_FOR seconds ago and has not
# attached yet: on a cold WSL a tab takes longer than open_tab waits.
tab_pending() { # key
  local at="" key="" now
  stamp_usable || return 1
  { IFS=' ' read -r at key <"$PENDING"; } 2>/dev/null
  printf -v now '%(%s)T' -1
  [[ $at =~ ^[0-9]+$ && $key == "$1" ]] && (( now >= at && now - at < PENDING_FOR ))
}

# Open a tab attached to `target`, unless one is still starting, then wait for
# its client so the next launch sees it; ATTACHED says whether it came. If
# wt.exe fails, run undo.
open_tab() { # target tmux-socket-args...
  local target=$1 key; shift
  key="$* $target"
  ATTACHED=0
  tab_pending "$key" && return 0
  # The lock fd is closed for wt.exe so a tab never outlives the lock.
  "$WT" -w fleet new-tab "${TITLE_ARGS[@]}" wsl.exe -d "$WSL_DISTRO_NAME" -e tmux "$@" attach -t "$target" \
    >/dev/null 2>&1 {LOCKFD}>&- || {
    undo
    fail "Windows Terminal did not open a tab."
  }
  if [[ ! -e $PENDING && ! -L $PENDING ]] || stamp_usable; then
    { printf '%(%s)T %s\n' -1 "$key" >"$PENDING"; } 2>/dev/null
  fi
  local _
  for _ in $(seq 50); do
    if has_client "$target" "$@"; then
      ATTACHED=1
      rm -f -- "$PENDING"
      return 0
    fi
    sleep 0.1
  done
}

new() { # dir
  local dir=$1
  # shellcheck disable=SC2088 # a literal ~/ from the overlay
  case $dir in
    "~") dir=$HOME ;;
    "~/"*) dir=$HOME/${dir#"~/"} ;;
  esac
  [[ -d $dir ]] || fail "The folder $dir does not exist."
  need tmux "tmux is not installed in this distro."
  need "${CLAUDE%% *}" "claude was not found on PATH."
  take_lock
  local -a t=(-L "$SOCKET_NAME") conf=()
  [[ -r $CONF ]] && conf=(-f "$CONF")
  local target="=$SESSION" exists=0 shown=0 win path
  tmux "${t[@]}" has-session -t "$target" 2>/dev/null && exists=1
  (( exists )) && has_client "$target" "${t[@]}" && shown=1
  (( shown )) || tab_preflight
  # The tmux server must not inherit the lock fd, or it holds the lock for good.
  if (( exists )); then
    win=$(tmux "${t[@]}" new-window -P -F '#{window_id}' -t "$target:" -c "$dir" "$CLAUDE" {LOCKFD}>&- 2>/dev/null) ||
      fail "tmux could not open a window."
    UNDO=(tmux "${t[@]}" kill-window -t "$win")
  else
    tmux "${t[@]}" "${conf[@]}" new-session -d -s "$SESSION" -c "$dir" "$CLAUDE" {LOCKFD}>&- 2>/dev/null ||
      fail "tmux could not start the fleet session."
    UNDO=(tmux "${t[@]}" kill-session -t "$target")
  fi
  if (( ! shown )); then
    # The tab attaches by the server's own path, whatever TMUX_TMPDIR it sees.
    path=$(tmux "${t[@]}" display-message -p -t "$target:" '#{socket_path}' 2>/dev/null)
    [[ $path =~ $SOCKET_RE ]] || { undo; fail "The tmux socket path cannot be passed to a tab: $path"; }
    TITLE_ARGS=(--title "$TAB_TITLE" --suppressApplicationTitle)
    open_tab "$target" -S "$path"
  fi
  if (( ATTACHED )); then
    printf 'Started a session in %s.\n' "$dir"
  else
    printf 'Started a session in %s. The terminal tab has not attached yet.\n' "$dir"
  fi
}

# --- proc stat: identical in hooks/klepsydra-fleet.sh and hooks/klepsydra-launch.sh ---
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

# Whether PID is alive with start time START and `ancestor` is PID or its ancestor.
owns_process() { # ancestor pid start
  local p=$2 _
  local -a stat=()
  proc_is "$p" "$3" || return 1
  for _ in $(seq 64); do
    [[ $p == "$1" ]] && return 0
    proc_stat "$p" || return 1
    p=${stat[1]}
    [[ $p =~ ^[1-9][0-9]*$ ]] || return 1
  done
  return 1
}

jump() { # socket pane pid start
  local socket=$1 pane=$2 pid=$3 start=$4 session pane_pid
  [[ $socket =~ $SOCKET_RE ]] || fail "Not a tmux socket path: $socket"
  [[ $pane =~ ^%[0-9]{1,9}$ ]] || fail "Not a tmux pane: $pane"
  [[ $pid =~ ^[1-9][0-9]{0,9}$ ]] || fail "Not a process id: $pid"
  [[ $start =~ ^[0-9]{1,20}$ ]] || fail "Not a process start time: $start"
  need tmux "tmux is not installed in this distro."
  local -a t=(-S "$socket")
  # tmux 3.4 exits 0 with empty output for an unknown pane.
  session=$(tmux "${t[@]}" display-message -p -t "$pane" '#{session_name}' 2>/dev/null) ||
    fail "That session's tmux pane is gone."
  [[ -n $session ]] || fail "That session's tmux pane is gone."
  [[ $session =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "The tmux session's name cannot be passed to a tab."
  pane_pid=$(tmux "${t[@]}" display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
  [[ $pane_pid =~ ^[1-9][0-9]*$ ]] || fail "That session's tmux pane is gone."
  owns_process "$pane_pid" "$pid" "$start" ||
    fail "That session's tmux pane now belongs to another session."
  { tmux "${t[@]}" select-window -t "$pane" && tmux "${t[@]}" select-pane -t "$pane"; } 2>/dev/null ||
    fail "tmux could not select the window."
  take_lock
  if ! has_client "=$session" "${t[@]}"; then
    tab_preflight
    # Only the fleet's own server gets the fixed title; another stays a plain tab.
    [[ ${socket##*/} == "$SOCKET_NAME" ]] && TITLE_ARGS=(--title "$TAB_TITLE" --suppressApplicationTitle)
    open_tab "=$session" "${t[@]}"
  fi
  printf "Selected the session's tmux window.\n"
}

case ${1:-} in
  new) (( $# == 2 )) || fail "usage: klepsydra-launch.sh new DIR"; new "$2" ;;
  jump) (( $# == 5 )) || fail "usage: klepsydra-launch.sh jump SOCKET PANE PID START"; jump "$2" "$3" "$4" "$5" ;;
  *) fail "usage: klepsydra-launch.sh new DIR | jump SOCKET PANE PID START" ;;
esac
