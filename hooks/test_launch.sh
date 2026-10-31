#!/usr/bin/env bash
# Tests for the launcher against a private tmux server and a stub wt.exe.
# Run: bash hooks/test_launch.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
launch="$here/klepsydra-launch.sh"
work=$(mktemp -d)
sock="kl-test-$$" sock2="kl-test2-$$" sock3="kl-test3-$$"
sockdir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)" # where tmux puts a -L socket
clients=()
cleanup() {
  for p in "${clients[@]}" ${holder:-} $(cat "$work/stub-pids" 2>/dev/null); do kill "$p" 2>/dev/null; done
  tmux -L "$sock" kill-server 2>/dev/null
  tmux -L "$sock2" kill-server 2>/dev/null
  tmux -L "$sock3" kill-server 2>/dev/null
  rm -f -- "$sockdir/$sock" "$sockdir/$sock2" "$sockdir/$sock3"
  rm -rf "$work"
}
trap cleanup EXIT

pass=0 fail=0
check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}

mkdir -p "$work/bin" "$work/home" "$work/repos/my repos"
cat >"$work/bin/wt.exe" <<'EOF'
#!/usr/bin/env bash
# Logs its argv, then attaches like the real tab: WT_DELAY seconds after returning,
# with Windows Terminal's TERM, whatever the runner has (CI sets none).
# WT_DELAY=never is a tab that never attaches.
printf '%s\n' "$*" >>"$WT_LOG"
[[ ${WT_DELAY:-} == never ]] && exit 0
args=("$@")
for i in "${!args[@]}"; do [[ ${args[i]} == -e ]] && { cmd=("${args[@]:i+1}"); break; }; done
(
  sleep "${WT_DELAY:-0}"
  TERM=xterm-256color exec script -qfc "$(printf '%q ' "${cmd[@]}")" /dev/null
) >/dev/null 2>&1 </dev/null &
echo $! >>"$WT_PIDS"
EOF
chmod +x "$work/bin/wt.exe"
export WT_LOG="$work/wt.log" WT_PIDS="$work/stub-pids" HOME="$work/home" XDG_RUNTIME_DIR="$work" WSL_DISTRO_NAME=Test
export KLEPSYDRA_TMUX_SOCKET="$sock" KLEPSYDRA_TMUX_CONF="$here/klepsydra-tmux.conf"
export KLEPSYDRA_CLAUDE="sleep 600" KLEPSYDRA_WT="$work/bin/wt.exe"
: >"$WT_LOG"

t() { tmux -L "$sock" "$@"; }
# kill-server returns before the server exits; a launch that reached the dying
# server would lose its session with it, so wait until the process is gone.
stop_server() {
  local pid _
  pid=$(t display -p '#{pid}' 2>/dev/null) || return 0
  t kill-server 2>/dev/null
  for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
}
windows() { t list-windows -t =fleet 2>/dev/null | wc -l; }
tabs() { wc -l <"$WT_LOG"; }
attach() { # a real client on a pty, like the tab would be
  TERM=xterm-256color script -qfc "tmux -L $sock attach -t =fleet" /dev/null >/dev/null 2>&1 </dev/null &
  clients+=($!)
  for _ in $(seq 50); do [[ -n $(t list-clients -t =fleet 2>/dev/null) ]] && return; sleep 0.1; done
}
pane_pid() { t display -p -t "$1" '#{pane_pid}'; }
stat_fields() { # pid index...: /proc/PID/stat fields after the command name (index 0 is field 3)
  local raw st i vals=(); raw=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  read -r -a st <<<"${raw##*") "}"; shift
  for i; do vals+=("${st[i]}"); done
  echo "${vals[*]}"
}
pstart() { stat_fields "$1" 19; } # pid: field 22, as proc_stat in the launcher's proc stat block reads it
jmp() { bash "$launch" jump "$socket" "$1" "$2" "$3"; } # pane pid start
detach_all() {
  for p in "${clients[@]}" $(cat "$WT_PIDS" 2>/dev/null); do kill "$p" 2>/dev/null; done
  clients=(); : >"$WT_PIDS"
  for _ in $(seq 50); do [[ -z $(t list-clients -t =fleet 2>/dev/null) ]] && return; sleep 0.1; done
}

echo "new"
out=$(bash "$launch" new "$work/repos" 2>&1); rc=$?
check "first: exit 0" "$rc" "0"
check "first: says where" "$out" "Started a session in $work/repos."
check "first: one window" "$(windows)" "1"
check "first: one tab" "$(tabs)" "1"
check "first: the tab attaches by the socket's path" "$(head -1 "$WT_LOG")" \
  "-w fleet new-tab --title klepsydra sessions --suppressApplicationTitle wsl.exe -d Test -e tmux -S $(t display -p '#{socket_path}') attach -t =fleet"
