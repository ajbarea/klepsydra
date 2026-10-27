#!/usr/bin/env bash
# klepsydra's launcher, run by the overlay as
#   wsl.exe -e bash -l .claude/klepsydra-launch.sh new DIR
#   wsl.exe -e bash .claude/klepsydra-launch.sh jump|end|interrupt|wrapup SOCKET PANE PID START
# `new` starts claude in DIR as a window of tmux session "fleet" (socket
# "klepsydra"); `jump` brings PANE's window to the front of its session, once
# PANE still hosts Claude process PID (START = /proc/PID/stat field 22).
# `end` types /exit into that Claude Code, `wrapup` types /klepsydra-wrapup
# and `interrupt` presses Esc there, on klepsydra's own tmux server only. `new` and `jump` open a Windows Terminal tab (window "fleet", titled TAB_TITLE) only when no
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
END_WAIT=${KLEPSYDRA_END_WAIT:-10} # seconds `end` waits for Claude to exit
[[ $END_WAIT =~ ^[1-9][0-9]{0,2}$ ]] || END_WAIT=10 # it reaches $(( )), which would run a crafted value
# Claude Code's input line as capture-pane shows it: U+276F and a no-break
# space at the left edge, a rule (U+2500) on the lines above and below.
PROMPT_MARK=$'\xe2\x9d\xaf\xc2\xa0'
RULE=$'\xe2\x94\x80'

