#!/usr/bin/env bash
# klepsydra's launcher, run by the overlay as
#   wsl.exe -e bash -l .claude/klepsydra-launch.sh new DIR
#   wsl.exe -e bash .claude/klepsydra-launch.sh jump SOCKET PANE
# `new` starts claude in DIR as a window of tmux session "fleet" (socket
# "klepsydra"); `jump` brings PANE's window to the front of its session. Both
# open a Windows Terminal tab (window "fleet") only when no client shows the
# session. One line out: stdout on success, stderr on failure.
set -uo pipefail

SOCKET_NAME=${KLEPSYDRA_TMUX_SOCKET:-klepsydra}
SESSION=fleet
CONF=${KLEPSYDRA_TMUX_CONF:-$HOME/.claude/klepsydra-tmux.conf}
CLAUDE=${KLEPSYDRA_CLAUDE:-claude}
WT=${KLEPSYDRA_WT:-wt.exe}
LOCK=${XDG_RUNTIME_DIR:-/tmp}/klepsydra-launch-$UID.lock

fail() { printf '%s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$2"; }

# Open a tab attached to session `target` unless a client already shows it.
show() { # target tmux-socket-args...
  local target=$1; shift
  [[ -n $(tmux "$@" list-clients -t "$target" -F x 2>/dev/null) ]] && return 0
  need "$WT" "wt.exe was not found, so no terminal tab could be opened."
  [[ -n ${WSL_DISTRO_NAME:-} ]] || fail "WSL_DISTRO_NAME is not set, so no tab could be opened."
  "$WT" -w fleet new-tab wsl.exe -d "$WSL_DISTRO_NAME" -e tmux "$@" attach -t "$target" >/dev/null 2>&1 ||
    fail "Windows Terminal did not open a tab."
}

new() { # dir
  local dir=$1 lock
  # shellcheck disable=SC2088 # a literal ~/ from the overlay
  case $dir in
    "~") dir=$HOME ;;
    "~/"*) dir=$HOME/${dir#"~/"} ;;
  esac
  [[ -d $dir ]] || fail "The folder $dir does not exist."
  need tmux "tmux is not installed in this distro."
  need "${CLAUDE%% *}" "claude was not found on PATH."
  exec {lock}>>"$LOCK" || fail "Could not open $LOCK."
  flock -w 10 "$lock" || fail "Another launch is still running."
  local -a t=(-L "$SOCKET_NAME") conf=()
  # The tmux server must not inherit the lock fd, or it holds the lock for good.
  [[ -r $CONF ]] && conf=(-f "$CONF")
  if tmux "${t[@]}" has-session -t "=$SESSION" 2>/dev/null; then
    tmux "${t[@]}" new-window -t "=$SESSION:" -c "$dir" "$CLAUDE" {lock}>&- ||
      fail "tmux could not open a window."
  else
    tmux "${t[@]}" "${conf[@]}" new-session -d -s "$SESSION" -c "$dir" "$CLAUDE" {lock}>&- ||
      fail "tmux could not start the fleet session."
  fi
  show "=$SESSION" "${t[@]}"
  printf 'Started a session in %s.\n' "$dir"
}

jump() { # socket pane
  local socket=$1 pane=$2 session
  [[ $socket =~ ^/[A-Za-z0-9._/-]{1,255}$ ]] || fail "Not a tmux socket path: $socket"
  [[ $pane =~ ^%[0-9]{1,9}$ ]] || fail "Not a tmux pane: $pane"
  need tmux "tmux is not installed in this distro."
  local -a t=(-S "$socket")
  session=$(tmux "${t[@]}" display-message -p -t "$pane" '#{session_name}' 2>/dev/null) ||
    fail "That session's tmux pane is gone."
  [[ -n $session ]] || fail "That session's tmux pane is gone."
  [[ $session =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "The tmux session's name cannot be passed to a tab."
  { tmux "${t[@]}" select-window -t "$pane" && tmux "${t[@]}" select-pane -t "$pane"; } 2>/dev/null ||
    fail "tmux could not select the window."
  show "=$session" "${t[@]}"
  printf "Selected the session's tmux window.\n"
}

case ${1:-} in
  new) (( $# == 2 )) || fail "usage: klepsydra-launch.sh new DIR"; new "$2" ;;
  jump) (( $# == 3 )) || fail "usage: klepsydra-launch.sh jump SOCKET PANE"; jump "$2" "$3" ;;
  *) fail "usage: klepsydra-launch.sh new DIR | jump SOCKET PANE" ;;
esac