check "first: an attached tab leaves no pending stamp" "$([[ -e $work/klepsydra-tab-pending-$UID ]] && echo left)" ""
check "first: conf loaded" "$(t show -gv automatic-rename-format)" "#{pane_title}"
check "first: focus events on" "$(t show -gv focus-events)" "on"
attach
bash "$launch" new "$work/repos" >/dev/null 2>&1
check "second: two windows" "$(windows)" "2"
check "second: no new tab" "$(tabs)" "1"
detach_all
check "closed tab: sessions survive" "$(windows)" "2"
bash "$launch" new "$work/repos" >/dev/null 2>&1
check "closed tab: a window" "$(windows)" "3"
check "closed tab: one tab to reattach" "$(tabs)" "2"
# shellcheck disable=SC2088 # the overlay passes a literal ~
bash "$launch" new "~/../repos/my repos" >/dev/null 2>&1; rc=$?
check "folder with a space: exit 0" "$rc" "0"
check "folder with a space: cwd" "$(t display -p -t =fleet: '#{pane_current_path}')" "$work/repos/my repos"
out=$(bash "$launch" new "$work/nowhere" 2>&1); rc=$?
check "missing folder: exit 1" "$rc" "1"
check "missing folder: says so" "$out" "The folder $work/nowhere does not exist."
out=$(KLEPSYDRA_CLAUDE=no-such-claude bash "$launch" new "$work/repos" 2>&1); rc=$?
check "no claude: exit 1" "$rc" "1"
check "no claude: says so" "$out" "claude was not found on PATH."

stop_server; : >"$WT_LOG"
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
wait
check "concurrent: one session" "$(t list-sessions | wc -l)" "1"
check "concurrent: two windows" "$(windows)" "2"
check "concurrent: one tab" "$(tabs)" "1"

echo "jump"
first=$(t list-panes -s -t =fleet -F '#{pane_id}' | head -1)
socket=$(t display -p '#{socket_path}')
second=$(t list-panes -s -t =fleet -F '#{pane_id}' | sed -n 2p)
fpid=$(pane_pid "$first"); fstart=$(pstart "$fpid")
spid=$(pane_pid "$second"); sstart=$(pstart "$spid")
attach; : >"$WT_LOG"
out=$(jmp "$first" "$fpid" "$fstart" 2>&1); rc=$?
check "jump: exit 0" "$rc" "0"
check "jump: says so" "$out" "Selected the session's tmux window."
check "jump: active pane" "$(t display -p -t =fleet: '#{pane_id}')" "$first"
check "jump with a client: no tab" "$(tabs)" "0"
t select-window -t "$second"
out=$(jmp "$first" "$spid" "$sstart" 2>&1); rc=$?
check "another pane's process: exit 1" "$rc" "1"
check "another pane's process: says so" "$out" "That session's tmux pane now belongs to another session."
check "another pane's process: no window change" "$(t display -p -t =fleet: '#{pane_id}')" "$second"
out=$(jmp "$first" 2999999 "$fstart" 2>&1); rc=$?
check "dead pid: exit 1" "$rc" "1"
check "dead pid: says so" "$out" "That session's tmux pane now belongs to another session."
out=$(jmp "$first" "$fpid" "$((fstart + 1))" 2>&1); rc=$?
check "reused pid: exit 1" "$rc" "1"
check "reused pid: says so" "$out" "That session's tmux pane now belongs to another session."
for bad in 12a "" 0 01; do
  out=$(jmp "$first" "$bad" "$fstart" 2>&1); rc=$?
  check "bad pid '$bad': exit 1" "$rc" "1"
  check "bad pid '$bad': says so" "$out" "Not a process id: $bad"
done
for bad in 12a ""; do
  out=$(jmp "$first" "$fpid" "$bad" 2>&1); rc=$?
  check "bad start '$bad': says so" "$out" "Not a process start time: $bad"