fail() { printf '%s\n' "$*" >&2; exit 1; }
undo() { (( ${#UNDO[@]} )) && "${UNDO[@]}" >/dev/null 2>&1; } # what a failed launch created
need() { command -v "$1" >/dev/null 2>&1 || fail "$2"; }

has_client() { [[ -n $(tmux "${@:2}" list-clients -t "$1" -F x 2>/dev/null) ]]; } # target socket-args...

# Serialise launches: one tab per fleet even for back-to-back clicks.
take_lock() { # [what to say when another holds it for 10 s]
  { exec {LOCKFD}>>"$LOCK"; } 2>/dev/null || fail "Could not open $LOCK."
  flock -w 10 "$LOCKFD" || fail "${1:-Another launch is still running.}"
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

# Refuse unless PANE on SOCKET still hosts Claude process PID with START.
# Sets the caller's `t` (tmux's socket args) and `session` (PANE's session).
check_pane() { # socket pane pid start
  local socket=$1 pane=$2 pid=$3 start=$4 pane_pid
  [[ $socket =~ $SOCKET_RE ]] || fail "Not a tmux socket path: $socket"
  [[ $pane =~ ^%[0-9]{1,9}$ ]] || fail "Not a tmux pane: $pane"
  [[ $pid =~ ^[1-9][0-9]{0,9}$ ]] || fail "Not a process id: $pid"
  [[ $start =~ ^[0-9]{1,20}$ ]] || fail "Not a process start time: $start"
  need tmux "tmux is not installed in this distro."
  t=(-S "$socket")
  # tmux 3.4 exits 0 with empty output for an unknown pane.
  session=$(tmux "${t[@]}" display-message -p -t "$pane" '#{session_name}' 2>/dev/null) ||
    fail "That session's tmux pane is gone."
  [[ -n $session ]] || fail "That session's tmux pane is gone."
  [[ $session =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "The tmux session's name cannot be passed to a tab."
  pane_pid=$(tmux "${t[@]}" display-message -p -t "$pane" '#{pane_pid}' 2>/dev/null)
  [[ $pane_pid =~ ^[1-9][0-9]*$ ]] || fail "That session's tmux pane is gone."
  owns_process "$pane_pid" "$pid" "$start" ||
    fail "That session's tmux pane now belongs to another session."
}

jump() { # socket pane pid start
  local socket=$1 pane=$2 session
  local -a t=()
  check_pane "$@"
  { tmux "${t[@]}" select-window -t "$pane" && tmux "${t[@]}" select-pane -t "$pane"; } 2>/dev/null ||
    fail "tmux could not select the window."
  # An attached tab needs no lock; one missing is checked again under it.
  has_client "=$session" "${t[@]}" && { printf "Selected the session's tmux window.\n"; return 0; }
  take_lock "Selected the session's tmux window, but another click is still opening a terminal tab. Try again."
  if ! has_client "=$session" "${t[@]}"; then
    tab_preflight
    # Only the fleet's own server gets the fixed title; another stays a plain tab.
    [[ ${socket##*/} == "$SOCKET_NAME" ]] && TITLE_ARGS=(--title "$TAB_TITLE" --suppressApplicationTitle)
    open_tab "=$session" "${t[@]}"
  fi
  printf "Selected the session's tmux window.\n"
}

# Typing into a session is for klepsydra's own server; a hand-started tmux is
# the user's.
fleet_pane() { # socket pane pid start
  check_pane "$@"
  [[ ${1##*/} == "$SOCKET_NAME" ]] ||
    fail "That session is not in klepsydra's tmux, so klepsydra will not type into it."
}

# What a refusal tells the user to do instead, per verb; each verb sets its own.
open_to="end it"
busy="That session is already being ended or interrupted."

# A pane in copy mode swallows keys as copy-mode commands, so leave it first.
leave_modes() {
  local _
  for _ in $(seq 5); do
    [[ $(tmux "${t[@]}" display-message -p -t "$pane" '#{pane_in_mode}' 2>/dev/null) == 1 ]] || return 0
    tmux "${t[@]}" send-keys -t "$pane" -X cancel 2>/dev/null || return 0
  done
  fail "The session's pane is in a tmux mode that would not close. Open its terminal to $open_to."
}

# One End, Interrupt or Wrap up per pane: an End the app gave up on may still
# be running. The pane is checked again under the lock, as such an End may
# just have finished.
own_pane() { # socket pane pid start
  fleet_pane "$@"
  local file=${XDG_RUNTIME_DIR:-/tmp}/klepsydra-pane-$UID-${pane#%}.lock
  { exec {PANEFD}>>"$file"; } 2>/dev/null || fail "Could not open $file."
  flock -n "$PANEFD" || fail "$busy"
  fleet_pane "$@"
}

keys() { tmux "${t[@]}" send-keys -t "$pane" "$@" 2>/dev/null || fail "tmux could not send keys to the session."; }

screen() { LC_ALL=C.UTF-8 tmux "${t[@]}" capture-pane -p -t "$pane" 2>/dev/null; }

# Whether PANE's input line reads exactly COMMAND, between its rules: not a
# line of the transcript, not the command menu's entry.
reads() { # command
  screen | awk -v mark="$PROMPT_MARK" -v rule="$RULE" -v want="$1" '
    { line[NR] = $0 }
    END {
      for (i = 2; i < NR; i++) {
        if (index(line[i - 1], rule) != 1 || index(line[i + 1], rule) != 1) continue
        if (index(line[i], mark want) == 1 && substr(line[i], length(mark want) + 1) ~ /^ *$/) found = 1
      }
      exit !found
    }'
}

# What tells a running turn, around the input box: "S" + the first line above
# it that starts in column 0 (Claude Code's spinner, "✢ Pollinating… (5m 2s ·
# ↓ 9.8k tokens)"; tips and notices under the spinner are indented, the
# transcript's last line is not), and "F" + each footer line below it, where
# "esc to interrupt" shows while a tool runs. Fails when no input box is on
# the screen. Lines the terminal wrapped are joined first, so a long tip's
# tail never reads as a column-0 line.
around_box() {
  LC_ALL=C.UTF-8 tmux "${t[@]}" capture-pane -p -J -t "$pane" 2>/dev/null | awk -v mark="$PROMPT_MARK" -v rule="$RULE" '
    { line[NR] = $0 }
    END {
      for (i = 2; i < NR; i++)
        if (index(line[i - 1], rule) == 1 && index(line[i + 1], rule) == 1 && index(line[i], mark) == 1) box = i - 1
      if (!box) exit 1
      for (j = box - 1; j >= 1; j--) if (line[j] ~ /^[^ \t]/) { print "S" line[j]; break }
      for (k = box + 3; k <= NR; k++) print "F" line[k]
    }'
}

# Whether the session is mid-turn: a spinner as the first column-0 line above
# its box, or the esc hint in its footer. The transcript above is never read,
# so one that quotes a spinner or the hint does not count.
mid_turn() {
  local around
  around=$(around_box) || fail "The session's input box is not on its screen, so klepsydra did not type into it. Open its terminal to $open_to."
  LC_ALL=C.UTF-8 grep -qE '^S. .+… \(|^F.*esc to (interrupt|cancel)' <<<"$around"
}

# Type COMMAND into the cleared input line and press Enter, only once the line
# reads exactly COMMAND, over 50 reads 0.1 s apart (at least 5 s on a busy
# machine); else clear it again and fail.
run_command() { # command
  local _
  keys -l "$1"
  for _ in $(seq 50); do reads "$1" && break; sleep 0.1; done
  if ! reads "$1"; then
    keys C-c
    fail "The session's prompt did not read $1, so Enter was not pressed. Its prompt may be in vim editor mode, or Claude Code's layout changed. Open its terminal to do it there."
  fi
  keys Enter
}

end_session() { # socket pane pid start
  local socket=$1 pane=$2 pid=$3 start=$4 session _
  local -a t=()
  own_pane "$@"
  leave_modes
  # Esc closes a dialog, declines a pending permission or stops a turn, so
  # Enter cannot answer one; Ctrl+C then clears a draft (Up brings it back).
  keys Escape
  sleep 1
  keys C-c
  sleep 0.5
  run_command /exit
  for _ in $(seq $((END_WAIT * 10))); do
    proc_is "$pid" "$start" || { printf 'Ended the session.\n'; return 0; }
    sleep 0.1
  done
  fail "Sent /exit, but the session is still running. Open its terminal to see why."
}

# Ask an idle session to wrap up. A session mid-turn is refused, since
# Ctrl+C would stop its turn; the Stop hook asks it when the turn ends.
wrapup() { # socket pane pid start
  local socket=$1 pane=$2 session
  local -a t=()
  local open_to="ask it there: type /klepsydra-wrapup"
  local busy="klepsydra is already sending that session something; ask it by hand: type /klepsydra-wrapup in its terminal."
  own_pane "$@"
  leave_modes
  mid_turn && fail "The session is mid-turn; it is asked when the turn ends."
  # One Ctrl+C clears a draft (Up brings it back); on an idle prompt it does nothing else.
  keys C-c
  sleep 0.5
  run_command /klepsydra-wrapup
  printf 'Asked the session to wrap up.\n'
}

interrupt() { # socket pane pid start
  local socket=$1 pane=$2 session
  local -a t=()
  local open_to="interrupt it"
  own_pane "$@"
  leave_modes
  keys Escape
  printf 'Sent Esc to the session.\n'
}

case ${1:-} in
  new) (( $# == 2 )) || fail "usage: klepsydra-launch.sh new DIR"; new "$2" ;;
  jump) (( $# == 5 )) || fail "usage: klepsydra-launch.sh jump SOCKET PANE PID START"; jump "$2" "$3" "$4" "$5" ;;
  end) (( $# == 5 )) || fail "usage: klepsydra-launch.sh end SOCKET PANE PID START"; end_session "$2" "$3" "$4" "$5" ;;
  wrapup) (( $# == 5 )) || fail "usage: klepsydra-launch.sh wrapup SOCKET PANE PID START"; wrapup "$2" "$3" "$4" "$5" ;;
  interrupt) (( $# == 5 )) || fail "usage: klepsydra-launch.sh interrupt SOCKET PANE PID START"; interrupt "$2" "$3" "$4" "$5" ;;
  *) fail "usage: klepsydra-launch.sh new DIR | jump|end|interrupt|wrapup SOCKET PANE PID START" ;;
esac
