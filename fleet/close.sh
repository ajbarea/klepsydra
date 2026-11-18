#!/usr/bin/env bash
# close.sh NAME: close the pane of a finished agent once its report is read
# (#445). `fleet done` leaves the pane open so the report can be read; the
# orchestrator runs this after reading it. NAME must be in finished.tsv (a
# running agent is never closed), and its pane must still run the session that
# finished there: panes ids are reused by a restarted tmux server. The pane gets
# /exit once it is confirmed at rest (close_now), and is never killed. The
# agent's record in done-reports.tsv is dropped, which also clears the doctor's
# flag. Exits 1 when NAME has not finished, the pane is the orchestrator's, is
# not confirmed at rest, or is still there after /exit; 2 on bad usage.
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
# When PANE's process started, in epoch seconds.
pane_born() { # PANE
  local pid et
  pid=$(t display -p -t "$1" '#{pane_pid}' 2>/dev/null) && [[ $pid =~ ^[0-9]+$ ]] || return 1
  et=$(ps -o etimes= -p "$pid" 2>/dev/null) && et=${et//[[:space:]]/} && [[ $et =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$(( $(date +%s) - et ))"
}
# Whether the session SID in PANE is at rest, read from its session file and never from the screen
# alone (a new turn's spinner can show no timer for seconds). Prints why not and fails on anything
# it cannot confirm, errors included: not found, not the only live session for this pane, last
# written before the pane's process started (a reused pane whose new occupant writes no file),
# unreadable, owing the wall's wrap-up an answer (its checkpoint turn runs on while the file says
# done), working, or with background work (a shell or watcher dies with its pane). At rest, prints
# the file's fingerprint, so a later read can tell whether anything was written since.
at_rest() { # PANE SID
  local f=$KLEPSYDRA_DIR/fleet/$2.json n r w born live
  [[ -f $f && ! -L $f ]] || { echo "unreadable its session file is missing"; return 1; }
  live=$(fleet_sessions "$1")
  n=$(grep -c . <<<"$live") || true
  (( n == 1 )) && [[ $live == "$2" ]] || { echo "unconfirmed $n live sessions name $1 on the fleet's server, not just $2"; return 1; }
  born=$(pane_born "$1") || { echo "unconfirmed the start of $1's process cannot be read"; return 1; }
  w=$(jq -r '[.written_at, .started_at] | map(numbers) | max // empty' "$f" 2>/dev/null)
  [[ $w =~ ^[0-9]+$ ]] || w=$(stat -c %Y -- "$f" 2>/dev/null)
  if ! [[ $w =~ ^[0-9]+$ ]] || (( w + 2 < born )); then
    echo "unconfirmed its session file was last written before $1's process started (a reused pane)"; return 1
  fi
  if w=$(wrapup_pending "$2"); then echo "wrapup $w"; return 1; fi
  r=$(jq -r 'if .state == "working" and .reason != "background" then "working"
    elif ((.background // []) | type) != "array" or ((.background // []) | length) > 0 then "background"
    elif .state == "done" or (.state == "working" and .reason == "background") then "ok"
    else "unconfirmed its state is " + ((.state // "unknown") | tostring) end' "$f" 2>/dev/null) || r=""
  [[ -n $r ]] || { echo "unreadable its session file cannot be read"; return 1; }
  [[ $r == ok ]] || { echo "$r"; return 1; }
  { stat -c '%Y %s' -- "$f"; cat -- "$f"; } 2>/dev/null | cksum
}
# SCREEN above the input box's top rule, escapes kept: a turn printing text or a spinner with no
# timer changes it (the glyph and its colours move), where busy reads nothing.
above_raw() { # SCREEN
  local n
  n=$(plain <<<"$1" | awk 'index($0, "────") == 1 { r[++k] = NR } END { print (k >= 2) ? r[k - 1] - 1 : NR }')
  head -n "$n" <<<"$1"
}
# ABOVE (above_raw's) as plain lines, blank ones and a trailing slash-command menu dropped. Typing
# /exit opens that menu just above the box: Claude Code 2.1.316 draws it over the transcript's last
# rows (a full screen might scroll up instead). Prints how many menu lines went, then the rest.
screen_lines() { # ABOVE
  plain <<<"$1" | grep -v '^[[:space:]]*$' | awk '{ l[++n] = $0 } END {
    k = 0; while (n > 0 && l[n] ~ /^ {2,4}(❯ )?\/[^ ]+( |$)/) { n--; k++ }
    print k; for (i = 1; i <= n; i++) print l[i] }'
}
# Whether AFTER (a screen with /exit typed) shows REF's transcript (above_raw's) unchanged: its
# first lines or its last ones, less at most the rows the menu covers, and no line it lacks.
same_transcript() { # REF AFTER
  local r a k n m
  r=$(screen_lines "$1" | tail -n +2)
  a=$(screen_lines "$(above_raw "$2")")
  k=$(head -1 <<<"$a"); a=$(tail -n +2 <<<"$a")
  n=$(grep -c . <<<"$r") m=$(grep -c . <<<"$a")
  (( m >= 1 && m <= n && n - m <= k + 1 )) || return 1
  [[ $(head -n "$m" <<<"$r") == "$a" || $(tail -n "$m" <<<"$r") == "$a" ]]
}
# Whether PANE's screen above the box stays as REF (above_raw) and not busy for SECONDS.
steady() { # PANE SECONDS REF
  local i n s
  n=$(awk -v s="$2" -v t="${FLEET_TICK:-0.5}" 'BEGIN { n = int(s / t + 0.999); print (n < 1) ? 1 : n }')
  for (( i = 0; i < n; i++ )); do
    sleep "${FLEET_TICK:-0.5}"
    s=$(screen "$1")
    ! busy "$s" && [[ $(above_raw "$s") == "$3" ]] || return 1
  done
}
# Claude Code's dialog on /exit while background work runs ("Exit and stop tasks" first), standing
# where the input box was: a transcript that only quotes its title is no dialog.
exit_dialog() {
  local tail
  has_input_box "$1" && return 1
  tail=$(plain <<<"$1" | grep -v '^[[:space:]]*$' | tail -12)
  grep -q '^ *Background work is running' <<<"$tail" && grep -q 'Esc to cancel' <<<"$tail"
}
no_exit_dialog() { ! exit_dialog "$1"; }
# Refuse the close for WHY (at_rest's or the screen's), saying so; returns 10 to 12.
refuse() { # NAME PANE WHY
  flog WARN "close: not confirmed at rest; left open" name="$1" pane="$2" why="$3"
  case $3 in
    working) err "refused: $1 is working again (its session file says so); close it once the turn ends"; return 10 ;;
    working*) err "refused: $1 is working again (${3#working (}; close it once the turn ends"; return 10 ;;
    background*) err "refused: $1 still has background work running (a shell or watcher dies with its pane); close it once that ends"; return 11 ;;
    wrapup*) err "refused: $1 owes the wall's wrap-up an answer (${3#wrapup }): its checkpoint turn may still run; close it once it answers or the request closes"; return 12 ;;
    *) err "refused: cannot confirm $1 is idle (${3#* }); left open"; return 12 ;;
  esac
}
# The checks and the /exit hold one pane lock, so a `fleet send` that is mid-paste cannot start a
# turn between them. A finished agent may work again (a follow-up message, a phone prompt, the
# wrap-up's checkpoint): /exit would end the turn or kill its shells with the pane. So the pane must
# look idle with an empty box, its session file be at rest, and then both stay unchanged for
# FLEET_CLOSE_QUIET s (the hook writes the file async, up to a second after a prompt). /exit is
# typed, both are read once more, and only then is Enter pressed. The pane is never killed: one that
# does not go is left open and said so.
close_now() { # PANE NAME SID
  local s ref fp why q=${FLEET_CLOSE_QUIET:-6}
  [[ $q =~ ^[0-9]+([.][0-9]+)?$ ]] || q=6
  s=$(screen "$1")
  busy "$s" && { refuse "$2" "$1" "working ($1 is mid-turn)"; return; }
  idle_empty "$s" || { refuse "$2" "$1" "unconfirmed its input box is not showing, or holds text"; return; }
  fp=$(at_rest "$1" "$3") || { refuse "$2" "$1" "$fp"; return; }
  ref=$(above_raw "$s")
  steady "$1" "$q" "$ref" || { refuse "$2" "$1" "working (its screen changed within ${q} s)"; return; }
  why=$(at_rest "$1" "$3") || { refuse "$2" "$1" "$why"; return; }
  [[ $why == "$fp" ]] || { refuse "$2" "$1" "working (its session file was written within ${q} s)"; return; }
  type_exactly "$1" "/exit" || return 13
  why=$(at_rest "$1" "$3")
  s=$(screen "$1")
  if [[ $why != "$fp" ]] || busy "$s" || ! same_transcript "$ref" "$s" || [[ $(input_text "$s") != /exit ]]; then
    # Back out only our own /exit: text typed after it stays, and so does the close's refusal.
    [[ $(input_text "$s") == /exit ]] && t send-keys -t "$1" -N 5 BSpace
    if [[ $why == "$fp" ]]; then why="working (its screen or box changed as /exit went in)"
    elif [[ $why =~ ^[0-9]+\ [0-9]+$ ]]; then why="working (its session file was written as /exit went in)"; fi
    refuse "$2" "$1" "$why"
    return
  fi
  t send-keys -t "$1" Enter
  exit_wait "$1"
}
# After /exit: 0 once PANE has gone; 14 when Claude Code asked to stop background work (cancelled
# with Esc, its default being "Exit and stop tasks"); 15 when it is still there after
# FLEET_CLOSE_EXIT_WAIT s.
exit_wait() { # PANE
  local end=$((SECONDS + ${FLEET_CLOSE_EXIT_WAIT:-30})) s
  while :; do
    fleet_panes | grep -qx -- "$1" || return 0
    s=$(screen "$1")
    if exit_dialog "$s"; then
      t send-keys -t "$1" Escape
      wait_for "$1" 5 no_exit_dialog || return 16
      return 14
    fi
    (( SECONDS >= end )) && return 15
    sleep "${FLEET_TICK:-0.5}"
  done
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
    14)
      flog WARN "close: /exit asked to stop background work; cancelled, left open" name="$name" pane="$pane"
      err "left open: $name still runs background work (/exit asked to stop it; cancelled with Esc); close it once that ends"
      exit 1 ;;
    15 | 16)
      flog WARN "close: the pane did not go after /exit; left open" name="$name" pane="$pane" rc="$rc"
      err "left open: $pane is still there after /exit$( (( rc == 16 )) && printf ' (its stop-tasks dialog would not cancel)'); look at it"
      exit 1 ;;
    75) err "could not take $pane's lock (a send is using it); try again"; exit 1 ;;
    *) err "could not close $pane (/exit would not go in); it is left open"; exit 1 ;;
  esac
fi
with_registry dr_drop "$name" || { err "done-reports.tsv could not be updated"; exit 1; }