done
check "refusals: window unchanged" "$(t display -p -t =fleet: '#{pane_id}')" "$second"
# Run "$@" every 0.1 s until it succeeds, at most 10 s.
until_true() { local _; for _ in $(seq 100); do "$@" && return 0; sleep 0.1; done; return 1; }
has_child() { [[ -n $(pgrep -P "$1") ]]; }
zombie_child() { local c; c=$(pgrep -P "$1" | head -1); [[ -n $c && $(awk '{print $3}' "/proc/$c/stat" 2>/dev/null) == Z ]]; }
# The walk: claude is a descendant of pane_pid, not pane_pid itself.
leaf() { local p=$1 c _; for _ in 1 2 3 4 5 6 7 8; do c=$(pgrep -P "$p" | head -1); [[ -n $c ]] || break; p=$c; done; echo "$p"; }
deep=$(t new-window -d -P -F '#{pane_id}' -t =fleet: "bash -c 'sleep 600; true'")
until_true has_child "$(pane_pid "$deep")"
dleaf=$(leaf "$(pane_pid "$deep")"); dstart=$(pstart "$dleaf")
check "descendant: leaf is not the pane pid" "$([[ $dleaf != "$(pane_pid "$deep")" ]] && echo yes)" "yes"
out=$(jmp "$deep" "$dleaf" "$dstart" 2>&1); rc=$?
check "descendant: exit 0" "$rc" "0"
check "descendant: active pane" "$(t display -p -t =fleet: '#{pane_id}')" "$deep"
out=$(jmp "$first" "$dleaf" "$dstart" 2>&1); rc=$?
check "descendant against another pane: refused" "$out" "That session's tmux pane now belongs to another session."
# A zombie child is not Claude.
zp=$(t new-window -d -P -F '#{pane_id}' -t =fleet: "bash -c 'sleep 0.2 & exec sleep 600'")
until_true zombie_child "$(pane_pid "$zp")"
zleaf=$(leaf "$(pane_pid "$zp")")
check "zombie: made" "$(awk '{print $3}' "/proc/$zleaf/stat")" "Z"
out=$(jmp "$zp" "$zleaf" "$(pstart "$zleaf")" 2>&1); rc=$?
check "zombie: refused" "$out" "That session's tmux pane now belongs to another session."
t select-window -t "$second"
out=$(bash "$launch" jump "$socket" "$first" "$fpid" 2>&1); rc=$?
check "missing start: exit 1" "$rc" "1"
out=$(jmp '%3;x' "$fpid" "$fstart" 2>&1); rc=$?
check "bad pane: exit 1" "$rc" "1"
check "bad pane: says so" "$out" "Not a tmux pane: %3;x"
out=$(bash "$launch" jump "rel/sock" "$first" "$fpid" "$fstart" 2>&1); rc=$?
check "relative socket: exit 1" "$rc" "1"
check "relative socket: says so" "$out" "Not a tmux socket path: rel/sock"
check "bad arguments: no tab" "$(tabs)" "0"
out=$(jmp '%99999' "$fpid" "$fstart" 2>&1); rc=$?
check "unknown pane: exit 1" "$rc" "1"
check "unknown pane: says so" "$out" "That session's tmux pane is gone."
detach_all
jmp "$first" "$fpid" "$fstart" >/dev/null 2>&1
check "jump without a client: one tab" "$(tabs)" "1"
check "jump's tab names the socket" "$(head -1 "$WT_LOG")" \
  "-w fleet new-tab --title klepsydra sessions --suppressApplicationTitle wsl.exe -d Test -e tmux -S $socket attach -t =fleet"
# A hand-started tmux on another socket gets a plain tab.
tmux -L "$sock2" -f /dev/null new-session -d -s hand "sleep 600"
socket2=$(tmux -L "$sock2" display -p '#{socket_path}')
pane2=$(tmux -L "$sock2" display -p '#{pane_id}')
p2=$(tmux -L "$sock2" display -p '#{pane_pid}')
: >"$WT_LOG"
out=$(bash "$launch" jump "$socket2" "$pane2" "$p2" "$(pstart "$p2")" 2>&1); rc=$?
check "other socket: exit 0" "$rc" "0"
check "other socket: a plain tab" "$(head -1 "$WT_LOG")" \
  "-w fleet new-tab wsl.exe -d Test -e tmux -S $socket2 attach -t =hand"
