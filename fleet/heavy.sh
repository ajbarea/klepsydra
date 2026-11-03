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

# The pids other than this one with $lock open (its real path, so a symlinked
# name counts too). A flock belongs to the open file, not to the process that
# called flock(2) (a heavy.sh's own lock is taken by a flock(1) that exits at
# once), so the holder is found by its open file: the run holding it, or a run
# waiting on it. Read only when the lock is busy.
openers() {
  local real q a mine out=()
  real=$(readlink -f -- "$lock") || return 0
  for q in $(find /proc/[0-9]*/fd -maxdepth 1 -lname "$real" -printf '%h\n' 2>/dev/null | cut -d/ -f3 | sort -un); do
    # Not this script, nor its own short-lived helpers (they inherit the file).
    mine=0 a=$q
    while [[ $a =~ ^[0-9]+$ ]] && (( a > 1 )); do
      [[ $a == "$$" ]] && { mine=1; break; }
      a=$(awk '/^PPid:/ { print $2 }' "/proc/$a/status" 2>/dev/null) || break
    done
    (( mine )) || [[ ! -d /proc/$q ]] || out+=("$q")
  done
  printf '%s' "${out[*]}"
}
ancestors() { # this shell's parent chain, one pid per line
  local p=$$
  while [[ $p =~ ^[0-9]+$ ]] && (( p > 1 )); do
    p=$(awk '/^PPid:/ { print $2 }' "/proc/$p/status" 2>/dev/null) || break
    [[ -n $p ]] && echo "$p"
  done
}

if ! flock -n "$fd"; then
  open=$(openers)
  # A caller with the lock open is past its own flock on it, so it holds it.
  for a in $(ancestors); do
    if [[ " $open " == *" $a "* ]]; then
      echo "heavy.sh: a caller (pid $a) already holds $lock; run the make target bare, or pass FLEET_HEAVY_HELD=1" >&2
      exit 2
    fi
  done
  echo "heavy.sh: waiting for $lock (open in pid ${open:-unknown}: the run holding it, and any others waiting)" >&2
  flock "$fd" || { echo "heavy.sh: could not lock $lock" >&2; exit 2; }
fi
# A make target COMMAND runs takes no second lock.
export FLEET_HEAVY_HELD=1

# Without job control a background job's stdin is /dev/null: keep the caller's.
# The trap is set first, so a signal before the job starts still stops it.
job="" stopping=0
# shellcheck disable=SC2329 # run by the trap below
stop() { stopping=1; [[ -n $job ]] && kill -TERM -- "$job" 2>/dev/null; }
trap stop INT TERM HUP
timeout -k "$grace" "$limit" "$@" 0<&0 {fd}>&- &
job=$!
(( stopping )) && kill -TERM -- "$job" 2>/dev/null
rc=0
while :; do
  wait "$job"; rc=$?
  kill -0 "$job" 2>/dev/null || break # a trapped signal ended the wait, not the job
done
exit "$rc"
