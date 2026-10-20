#!/usr/bin/env bash
# Tests for the launcher against a private tmux server and a stub wt.exe.
# Run: bash hooks/test_launch.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
launch="$here/klepsydra-launch.sh"
work=$(mktemp -d)
sock="kl-test-$$" sock2="kl-test2-$$"
sockdir="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)" # where tmux puts a -L socket
clients=()
cleanup() {
  for p in "${clients[@]}" $(cat "$work/stub-pids" 2>/dev/null); do kill "$p" 2>/dev/null; done
  tmux -L "$sock" kill-server 2>/dev/null
  tmux -L "$sock2" kill-server 2>/dev/null
  rm -f -- "$sockdir/$sock" "$sockdir/$sock2"
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
printf '%s\n' "$*" >>"$WT_LOG"
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
pstart() { # pid: /proc/PID/stat field 22, as proc_stat in the launcher's proc stat block reads it
  local raw; raw=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
  read -r -a st <<<"${raw##*") "}"; echo "${st[19]}"
}
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
  "-w fleet new-tab --title klepsydra fleet --suppressApplicationTitle wsl.exe -d Test -e tmux -S $(t display -p '#{socket_path}') attach -t =fleet"
check "first: an attached tab leaves no pending stamp" "$([[ -e $work/klepsydra-tab-pending-$UID ]] && echo left)" ""
check "first: conf loaded" "$(t show -gv automatic-rename-format)" "#{pane_title}"
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
# The walk: claude is a descendant of pane_pid, not pane_pid itself.
leaf() { local p=$1 c _; for _ in 1 2 3 4 5 6 7 8; do c=$(pgrep -P "$p" | head -1); [[ -n $c ]] || break; p=$c; done; echo "$p"; }
deep=$(t new-window -d -P -F '#{pane_id}' -t =fleet: "bash -c 'sleep 600; true'")
sleep 0.3
dleaf=$(leaf "$(pane_pid "$deep")"); dstart=$(pstart "$dleaf")
check "descendant: leaf is not the pane pid" "$([[ $dleaf != "$(pane_pid "$deep")" ]] && echo yes)" "yes"
out=$(jmp "$deep" "$dleaf" "$dstart" 2>&1); rc=$?
check "descendant: exit 0" "$rc" "0"
check "descendant: active pane" "$(t display -p -t =fleet: '#{pane_id}')" "$deep"
out=$(jmp "$first" "$dleaf" "$dstart" 2>&1); rc=$?
check "descendant against another pane: refused" "$out" "That session's tmux pane now belongs to another session."
# A zombie child is not Claude.
zp=$(t new-window -d -P -F '#{pane_id}' -t =fleet: "bash -c 'sleep 0.2 & exec sleep 600'")
sleep 0.8
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
  "-w fleet new-tab --title klepsydra fleet --suppressApplicationTitle wsl.exe -d Test -e tmux -S $socket attach -t =fleet"
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
detach_all; : >"$WT_LOG"
bash "$launch" jump "$socket" "$first" "$fpid" "$fstart" >/dev/null 2>&1
check "fleet socket: titled tab" "$(head -1 "$WT_LOG" | grep -c -- "^-w fleet new-tab --title klepsydra fleet --suppressApplicationTitle wsl.exe")" "1"
out=$(bash "$launch" bogus 2>&1); rc=$?
check "unknown command: exit 1" "$rc" "1"
check "unknown command: says so" "$out" "usage: klepsydra-launch.sh new DIR | jump SOCKET PANE PID START"
check "unknown command: no tab" "$(tabs)" "1"

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
export WT_DELAY=6 # a cold WSL: the tab attaches after the launcher stops waiting
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
check "no socket files left" "$(find "$sockdir" -maxdepth 1 \( -name "$sock" -o -name "$sock2" \) 2>/dev/null)" ""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