tmux -L "$sock2" kill-server 2>/dev/null
# The user's ~/.tmux.conf can turn focus events back off.
printf 'set -g focus-events off\n' >"$HOME/.tmux.conf"
tmux -L "$sock3" -f "$KLEPSYDRA_TMUX_CONF" new-session -d -s optout "sleep 600"
check "the user's tmux.conf turns focus events off" "$(tmux -L "$sock3" show -gv focus-events)" "off"
check "the user's tmux.conf keeps the window names" "$(tmux -L "$sock3" show -gv automatic-rename-format)" "#{pane_title}"
tmux -L "$sock3" kill-server 2>/dev/null; rm -f "$HOME/.tmux.conf"
detach_all; : >"$WT_LOG"
bash "$launch" jump "$socket" "$first" "$fpid" "$fstart" >/dev/null 2>&1
check "fleet socket: titled tab" "$(head -1 "$WT_LOG" | grep -c -- "^-w fleet new-tab --title klepsydra sessions --suppressApplicationTitle wsl.exe")" "1"
echo "end and interrupt"
# Draws Claude Code's input box as capture-pane shows it (U+276F, a no-break
# space, rules above and below) and logs each key that matters and what Enter
# submits. FAKE_DROP is a key it loses, as keys typed during a redraw are;
# FAKE_STAY makes it ignore /exit.
cat >"$work/bin/fake-claude" <<'EOF'
#!/usr/bin/env bash
log=$1 buf=""
stty -icanon -echo -isig
mark=$'\xe2\x9d\xaf\xc2\xa0'
draw() {
  # FAKE_TAIL: a recorded screen tail, its input line showing what was typed.
  if [[ -n ${FAKE_TAIL:-} ]]; then
    printf '\033[2J\033[Hhistory\n'
    while IFS= read -r line; do
      [[ $line == "$mark"* ]] && line=$mark$buf
      printf '%s\n' "$line"
    done <"$FAKE_TAIL"
    return
  fi
  printf '\033[2J\033[Hhistory\n\xe2\x9d\xaf\xc2\xa0/exit\nout\n'
  # An older Claude Code's spinner, with its hint, just above the input box.
  [[ -z ${FAKE_BUSY:-} ]] || printf '\xe2\x9c\xbb Thinking\xe2\x80\xa6 (12s \xc2\xb7 esc to interrupt)\n'
  printf '\xe2\x94\x80\xe2\x94\x80\n\xe2\x9d\xaf\xc2\xa0%s\n\xe2\x94\x80\xe2\x94\x80\n  \xe2\x9d\xaf /exit   Exit the CLI\n' "$buf"
}
draw
# dd, not read -n: bash's read turns ISIG back on, and Ctrl+C would kill it.
while c=$(dd bs=1 count=1 2>/dev/null); do
  case $c in
    "") printf 'submit:%s\n' "$buf" >>"$log"; [[ $buf == /exit && -z ${FAKE_STAY:-} ]] && exit 0; buf="" ;;
    $'\e') printf 'esc\n' >>"$log" ;;
    $'\x03') printf 'ctrl-c\n' >>"$log"; buf="" ;;
    "${FAKE_DROP:-}") ;;
    *) buf+=$c ;;
  esac
  draw
done
EOF
chmod +x "$work/bin/fake-claude"
export KLEPSYDRA_END_WAIT=3
fake() { # [env...]: a fleet window running the fake; prints its pane id
  local p _
  p=$(t new-window -d -P -F '#{pane_id}' -t =fleet: "env $* $work/bin/fake-claude $work/fake.log")
  for _ in $(seq 50); do t capture-pane -p -t "$p" | grep -q '^history' && break; sleep 0.1; done
  echo "$p"
}
send() { bash "$launch" "$1" "$socket" "$2" "$(pane_pid "$2")" "$(pstart "$(pane_pid "$2")")"; } # verb pane
alive() { [[ -n $(t display -p -t "$1" '#{pane_id}' 2>/dev/null) ]] && echo alive || echo gone; }
# The session is gone once its process is: tmux closes the pane, or, under
# load, has seen the terminal close but not yet reaped the process (#134: dead=1
# and no status after 10 s). A non-zero exit keeps the pane (remain-on-exit
# failed) and is not gone. Waits up to 20 s; a pane still there says why.
gone() { # pane pid start
  local why
  { until_true ended "$@" || until_true ended "$@"; } && { echo gone; return; }
  why=$(t display -p -t "$1" 'dead=#{pane_dead} status=#{pane_dead_status} signal=#{pane_dead_signal}')
  ended "$@" && { echo gone; return; }
  echo "alive ($why; pid $2 $(proc_state "$2" "$3"))"
}
ended() { # pane pid start
  # The process first: one tmux reaps after this read shows its status below.
  local proc; proc=$(proc_state "$2" "$3")
  is_gone "$1" && return 0
  [[ $(t display -p -t "$1" '#{pane_dead}:#{pane_dead_status}' 2>/dev/null) == 1: ]] || return 1
  [[ $proc == exited || $proc == zombie:0 ]]
}
proc_state() { # pid start: exited, running, or zombie:N with N its wait status (field 52)
  [[ $2 =~ ^[0-9]+$ ]] || { echo "no start time"; return; }
  local f start state code
  f=$(stat_fields "$1" 19 0 49) || { echo exited; return; }
  read -r start state code <<<"$f"
  [[ $start == "$2" ]] || { echo exited; return; }
  [[ $state == Z ]] && echo "zombie:$code" || echo running
}
is_gone() { [[ $(alive "$1") == gone ]]; }
# The fake logs a key when it reads it, which can be after the launch script
# returns: check its key log once it reads WANT, or as it stands after 10 s.
check_keys() { # name want
  until_true keys_read "$2"
  check "$1" "$(paste -sd' ' "$work/fake.log")" "$2"
}
keys_read() { [[ $(paste -sd' ' "$work/fake.log") == "$1" ]]; }
detach_all; tabs0=$(tabs)

