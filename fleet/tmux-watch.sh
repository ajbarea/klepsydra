#!/usr/bin/env bash
# tmux-watch.sh: the fleet's tmux server watchdog (#290), run each minute by
# fleet-tmux-watch.timer. The server's pid and process start are kept in
# tmux-server. Once that server has ended on the same boot (whether or not a new
# one has started since), a crash record naming its pid (WSL's crash dump in
# wsl-crashes, or the kernel's segfault line) means it crashed, and
# `fleet recover` relaunches the agents and Heph. A server that ended with no
# crash record (kill-server, its last pane closed) is logged and left to AJ or
# Heph. A new boot is #154's case: `fleet recover` by hand.
set -u
FLEET_TARGET=fleet::tmux-watch
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
STATE_F=$FLEET_STATE/tmux-server
RECOVER=${FLEET_RECOVER:-$here/recover.sh}
# WSL writes crash dumps beside klepsydra's data folder, in Local\Temp\wsl-crashes.
CRASH_DIR=${FLEET_CRASH_DIR:-${KLEPSYDRA_DIR%/*}/Temp/wsl-crashes}
JOURNAL=${FLEET_JOURNAL:-journalctl}
boot=$(cat "${FLEET_BOOT_ID:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)

# The server answering now, as "PID START BOOT", or nothing.
now_line=""
if pid=$(t display-message -p '#{pid}' 2>/dev/null) && [[ $pid =~ ^[0-9]+$ ]]; then
  now_line="$pid $(proc_start "$pid") $boot"
fi
record() {
  if [[ -n $now_line ]]; then
    printf '%s\n' "$now_line" >"$STATE_F.$$" && mv -f -- "$STATE_F.$$" "$STATE_F"
    flog INFO "watching the fleet's tmux server" pid="${now_line%% *}" socket="$FLEET_SOCK"
  else
    rm -f -- "$STATE_F"
  fi
}

was=$(cat "$STATE_F" 2>/dev/null)
[[ $was == "$now_line" ]] && exit 0
if [[ -z $was ]]; then record; exit 0; fi
read -r was_pid was_start was_boot <<<"$was"
if [[ $was_boot != "$boot" ]]; then
  flog INFO "the fleet's tmux server was from an earlier boot; fleet recover brings the agents back" pid="$was_pid"
  record; exit 0
fi
# The recorded server still runs (it did not answer this once): nothing yet.
if [[ -n $was_start && $(proc_start "$was_pid") == "$was_start" ]]; then exit 0; fi
record

dump=$(find "$CRASH_DIR" -maxdepth 1 -name "wsl-crash-*-$was_pid-*tmux-*.dmp" -printf '%f\n' 2>/dev/null | head -1)
kernel=$($JOURNAL -k -b --no-pager -q 2>/dev/null | grep -E "tmux: server\[$was_pid\]: segfault|tmux.*\[$was_pid\].*fatal signal" | tail -1)
if [[ -z $dump && -z $kernel ]]; then
  flog WARN "the fleet's tmux server ended with no crash record (kill-server, or its last pane closed); not recovering" pid="$was_pid" new_pid="${now_line%% *}" crash_dir="$CRASH_DIR"
  exit 0
fi
sig=$(grep -oE 'tmux-[0-9]+\.dmp$' <<<"$dump" | grep -oE '[0-9]+')
flog ERROR "the fleet's tmux server crashed; running fleet recover" pid="$was_pid" new_pid="${now_line%% *}" signal="${sig:-unknown}" dump="${dump:-none}" kernel="${kernel:-none}"
if out=$(bash "$RECOVER" 2>&1 </dev/null); then
  flog INFO "fleet recover after the tmux crash finished" pid="$was_pid" result="$(tr '\n' ';' <<<"$out")"
else
  flog ERROR "fleet recover after the tmux crash failed" pid="$was_pid" result="$(tr '\n' ';' <<<"$out")"
  exit 1
fi
