#!/usr/bin/env bash
# tmux-watch.sh: the fleet's tmux server watchdog (#290), run each minute by
# fleet-tmux-watch.timer. The server's pid and process start are kept in
# tmux-server. Once that server has ended on the same boot (whether or not a new
# one has started since), a crash record naming its pid and dated after it
# started (WSL's crash dump in wsl-crashes, or WSL's CaptureCrash line in the
# journal) means it crashed, and `fleet recover` relaunches the agents whose
# sessions are gone. Its tabs need Windows interop, which a systemd unit lacks:
# WSL_INTEROP is set to init's own interop socket and checked first. A recover
# that cannot reach Windows or leaves an agent NOT STARTED is tried again each
# minute, FLEET_RECOVER_TRIES times. A server that ended with no crash record
# (kill-server, its last pane closed) is logged and left to AJ or Heph. A new
# boot is #154's case: `fleet recover` by hand.
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
PENDING=$FLEET_STATE/tmux-recover.pending # "PID TRIES": a recover not yet done
TRIES=${FLEET_RECOVER_TRIES:-5}
boot=$(cat "${FLEET_BOOT_ID:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)

# Windows interop, which opening a terminal tab needs: a unit has no
# WSL_INTEROP, so init's own socket (it lives as long as the distro) is used.
interop() {
  [[ -n ${WSL_INTEROP:-} && -S $WSL_INTEROP ]] || { [[ -S ${FLEET_INIT_INTEROP:-/run/WSL/1_interop} ]] && export WSL_INTEROP=${FLEET_INIT_INTEROP:-/run/WSL/1_interop}; }
  [[ ${WSL_DISTRO_NAME:-} =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { why="the service has no WSL_DISTRO_NAME (fleet install sets it)"; return 1; }
  # shellcheck disable=SC2086 # the probe is a command line
  timeout 20 ${FLEET_INTEROP_PROBE:-cmd.exe /c exit 0} </dev/null >/dev/null 2>&1 || { why="Windows interop did not answer (WSL_INTEROP=${WSL_INTEROP:-none})"; return 1; }
}

# fleet recover for the server PID that crashed: done (0) once every agent
# whose session was gone is started again; otherwise left pending for the next
# minute, until TRIES tries.
run_recover() { # PID
  local tries=0 out rc why=""
  [[ -s $PENDING ]] && read -r _ tries <"$PENDING"
  tries=$(( ${tries:-0} + 1 ))
  printf '%s %s\n' "$1" "$tries" >"$PENDING.$$" && mv -f -- "$PENDING.$$" "$PENDING"
  if ! interop; then
    rc=1 out=""
  else
    out=$(bash "$RECOVER" 2>&1 </dev/null); rc=$?
    (( rc == 0 )) && grep -q 'NOT STARTED' <<<"$out" && { rc=1; why="an agent was NOT STARTED"; }
    (( rc == 0 )) || why=${why:-"fleet recover exited $rc"}
  fi
  if (( rc == 0 )); then
    rm -f -- "$PENDING"
    flog INFO "fleet recover after the tmux crash finished" pid="$1" tries="$tries" result="$(tr '\n' ';' <<<"$out")"
    return 0
  fi
  if (( tries >= TRIES )); then
    rm -f -- "$PENDING"
    flog ERROR "fleet recover after the tmux crash gave up; run fleet recover by hand" pid="$1" tries="$tries" why="$why" result="$(tr '\n' ';' <<<"$out")"
  else
    flog ERROR "fleet recover after the tmux crash did not bring every agent back; trying again next minute" pid="$1" tries="$tries" why="$why" result="$(tr '\n' ';' <<<"$out")"
  fi
  return 1
}
if [[ -s $PENDING ]]; then
  read -r pending_pid _ <"$PENDING"
  run_recover "$pending_pid"
fi

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

# A dump stays in Windows Temp across boots, and pids come again: only one
# dated no earlier than this server's start counts (wsl-crash-EPOCH-PID-...).
btime=$(awk '$1 == "btime" { print $2 }' "${FLEET_PROC:-/proc}/stat" 2>/dev/null)
since=$(( ${btime:-0} + ${was_start:-0} / $(getconf CLK_TCK 2>/dev/null || echo 100) ))
dump=$(find "$CRASH_DIR" -maxdepth 1 -name "wsl-crash-*-$was_pid-*tmux-*.dmp" -printf '%f\n' 2>/dev/null | awk -F- -v s="$since" '$3 ~ /^[0-9]+$/ && $3 >= s' | head -1)
# WSL's own line names the pid tmux reports (the kernel's segfault line, in
# another pid namespace, names another); -b keeps it to this boot.
kernel=$($JOURNAL -b --no-pager -q 2>/dev/null | grep -E "CaptureCrash\): Capturing crash for pid: $was_pid, executable: !usr!bin!tmux," | tail -1)
if [[ -z $dump && -z $kernel ]]; then
  flog WARN "the fleet's tmux server ended with no crash record (kill-server, or its last pane closed); not recovering" pid="$was_pid" new_pid="${now_line%% *}" crash_dir="$CRASH_DIR"
  exit 0
fi
sig=$(grep -oE 'tmux-[0-9]+\.dmp$' <<<"$dump" | grep -oE '[0-9]+')
flog ERROR "the fleet's tmux server crashed; running fleet recover" pid="$was_pid" new_pid="${now_line%% *}" signal="${sig:-unknown}" dump="${dump:-none}" journal="${kernel:-none}"
rm -f -- "$PENDING"
run_recover "$was_pid" || exit 1