: >"$work/fake.log"; p=$(fake)
t send-keys -t "$p" -l 'half a draft'; sleep 0.2
pid=$(pane_pid "$p"); start=$(pstart "$pid")
out=$(send end "$p" 2>&1); rc=$?
check "end: exit 0" "$rc" "0"
check "end: says so" "$out" "Ended the session."
check_keys "end: Esc, Ctrl+C, then /exit alone" "esc ctrl-c submit:/exit"
check "end: the process is gone" "$(gone "$p" "$pid" "$start")" "gone"

: >"$work/fake.log"; p=$(fake FAKE_DROP=x)
out=$(send end "$p" 2>&1); rc=$?
check "lost keys: exit 1" "$rc" "1"
check "lost keys: says so" "$out" "The session's prompt did not read /exit, so Enter was not pressed. Its prompt may be in vim editor mode, or Claude Code's layout changed. Open its terminal to do it there."
check_keys "lost keys: the line is cleared" "esc ctrl-c ctrl-c"
check "lost keys: Enter never pressed" "$(grep -c '^submit:' "$work/fake.log")" "0"
check "lost keys: still running" "$(alive "$p")" "alive"
t kill-pane -t "$p"

: >"$work/fake.log"; p=$(fake FAKE_STAY=1)
out=$(send end "$p" 2>&1); rc=$?
check "ignored /exit: exit 1" "$rc" "1"
check "ignored /exit: says so" "$out" "Sent /exit, but the session is still running. Open its terminal to see why."
t kill-pane -t "$p"

: >"$work/fake.log"; p=$(fake)
out=$(send interrupt "$p" 2>&1); rc=$?
check "interrupt: exit 0" "$rc" "0"
check "interrupt: says so" "$out" "Sent Esc to the session."
check_keys "interrupt: Esc alone" "esc"
check "interrupt: still running" "$(alive "$p")" "alive"

# A pane in copy mode would eat the keys as copy-mode commands.
: >"$work/fake.log"; p=$(fake)
t copy-mode -t "$p"
check "copy mode: the pane is in it" "$(t display -p -t "$p" '#{pane_in_mode}')" "1"
out=$(send end "$p" 2>&1); rc=$?
check "copy mode, end: exit 0" "$rc" "0"
check "copy mode, end: says so" "$out" "Ended the session."
check_keys "copy mode, end: the keys reached the session" "esc ctrl-c submit:/exit"
: >"$work/fake.log"; p=$(fake)
t copy-mode -t "$p"
out=$(send interrupt "$p" 2>&1); rc=$?
check "copy mode, interrupt: exit 0" "$rc" "0"
check_keys "copy mode, interrupt: Esc reached the session" "esc"
check "copy mode, interrupt: out of copy mode" "$(t display -p -t "$p" '#{pane_in_mode}')" "0"

# An End the app gave up on may still be running: a second one is refused.
: >"$work/fake.log"; p=$(fake)
exec {held}>>"$work/klepsydra-pane-$UID-${p#%}.lock"; flock -n "$held"
for verb in end interrupt wrapup; do
  out=$(send "$verb" "$p" 2>&1); rc=$?
  check "pane locked, $verb: exit 1" "$rc" "1"
  if [[ $verb == wrapup ]]; then
    check "pane locked, $verb: says so in its own words" "$out" \
      "klepsydra is already sending that session something; ask it by hand: type /klepsydra-wrapup in its terminal."
  else
    check "pane locked, $verb: says so" "$out" "That session is already being ended or interrupted."
  fi
done
check "pane locked: no key sent" "$(wc -c <"$work/fake.log")" "0"
exec {held}>&-
out=$(send interrupt "$p" 2>&1)
check "pane unlocked: interrupt runs" "$out" "Sent Esc to the session."
t kill-pane -t "$p"

# KLEPSYDRA_END_WAIT reaches arithmetic: only 1 to 999 counts, else 10 s.
: >"$work/fake.log"; p=$(fake FAKE_STAY=1)
rm -f "$work/crafted"
out=$(KLEPSYDRA_END_WAIT="a[\$(touch $work/crafted)]" send end "$p" 2>&1); rc=$?
check "END_WAIT crafted: no command ran" "$([[ -e $work/crafted ]] && echo ran || echo none)" "none"
check "END_WAIT crafted: waits out and says so" "$out" "Sent /exit, but the session is still running. Open its terminal to see why."
t kill-pane -t "$p"

