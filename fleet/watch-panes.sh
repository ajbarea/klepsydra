#!/usr/bin/env bash
# watch-panes.sh PANE... : exit with a reason once any pane sits at its prompt with no spinner
# for IDLE_S (default 300) after printing a "done" line, or is gone. Run it in the background so
# the orchestrator is re-invoked when an agent finishes; session notifications may be off.
IDLE_S=${IDLE_S:-300}
declare -A since
while :; do
  now=$(date +%s)
  for p in "$@"; do
    tmux -L klepsydra list-panes -s -t fleet -F '#{pane_id}' | grep -qx "$p" || { echo "GONE $p"; exit 0; }
    txt=$(tmux -L klepsydra capture-pane -t "$p" -p | tail -25)
    # A usage limit wakes the orchestrator too (the resume service restarts the pane; this only
    # makes sure the orchestrator knows).
    if ! grep -q '… (' <<<"$txt" && tail -8 <<<"$txt" | grep -Eq "hit your (session|weekly) limit|Usage limit reached"; then
      echo "LIMIT $p $(grep -oE 'resets [0-9]{1,2}(:[0-9]{2})? ?[ap]m' <<<"$txt" | tail -1)"; exit 0
    fi
    if grep -q '… (' <<<"$txt" || grep -qE 'still running|Waiting for [0-9]+ background' <<<"$txt" || ! grep -q 'done [0-9]\{1,2\}:[0-9][0-9] [AP]M' <<<"$txt"; then unset "since[$p]"; continue; fi
    : "${since[$p]:=$now}"
    (( now - since[$p] >= IDLE_S )) && { echo "IDLE $p $(grep -o 'done [0-9:]* [AP]M' <<<"$txt" | tail -1)"; grep -E 'hit your|limit' <<<"$txt" | tail -1; exit 0; }
  done
  sleep 30
done
