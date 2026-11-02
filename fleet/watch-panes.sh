#!/usr/bin/env bash
# watch-panes.sh PANE...: exit with a reason once any pane sits at its prompt
# with no turn running for IDLE_S (default 300) after printing a "done" line,
# stops on a usage limit (a pane already limited when the watcher starts is
# watched once its limit clears), or is gone, or once the CI watch logs a red run for
# the orchestrator (ci/alerts.jsonl: main, a branch no agent is on, or one
# still red 30 min after it was routed). Run it in the background so the
# orchestrator is woken when an agent finishes or CI needs him.
set -u
FLEET_TARGET=fleet::watch
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
IDLE_S=${IDLE_S:-300}
declare -A since
ALERTS=$FLEET_STATE/ci/alerts.jsonl SEEN=$FLEET_STATE/ci/alerts.seen
# The alert lines read so far, kept across watchers so none is missed between
# two; the first watcher starts at the end, so old alerts wake nobody.
if [[ ! -e $SEEN ]]; then
  mkdir -p -- "${SEEN%/*}"
  { { wc -l <"$ALERTS"; } 2>/dev/null || echo 0; } >"$SEEN"
fi

# The first new alert that wakes the orchestrator, as one line; every line
# read up to it counts as read. Fails when there is none.
ci_wake() {
  local seen n line
  [[ -e $ALERTS ]] || return 1
  seen=$(cat "$SEEN" 2>/dev/null)
  [[ $seen =~ ^[0-9]+$ ]] || seen=0
  n=$({ wc -l <"$ALERTS"; } 2>/dev/null || echo 0)
  (( n < seen )) && seen=0 # the log started over
  while IFS= read -r line; do
    seen=$((seen + 1))
    if jq -e '.wake == true' <<<"$line" >/dev/null 2>&1; then
      printf '%s\n' "$seen" >"$SEEN"
      jq -r '"CI \(.kind | ascii_upcase) \(.repo) \(.branch): \(.text)"
        + (if .taken_by then " Taken by \(.taken_by)." else "" end)
        + (if .ask then " Next: \(.ask)." else "" end)' <<<"$line"
      return 0
    fi
  done < <(tail -n +"$((seen + 1))" "$ALERTS" 2>/dev/null)
  printf '%s\n' "$seen" >"$SEEN"
  return 1
}
# Panes already waiting out a usage limit when the watcher starts are held
# until it clears (#246), so a watcher started during a shared limit does not
# wake the orchestrator at once on each of them.
declare -A held
resets=""
for p in "$@"; do
  s=$(screen "$p")
  if ! busy "$s" && l=$(limit_line "$s"); then
    held[$p]=1
    r=$(grep -oE 'resets [^(]*[ap]m' <<<"$l" | tail -1)
    [[ -n $r && $resets != *"${r#resets }"* ]] && resets+="${r#resets }, "
  fi
done
flog INFO "watching" panes="$*" idle_s="$IDLE_S" limited_at_start="${!held[*]}" resets="${resets%, }"
while :; do
  now=$(date +%s)
  if wake=$(ci_wake); then
    flog INFO "CI alert for the orchestrator" alert="$wake"
    echo "$wake"; exit 0
  fi
  for p in "$@"; do
    if ! fleet_panes | grep -qx "$p"; then
      flog INFO "watched pane gone" pane="$p"; echo "GONE $p"; exit 0
    fi
    s=$(screen "$p") ps=$(plain <<<"$s")
    if [[ -n ${held[$p]:-} ]]; then
      if ! busy "$s" && limit_line "$s" >/dev/null; then continue; fi
      unset "held[$p]"
      flog INFO "watched pane's limit cleared: watching it now" pane="$p"
    fi
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
