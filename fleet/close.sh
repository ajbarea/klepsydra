#!/usr/bin/env bash
# close.sh NAME: close the pane of a finished agent once its report is read
# (#445). `fleet done` leaves the pane open so the report can be read; the
# orchestrator runs this after reading it. NAME must be in finished.tsv (a
# running agent is never closed), and its pane must still run the session that
# finished there: panes ids are reused by a restarted tmux server. The pane gets
# /exit once it is confirmed at rest (close_now), and is never killed. The
# agent's record in done-reports.tsv is dropped, which also clears the doctor's
# flag. Exits 1 when NAME has not finished, the pane is the orchestrator's, is
# not confirmed at rest, or is still there after /exit; 2 on bad usage. Each
# refusal is logged with the check that failed and what differed;
# `close.sh --why NAME` prints NAME's last close record from the fleet log.
set -u
FLEET_TARGET=fleet::close
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
FINISHED=${FLEET_FINISHED:-$FLEET_STATE/finished.tsv}
usage="usage: fleet close NAME | fleet close --why NAME"
# NAME's last close record in the fleet log (the current one, then the renamed ones, newest first):
# its time and message, then each field (the check that failed, why, what differed) on its own line.
why_report() { # NAME
  local f rec=
  while IFS= read -r f; do
    rec=$(tr -d '\000' <"$f" 2>/dev/null | grep -a -F '"target":"fleet::close"' \
      | jq -R -c --arg n "$1" 'fromjson? | select(type == "object" and .name == $n)' 2>/dev/null | tail -1)
    [[ -n $rec ]] && break
  done < <(printf '%s\n' "$FLEET_LOG"; find "${FLEET_LOG%/*}" -maxdepth 1 -name "$(basename "${FLEET_LOG%.log}")_*.log" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  [[ -n $rec ]] || { err "no close of $1 in the fleet log"; return 1; }
  jq -r '"\(.ts) \(.level) \(.message)",
    (to_entries[] | select(.key | IN("ts", "level", "target", "message", "run_id", "name") | not) | "  \(.key): \(.value)")' <<<"$rec"
}
case ${1:-} in
  -h | --help) echo "$usage"; exit 0 ;;
  --why) (( $# == 2 )) && [[ -n $2 ]] || { err "$usage"; exit 2; }; why_report "$2"; exit ;;
esac
(( $# == 1 )) && [[ -n $1 ]] || { err "$usage"; exit 2; }
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
above_raw() { head -n "$(above_rows "$1")" <<<"$1"; } # SCREEN
# How many rows SCREEN has above the input box's top rule, blank ones included: counted from the
# rule's position, since a command substitution drops a text's trailing blank rows.
above_rows() { # SCREEN
  plain <<<"$1" | awk 'index($0, "────") == 1 { r[++k] = NR } END { print (k >= 2) ? r[k - 1] - 1 : NR }'
}
# ABOVE (above_raw's) as plain lines, trailing spaces trimmed and the slash-command menu that typing
# /exit opens dropped. Blank rows stay: each is a row the menu can cover, so a transcript that
# scrolls up under the menu cannot hide behind blank rows that scrolled off its top. Claude Code
# 2.1.316 draws that menu just above the box, over the transcript's last rows: "  ❯ /exit" and its
# description, then "    /name" rows whose descriptions start in the same column,
# a description too long for the pane wrapping onto lines indented to exactly that column (an
# 84-column pane wraps two of the three). Only such a block, running from the "❯ /exit" row to the
# last line, is dropped; anything else in it keeps the whole block. Prints how many lines went, then
# the rest.
screen_lines() { # ABOVE
  plain <<<"$1" | sed 's/[[:space:]]*$//' | awk '{ l[++n] = $0 } END {
    k = 0
    for (h = n; h >= 1; h--) if (l[h] ~ /^  ❯ \/exit( |$)/) break
    if (h >= 1) {
      t = l[h]; gsub(/❯/, "*", t)   # one column, whether awk counts bytes or characters
      d = match(t, /^  \* \/exit +[^ ]/) ? RLENGTH - 1 : 0
      ok = 1
      for (i = h + 1; i <= n && ok; i++) {
        if (match(l[i], /^    \/[^ ]+ +[^ ]/)) ok = d > 0 && RLENGTH - 1 == d
        else if (l[i] ~ /^    \/[^ ]+ *$/) ok = 1
        else ok = d > 0 && match(l[i], /^ +[^ ]/) && RLENGTH - 1 == d
      }
      if (ok) { k = n - h + 1; n = h - 1 }
    }
    print k; for (i = 1; i <= n; i++) print l[i] }'
}
# Whether AFTER (a screen with /exit typed) shows the transcript of REF (the screen read before
# the quiet window) unchanged, row for row from the top: the menu is drawn over the transcript's
# last rows (2.1.316, at 84 and 160 columns), so at most the rows it covers are missing, and only from the end. A
# transcript that scrolled up under the menu (a prompt and its spinner arriving as /exit went in)
# fails. One that fills a blank gap under the menu without moving a visible row passes here; the
# session file's fingerprint, read again before Enter, is what sees that turn. Rows are counted from
# the box's position, blank ones included. Fails with SAME_WHY set to the counts and the first lines
# that differ, for the refusal's log.
same_transcript() { # REF AFTER
  local r a k n m
  n=$(above_rows "$1")
  r=$(screen_lines "$(above_raw "$1")" | tail -n +2)
  a=$(screen_lines "$(above_raw "$2")")
  k=$(head -1 <<<"$a"); a=$(tail -n +2 <<<"$a")
  m=$(( $(above_rows "$2") - k ))
  if (( m >= 1 && m <= n && n - m <= k )) && [[ $(head -n "$m" <<<"$r") == "$(head -n "$m" <<<"$a")" ]]; then
    return 0
  fi
  SAME_WHY="menu lines dropped $k, transcript lines before $n, after $m; differs: $(excerpt "$r" "$a")"
  return 1
}
# The first lines that differ between OLD and NEW (plain text), at most 5, each cut to 120
# characters and joined by " | ", then how many blank lines differ: what a refusal's log shows of a
# screen that changed. Blank lines are counted, not quoted, so they cannot hide the line that moved.
excerpt() { # OLD NEW
  local LC_ALL=C.UTF-8 l out='' d b
  d=$(diff -- <(printf '%s\n' "$1") <(printf '%s\n' "$2") | grep -E '^[<>] ')
  while IFS= read -r l; do
    l=${l%"${l##*[![:space:]]}"}
    out+="${out:+ | }${l:0:120}"
  done < <(grep -E '^[<>] +[^[:space:]]' <<<"$d" | head -5)
  b=$(grep -cE '^[<>][[:space:]]*$' <<<"$d")
  (( b > 0 )) && out+="${out:+ | }($b blank lines)"
  printf '%s' "${out:-(none)}"
}
# The first line of stdin, cut to N characters (120).
clip() { local LC_ALL=C.UTF-8 l; IFS= read -r l; printf '%s' "${l:0:${1:-120}}"; }
# SID's session file in brief, for a refusal's log: its state, reason, background count, and when
# it was last written.
session_brief() { # SID
  jq -c '{state, reason, background: ((.background // []) | if type == "array" then length else . end), written_at}' \
    -- "$KLEPSYDRA_DIR/fleet/$1.json" 2>/dev/null || echo unreadable
}
# Whether PANE's screen above the box stays as REF (above_raw) and not busy for SECONDS. Fails with
# STEADY_SCREEN set to the screen that broke it.
steady() { # PANE SECONDS REF
  local i n s
  n=$(awk -v s="$2" -v t="${FLEET_TICK:-0.5}" 'BEGIN { n = int(s / t + 0.999); print (n < 1) ? 1 : n }')
  for (( i = 0; i < n; i++ )); do
    sleep "${FLEET_TICK:-0.5}"
    s=$(screen "$1")
    ! busy "$s" && [[ $(above_raw "$s") == "$3" ]] || { STEADY_SCREEN=$s; return 1; }
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
# Refuse the close for WHY (at_rest's or the screen's), found by CHECK (busy, input_box,
# session_file, quiet_screen, fingerprint, transcript, input_text), saying so in one line that names
# the check; the log line adds what differed (KEY=VALUE...). Returns 10 to 12.
refuse() { # NAME PANE CHECK WHY [KEY=VALUE...]
  local c=$3 w=$4 more
  flog WARN "close: not confirmed at rest; left open" name="$1" pane="$2" check="$c" why="$w" "${@:5}"
  more="[check: $c; fleet close --why $1]"
  case $w in
    working) err "refused: $1 is working again (its session file says so); close it once the turn ends $more"; return 10 ;;
    working*) err "refused: $1 is working again (${w#working (}; close it once the turn ends $more"; return 10 ;;
    background*) err "refused: $1 still has background work running (a shell or watcher dies with its pane); close it once that ends $more"; return 11 ;;
    wrapup*) err "refused: $1 owes the wall's wrap-up an answer (${w#wrapup }): its checkpoint turn may still run; close it once it answers or the request closes $more"; return 12 ;;
    *) err "refused: cannot confirm $1 is idle (${w#* }); left open $more"; return 12 ;;
  esac
}
# The checks and the /exit hold one pane lock, so a `fleet send` that is mid-paste cannot start a
# turn between them. A finished agent may work again (a follow-up message, a phone prompt, the
# wrap-up's checkpoint): /exit would end the turn or kill its shells with the pane. So the pane must
# look idle with an empty box, its session file be at rest, and then both stay unchanged for
# FLEET_CLOSE_QUIET s (the hook writes the file async, up to a second after a prompt). /exit is
# typed, both are read once more, and again after FLEET_CLOSE_SETTLE s (2: past the hook's write,
# since the menu /exit opens covers the rows a new turn's spinner would show in), and only then is
# Enter pressed. The pane is never killed: one that does not go is left open and said so.
close_now() { # PANE NAME SID
  local s s0 ref fp why box q=${FLEET_CLOSE_QUIET:-6} g=${FLEET_CLOSE_SETTLE:-2}
  [[ $q =~ ^[0-9]+([.][0-9]+)?$ ]] || q=6
  [[ $g =~ ^[0-9]+([.][0-9]+)?$ ]] || g=2
  s=$(screen "$1")
  busy "$s" && { refuse "$2" "$1" busy "working ($1 is mid-turn)" spinner="$(near 4 | grep -E '… \(|esc to interrupt' | clip)"; return; }
  if ! idle_empty "$s"; then
    box=$(input_text "$s")
    refuse "$2" "$1" input_box "unconfirmed its input box is not showing, or holds text" \
      box="$(has_input_box "$s" && echo shown || echo missing)" text="$(clip 80 <<<"$box")"
    return
  fi
  fp=$(at_rest "$1" "$3") || { refuse "$2" "$1" session_file "$fp" session="$(session_brief "$3")"; return; }
  ref=$(above_raw "$s") s0=$s
  steady "$1" "$q" "$ref" || { refuse "$2" "$1" quiet_screen "working (its screen changed within ${q} s)" \
    busy="$(busy "$STEADY_SCREEN" && echo yes || echo no)" differs="$(excerpt "$(plain <<<"$ref")" "$(above_raw "$STEADY_SCREEN" | plain)")"; return; }
  why=$(at_rest "$1" "$3") || { refuse "$2" "$1" session_file "$why" session="$(session_brief "$3")"; return; }
  [[ $why == "$fp" ]] || { refuse "$2" "$1" fingerprint "working (its session file was written within ${q} s)" \
    fp_before="$fp" fp_after="$why" session="$(session_brief "$3")"; return; }
  type_exactly "$1" "/exit" || { flog WARN "close: /exit would not go in; left open" name="$2" pane="$1" check=typing; return 13; }
  why=$(at_rest "$1" "$3")
  s=$(screen "$1")
  box=$(input_text "$s")
  # Each check in turn, the first that fails named: the file, a turn, the transcript, the box.
  local check='' more=()
  if [[ $why != "$fp" ]]; then
    if [[ $why =~ ^[0-9]+\ [0-9]+$ ]]; then
      check=fingerprint more=(fp_before="$fp" fp_after="$why" session="$(session_brief "$3")")
      why="working (its session file was written as /exit went in)"
    else
      check=session_file more=(session="$(session_brief "$3")")
    fi
  elif busy "$s"; then
    check=busy why="working (a turn started as /exit went in)" more=(spinner="$(near 4 | grep -E '… \(|esc to interrupt' | clip)")
  elif ! same_transcript "$s0" "$s"; then
    check=transcript why="working (its screen changed as /exit went in)" more=(differs="$SAME_WHY")
  elif [[ $box != /exit ]]; then
    check=input_text why="working (its box changed as /exit went in)" more=(text="$(clip 80 <<<"$box")")
  elif ! steady "$1" "$g" "$(above_raw "$s")"; then
    check=quiet_screen why="working (its screen changed within ${g} s of /exit going in)" box=$(input_text "$STEADY_SCREEN")
    more=(differs="$(excerpt "$(above_raw "$s" | plain)" "$(above_raw "$STEADY_SCREEN" | plain)")")
  elif why=$(at_rest "$1" "$3"); [[ $why != "$fp" ]]; then
    if [[ $why =~ ^[0-9]+\ [0-9]+$ ]]; then
      check=fingerprint more=(fp_before="$fp" fp_after="$why" session="$(session_brief "$3")")
      why="working (its session file was written within ${g} s of /exit going in)"
    else
      check=session_file more=(session="$(session_brief "$3")")
    fi
    box=$(input_text "$(screen "$1")")
  # The last look before Enter: the box still holds just our /exit, and no spinner shows (where the
  # menu leaves its row in view; at 84 columns it covers it, and the fingerprint is the guard).
  elif s=$(screen "$1"); box=$(input_text "$s"); busy "$s"; then
    check=busy why="working (a turn started within ${g} s of /exit going in)" more=(spinner="$(near 4 | grep -E '… \(|esc to interrupt' | clip)")
  elif [[ $box != /exit ]]; then
    check=input_text why="working (its box changed within ${g} s of /exit going in)" more=(text="$(clip 80 <<<"$box")")
  fi
  if [[ -n $check ]]; then
    # Back out only our own /exit: text typed after it stays, and so does the close's refusal.
    [[ $box == /exit ]] && t send-keys -t "$1" -N 5 BSpace
    refuse "$2" "$1" "$check" "$why" "${more[@]}"
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
  flog WARN "close: the orchestrator's pane; left open" name="$name" pane="$pane" check=orchestrator
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
    75)
      flog WARN "close: the pane's lock was busy; left open" name="$name" pane="$pane" check=lock
      err "could not take $pane's lock (a send is using it); try again"; exit 1 ;;
    *) err "could not close $pane (/exit would not go in); it is left open"; exit 1 ;;
  esac
fi
with_registry dr_drop "$name" || { err "done-reports.tsv could not be updated"; exit 1; }
