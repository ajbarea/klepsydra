#!/usr/bin/env bash
# klepsydra's launcher, run by the overlay as
#   wsl.exe -e bash -l .claude/klepsydra-launch.sh new DIR
#   wsl.exe -e bash .claude/klepsydra-launch.sh jump SOCKET PANE PID START
# `new` starts claude in DIR as a window of tmux session "fleet" (socket
# "klepsydra"); `jump` brings PANE's window to the front of its session, once
# PANE still hosts Claude process PID (START = /proc/PID/stat field 22). Both
# open a Windows Terminal tab (window "fleet", titled TAB_TITLE) only when no
# client shows the session. One line out: stdout on success, stderr on failure.
set -uo pipefail

SOCKET_NAME=${KLEPSYDRA_TMUX_SOCKET:-klepsydra} # default is FLEET_SOCKET in launch.rs
SESSION=fleet
TAB_TITLE="klepsydra fleet" # also FLEET_TAB in src-tauri/src/launch.rs
CONF=${KLEPSYDRA_TMUX_CONF:-$HOME/.claude/klepsydra-tmux.conf}
CLAUDE=${KLEPSYDRA_CLAUDE:-claude}
WT=${KLEPSYDRA_WT:-wt.exe}
UNDO=()
LOCK=${XDG_RUNTIME_DIR:-/tmp}/klepsydra-launch-$UID.lock

fail() { printf '%s\n' "$*" >&2; exit 1; }
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

# Open a tab attached to `target`, then wait for its client so the next launch
# sees it. If wt.exe fails, run the cleanup command in "${UNDO[@]}".
open_tab() { # target tmux-socket-args...
  local target=$1; shift
  # The lock fd is closed for wt.exe so a tab never outlives the lock.
  "$WT" -w fleet new-tab "${TITLE_ARGS[@]}" wsl.exe -d "$WSL_DISTRO_NAME" -e tmux "$@" attach -t "$target" \
    >/dev/null 2>&1 {LOCKFD}>&- || {
    (( ${#UNDO[@]} )) && "${UNDO[@]}" >/dev/null 2>&1
    fail "Windows Terminal did not open a tab."
  }
  local _
  for _ in $(seq 50); do has_client "$target" "$@" && return 0; sleep 0.1; done
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
  local target="=$SESSION" exists=0 shown=0 win
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
  TITLE_ARGS=(--title "$TAB_TITLE" --suppressApplicationTitle)
  (( shown )) || open_tab "$target" "${t[@]}"
  printf 'Started a session in %s.\n' "$dir"
}

# Whether PID is alive with start time START and `ancestor` is PID or its ancestor.
owns_process() { # ancestor pid start
  local raw="" p=$2
  local -a stat=()
  { IFS= read -r raw <"/proc/$p/stat"; } 2>/dev/null
  [[ $raw == *") "* ]] || return 1
  read -r -a stat <<<"${raw##*") "}"
  (( ${#stat[@]} > 19 )) && [[ ${stat[0]} != Z && ${stat[19]} == "$3" ]] || return 1
  for _ in $(seq 64); do
    [[ $p == "$1" ]] && return 0
    { IFS= read -r raw <"/proc/$p/stat"; } 2>/dev/null
    [[ $raw == *") "* ]] || return 1
    read -r -a stat <<<"${raw##*") "}"
    p=${stat[1]:-0}
    [[ $p =~ ^[1-9][0-9]*$ ]] || return 1
  done
  return 1
}

jump() { # socket pane pid start
  local socket=$1 pane=$2 pid=$3 start=$4 session pane_pid
  [[ $socket =~ ^/[A-Za-z0-9._/-]{1,255}$ ]] || fail "Not a tmux socket path: $socket"
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