echo "wrap up"
: >"$work/fake.log"; p=$(fake)
t send-keys -t "$p" -l 'a draft'; sleep 0.2
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup: exit 0" "$rc" "0"
check "wrapup: says so" "$out" "Asked the session to wrap up."
check_keys "wrapup: Ctrl+C, then the command alone, no Esc" "ctrl-c submit:/klepsydra-wrapup"
check "wrapup: still running" "$(alive "$p")" "alive"
t kill-pane -t "$p"
: >"$work/fake.log"; p=$(fake FAKE_BUSY=1)
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup mid-turn: exit 1" "$rc" "1"
check "wrapup mid-turn: says so" "$out" "The session is mid-turn; it is asked when the turn ends."
check "wrapup mid-turn: no key" "$(wc -l <"$work/fake.log")" "0"
t kill-pane -t "$p"
# Claude Code 2.1.302 at work: a spinner above the box, no "esc to interrupt" anywhere.
: >"$work/fake.log"; p=$(fake FAKE_TAIL="$here/fixtures/pane-working-2.1.302.txt")
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup, 2.1.302 at work: refused" "$rc $out" "1 The session is mid-turn; it is asked when the turn ends."
check "wrapup, 2.1.302 at work: no key" "$(wc -l <"$work/fake.log")" "0"
t kill-pane -t "$p"
# 2.1.302 running a tool: a tip sits under the spinner, and the footer reads "esc to interrupt".
: >"$work/fake.log"; p=$(fake FAKE_TAIL="$here/fixtures/pane-working-tool-2.1.302.txt")
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup, 2.1.302 running a tool: refused" "$rc $out" "1 The session is mid-turn; it is asked when the turn ends."
check "wrapup, 2.1.302 running a tool: no key" "$(wc -l <"$work/fake.log")" "0"
t kill-pane -t "$p"
# The footer's hint alone, with the transcript's last line above the box: refused.
sed '$s/$/ \xc2\xb7 esc to interrupt/' "$here/fixtures/pane-idle-2.1.302.txt" >"$work/footer-hint.txt"
: >"$work/fake.log"; p=$(fake FAKE_TAIL="$work/footer-hint.txt")
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup, esc hint in the footer: refused" "$rc $out" "1 The session is mid-turn; it is asked when the turn ends."
check "wrapup, esc hint in the footer: no key" "$(wc -l <"$work/fake.log")" "0"
t kill-pane -t "$p"
# Idle, though its transcript quotes the hint and a spinner line: only the line above the box counts.
{ printf 'it read \xe2\x9c\xbb Thinking\xe2\x80\xa6 (12s \xc2\xb7 esc to interrupt)\n'; cat "$here/fixtures/pane-idle-2.1.302.txt"; } >"$work/idle-quoting.txt"
: >"$work/fake.log"; p=$(fake FAKE_TAIL="$work/idle-quoting.txt")
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup, idle 2.1.302 quoting the hint: typed" "$rc $out" "0 Asked the session to wrap up."
check_keys "wrapup, idle 2.1.302 quoting the hint: Ctrl+C, then the command" "ctrl-c submit:/klepsydra-wrapup"
t kill-pane -t "$p"
: >"$work/fake.log"; p=$(fake FAKE_DROP=k)
out=$(send wrapup "$p" 2>&1); rc=$?
check "wrapup, lost keys: refused" "$out" "The session's prompt did not read /klepsydra-wrapup, so Enter was not pressed. Its prompt may be in vim editor mode, or Claude Code's layout changed. Open its terminal to do it there."
check_keys "wrapup, lost keys: the line is cleared, Enter never pressed" "ctrl-c ctrl-c"
t kill-pane -t "$p"
: >"$work/fake.log"; p=$(fake)

# Every refusal Jump makes, End, Interrupt and Wrap up make too, before any key.
: >"$work/fake.log"
ppid_=$(pane_pid "$p"); pst=$(pstart "$ppid_")
for verb in end interrupt wrapup; do
  out=$(bash "$launch" "$verb" "$socket" "$p" "$spid" "$sstart" 2>&1)
  check "$verb, another pane's process: refused" "$out" "That session's tmux pane now belongs to another session."
  out=$(bash "$launch" "$verb" "$socket" "$p" 2999999 "$pst" 2>&1)
  check "$verb, dead pid: refused" "$out" "That session's tmux pane now belongs to another session."
  out=$(bash "$launch" "$verb" "$socket" "$p" "$ppid_" "$((pst + 1))" 2>&1)
  check "$verb, reused pid: refused" "$out" "That session's tmux pane now belongs to another session."
  out=$(bash "$launch" "$verb" "$socket" '%3;x' "$ppid_" "$pst" 2>&1)
  check "$verb, bad pane: refused" "$out" "Not a tmux pane: %3;x"
  out=$(bash "$launch" "$verb" "$socket" '%99999' "$ppid_" "$pst" 2>&1)
  check "$verb, unknown pane: refused" "$out" "That session's tmux pane is gone."
  out=$(bash "$launch" "$verb" "rel/sock" "$p" "$ppid_" "$pst" 2>&1)
  check "$verb, relative socket: refused" "$out" "Not a tmux socket path: rel/sock"
  bash "$launch" "$verb" "$socket" "$p" "$ppid_" >/dev/null 2>&1; rc=$?
  check "$verb, missing start: exit 1" "$rc" "1"
