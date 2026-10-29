#!/usr/bin/env bash
# watch-panes.sh PANE...: exit with a reason once any pane sits at its prompt
# with no turn running for IDLE_S (default 300) after printing a "done" line,
# stops on a usage limit, or is gone. Run it in the background so the
# orchestrator is woken when an agent finishes.
set -u
FLEET_TARGET=fleet::watch
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
IDLE_S=${IDLE_S:-300}
declare -A since
flog INFO "watching" panes="$*" idle_s="$IDLE_S"
while :; do
  now=$(date +%s)
  for p in "$@"; do
    if ! fleet_panes | grep -qx "$p"; then
      flog INFO "watched pane gone" pane="$p"; echo "GONE $p"; exit 0
    fi
    s=$(screen "$p") ps=$(plain <<<"$s")
    # A usage limit wakes the orchestrator too; the resume service restarts the pane.
    if ! busy "$s" && limit=$(limit_line "$s"); then
      flog INFO "watched pane limited" pane="$p" message="$limit"
      echo "LIMIT $p $(grep -oE 'resets [^(]*[ap]m' <<<"$limit" | tail -1)"; exit 0
    fi
    if busy "$s" || grep -qE 'still running|Waiting for [0-9]+ background' <<<"$ps" || ! grep -q 'done [0-9]\{1,2\}:[0-9][0-9] [AP]M' <<<"$ps"; then
      unset "since[$p]"; continue
    fi
    : "${since[$p]:=$now}"
    if (( now - since[$p] >= IDLE_S )); then
      done_at=$(grep -o 'done [0-9:]* [AP]M' <<<"$ps" | tail -1)
      flog INFO "watched pane idle" pane="$p" since="$done_at"
      echo "IDLE $p $done_at"; exit 0
    fi
  done
  sleep "${WATCH_TICK:-30}"
done
