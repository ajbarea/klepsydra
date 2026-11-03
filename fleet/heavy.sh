#!/usr/bin/env bash
# Run COMMAND under the fleet's heavy lock (#289), for the Makefile's heavy targets.
# Says so when another run holds the lock, and refuses to wait on a lock one of
# its own callers holds (an outer flock on the same file would wait forever).
# The timeout runs in the caller's process group (--foreground), so Ctrl-C or a
# killed tool call ends the command, not only the lock's holder.
# Usage: fleet/heavy.sh COMMAND [ARGS...]
set -u
lock=${FLEET_HEAVY_LOCK:-/tmp/fleet-heavy.lock}
limit=${FLEET_HEAVY_TIMEOUT:-3600}
(( $# )) || { echo "usage: fleet/heavy.sh COMMAND [ARGS...]" >&2; exit 2; }

# The pids holding a flock on $lock, from /proc/locks (field 5 pid, field 6 dev:inode).
holders() {
  local ino
  ino=$(stat -c %i -- "$lock" 2>/dev/null) || return 0
  awk -v i=":$ino" '$2 == "FLOCK" && substr($6, length($6) - length(i) + 1) == i { print $5 }' /proc/locks 2>/dev/null | sort -u
}
ancestors() { # this shell's parent chain, one pid per line
  local p=$$
  while [[ $p =~ ^[0-9]+$ ]] && (( p > 1 )); do
    p=$(awk '/^PPid:/ { print $2 }' "/proc/$p/status" 2>/dev/null) || break
    [[ -n $p ]] && echo "$p"
  done
}

if ! flock -n -o "$lock" true 2>/dev/null; then
  held=$(holders | paste -sd " " -)
  for a in $(ancestors); do
    if [[ " $held " == *" $a "* ]]; then
      echo "heavy.sh: a caller (pid $a) already holds $lock; run the make target bare, or pass FLEET_HEAVY_HELD=1" >&2
      exit 2
    fi
  done
  echo "heavy.sh: waiting for $lock (held by pid ${held:-unknown})" >&2
fi
exec flock -o "$lock" timeout --foreground "$limit" "$@"