done
tmux -L "$sock2" -f /dev/null new-session -d -s hand "$work/bin/fake-claude $work/fake.log"
for _ in $(seq 50); do tmux -L "$sock2" capture-pane -p | grep -q '^history' && break; sleep 0.1; done
socket2=$(tmux -L "$sock2" display -p '#{socket_path}')
pane2=$(tmux -L "$sock2" display -p '#{pane_id}')
p2=$(tmux -L "$sock2" display -p '#{pane_pid}')
for verb in end interrupt wrapup; do
  out=$(bash "$launch" "$verb" "$socket2" "$pane2" "$p2" "$(pstart "$p2")" 2>&1); rc=$?
  check "$verb, a hand-started tmux: exit 1" "$rc" "1"
  check "$verb, a hand-started tmux: says so" "$out" "That session is not in klepsydra's tmux, so klepsydra will not type into it."
done
tmux -L "$sock2" kill-server 2>/dev/null
check "refusals: no key reached a session" "$(wc -l <"$work/fake.log")" "0"
check "end and interrupt: never a tab" "$(tabs)" "$tabs0"
t kill-pane -t "$p"

out=$(bash "$launch" bogus 2>&1); rc=$?
check "unknown command: exit 1" "$rc" "1"
check "unknown command: says so" "$out" "usage: klepsydra-launch.sh new DIR | jump|end|interrupt|wrapup SOCKET PANE PID START"
check "unknown command: no tab" "$(tabs)" "1"

# Another click holding the lock past its 10 s: the window is selected anyway.
detach_all; : >"$WT_LOG"
lock="$work/klepsydra-launch-$UID.lock"
( exec 9>>"$lock"; flock 9; exec sleep 30 ) &
holder=$!
for _ in $(seq 100); do flock -n "$lock" true || break; sleep 0.05; done
attach
started=$SECONDS
out=$(jmp "$first" "$fpid" "$fstart" 2>&1); rc=$?
check "attached jump beside a held lock: exit 0" "$rc" "0"
check "attached jump beside a held lock: says so" "$out" "Selected the session's tmux window."
check "attached jump beside a held lock: no wait" "$(( SECONDS - started < 5 ))" "1"
detach_all; : >"$WT_LOG"
t select-window -t "$(t list-windows -t =fleet -F '#{window_id}' | tail -1)"
out=$(jmp "$first" "$fpid" "$fstart" 2>&1); rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check "jump behind a held lock: exit 1" "$rc" "1"
check "jump behind a held lock: says no launch" "$out" \
  "Selected the session's tmux window, but another click is still opening a terminal tab. Try again."
check "jump behind a held lock: window selected" "$(t display -p -t =fleet: '#{pane_id}')" "$first"
check "jump behind a held lock: no tab" "$(tabs)" "0"

echo "one tab per fleet"
stop_server; detach_all; : >"$WT_LOG"
export WT_DELAY=0.5
bash "$launch" new "$work/repos" >/dev/null 2>&1
bash "$launch" new "$work/repos" >/dev/null 2>&1
check "slow tab, two new: one tab" "$(tabs)" "1"
check "slow tab, two new: two windows" "$(windows)" "2"
stop_server; detach_all; : >"$WT_LOG"
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
wait
check "slow tab, concurrent new: one tab" "$(tabs)" "1"
detach_all; : >"$WT_LOG"
bash "$launch" new "$work/repos" >/dev/null 2>&1
socket=$(t display -p '#{socket_path}')
first=$(t list-panes -s -t =fleet -F '#{pane_id}' | head -1)
fpid=$(pane_pid "$first"); fstart=$(pstart "$fpid")
detach_all; : >"$WT_LOG"
bash "$launch" new "$work/repos" >/dev/null 2>&1
jmp "$first" "$fpid" "$fstart" >/dev/null 2>&1
check "slow tab, new then jump: one tab" "$(tabs)" "1"
unset WT_DELAY

echo "a tab that has not attached yet"
stop_server; detach_all; : >"$WT_LOG"
pending="$work/klepsydra-tab-pending-$UID"
# A cold WSL: the tab attaches after the launcher stops waiting. The launcher's
# poll runs longer on a loaded machine, so any fixed delay can land inside it
# and leave no pending stamp; this tab never attaches.
export WT_DELAY=never
out=$(bash "$launch" new "$work/repos" 2>&1); rc=$?
check "cold tab: exit 0" "$rc" "0"
check "cold tab: says the tab has not attached" "$out" \
  "Started a session in $work/repos. The terminal tab has not attached yet."
