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
# Written whole (temp file, then rename): a watcher killed mid-write must not
# leave an empty count that replays every old alert.
put_seen() { printf '%s\n' "$1" >"$SEEN.$$" && mv -f -- "$SEEN.$$" "$SEEN"; }
# A watcher stopped mid-write leaves no temp file behind.
trap 'rm -f -- "${SEEN:?}.$$"' EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
if [[ ! -e $SEEN ]]; then
  mkdir -p -- "${SEEN%/*}"
  put_seen "$({ wc -l <"$ALERTS"; } 2>/dev/null || echo 0)"
fi

# The first new alert that wakes the orchestrator, as one line in WAKE, and the
# count of lines read through it in WAKE_SEEN. Lines read with no wake are
# marked read here; the caller marks a wake read as its last act before exit,
# after logging and printing it (at least once: a watcher killed before that
# leaves the alert for the next one, which may print it again). Fails when
# there is none. It runs in the watcher's own shell, never a $( ) subshell: a
# subshell outlives a killed watcher.
ci_wake() {
  local seen n out
  [[ -e $ALERTS ]] || return 1
  seen=$(cat "$SEEN" 2>/dev/null)
  [[ $seen =~ ^[0-9]+$ ]] || seen=0
  n=$({ wc -l <"$ALERTS"; } 2>/dev/null || echo 0)
  (( n < seen )) && seen=0 # the log started over
  (( n > seen )) || return 1
  # One jq pass over the unread whole lines: the first wake line that no later
  # "withdrawn" line for its run cancelled (#321: a red let go while it waited
  # unread is never replayed), as "INDEX<TAB>TEXT"; "-" when there is none.
  # A line jq cannot read wakes nobody.
  out=$(tail -n +"$((seen + 1))" "$ALERTS" 2>/dev/null | head -n "$((n - seen))" | jq -nrR '
    [inputs | (fromjson? // {}) | if type == "object" then . else {} end] as $l
    | (reduce range(0; $l | length) as $i ({};
        if $l[$i].kind == "withdrawn" then .["\($l[$i].repo) \($l[$i].run_id)"] = $i else . end)) as $wd
    | first(range(0; $l | length) as $i | $l[$i]
        | select(.wake == true and ($wd["\(.repo) \(.run_id)"] // -1) < $i)
        | "\($i + 1)\t" + "CI \(.kind // "alert" | tostring | ascii_upcase) \(.repo) \(.branch): \(.text)"
          + (if .taken_by then " Taken by \(.taken_by)." else "" end)
          + (if .ask then " Next: \(.ask)." else "" end)) // "-"' 2>/dev/null)
  [[ -n $out ]] || return 1 # jq failed: nothing is marked read
  if [[ $out == - ]]; then
    put_seen "$n"
    return 1
  fi
  WAKE=${out#*$'\t'} WAKE_SEEN=$((seen + ${out%%$'\t'*}))
  return 0
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
  if ci_wake; then
    flog INFO "CI alert for the orchestrator" alert="$WAKE"
    echo "$WAKE"
    put_seen "$WAKE_SEEN"
    exit 0
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
    # A usage limit wakes the orchestrator too; the resume service restarts the
    # pane, unless its agent ran `fleet done`.
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
  # In the background, so a TERM is acted on at once, not after the tick.
  sleep "${WATCH_TICK:-30}" &
  wait $!
done
