#!/usr/bin/env bash
# Tests for the launcher against a private tmux server and a stub wt.exe.
# Run: bash hooks/test_launch.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
launch="$here/klepsydra-launch.sh"
work=$(mktemp -d)
sock="kl-test-$$"
clients=()
cleanup() {
  for p in "${clients[@]}" $(cat "$work/stub-pids" 2>/dev/null); do kill "$p" 2>/dev/null; done
  tmux -L "$sock" kill-server 2>/dev/null
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
# Logs its argv, then attaches like the real tab: WT_DELAY seconds after returning.
printf '%s\n' "$*" >>"$WT_LOG"
args=("$@")
for i in "${!args[@]}"; do [[ ${args[i]} == -e ]] && { cmd=("${args[@]:i+1}"); break; }; done
(
  sleep "${WT_DELAY:-0}"
  exec script -qfc "$(printf '%q ' "${cmd[@]}")" /dev/null
) >/dev/null 2>&1 </dev/null &
echo $! >>"$WT_PIDS"
EOF
chmod +x "$work/bin/wt.exe"
export WT_LOG="$work/wt.log" WT_PIDS="$work/stub-pids" HOME="$work/home" XDG_RUNTIME_DIR="$work" WSL_DISTRO_NAME=Test
export KLEPSYDRA_TMUX_SOCKET="$sock" KLEPSYDRA_TMUX_CONF="$here/klepsydra-tmux.conf"
export KLEPSYDRA_CLAUDE="sleep 600" KLEPSYDRA_WT="$work/bin/wt.exe"
: >"$WT_LOG"

t() { tmux -L "$sock" "$@"; }
windows() { t list-windows -t =fleet 2>/dev/null | wc -l; }
tabs() { wc -l <"$WT_LOG"; }
attach() { # a real client on a pty, like the tab would be
  script -qfc "tmux -L $sock attach -t =fleet" /dev/null >/dev/null 2>&1 </dev/null &
  clients+=($!)
  for _ in $(seq 50); do [[ -n $(t list-clients -t =fleet 2>/dev/null) ]] && return; sleep 0.1; done
}
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
check "first: the tab attaches with exec" "$(head -1 "$WT_LOG")" \
  "-w fleet new-tab wsl.exe -d Test -e tmux -L $sock attach -t =fleet"
check "first: conf loaded" "$(t show -gv set-titles)" "on"
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

t kill-server 2>/dev/null; : >"$WT_LOG"
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
wait
check "concurrent: one session" "$(t list-sessions | wc -l)" "1"
check "concurrent: two windows" "$(windows)" "2"
check "concurrent: one tab" "$(tabs)" "1"

echo "jump"
first=$(t list-panes -s -t =fleet -F '#{pane_id}' | head -1)
socket=$(t display -p '#{socket_path}')
attach; : >"$WT_LOG"
out=$(bash "$launch" jump "$socket" "$first" 2>&1); rc=$?
check "jump: exit 0" "$rc" "0"
check "jump: says so" "$out" "Selected the session's tmux window."
check "jump: active pane" "$(t display -p -t =fleet: '#{pane_id}')" "$first"
check "jump with a client: no tab" "$(tabs)" "0"
out=$(bash "$launch" jump "$socket" '%3;x' 2>&1); rc=$?
check "bad pane: exit 1" "$rc" "1"
check "bad pane: says so" "$out" "Not a tmux pane: %3;x"
out=$(bash "$launch" jump "rel/sock" "$first" 2>&1); rc=$?
check "relative socket: exit 1" "$rc" "1"
check "relative socket: says so" "$out" "Not a tmux socket path: rel/sock"
check "bad arguments: no tab" "$(tabs)" "0"
out=$(bash "$launch" jump "$socket" '%99999' 2>&1); rc=$?
check "unknown pane: exit 1" "$rc" "1"
check "unknown pane: says so" "$out" "That session's tmux pane is gone."
detach_all
bash "$launch" jump "$socket" "$first" >/dev/null 2>&1
check "jump without a client: one tab" "$(tabs)" "1"
check "jump's tab names the socket" "$(head -1 "$WT_LOG")" \
  "-w fleet new-tab wsl.exe -d Test -e tmux -S $socket attach -t =fleet"
out=$(bash "$launch" bogus 2>&1); rc=$?
check "unknown command: exit 1" "$rc" "1"
check "unknown command: says so" "$out" "usage: klepsydra-launch.sh new DIR | jump SOCKET PANE"
check "unknown command: no tab" "$(tabs)" "1"

echo "one tab per fleet"
t kill-server 2>/dev/null; detach_all; : >"$WT_LOG"
export WT_DELAY=0.5
bash "$launch" new "$work/repos" >/dev/null 2>&1
bash "$launch" new "$work/repos" >/dev/null 2>&1
check "slow tab, two new: one tab" "$(tabs)" "1"
check "slow tab, two new: two windows" "$(windows)" "2"
t kill-server 2>/dev/null; detach_all; : >"$WT_LOG"
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
bash "$launch" new "$work/repos" >/dev/null 2>&1 &
wait
check "slow tab, concurrent new: one tab" "$(tabs)" "1"
detach_all; : >"$WT_LOG"
bash "$launch" new "$work/repos" >/dev/null 2>&1
socket=$(t display -p '#{socket_path}')
first=$(t list-panes -s -t =fleet -F '#{pane_id}' | head -1)
detach_all; : >"$WT_LOG"
bash "$launch" new "$work/repos" >/dev/null 2>&1
bash "$launch" jump "$socket" "$first" >/dev/null 2>&1
check "slow tab, new then jump: one tab" "$(tabs)" "1"
unset WT_DELAY

echo "failed tab"
t kill-server 2>/dev/null; detach_all; : >"$WT_LOG"
out=$(KLEPSYDRA_WT=false bash "$launch" new "$work/repos" 2>&1); rc=$?
check "wt fails, no session: exit 1" "$rc" "1"
check "wt fails, no session: says so" "$out" "Windows Terminal did not open a tab."
check "wt fails, no session: nothing running" "$(t list-sessions 2>/dev/null | wc -l)" "0"
bash "$launch" new "$work/repos" >/dev/null 2>&1; detach_all
out=$(KLEPSYDRA_WT=false bash "$launch" new "$work/repos" 2>&1); rc=$?
check "wt fails, session: exit 1" "$rc" "1"
check "wt fails, session: window count unchanged" "$(windows)" "1"
t kill-server 2>/dev/null
out=$(KLEPSYDRA_WT=no-such-wt bash "$launch" new "$work/repos" 2>&1); rc=$?
check "no wt.exe: exit 1" "$rc" "1"
check "no wt.exe: says so" "$out" "wt.exe was not found, so no terminal tab could be opened."
check "no wt.exe: nothing running" "$(t list-sessions 2>/dev/null | wc -l)" "0"
out=$(WSL_DISTRO_NAME='a;b' bash "$launch" new "$work/repos" 2>&1); rc=$?
check "bad distro name: exit 1" "$rc" "1"
check "bad distro name: says so" "$out" "WSL_DISTRO_NAME is missing or not usable, so no tab could be opened."
check "bad distro name: nothing running" "$(t list-sessions 2>/dev/null | wc -l)" "0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
