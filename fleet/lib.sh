#!/usr/bin/env bash
# Shared by the fleet scripts: where things live, the log, and how a Claude
# Code pane's screen is read and typed into. Sourced, never run.

FLEET_STATE=${FLEET_STATE:-$HOME/.local/state/fleet-orchestrator}
FLEET_SOCK=${FLEET_SOCK:-klepsydra}
FLEET_SESSION=${FLEET_SESSION:-fleet}
KLEPSYDRA_DIR=${KLEPSYDRA_DIR:-/mnt/c/Users/ajbar/AppData/Local/dev.ajsoftworks.klepsydra}
FLEET_LOG=${FLEET_LOG:-$FLEET_STATE/log/fleet.log}
FLEET_LOG_MAX=${FLEET_LOG_MAX:-1048576} # bytes before the log is renamed and a new one starts
FLEET_LOG_KEEP=4                        # renamed logs kept
FLEET_TARGET=${FLEET_TARGET:-fleet::$(basename "${0%.sh}")}
# A fleet-wide id for the lines of one run (a launch, one resume pass).
FLEET_RUN_ID=${FLEET_RUN_ID:-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')}
export FLEET_RUN_ID

# The preamble a fresh session's brief starts with; WHY says why it replaces the last one.
fresh_preamble() { # WHY
  printf 'Fresh start: a previous agent with the brief below %s; you replace it. Before acting, rebuild state from disk and GitHub: IMPL.md in the repo and in each worktree, git log and git status per worktree, open PRs with their comments and reviews, and your repo'"'"'s lines under "Running now" in /mnt/c/Users/ajbar/fleet-briefing/claude-queue.md. Where those are newer than the brief, they win; never redo merged work. No /code-review high (nor xhigh or max); low or medium is fine.' "$1"
}

t() { tmux -L "$FLEET_SOCK" "$@"; }

err() { printf 'error: %s\n' "$*" >&2; }

# flog LEVEL MESSAGE [KEY=VALUE...]: one JSON line in the fleet log (the
# klepsydra log's fields: ts, level, target, message, then the event's own),
# and the same as a plain line on stderr.
flog() {
  local level=$1 message=$2 kv
  shift 2
  local -a named=()
  for kv in "$@"; do named+=(--arg "${kv%%=*}" "${kv#*=}"); done
  local line
  line=$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" --arg level "$level" \
    --arg target "$FLEET_TARGET" --arg message "$message" --arg run_id "$FLEET_RUN_ID" "${named[@]}" \
    '{ts: $ts, level: $level, target: $target, message: $message}
     + ($ARGS.named | del(.ts, .level, .target, .message))') || return 0
  printf '%s %s %s %s\n' "$(date '+%F %T')" "$level" "$message" "$*" >&2
  mkdir -p -- "${FLEET_LOG%/*}" 2>/dev/null
  (
    flock 9
    local size
    size=$(stat -c %s -- "$FLEET_LOG" 2>/dev/null || echo 0)
    if (( size > FLEET_LOG_MAX )); then
      mv -- "$FLEET_LOG" "${FLEET_LOG%.log}_$(date -u +%Y%m%dT%H%M%S.%NZ).log"
      local old
      while IFS= read -r old; do rm -f -- "${old:?}"; done < <(find "${FLEET_LOG%/*}" -maxdepth 1 -name "$(basename "${FLEET_LOG%.log}")_*.log" -printf '%T@ %p\n' | sort -rn | tail -n +$((FLEET_LOG_KEEP + 1)) | cut -d' ' -f2-)
    fi
    printf '%s\n' "$line" >>"$FLEET_LOG"
  ) 9>>"${FLEET_LOG%/*}/.lock"
}

# Claude Code's screen as capture-pane shows it, with its escapes.
screen() { t capture-pane -e -p -t "$1" 2>/dev/null; }

# Text with its escapes removed: SGR and other CSI, and OSC 8 links.
plain() { sed -E $'s/\e\\][^\a\e]*(\a|\e\\\\)//g; s/\e\\[[0-9;?]*[A-Za-z]//g'; }

# The input box of SCREEN (with escapes): the lines between its last two rules
# (U+2500), the first starting with U+276F. Prints its text, dim text
# (Claude Code's placeholder and suggestions) and the mark removed, or
# nothing when the box is empty or not on screen (a menu replaces it).
input_text() {
  sed -E $'s/\e\\[2m[^\e]*//g' <<<"$1" | plain | awk '
    index($0, "────") == 1 { r[++n] = NR }
    { line[NR] = $0 }
    END {
      if (n < 2 || r[n] - r[n - 1] < 2) exit
      first = line[r[n - 1] + 1]
      if (index(first, "❯") != 1) exit
      sub(/^❯(\xc2\xa0| )?/, "", first)
      out = first
      for (i = r[n - 1] + 2; i < r[n]; i++) { l = line[i]; sub(/^  /, "", l); out = out " " l }
      gsub(/\xc2\xa0/, " ", out); sub(/[ \n]+$/, "", out); sub(/^ +/, "", out)
      printf "%s", out
    }'
}

# Whether SCREEN shows the input box at all (idle, or typed into).
has_input_box() {
  plain <<<"$1" | awk 'index($0, "────") == 1 { r[++n] = NR } { line[NR] = $0 }
    END { exit !(n >= 2 && r[n] - r[n - 1] >= 2 && index(line[r[n - 1] + 1], "❯") == 1) }'
}

# The lines above the input box's top rule (or the whole screen without one)
# and below its bottom rule, plain, as ABOVE and BELOW.
split_screen() { # SCREEN
  local p
  p=$(plain <<<"$1")
  ABOVE=$(awk 'index($0, "────") == 1 { r[++n] = NR } { line[NR] = $0 }
    END { last = (n >= 2) ? r[n - 1] - 1 : NR; for (i = 1; i <= last; i++) print line[i] }' <<<"$p")
  BELOW=$(awk 'index($0, "────") == 1 { r[++n] = NR } { line[NR] = $0 }
    END { if (n < 2) exit; for (i = r[n] + 1; i <= NR; i++) print line[i] }' <<<"$p")
}

# The last non-empty lines of ABOVE, nearest the input box.
near() { grep -v '^[[:space:]]*$' <<<"$ABOVE" | tail -"${1:-6}"; }

# A turn is running: the spinner line ("… (" with its timer, or "esc to
# interrupt") sits just above the input box.
busy() { split_screen "$1"; near 4 | grep -Eq '… \(|esc to interrupt'; }

LIMIT_RE='hit your (session|weekly|usage) limit|Usage limit reached'

# The limit message nearest the input box: Claude Code's "hit your ... limit"
# as the last thing the session printed, or the status line's "Usage limit
# reached" banner below the box. Prints it; fails when there is none.
limit_line() {
  split_screen "$1"
  { near 6; printf '%s\n' "$BELOW"; } | grep -E "$LIMIT_RE" | tail -1 | grep .
}

# The epoch at which the reset in TEXT falls, from NOW: "resets 1:10pm",
# "resets 4:10am", "resets Nov 2, 1pm" or "resets Nov 2, 1:30pm", each with an
# optional "(Area/City)" zone (else local time). A time-only reset more than 6 h
# past is tomorrow's; a dated one more than 180 days past is next year's.
# Fails when TEXT names none.
reset_epoch() { # TEXT NOW
  local text=$1 now=$2 m
  m=$(grep -oE 'resets ([A-Z][a-z]{2} [0-9]{1,2}, )?[0-9]{1,2}(:[0-9]{2})? ?[ap]m( \([A-Za-z0-9_+/-]+\))?' <<<"$text" | tail -1)
  local re='^resets (([A-Z][a-z]{2}) ([0-9]{1,2}), )?([0-9]{1,2})(:([0-9]{2}))? ?([ap]m)( \(([A-Za-z0-9_+/-]+)\))?$'
  [[ $m =~ $re ]] || return 1
  local mon=${BASH_REMATCH[2]} day=${BASH_REMATCH[3]} hour=${BASH_REMATCH[4]} min=${BASH_REMATCH[6]:-00}
  local ampm=${BASH_REMATCH[7]} zone=${BASH_REMATCH[9]} tz="" year date at
  [[ -n $zone && -e /usr/share/zoneinfo/$zone ]] || zone=""
  [[ -n $zone ]] && tz="TZ=\"$zone\" "
  # The day and year NOW falls on where the reset is said, so the parse never reads the clock.
  if [[ -n $zone ]]; then
    year=$(TZ=$zone date -d "@$now" +%Y) date=$(TZ=$zone date -d "@$now" +%F)
  else
    year=$(date -d "@$now" +%Y) date=$(date -d "@$now" +%F)
  fi
  if [[ -n $mon ]]; then
    at=$(date -d "$tz$mon $day $year $hour:$min$ampm" +%s 2>/dev/null) || return 1
    (( now - at > 180 * 86400 )) && at=$(date -d "$tz$mon $day $((year + 1)) $hour:$min$ampm" +%s)
  else
    at=$(date -d "$tz$date $hour:$min$ampm" +%s 2>/dev/null) || return 1
    (( now - at > 21600 )) && at=$((at + 86400))
  fi
  printf '%s\n' "$at"
}

# Wait up to SECONDS for pane PANE's screen to satisfy CHECK (a function
# given the screen); fails on time out.
wait_for() { # PANE SECONDS CHECK
  local end=$((SECONDS + $2)) s
  while :; do
    s=$(screen "$1")
    "$3" "$s" && return 0
    (( SECONDS >= end )) && return 1
    sleep "${FLEET_TICK:-0.5}"
  done
}

# Claude Code's limit menu, standing where the input box was.
limit_menu() {
  local tail
  has_input_box "$1" && return 1
  tail=$(plain <<<"$1" | grep -v '^[[:space:]]*$' | tail -8)
  grep -q 'Stop and wait for limit to reset' <<<"$tail" && grep -q 'Enter to confirm' <<<"$tail"
}

# Type TEXT into PANE's empty input box and wait until the box holds exactly
# it. If it holds more (AJ typed meanwhile), the script's own characters are
# backed out, leaving his, and it fails.
type_exactly() { # PANE TEXT
  local p=$1 text=$2 end got want
  # Compared without whitespace: a long line wraps in the box.
  want=${text//[[:space:]]/}
  t send-keys -t "$p" -l "$text"
  end=$((SECONDS + 5))
  while (( SECONDS < end )); do
    got=$(input_text "$(screen "$p")")
    got=${got//[[:space:]]/}
    [[ $got == "$want" ]] && return 0
    [[ ${#got} -gt ${#want} ]] && break
    sleep "${FLEET_TICK:-0.5}"
  done
  t send-keys -t "$p" -N "${#text}" BSpace
  return 1
}

idle_empty() { has_input_box "$1" && [[ -z $(input_text "$1") ]] && ! busy "$1"; }
holds_input() { [[ -n $(input_text "$1") ]]; }
started() { busy "$1" || limit_line "$1" >/dev/null; }
rc_settled() { # the connect line, or the menu shown when it is already on
  local p
  p=$(plain <<<"$1")
  grep -q 'Enter to select · Esc to continue' <<<"$p" && return 0
  split_screen "$1"
  near 4 | grep -q '/remote-control is active' && idle_empty "$1"
}

# Turn Remote Control on in PANE, idle at an empty prompt, and wait for it to
# settle: the connect line, or (already on) its menu, answered with Continue.
# Fails, having typed nothing more, when the pane is not idle at an empty
# prompt or the command never settles.
remote_control() { # PANE
  local p=$1 s
  s=$(screen "$p")
  idle_empty "$s" || return 1
  type_exactly "$p" "/remote-control" || return 1
  t send-keys -t "$p" Enter
  wait_for "$p" "${FLEET_RC_WAIT:-20}" rc_settled || return 1
  s=$(screen "$p")
  if grep -q 'Enter to select · Esc to continue' <<<"$(plain <<<"$s")"; then
    # Continue is preselected the first time the menu shows; Esc also continues.
    if plain <<<"$s" | grep -Eq '^ *❯ Continue'; then t send-keys -t "$p" Enter; else t send-keys -t "$p" Escape; fi
    wait_for "$p" 10 idle_empty || return 1
  fi
}

# Put FILE's text in PANE's input box (a bracketed paste, so newlines do not
# submit) and submit it once it shows there. Once the box has emptied the text
# was sent, so it is never pasted again; while it still holds it, Enter is
# pressed again. Never sends Escape, which would cancel a turn that started.
# Prints started, blocked-by-limit or not-delivered.
deliver() { # PANE FILE
  local p=$1 file=$2 s
  s=$(screen "$p")
  if busy "$s"; then echo started; return 0; fi
  if [[ -z $(input_text "$s") ]]; then
    for _ in 1 2 3; do
      wait_for "$p" 10 idle_empty || continue
      t load-buffer -b "fleet-$$" "$file" && t paste-buffer -p -d -b "fleet-$$" -t "$p"
      wait_for "$p" 10 holds_input && break
    done
    holds_input "$(screen "$p")" || { echo not-delivered; return 0; }
  fi
  for _ in 1 2 3; do
    t send-keys -t "$p" Enter
    wait_for "$p" "${FLEET_START_WAIT:-30}" sent_or_started || continue
    s=$(screen "$p")
    busy "$s" && { echo started; return 0; }
    holds_input "$s" && continue
    # Sent: wait for its turn, or the limit, without touching the pane.
    if wait_for "$p" "${FLEET_TURN_WAIT:-60}" started; then
      if busy "$(screen "$p")"; then echo started; else echo blocked-by-limit; fi
    else
      echo not-delivered
    fi
    return 0
  done
  echo not-delivered
}
sent_or_started() { started "$1" || { has_input_box "$1" && [[ -z $(input_text "$1") ]]; }; }

# klepsydra's newest usage reading (one file per session under accounts/<id>/).
newest_reading() {
  find "$KLEPSYDRA_DIR/accounts" -mindepth 2 -maxdepth 2 -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
}

# The registry, panes.tsv: pane, name, brief, then (from launch.sh) session id and folder.
REGISTRY=${REGISTRY:-$FLEET_STATE/panes.tsv}
registered() { awk -F'\t' -v p="$1" '$1 == p { f = 1 } END { exit !f }' "$REGISTRY" 2>/dev/null; }
reg_field() { awk -F'\t' -v p="$1" -v n="$2" '$1 == p { print $n; exit }' "$REGISTRY" 2>/dev/null; }
orchestrator() { cat "$FLEET_STATE/orchestrator.pane" 2>/dev/null; }
fleet_panes() { t list-panes -s -t "$FLEET_SESSION" -F '#{pane_id}' 2>/dev/null; }

# The live session id klepsydra's fleet file shows in pane PANE, or nothing.
live_session() { # PANE
  local f
  for f in "$KLEPSYDRA_DIR"/fleet/*.json; do
    [[ -f $f && ! -L $f ]] || continue
    jq -e --arg p "$1" '.tmux.pane == $p and .ended == null' "$f" >/dev/null 2>&1 && { basename "$f" .json; return 0; }
  done
  return 1
}

# Set the registry's session id for pane PANE (column 4) to SID.
set_session() { # PANE SID
  local tmp
  [[ -e $REGISTRY ]] || return 1
  tmp=$(mktemp "$REGISTRY.XXXXXX") || return 1
  awk -F'\t' -v OFS='\t' -v p="$1" -v sid="$2" '$1 == p { $4 = sid } { print }' "$REGISTRY" >"$tmp" && mv -f -- "$tmp" "$REGISTRY"
}

# Whether pane PANE still runs the session registered for it: a live fleet
# file (klepsydra's, written by the fleet hook) with that session id and pane.
# After a tmux restart pane ids start over, so a stale panes.tsv row can name
# another agent's pane; nothing is exited, killed or cleared without this.
pane_runs() { # PANE SESSION-ID
  local f
  [[ $2 =~ ^[0-9a-f-]{36}$ ]] || return 1
  f=$KLEPSYDRA_DIR/fleet/$2.json
  [[ -f $f && ! -L $f ]] || return 1
  jq -e --arg p "$1" '.tmux.pane == $p and .ended == null' "$f" >/dev/null 2>&1
}
