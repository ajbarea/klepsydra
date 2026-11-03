#!/usr/bin/env bash
# Run COMMAND under the fleet's heavy lock (#289), for the Makefile's heavy targets.
# Says so when another run holds the lock, and refuses to wait on a lock one of
# its own callers holds (an outer flock on the same file would wait forever).
# The lock stays with this script, never with COMMAND, so nothing COMMAND
# leaves running keeps it (as flock -o). COMMAND runs under timeout in its own
# process group: at the limit every process in it gets TERM, then KILL after
# FLEET_HEAVY_KILL_S. INT, TERM or HUP here (Ctrl-C, a stopped tool call) is
# passed on to that group as TERM, which a script's background job never ignores.
# Usage: fleet/heavy.sh COMMAND [ARGS...]
set -u
lock=${FLEET_HEAVY_LOCK:-/tmp/fleet-heavy.lock}
limit=${FLEET_HEAVY_TIMEOUT:-3600}
grace=${FLEET_HEAVY_KILL_S:-30}
(( $# )) || { echo "usage: fleet/heavy.sh COMMAND [ARGS...]" >&2; exit 2; }
{ exec {fd}>>"$lock"; } 2>/dev/null || { echo "heavy.sh: cannot open $lock" >&2; exit 2; }

# The pids holding a flock on $lock, from /proc/locks (field 5 pid, field 6 dev:inode).
holders() {
  local ino
  ino=$(stat -L -c %i -- "$lock" 2>/dev/null) || return 0
  awk -v i=":$ino" '$2 == "FLOCK" && substr($6, length($6) - length(i) + 1) == i { print $5 }' /proc/locks 2>/dev/null | sort -u
}
ancestors() { # this shell's parent chain, one pid per line
  local p=$$
  while [[ $p =~ ^[0-9]+$ ]] && (( p > 1 )); do
    p=$(awk '/^PPid:/ { print $2 }' "/proc/$p/status" 2>/dev/null) || break
    [[ -n $p ]] && echo "$p"
  done
}

if ! flock -n "$fd"; then
  held=$(holders | paste -sd " " -)
  for a in $(ancestors); do
    if [[ " $held " == *" $a "* ]]; then
      echo "heavy.sh: a caller (pid $a) already holds $lock; run the make target bare, or pass FLEET_HEAVY_HELD=1" >&2
      exit 2
    fi
  done
  echo "heavy.sh: waiting for $lock (held by pid ${held:-unknown})" >&2
  flock "$fd" || { echo "heavy.sh: could not lock $lock" >&2; exit 2; }
fi

# Without job control a background job's stdin is /dev/null: keep the caller's.
timeout -k "$grace" "$limit" "$@" 0<&0 {fd}>&- &
job=$!
# shellcheck disable=SC2329 # run by the trap below
stop() { kill -TERM -- "$job" 2>/dev/null; }
trap stop INT TERM HUP
rc=0
while :; do
  wait "$job"; rc=$?
  kill -0 "$job" 2>/dev/null || break # a trapped signal ended the wait, not the job
done
exit "$rc"
