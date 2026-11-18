#!/usr/bin/env bash
# close.sh NAME: close the pane of a finished agent once its report is read
# (#445). `fleet done` leaves the pane open so the report can be read; the
# orchestrator runs this after reading it. NAME must be in finished.tsv (a
# running agent is never closed), and its pane must still run the session that
# finished there: panes ids are reused by a restarted tmux server. The pane gets
# /exit and is killed when it does not go (retire, lib.sh). The agent's record in
# done-reports.tsv is dropped, which also clears the doctor's flag. Exits 1 when
# NAME has not finished, the pane is the orchestrator's, mid-turn, has background work or cannot be confirmed idle, or 2 on bad usage.
set -u
FLEET_TARGET=fleet::close
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
FINISHED=${FLEET_FINISHED:-$FLEET_STATE/finished.tsv}
(( $# == 1 )) && [[ -n $1 ]] || { err "usage: fleet close NAME"; exit 2; }
name=$1
# The newest finished row of that name (names compare as text).
mapfile -t row < <(awk -F'\t' -v n="$name" '$2 "" == n "" { p = $1; s = $4 } END { if (p != "") { print p; print s } }' "$FINISHED" 2>/dev/null)
pane=${row[0]:-} sid=${row[1]:-}
if [[ -z ${pane:-} ]]; then
  flog WARN "close: no finished agent of that name" name="$name"
  err "no finished agent named $name (fleet done marks one finished first)"
  exit 1
fi
# The ids of the live sessions that name PANE on the fleet's tmux server (a file with no socket counts,
# as in pane_runs): AJ's own tmux hands out the same %N, so a file for another socket is no one of ours.
fleet_sessions() { # PANE
  local f
  while IFS= read -r f; do
    [[ -f $f && ! -L $f ]] || continue
    jq -e --arg p "$1" --arg s "/$FLEET_SOCK" '.tmux.pane == $p and .ended == null
      and (.tmux.socket == null or (.tmux.socket | strings | endswith($s)))' "$f" >/dev/null 2>&1 && basename "$f" .json
  done < <(grep -l -F -- "\"$1\"" "$KLEPSYDRA_DIR"/fleet/*.json 2>/dev/null)
}
# Whether the session SID in PANE is at rest, read from its session file and never from the screen
# alone (a new turn's spinner can show no timer for seconds). Prints why not and fails on anything
# it cannot confirm, errors included: not found, not the only live session for this pane, unreadable,
# working, or with background work (a shell or watcher dies with its pane).
at_rest() { # PANE SID
  local f=$KLEPSYDRA_DIR/fleet/$2.json n r
  [[ -f $f && ! -L $f ]] || { echo "unreadable its session file is missing"; return 1; }
  n=$(fleet_sessions "$1" | grep -c .) || true
  (( n == 1 )) && [[ $(fleet_sessions "$1") == "$2" ]] || { echo "unconfirmed $n live sessions name $1 on the fleet's server, not just $2"; return 1; }
  r=$(jq -r 'if .state == "working" and .reason != "background" then "working"
    elif ((.background // []) | type) != "array" or ((.background // []) | length) > 0 then "background"
    elif .state == "done" or (.state == "working" and .reason == "background") then "ok"
    else "unconfirmed its state is " + ((.state // "unknown") | tostring) end' "$f" 2>/dev/null) || r=""
  [[ -n $r ]] || { echo "unreadable its session file cannot be read"; return 1; }
  [[ $r == ok ]] && return 0
  echo "$r"
  return 1
}
# The checks and the /exit hold one pane lock (retire's own lock is then the held one), so a `fleet send`
# that is mid-paste cannot start a turn between them. A finished agent may work again (a follow-up message,
# a hand resume): /exit would end the turn or kill its shells with the pane.
close_now() { # PANE NAME SID
  local why
  if busy "$(screen "$1")"; then
    flog WARN "close: the pane is mid-turn; left open" name="$2" pane="$1"
    err "refused: $2 is working again ($1 is mid-turn); close it once the turn ends"
    return 10
  fi
  why=$(at_rest "$1" "$3") || {
    flog WARN "close: not confirmed at rest; left open" name="$2" pane="$1" why="$why"
    case $why in
      working*) err "refused: $2 is working again (its session file says so); close it once the turn ends"; return 10 ;;
      background*) err "refused: $2 still has background work running (a shell or watcher dies with its pane); close it once that ends"; return 11 ;;
      *) err "refused: cannot confirm $2 is idle (${why#* }); left open"; return 12 ;;
    esac
  }
  retire "$1"
}
if ! fleet_panes | grep -qx -- "$pane"; then
  flog INFO "close: the pane is gone; nothing to close" name="$name" pane="$pane"
  echo "already closed: $name"
elif ! pane_runs "$pane" "$sid"; then
  other=$(fleet_sessions "$pane" | grep -vxF -- "$sid" | head -1)
  if [[ -n $other ]]; then
    # A pane id a restarted tmux server gave to another session: never ours to close, and the
    # record is cleared, since no one can read that pane as this agent's any more.
    flog WARN "close: the pane now runs another session; left open, record cleared" name="$name" pane="$pane" other="$other"
    echo "left open: $pane now runs another session; $name's record is cleared"
  else
    # Its fleet file is gone or unreadable: not ours to close, and the record stays.
    flog WARN "close: the pane does not run the finished session; left open" name="$name" pane="$pane"
    err "left open: $pane no longer runs $name's session (or its fleet file is gone)"
    exit 1
  fi
elif [[ $pane == "$(orchestrator)" ]]; then
  err "refused: $pane is the orchestrator's pane"
  exit 1
else
  pane_locked "$pane" close_now "$pane" "$name" "$sid"
  rc=$?
  case $rc in
    0) flog INFO "close: finished agent's pane closed" name="$name" pane="$pane"; echo "closed: $name ($pane)" ;;
    10 | 11 | 12) exit 1 ;;
    75) err "could not take $pane's lock (a send is using it); try again"; exit 1 ;;
    *) err "could not close $pane (/exit would not go in); it is left open"; exit 1 ;;
  esac
fi
with_registry dr_drop "$name" || { err "done-reports.tsv could not be updated"; exit 1; }