check "cold tab: a pending stamp" "$(read -r at key <"$pending"; echo "$key")" "-S $(t display -p '#{socket_path}') =fleet"
out=$(bash "$launch" new "$work/repos" 2>&1); rc=$?
check "cold tab, second new: exit 0" "$rc" "0"
check "cold tab, second new: one tab, not two" "$(tabs)" "1"
check "cold tab, second new: two windows" "$(windows)" "2"
check "cold tab, second new: says so" "$out" "Started a session in $work/repos. The terminal tab has not attached yet."
socket=$(t display -p '#{socket_path}')
first=$(t list-panes -s -t =fleet -F '#{pane_id}' | head -1)
fpid=$(pane_pid "$first"); fstart=$(pstart "$fpid")
jmp "$first" "$fpid" "$fstart" >/dev/null 2>&1
check "cold tab, then jump: one tab" "$(tabs)" "1"
detach_all; : >"$WT_LOG"
read -r at key <"$pending"; printf '%s %s\n' "$((at - 31))" "$key" >"$pending"
bash "$launch" new "$work/repos" >/dev/null 2>&1
check "a stamp over 30 s old: a new tab" "$(tabs)" "1"
detach_all; : >"$WT_LOG"
read -r at key <"$pending"; printf '%s %s\n' "$at" "-S /tmp/elsewhere =fleet" >"$pending"
bash "$launch" new "$work/repos" >/dev/null 2>&1
check "another server's stamp: a new tab" "$(tabs)" "1"
unset WT_DELAY
detach_all; rm -f "$pending"

echo "a stamp that is not our own file"
socket=$(t display -p '#{socket_path}')
mkfifo "$pending"; : >"$WT_LOG"
timeout 5 bash "$launch" new "$work/repos" >/dev/null 2>&1; rc=$?
check "a FIFO stamp: no block, exit 0" "$rc" "0"
check "a FIFO stamp: ignored, a tab" "$(tabs)" "1"
check "a FIFO stamp: removed" "$([[ -p $pending ]] && echo fifo)" ""
detach_all; rm -f "$pending"; : >"$WT_LOG"
printf -v now '%(%s)T' -1
printf '%s %s\n' "$now" "-S $socket =fleet" >"$work/planted"
ln -s "$work/planted" "$pending"
timeout 5 bash "$launch" new "$work/repos" >/dev/null 2>&1; rc=$?
check "a symlinked stamp: exit 0" "$rc" "0"
check "a symlinked stamp: not followed, a tab" "$(tabs)" "1"
check "a symlinked stamp: its target untouched" "$(cat "$work/planted")" "$now -S $socket =fleet"
check "a symlinked stamp: the link removed" "$([[ -L $pending ]] && echo link)" ""
detach_all; rm -f "$pending"

echo "failed tab"
stop_server; detach_all; : >"$WT_LOG"
out=$(KLEPSYDRA_WT=false bash "$launch" new "$work/repos" 2>&1); rc=$?
check "wt fails, no session: exit 1" "$rc" "1"
check "wt fails, no session: says so" "$out" "Windows Terminal did not open a tab."
check "wt fails, no session: nothing running" "$(t list-sessions 2>/dev/null | wc -l)" "0"
bash "$launch" new "$work/repos" >/dev/null 2>&1; detach_all
out=$(KLEPSYDRA_WT=false bash "$launch" new "$work/repos" 2>&1); rc=$?
check "wt fails, session: exit 1" "$rc" "1"
check "wt fails, session: window count unchanged" "$(windows)" "1"
stop_server
out=$(KLEPSYDRA_WT=no-such-wt bash "$launch" new "$work/repos" 2>&1); rc=$?
check "no wt.exe: exit 1" "$rc" "1"
check "no wt.exe: says so" "$out" "wt.exe was not found, so no terminal tab could be opened."
check "no wt.exe: nothing running" "$(t list-sessions 2>/dev/null | wc -l)" "0"
out=$(WSL_DISTRO_NAME='a;b' bash "$launch" new "$work/repos" 2>&1); rc=$?
check "bad distro name: exit 1" "$rc" "1"
check "bad distro name: says so" "$out" "WSL_DISTRO_NAME is missing or not usable, so no tab could be opened."
check "bad distro name: nothing running" "$(t list-sessions 2>/dev/null | wc -l)" "0"
odd="$work/a;b"; mkdir -p "$odd"; : >"$WT_LOG"
out=$(TMUX_TMPDIR="$odd" bash "$launch" new "$work/repos" 2>&1); rc=$?
check "a socket path wt.exe would split: exit 1" "$rc" "1"
check "a socket path wt.exe would split: says so" "$out" \
  "The tmux socket path cannot be passed to a tab: $odd/tmux-$(id -u)/$sock"
check "a socket path wt.exe would split: nothing running, no tab" \
  "$(TMUX_TMPDIR="$odd" tmux -L "$sock" list-sessions 2>/dev/null | wc -l)|$(tabs)" "0|0"

echo "cleanup"
cleanup; trap - EXIT
check "no socket files left" "$(find "$sockdir" -maxdepth 1 \( -name "$sock" -o -name "$sock2" -o -name "$sock3" \) 2>/dev/null)" ""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
