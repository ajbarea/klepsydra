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

# prefs.json's KEY as compact JSON (null when absent), read as the tray reads
# the file: one JSON object and nothing after it. Fails 1 when the file is
# missing, 2 when it does not read as one object.
prefs_get() { # KEY
  local f=$KLEPSYDRA_DIR/prefs.json
  [[ -f $f ]] || return 1
  jq -sc --arg k "$1" 'if length == 1 and (.[0] | type) == "object" then .[0][$k] else error("not one object") end' "$f" 2>/dev/null || return 2
}

# What every session reads from ~/.claude (both config folders' hooks point
# there): "repo path, installed name" per entry. install.sh copies them, and
# doctor checks the copies still match the checkout.
FLEET_HOOK_DIR=${FLEET_HOOK_DIR:-$HOME/.claude}
# shellcheck disable=SC2034 # read by install.sh and doctor.sh
HOOK_COPIES=(
  "hooks/klepsydra-fleet.sh klepsydra-fleet.sh"
  "hooks/klepsydra-launch.sh klepsydra-launch.sh"
  "hooks/klepsydra-agy-locked.json klepsydra-agy-locked.json"
  "hooks/klepsydra-engine-rules.md klepsydra-engine-rules.md"
  "hooks/klepsydra-tmux.conf klepsydra-tmux.conf"
  "hooks/klepsydra-pane-died.sh klepsydra-pane-died.sh"
  "hooks/klepsydra-wrapup.sh klepsydra-wrapup.sh"
  "hooks/klepsydra-wrapup.md skills/klepsydra-wrapup/SKILL.md"
  "statusline/klepsydra-statusline.sh klepsydra-statusline.sh"
  "src/fleet/themes/kourai.json klepsydra-cast.json"
)

# The preamble a fresh session's brief starts with; WHY says why it replaces the last one.
fresh_preamble() { # WHY
  printf 'Fresh start: a previous agent with the brief below %s; you replace it. Before acting, rebuild state from disk and GitHub: IMPL.md in the repo and in each worktree, git log and git status per worktree, open PRs with their comments and reviews, and your repo'"'"'s lines under "Running now" in /mnt/c/Users/ajbar/fleet-briefing/queue.md. Where those are newer than the brief, they win; never redo merged work. No /code-review high (nor xhigh or max); low or medium is fine.' "$1"
}

t() { tmux -L "$FLEET_SOCK" "$@"; }

err() { printf 'error: %s\n' "$*" >&2; }

# tilde TEXT: TEXT with the home folder read as ~, as doctor prints it and as
# the phone's report shows it.
tilde() { local s=${1//"$HOME/"/\~/}; [[ $s == "$HOME" ]] && s="~"; printf '%s' "$s"; }
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

# Claude Code names the window in its message ("You've hit your 5-hour
# limit", "... weekly limit", "... Fable limit", "... org's monthly spend
# limit", earlier "session limit"), and renamed it once already (2.1.316,
# #263): any name of up to three words matches. No {m,n}: mawk ignores it.
W="[A-Za-z0-9'-]+ "
LIMIT_RE="You've hit your ($W)?($W)?($W)?limit([^A-Za-z]|$)|Usage limit reached"
unset W

# The limit message nearest the input box: Claude Code's "hit your ... limit"
# as the last thing the session printed, or the status line's "Usage limit
# reached" banner below the box. A message followed by a prompt sent after it
# (the resume service's continue, or AJ's line) is past, but not by a slash
# command's echo: Claude Code sends /rate-limit-options itself at a limit, and
# /usage or /login answer nothing. "hit your fast limit" is the /fast dialog's,
# not a usage limit. Prints it; fails when there is none.
limit_line() {
  split_screen "$1"
  { near 6 | awk -v re="$LIMIT_RE" '
      /hit your fast limit/ { next }
      $0 ~ re { l = $0; next }
      /^❯ / && !/^❯ \// { l = "" }
      END { if (l != "") print l }'
    printf '%s\n' "$BELOW" | grep -E "$LIMIT_RE"; } | tail -1 | grep .
}

# Whether EPOCH reads as HH:MM on the clock in ZONE (empty: local time). GNU
# date refuses a time a DST change skips; uutils date (Ubuntu 26.04) moves it
# forward by the DST shift. The round trip tells them apart on both.
reads_as() { # EPOCH ZONE HH:MM
  local got
  if [[ -n $2 ]]; then got=$(TZ=$2 date -d "@$1" +%H:%M 2>/dev/null); else got=$(date -d "@$1" +%H:%M 2>/dev/null); fi
  [[ -n $got && $got == "$3" ]]
}

# The epoch at which the reset in TEXT falls, from NOW: "resets 1:10pm",
# "resets 4:10am", "resets Nov 2, 1pm" or "resets Nov 2, 1:30pm", each with an
# optional "(Area/City)" zone (else local time). A time-only reset more than
# ROLL_S (default 6 h) past is tomorrow's, at the same wall-clock time across a
# DST change (Claude Code dates a reset only when it is over 24 h away); a dated
# one more than 180 days past is next year's, and more than 180 days ahead last year's.
# Fails when TEXT names none, or a time that does not exist that day.
reset_epoch() { # TEXT NOW [ROLL_S]
  local text=$1 now=$2 roll=${3:-21600} m
  m=$(grep -oE 'resets ([A-Z][a-z]{2} [0-9]{1,2}, )?[0-9]{1,2}(:[0-9]{2})? ?[ap]m( \([A-Za-z0-9_+/-]+\))?' <<<"$text" | tail -1)
  local re='^resets (([A-Z][a-z]{2}) ([0-9]{1,2}), )?([0-9]{1,2})(:([0-9]{2}))? ?([ap]m)( \(([A-Za-z0-9_+/-]+)\))?$'
  [[ $m =~ $re ]] || return 1
  local mon=${BASH_REMATCH[2]} day=${BASH_REMATCH[3]} hour=${BASH_REMATCH[4]} min=${BASH_REMATCH[6]:-00}
  local ampm=${BASH_REMATCH[7]} zone=${BASH_REMATCH[9]} tz="" year date at
  [[ -n $zone && -e /usr/share/zoneinfo/$zone ]] || zone=""
  [[ -n $zone ]] && tz="TZ=\"$zone\" "
  local h24 want
  h24=$((10#$hour % 12))
  [[ $ampm == pm ]] && h24=$((h24 + 12))
  printf -v want '%02d:%s' "$h24" "$min"
  # The day and year NOW falls on where the reset is said, so the parse never reads the clock.
  if [[ -n $zone ]]; then
    year=$(TZ=$zone date -d "@$now" +%Y) date=$(TZ=$zone date -d "@$now" +%F)
  else
    year=$(date -d "@$now" +%Y) date=$(date -d "@$now" +%F)
  fi
  if [[ -n $mon ]]; then
    at=$(date -d "$tz$mon $day $year $hour:$min$ampm" +%s 2>/dev/null) || return 1
    if (( now - at > 180 * 86400 )); then at=$(date -d "$tz$mon $day $((year + 1)) $hour:$min$ampm" +%s 2>/dev/null) || return 1; fi
    if (( at - now > 180 * 86400 )); then at=$(date -d "$tz$mon $day $((year - 1)) $hour:$min$ampm" +%s 2>/dev/null) || return 1; fi
    reads_as "$at" "$zone" "$want" || return 1
  else
    at=$(date -d "$tz$date $hour:$min$ampm" +%s 2>/dev/null) || return 1
    reads_as "$at" "$zone" "$want" || return 1
    if (( now - at > roll )); then
      date=$(date -d "$date 12:00 tomorrow" +%F) || return 1
      # A wall-clock time tomorrow's DST change skips names no instant: fail.
      at=$(date -d "$tz$date $hour:$min$ampm" +%s 2>/dev/null) || return 1
      reads_as "$at" "$zone" "$want" || return 1
    fi
  fi
  printf '%s\n' "$at"
}

# N seconds, or fewer when DELIVER_DEADLINE (a SECONDS value: launch.sh's
# deadline) comes sooner, but never under MIN (default 0).
capped() { # N [MIN]
  local n=$1 min=${2:-0} left
  if [[ -n ${DELIVER_DEADLINE:-} ]]; then
    left=$((DELIVER_DEADLINE - SECONDS))
    (( left < n )) && n=$left
    (( n < min )) && n=$min
  fi
  printf '%s' "$n"
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

not_busy() { has_input_box "$1" && ! busy "$1"; }
idle_empty() { has_input_box "$1" && [[ -z $(input_text "$1") ]] && ! busy "$1"; }
box_empty() { has_input_box "$1" && [[ -z $(input_text "$1") ]]; }
holds_input() { [[ -n $(input_text "$1") ]]; }
started() { busy "$1" || limit_line "$1" >/dev/null; }
# PANE (showing SCREEN) stopped at a usage limit: no turn running, and a limit
# line on the screen, else the fleet hook's StopFailure record (#311). Prints
# "RESET<TAB>LINE", RESET the record's reset epoch (0 when the screen says).
pane_limited() { # PANE SCREEN
  local l
  busy "$2" && return 1
  if l=$(limit_line "$2"); then printf '0\t%s\n' "$l"; else limit_event "$1"; fi
}
# "resets 4:10am" for a limit from pane_limited: from RESET when known, with its
# day unless that is today (NOW's), else from LINE's text. Empty when neither says.
reset_label() { # RESET LINE [NOW]
  if [[ $1 =~ ^[1-9][0-9]*$ ]]; then
    if [[ $(date -d "@$1" +%F) == "$(date -d "@${3:-$(date +%s)}" +%F)" ]]; then date -d "@$1" '+resets %-I:%M%P'; else date -d "@$1" '+resets %a %-I:%M%P'; fi
  else
    grep -oE 'resets [^(]*[ap]m' <<<"$2" | tail -1
  fi
}
# One typer per pane at a time (#325): two scripts typing into one box glue
# their text together, or one's Enter submits the other's half. Every sequence
# that types into a pane's box runs as `pane_locked PANE COMMAND...`; one nested
# in a held sequence (remote_control inside fresh-now's) runs at once. Waits up
# to FLEET_SEND_WAIT s; exits 75, running nothing, when the lock cannot be had
# or its file opened. Only short-lived tmux clients run under it.
pane_locked() { # PANE COMMAND [ARG...]
  local p=$1
  shift
  if [[ ${FLEET_PANE_HELD:-} == "$p" ]]; then "$@"; return; fi
  mkdir -p -- "$FLEET_STATE/locks" 2>/dev/null
  (
    { exec 9>"$FLEET_STATE/locks/send-${p#%}"; } 2>/dev/null || exit 75
    flock -w "${FLEET_SEND_WAIT:-45}" 9 || exit 75
    FLEET_PANE_HELD=$p "$@"
  )
}
rc_settled() { # the connect line, or the menu shown when it is already on
  local p
  p=$(plain <<<"$1")
  grep -q 'Enter to select · Esc to continue' <<<"$p" && return 0
  split_screen "$1"
  near 4 | grep -q '/remote-control is active' && idle_empty "$1"
}

# Type TEXT into PANE's empty box (type_exactly) and press Enter. Run it under
# pane_locked.
type_enter() { type_exactly "$1" "$2" && t send-keys -t "$1" Enter; } # PANE TEXT

# Turn Remote Control on in PANE, idle at an empty prompt, and wait for it to
# settle: the connect line, or (already on) its menu, answered with Continue.
# Fails, having typed nothing more, when the pane is not idle at an empty
# prompt or the command never settles.
remote_control() { pane_locked "$1" remote_control_now "$1"; } # PANE
remote_control_now() { # PANE
  local p=$1 s
  s=$(screen "$p")
  idle_empty "$s" || return 1
  type_exactly "$p" "/remote-control" || return 1
  t send-keys -t "$p" Enter
  if ! wait_for "$p" "$(capped "${FLEET_RC_WAIT:-20}")" rc_settled; then
    # Its Enter never took (a session still starting): the command is backed
    # out, so the brief that follows is not sent with it.
    [[ $(input_text "$(screen "$p")") == "/remote-control" ]] && t send-keys -t "$p" -N 15 BSpace
    return 1
  fi
  s=$(screen "$p")
  if grep -q 'Enter to select · Esc to continue' <<<"$(plain <<<"$s")"; then
    # Continue is preselected the first time the menu shows; Esc also continues.
    if plain <<<"$s" | grep -Eq '^ *❯ Continue'; then t send-keys -t "$p" Enter; else t send-keys -t "$p" Escape; fi
    wait_for "$p" "$(capped 10)" idle_empty || return 1
  fi
}

# Put FILE's text in PANE's input box (a bracketed paste, so newlines do not
# submit) and submit it once it shows there. Once the box has emptied the text
# was sent, so it is never pasted again; while it still holds it (a pasted
# block shows as "[Pasted text #1 +30 lines]", and an Enter right after a paste
# can be lost), Enter is pressed again, three times in all. Never sends Escape,
# which would cancel a turn that started. Every wait stops at DELIVER_DEADLINE.
# Prints started, blocked-by-limit or not-delivered.
deliver() { pane_locked "$1" deliver_brief "$@" || echo not-delivered; } # PANE FILE
deliver_brief() { # PANE FILE
  local p=$1 file=$2 s try
  s=$(screen "$p")
  if busy "$s"; then echo started; return 0; fi
  if [[ -z $(input_text "$s") ]]; then
    for _ in 1 2 3; do
      wait_for "$p" "$(capped 10)" idle_empty || continue
      t load-buffer -b "fleet-$$" "$file" && t paste-buffer -p -d -b "fleet-$$" -t "$p"
      # A paste not yet drawn gets at least 3 s before another, whatever the deadline.
      wait_for "$p" "$(capped 10 3)" holds_input && break
    done
    holds_input "$(screen "$p")" || { echo not-delivered; return 0; }
  fi
  for try in 1 2 3; do
    t send-keys -t "$p" Enter
    if ! wait_for "$p" "$(capped "${FLEET_START_WAIT:-10}")" sent_or_started; then
      flog WARN "the brief is still in the prompt after Enter; pressing it again" pane="$p" try="$try" box="$(input_text "$(screen "$p")" | cut -c1-60)"
      continue
    fi
    s=$(screen "$p")
    busy "$s" && { echo started; return 0; }
    holds_input "$s" && continue
    # Sent: wait for its turn, or the limit, without touching the pane.
    if wait_for "$p" "$(capped "${FLEET_TURN_WAIT:-60}")" started; then
      if busy "$(screen "$p")"; then echo started; else echo blocked-by-limit; fi
    else
      echo not-delivered
    fi
    return 0
  done
  echo not-delivered
}
sent_or_started() { started "$1" || { has_input_box "$1" && [[ -z $(input_text "$1") ]]; }; }

# Paste inbox file FILE into PANE and send it, only while the box is empty and
# no turn runs, right before the paste; it is sent only when the box then
# holds the message alone (its text, or a paste's placeholder), never with a
# line AJ began meanwhile. Claude Code shows a paste over 800 characters, or
# with more than two newlines, as "[Pasted text #N]" ("... +M lines]" when it
# has newlines). Prints sent, not-pasted, mixed (pasted beside a line AJ
# began: left in the box unsent, since taking it back out by keystrokes could
# take his characters with it) or held (still in the box after three Enters, or no
# longer the message alone: a dialog stands in its place, or AJ began a line).
# With ANY, a running turn is no bar (Claude Code queues a message sent during
# one), and it is sent once the box has emptied; a pane stopped at a usage
# limit gets nothing (limited).
# It holds the pane's typing lock (pane_locked): a delivery that cannot have it
# in FLEET_SEND_WAIT s, or whose lock file cannot be opened, gets not-pasted.
inbox_deliver() { # PANE FILE [any]
  local out
  out=$(pane_locked "$1" deliver_now "$@")
  echo "${out:-not-pasted}"
}
# The box holds the message (WANT, without whitespace) alone: its text, or a
# paste's placeholder. Both sides lose their whitespace the same way: a long line wraps.
msg_in_box() { # SCREEN WANT
  local box
  has_input_box "$1" || return 1
  box=$(input_text "$1")
  [[ ${box//[[:space:]]/} == "$2" || $box =~ ^\[Pasted\ text\ \#[0-9]+(\ \+[0-9]+\ lines)?\]$ ]]
}
deliver_now() { # PANE FILE [any]
  local p=$1 file=$2 want text gone=sent_or_started s
  if [[ ${3:-} == any ]]; then
    # Read under the lock: a pane stopped at a limit is the resume service's.
    s=$(screen "$p")
    pane_limited "$p" "$s" >/dev/null && { echo limited; return; }
    box_empty "$s" || { echo not-pasted; return; }
    gone=box_empty
  else
    idle_empty "$(screen "$p")" || { echo not-pasted; return; }
  fi
  t load-buffer -b "fleet-$$" "$file" && t paste-buffer -p -d -b "fleet-$$" -t "$p"
  wait_for "$p" 5 holds_input || { echo not-pasted; return; }
  text=$(<"$file")
  want=${text//[[:space:]]/}
  msg_in_box "$(screen "$p")" "$want" || { echo mixed; return; }
  for _ in 1 2 3; do
    t send-keys -t "$p" Enter
    wait_for "$p" "${FLEET_START_WAIT:-10}" "$gone" && { echo sent; return; }
    # Enter again only on the message itself: a dialog may stand where the box
    # was (an Enter would answer it), or AJ may have begun a line.
    msg_in_box "$(screen "$p")" "$want" || break
  done
  echo held
}

# The newest (or oldest) path in a `find -printf '%T@ %p\n'` listing on stdin,
# read in one pass: sort | head closed sort's pipe early once the listing
# outgrew a pipe buffer, and the journal logged "sort: write error" (#319, #335).
pick_file() { # newest|oldest
  awk -v old="$([[ $1 == oldest ]] && echo 1)" '{ t = $1 + 0; p = substr($0, index($0, " ") + 1) }
    f == "" || (old ? t < m || (t == m && p < f) : t > m || (t == m && p > f)) { m = t; f = p }
    END { if (f == "") exit 1; print f }'
}

# klepsydra's newest usage reading (one file per session under accounts/<id>/).
newest_reading() {
  find "$KLEPSYDRA_DIR/accounts" -mindepth 2 -maxdepth 2 -name '*.json' -printf '%T@ %p\n' 2>/dev/null | pick_file newest
}

# The registry, panes.tsv: pane, name, brief, then (from launch.sh) session id,
# working folder and Claude Code config folder (its account).
REGISTRY=${REGISTRY:-$FLEET_STATE/panes.tsv}
registered() { awk -F'\t' -v p="$1" '$1 == p { f = 1 } END { exit !f }' "$REGISTRY" 2>/dev/null; }
reg_field() { awk -F'\t' -v p="$1" -v n="$2" '$1 == p { print $n; exit }' "$REGISTRY" 2>/dev/null; }
orchestrator() { cat "$FLEET_STATE/orchestrator.pane" 2>/dev/null; }
# The config folder PANE's session runs on: Heph's own (heph_config) for the
# orchestrator's pane when no row names it, else its row's (pane_config).
pane_folder() { # PANE
  if [[ $1 == "$(orchestrator)" ]] && ! registered "$1"; then heph_config; else pane_config "$1"; fi
}
# shellcheck disable=SC2034 # read by recover.sh and resume-at-reset.sh
HEPH=${FLEET_HEPH:-$FLEET_STATE/HEPH.md}
fleet_panes() { t list-panes -s -t "$FLEET_SESSION" -F '#{pane_id}' 2>/dev/null; }
# Whether PANE's window is the one its tmux session shows (#216). A pane's
# successor opens behind and comes forward only in place of a window AJ was
# looking at, so a replacement never moves him off the agent he is watching.
in_view() { [[ $(t display-message -p -t "$1" '#{window_active}' 2>/dev/null) == 1 ]]; }

# Whether the session live in PANE is one finished.tsv names (`fleet done`,
# or a finish the doctor or recover recorded; the registry's columns, pane
# first, session fourth). The resume service asks it of panes with no row.
finished_here() { # PANE
  local fin=${FLEET_FINISHED:-$FLEET_STATE/finished.tsv} sid
  # The pane alone first: reading every session file costs far more.
  awk -F'\t' -v p="$1" '$1 == p { f = 1 } END { exit !f }' "$fin" 2>/dev/null || return 1
  sid=$(live_session "$1") || return 1
  awk -F'\t' -v p="$1" -v s="$sid" '$1 == p && $4 == s { f = 1 } END { exit !f }' "$fin" 2>/dev/null
}

# The live session id klepsydra's fleet file shows in pane PANE, or nothing.
# Two live files naming one pane (a killed pane never writes "ended", and
# tmux reuses its id) is no answer at all.
live_session() { # PANE
  local f found=()
  # Only files that name the pane at all: one grep over the folder costs a
  # third of a stat and a jq per file on the Windows mount (#311).
  while IFS= read -r f; do
    [[ -f $f && ! -L $f ]] || continue
    jq -e --arg p "$1" '.tmux.pane == $p and .ended == null' "$f" >/dev/null 2>&1 && found+=("$(basename "$f" .json)")
  done < <(grep -l -F -- "\"$1\"" "$KLEPSYDRA_DIR"/fleet/*.json 2>/dev/null)
  (( ${#found[@]} == 1 )) || return 1
  printf '%s' "${found[0]}"
}

# The usage limit PANE's live session stopped at, from the fleet hook's
# StopFailure record (error rate_limit; a prompt since clears it), as
# "RESET<TAB>MESSAGE" (#311). RESET is the latest resets_at among the
# account's spent windows the stop fell in, else the end of the window the
# message names (only when it agrees with a reset the message dates itself, to
# the hour: a model's own weekly limit is no window the readings show), else
# the message's own reset read from the stop's time (a reset never precedes
# the stop), else 0. The readings count only while the pane's folder (Heph's
# own for his pane) still holds the account the session recorded: after a
# /login there, the stop was the new account's, and its text says when.
# A rate_limit error counts only when its text is a limit message or a window
# is spent: a passing "API Error: Rate limit reached" parks no pane for hours.
# Fails when there is none.
limit_event() { # PANE
  local sid f at id msg rd spent=0 named_at=0 r now_id text_at=0
  sid=$(live_session "$1") || return 1
  f=$KLEPSYDRA_DIR/fleet/$sid.json
  { read -r at id && IFS= read -r msg; } < <(jq -r 'select(.state == "error" and .reason == "rate limit")
    | "\(.state_at) \(.account.id // "-")", (.error // "" | tostring | gsub("[\t\r\n]"; " "))' "$f" 2>/dev/null) || return 1
  [[ $at =~ ^[0-9]+$ ]] || return 1
  [[ $msg == *"hit your fast limit"* ]] && return 1
  now_id=$(account_of "$(pane_folder "$1")") && [[ $now_id != "$id" ]] && id=-
  if [[ $id != - ]] && rd=$(reading_of "$id"); then
    read -r spent named_at < <(jq -r --argjson at "$at" --arg msg "$msg" '
      def span: {five_hour: 18000, seven_day: 604800};
      def holds(k): .windows[k] as $w | $w != null and ($w.resets_at | type) == "number"
        and $w.resets_at > $at and $w.resets_at - span[k] <= $at;
      ([("five_hour", "seven_day") as $k | select(holds($k) and (.windows[$k].used_percentage // 0) >= 100)
        | .windows[$k].resets_at] | max // 0) as $spent
      | (if ($msg | test("weekly"; "i")) then "seven_day" elif ($msg | test("5-hour|session"; "i")) then "five_hour" else null end) as $k
      | "\($spent) \(if $k != null and holds($k) then .windows[$k].resets_at else 0 end)"' "$rd" 2>/dev/null)
  fi
  [[ $spent =~ ^[0-9]+$ && $named_at =~ ^[0-9]+$ ]] || spent=0 named_at=0
  (( spent > 0 )) || grep -qE "$LIMIT_RE" <<<"$msg" || return 1
  text_at=$(reset_epoch "$msg" "$at" 1800) || text_at=0
  if (( named_at > 0 && text_at > 0 )); then
    local gap=$(( named_at - text_at ))
    (( gap < 0 )) && gap=$(( -gap ))
    (( gap <= 3600 )) || named_at=0
  fi
  r=$spent
  (( r > 0 )) || r=$named_at
  (( r > 0 )) || r=$text_at
  printf '%s\t%s\n' "$r" "${msg:-StopFailure rate_limit}"
}

# Run COMMAND... holding the registry's lock: every writer of panes.tsv does.
with_registry() { # FLEET_REGISTRY_WAIT: seconds to wait for the lock (60)
  ( flock -w "${FLEET_REGISTRY_WAIT:-60}" 9 || exit 1; "$@" ) 9>>"$FLEET_STATE/.registry.lock"
}

# Set the session id (column 4) of the registry row in pane PANE that names
# session OLD (empty: a row with none) to NEW. The pane alone is no key: a
# restarted tmux server hands out %N again, so finished or lost rows can share
# one with a running agent (#261 review 7). Fails when no row matches.
set_session() { with_registry set_session_now "$@"; }
set_session_now() { # PANE OLD NEW
  local tmp
  [[ -e $REGISTRY && -n ${3:-} ]] || return 1
  awk -F'\t' -v p="$1" -v o="$2" '$1 == p && $4 == o { f = 1 } END { exit !f }' "$REGISTRY" || return 1
  tmp=$(mktemp "$REGISTRY.XXXXXX") || return 1
  if ! awk -F'\t' -v OFS='\t' -v p="$1" -v o="$2" -v sid="$3" '!done && $1 == p && $4 == o { $4 = sid; done = 1 } { print }' "$REGISTRY" >"$tmp" ||
    ! mv -f -- "$tmp" "$REGISTRY"; then
    rm -f -- "${tmp:?}"
    return 1
  fi
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
  # On the fleet's own server: AJ's own tmux hands out the same pane ids (#261 review 9).
  jq -e --arg p "$1" --arg s "/$FLEET_SOCK" '.tmux.pane == $p and .ended == null
    and (.tmux.socket == null or (.tmux.socket | strings | endswith($s)))' "$f" >/dev/null 2>&1
}

# Whether tmux socket path SOCK is the fleet's own server.
fleet_socket() { [[ -n $1 && ${1##*/} == "$FLEET_SOCK" ]]; } # SOCK

# The pane session SID runs in, from its fleet file, only when that is on the
# fleet's own server: a pane id from another tmux server names nothing here.
fleet_pane_of() { # SID
  local f=$KLEPSYDRA_DIR/fleet/$1.json
  [[ $1 =~ ^[0-9a-f-]{36}$ && -f $f && ! -L $f ]] || return 1
  jq -r --arg s "/$FLEET_SOCK" '.tmux | select((.socket | strings | endswith($s)) and (.pane | strings | test("^%[0-9]+$"))) | .pane' "$f" 2>/dev/null | grep .
}

# Accounts: Claude Code keeps one login per config folder (CLAUDE_CONFIG_DIR),
# so each folder in FLEET_ACCOUNTS is one account, the default first. The
# default folder is used with CLAUDE_CONFIG_DIR unset: set to ~/.claude, Claude
# Code would look for ~/.claude/.claude.json instead of ~/.claude.json.
FLEET_DEFAULT_CONFIG=${FLEET_DEFAULT_CONFIG:-$HOME/.claude}
FLEET_ACCOUNTS=${FLEET_ACCOUNTS:-$FLEET_DEFAULT_CONFIG $HOME/.claude-rit}
FLEET_ROOM_PCT=${FLEET_ROOM_PCT:-90} # a five-hour window used past this has no room
# FLEET_ACCOUNTS is also the workers' preference order (#175): the first folder
# with room is used, whatever the others' room, so the RIT Team seat (no weekly
# cap) is spent first. A pane moved off its role's first folder moves back once
# that has FLEET_BACK_ROOM_PCT of its five-hour window free (well above the
# move-away line, so a window near its limit is not trusted at once), at its
# next finished turn, and never within 15 minutes of its last move.
FLEET_BACK_ROOM_PCT=${FLEET_BACK_ROOM_PCT:-50}
# Folders compared as written: "~/.claude/" must read as the default.
nodir() { local d=$1; while [[ $d == ?*/ ]]; do d=${d%/}; done; printf '%s' "$d"; }
FLEET_DEFAULT_CONFIG=$(nodir "$FLEET_DEFAULT_CONFIG")
FLEET_ACCOUNTS=$(for d in $FLEET_ACCOUNTS; do printf '%s ' "$(nodir "$d")"; done)
# The orchestrator's own order (#175): the same folders, last first, so worker
# burn on the first account's window never stalls him.
# shellcheck disable=SC2086 # split on purpose: one folder per line
FLEET_HEPH_ACCOUNTS=${FLEET_HEPH_ACCOUNTS:-$(printf '%s\n' $FLEET_ACCOUNTS | tac | tr '\n' ' ')}
FLEET_HEPH_ACCOUNTS=$(for d in $FLEET_HEPH_ACCOUNTS; do printf '%s ' "$(nodir "$d")"; done)

# The task cap for a fleet session's scope (#289): the tightest pids.max above
# the caller's own cgroup (on AJ's PC the user slice's), split over
# FLEET_TASK_SHARES scopes, the two workers and Heph that run at once, so two
# runaway workers still leave Heph room. Without it a scope inherits
# DefaultTasksMax, and two such scopes can fill the slice. FLEET_TASKS_MAX sets
# it outright. Fails when no cap is readable.
FLEET_TASK_SHARES=${FLEET_TASK_SHARES:-3}
fleet_tasks_max() {
  local root=${FLEET_CGROUP_ROOT:-/sys/fs/cgroup} cg d m min=""
  if [[ -n ${FLEET_TASKS_MAX:-} ]]; then
    [[ $FLEET_TASKS_MAX =~ ^[1-9][0-9]*$ ]] && printf '%s' "$FLEET_TASKS_MAX"
    return
  fi
  [[ $FLEET_TASK_SHARES =~ ^[1-9][0-9]*$ ]] || return 1
  cg=${FLEET_CGROUP:-$(awk -F: '$1 == "0" { print $3 }' /proc/self/cgroup 2>/dev/null)}
  [[ $cg == /* ]] || return 1
  d=${cg%/*}
  while [[ -n $d ]]; do
    m=$(cat "$root$d/pids.max" 2>/dev/null)
    [[ $m =~ ^[0-9]+$ ]] && { [[ -z $min ]] || (( m < min )); } && min=$m
    d=${d%/*}
  done
  [[ -n $min ]] && (( min / FLEET_TASK_SHARES > 0 )) || return 1
  printf '%s' "$((min / FLEET_TASK_SHARES))"
}

# The global config file of config folder DIR.
config_json() { # DIR
  if [[ $1 == "$FLEET_DEFAULT_CONFIG" ]]; then printf '%s' "${FLEET_DEFAULT_JSON:-$HOME/.claude.json}"; else printf '%s' "$1/.claude.json"; fi
}

# The account logged in at config folder DIR (its accountUuid), or nothing.
# The login itself (.credentials.json) is only checked for, never read.
account_of() { # DIR
  [[ -e $1/.credentials.json ]] || return 1
  jq -er '.oauthAccount.accountUuid // empty' "$(config_json "$1")" 2>/dev/null
}

# klepsydra's newest usage reading of account ID.
reading_of() { # ID
  [[ $1 =~ ^[0-9A-Za-z][0-9A-Za-z-]*$ ]] || return 1
  find "$KLEPSYDRA_DIR/accounts/$1" -maxdepth 1 -name '*.json' -printf '%T@ %p\n' 2>/dev/null | pick_file newest
}

# The newest reading's time for account ID (its file's, as Windows stamps it), 0 with none.
reading_mtime() { local f; f=$(reading_of "$1") && find "$f" -maxdepth 0 -printf '%T@' 2>/dev/null || echo 0; } # ID

# The window a limit message names: seven for a weekly one, else five.
limit_window() { if [[ $1 =~ [Ww]eekly ]]; then echo seven; else echo five; fi; } # TEXT

# A usage limit seen on account ID's WINDOW (five or seven) that resets at RESET
# (#319): until then that window has no room by any reading the account had at
# the sighting, since a request the limit refuses writes no reading. Each
# sighting keeps the later reset and the newest reading's time then, so only a
# reading taken after the latest sighting is news (both times Windows').
LIMITED_DIR=${FLEET_LIMITED_DIR:-$FLEET_STATE/limited}
mark_limited() { # ID RESET [WINDOW]
  local w=${3:-five} was="" f
  [[ $1 =~ ^[0-9A-Za-z][0-9A-Za-z-]*$ && $2 =~ ^[0-9]+$ && $w =~ ^(five|seven)$ ]] || return 1
  f=$LIMITED_DIR/$1.$w
  { read -r was _ <"$f"; } 2>/dev/null
  { [[ $was =~ ^[0-9]+$ ]] && (( was > $2 )); } || was=$2
  mkdir -p -- "$LIMITED_DIR" && printf '%s %s\n' "$was" "$(reading_mtime "$1")" >"$f.$$" && mv -f -- "$f.$$" "$f"
}
# The windows of account ID still at a limit seen on it at NOW, with no reading
# since, one a line (five, seven); fails with none. No mark costs no process.
limited_until() { # ID NOW
  local w reset seen cur="" any=1
  [[ $1 =~ ^[0-9A-Za-z][0-9A-Za-z-]*$ ]] || return 1
  for w in five seven; do
    [[ -e $LIMITED_DIR/$1.$w ]] || continue
    { read -r reset seen <"$LIMITED_DIR/$1.$w"; } 2>/dev/null || continue
    { [[ $reset =~ ^[0-9]+$ ]] && (( reset > $2 )); } || continue
    [[ -n $cur ]] || cur=$(reading_mtime "$1")
    awk -v c="$cur" -v s="${seen:-0}" 'BEGIN { exit !(c + 0 <= s + 0) }' || continue
    echo "$w"; any=0
  done
  return "$any"
}

# Account ID's name as its readings give it (the gauge's), else its id.
account_label() { # ID
  local f l=""
  f=$(reading_of "$1") && l=$(jq -r '.label // empty' "$f" 2>/dev/null)
  printf '%s' "${l:-$1}"
}

# Account ID's room from its newest reading, as "FIVE SEVEN": 100 less the
# percentage used, or 100 for a window that has reset, that the account does
# not have (a Team seat has no weekly window), or with no reading at all.
headroom() { # ID NOW (a window at a limit seen on it is 0, #319)
  local f five=100 seven=100 marked
  if f=$(reading_of "$1"); then
    read -r five seven < <(jq -r --argjson now "$2" 'def room(w): if w == null or (w.resets_at // 0) <= $now then 100
        else 100 - (w.used_percentage // 0) end;
      "\(room(.windows.five_hour) | floor) \(room(.windows.seven_day) | floor)"' "$f" 2>/dev/null)
    [[ $five =~ ^-?[0-9]+$ && $seven =~ ^-?[0-9]+$ ]] || five=100 seven=100
  fi
  if marked=$(limited_until "$1" "$2"); then
    [[ $marked == *five* ]] && five=0
    [[ $marked == *seven* ]] && seven=0
  fi
  echo "$five $seven"
}

# Whether account ID has room to work at NOW: its five-hour window under
# FLEET_ROOM_PCT used and its weekly one under 95%.
id_has_room() { # ID NOW
  local five seven
  read -r five seven <<<"$(headroom "$1" "$2")"
  (( five > 100 - FLEET_ROOM_PCT && seven > 5 ))
}

# The config folder to start on at NOW: the first logged-in folder in
# FLEET_ACCOUNTS with room (id_has_room: a spent weekly window reads as a full
# five-hour one once that lapses); when none has room, the one with the most,
# the five-hour window first, then the weekly. Prints nothing when none is
# logged in. Heph's order is FLEET_ACCOUNTS=$FLEET_HEPH_ACCOUNTS.
best_account() { # NOW
  local dir id five seven best="" best_five=-1 best_seven=-1
  for dir in $FLEET_ACCOUNTS; do
    id=$(account_of "$dir") || continue
    if id_has_room "$id" "$1"; then
      printf '%s' "$dir"
      return
    fi
    read -r five seven <<<"$(headroom "$id" "$1")"
    if (( five > best_five || (five == best_five && seven > best_seven) )); then
      best=$dir best_five=$five best_seven=$seven
    fi
  done
  printf '%s' "$best"
}

# A logged-in config folder other than DIR, on another account, with room at
# NOW: the first such in FLEET_ACCOUNTS. Fails when there is none.
room_elsewhere() { # DIR NOW
  local dir id mine
  mine=$(account_of "$1")
  for dir in $FLEET_ACCOUNTS; do
    [[ $dir == "$1" ]] && continue
    id=$(account_of "$dir") || continue
    [[ $id == "$mine" ]] && continue
    id_has_room "$id" "$2" && { printf '%s' "$dir"; return; }
  done
  return 1
}

# Whether account ID has room enough at NOW for a pane to move back to it: a
# reading at all (none says nothing), FLEET_BACK_ROOM_PCT of its five-hour
# window free and its week not spent.
back_room() { # ID NOW
  local five seven
  reading_of "$1" >/dev/null || return 1
  read -r five seven <<<"$(headroom "$1" "$2")"
  (( five >= FLEET_BACK_ROOM_PCT && seven > 5 ))
}

# The config folder the orchestrator runs on: his live session's process's
# CLAUDE_CONFIG_DIR (unset: the default), else orchestrator.config (written when
# fleet recover starts him or the resume service moves him), else the default.
heph_config() {
  local sid pid c env
  if sid=$(live_session "$(orchestrator)") && session_alive "$sid" &&
    pid=$(jq -r '.claude.pid' "$KLEPSYDRA_DIR/fleet/$sid.json" 2>/dev/null) &&
    env=${FLEET_PROC:-/proc}/$pid/environ && [[ -r $env ]]; then
    c=$(tr '\0' '\n' <"$env" | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | tail -1)
  else
    c=$(cat "$FLEET_STATE/orchestrator.config" 2>/dev/null)
  fi
  nodir "${c:-$FLEET_DEFAULT_CONFIG}"
}

# A session's stamp in its live fleet file: when it last took a typed or phone
# prompt (prompt.at) and when its last turn started (turn_at, a task
# notification's too), so a turn begun since the stamp was read shows.
STAMP_JQ='"\(.prompt.at // "")/\(.turn_at // "")"'

# Whether the agent in PANE has finished its turn: its live fleet file
# (klepsydra's) says done, or stopped with only background work, and lists no
# background work still running. Prints the session's stamp from the same
# read, for prompt_stamp comparisons.
turn_done() { # PANE
  local sid
  sid=$(live_session "$1") || return 1
  jq -er 'select((.state == "done" or (.state == "working" and .reason == "background"))
    and ((.background // []) | length) == 0) | '"$STAMP_JQ" "$KLEPSYDRA_DIR/fleet/$sid.json" 2>/dev/null
}

# Whether the agent in PANE has finished its turn but keeps background work
# running (a job watcher, a CI monitor): turn_done waits on it forever (#198).
turn_settled() { # PANE
  local sid
  sid=$(live_session "$1") || return 1
  jq -e '(.state == "done" or (.state == "working" and .reason == "background"))
    and ((.background // []) | length) > 0' "$KLEPSYDRA_DIR/fleet/$sid.json" >/dev/null 2>&1
}

# Whether the orchestrator in PANE has finished its turn with only pane
# watchers (watch-panes.sh) in the background: a successor starts them again,
# so they never hold a move back (#215). Prints its stamp, as turn_done does.
watchers_only() { # PANE
  local sid
  sid=$(live_session "$1") || return 1
  jq -er 'select((.state == "done" or (.state == "working" and .reason == "background"))
    and ((.background // []) | length) > 0
    and all(.background[]; .kind == "shell" and .watcher == true)) | '"$STAMP_JQ" "$KLEPSYDRA_DIR/fleet/$sid.json" 2>/dev/null
}

# The panes the watchers of the session in PANE watch (the hook's `watch`),
# one a line; fails when no watcher recorded them (an entry from before #215).
watched_panes() { # PANE
  local sid
  sid=$(live_session "$1") || return 1
  jq -er '[(.background // [])[] | select(.watcher == true)] as $w
    | if ($w | length) > 0 and all($w[]; .watch | type == "array") then [$w[].watch[]] | unique | .[] else error("none") end' \
    "$KLEPSYDRA_DIR/fleet/$sid.json" 2>/dev/null || [[ $? == 4 ]]
}

# How many pane watchers the session in PANE runs in the background.
watcher_count() { # PANE
  local sid
  sid=$(live_session "$1") || { echo 0; return; }
  jq -r '[(.background // [])[] | select(.watcher == true)] | length' "$KLEPSYDRA_DIR/fleet/$sid.json" 2>/dev/null || echo 0
}

# Whether the agent in PANE answered a move-back request sent at ASKED with a
# reply whose first line is READY-TO-MOVE alone (bold or code marks aside), and
# finished that turn, with no turn since (a later one, a task notification's,
# voids it until the next ask). Prints its stamp, as turn_done does.
ready_to_move() { # PANE ASKED
  local sid
  [[ $2 =~ ^[0-9]+$ ]] || return 1
  sid=$(live_session "$1") || return 1
  jq -er --argjson asked "$2" 'select((.state == "done" or (.state == "working" and .reason == "background"))
    and (.reply.at // 0) >= $asked and (.reply.at // 0) >= (.turn_at // 0)
    and ((.reply.text // "") | split("\n") | map(select(test("\\S"))) | (.[0] // "")
      | gsub("[*`]"; "") | gsub("^\\s+|\\s+$"; "")) == "READY-TO-MOVE")
    | '"$STAMP_JQ" "$KLEPSYDRA_DIR/fleet/$sid.json" 2>/dev/null
}

# The config folder pane PANE runs on: its registry row's (column 6), else the default.
pane_config() { # PANE
  local c
  c=$(reg_field "$1" 6)
  printf '%s' "${c:-$FLEET_DEFAULT_CONFIG}"
}

# The env(1) arguments that start claude on config folder DIR; the default
# unsets CLAUDE_CONFIG_DIR, which a caller on the second folder would pass on.
config_env() { # DIR
  if [[ $1 == "$FLEET_DEFAULT_CONFIG" ]]; then printf -- '-u CLAUDE_CONFIG_DIR '; else printf 'CLAUDE_CONFIG_DIR=%q ' "$1"; fi
}

# /exit the claude in PANE and close the pane once it has gone, or after 30 s.
# With INTERRUPT (a pane this pass just launched, busy on its brief), its turn
# is stopped first. A pane it cannot type /exit into is left running.
retire() { # PANE [INTERRUPT]
  if [[ ${2:-} == interrupt ]] && busy "$(screen "$1")"; then
    t send-keys -t "$1" Escape
    wait_for "$1" 15 not_busy || true
    # Interrupted before any reply, Claude Code puts the brief back in the box;
    # one C-c clears a box with text in it (an empty box would ask to exit).
    holds_input "$(screen "$1")" && t send-keys -t "$1" C-c
    wait_for "$1" 5 idle_empty || true
  elif [[ ${2:-} == interrupt ]] && holds_input "$(screen "$1")"; then
    # A brief that was pasted but never sent sits in the box: clear it, or /exit cannot go in.
    t send-keys -t "$1" C-c
    wait_for "$1" 5 idle_empty || true
  fi
  if ! pane_locked "$1" type_enter "$1" "/exit"; then
    flog ERROR "could not type /exit; the pane is left running" pane="$1"
    return 1
  fi
  for _ in $(seq 30); do fleet_panes | grep -qx "$1" || return 0; sleep 1; done
  t kill-pane -t "$1" 2>/dev/null
}

# Retire OLD for its successor NEW, which opened behind (#216): when AJ is
# watching OLD, NEW comes into view first, before OLD closes, since tmux then
# makes another window active, and a sibling replacement would read that one
# as watched (#229 review). An OLD that will not exit is put back in view, only
# while NEW still is: AJ may have moved on during retire's wait. Fails only when
# OLD still runs; one that exited as retire gave up is gone all the same.
retire_into() { # OLD NEW
  local viewed=0
  in_view "$1" && viewed=1
  (( viewed )) && t select-window -t "$2" 2>/dev/null
  retire "$1" && return 0
  fleet_panes | grep -qx -- "$1" || return 0
  (( viewed )) && in_view "$2" && t select-window -t "$1" 2>/dev/null
  return 1
}

LAUNCH=${LAUNCH:-$(dirname "${BASH_SOURCE[0]}")/launch.sh}

# The live session in PANE's stamp, or nothing: STAMP_JQ (its last prompt and
# turn), or with STAMP_KIND=prompt its last typed or phone prompt alone, for a
# move at a limit, where a turn a task notification starts fails at once.
prompt_stamp() { # PANE
  local sid of=$STAMP_JQ
  [[ ${STAMP_KIND:-} == prompt ]] && of='.prompt.at // ""'
  sid=$(live_session "$1") || return 0
  jq -r "$of" "$KLEPSYDRA_DIR/fleet/$sid.json" 2>/dev/null
}

# Retire a pane this pass launched, interrupting its turn; kill it if it will not exit.
drop() { # PANE
  retire "$1" interrupt || t kill-pane -t "$1" 2>/dev/null
}

# Replace PANE (registry NAME, BRIEF) with a fresh session from its brief,
# on config folder ACCOUNT when given (else launch.sh's pick), WHY in its
# preamble; prints the new pane. NOTE, what AJ typed at the pane, goes into the
# new brief, and the old box may hold exactly it. Gives up, typing nothing, if
# AJ has typed anything else meanwhile.
# (STAMP: the session's stamp when the caller judged the pane idle, so a
# prompt or turn taken since, even one already over, keeps the old pane; at a
# limit, STAMP_KIND=prompt, a prompt only.) Returns 5 when the new session's
# brief met a limit on ACCOUNT. FRESH_HINT, when set, goes in as a resume hint.
# Shared by the resume service and relaunch-fresh.sh (#274).
fresh() { # PANE NAME BRIEF [WHY] [ACCOUNT] [NOTE] [STAMP]
  local p=$1 name=$2 brief=$3 txt new
  local why=${4:-stopped at a usage limit over an hour ago, so its cached conversation expired and resuming it would re-cache everything}
  local account=${5:-} carried=${6:-} box
  box=$(input_text "$(screen "$p")")
  [[ -z $box || ( -n $carried && $box == "$carried" ) ]] || return 1
  local sid cfg out got
  # Shared: moves of different panes run side by side; a cut-over takes it alone.
  exec 7>>"$FLEET_STATE/.fresh.lock"
  flock -s 7
  sid=$(reg_field "$p" 4) cfg=$(reg_field "$p" 6)
  if ! pane_runs "$p" "$sid"; then
    flog WARN "fresh session refused: the pane no longer runs its registered session" pane="$p" name="$name" session_id="$sid"
    return 2
  fi
  local stamp
  if (( $# >= 7 )); then stamp=$7; else stamp=$(prompt_stamp "$p"); fi
  txt="$FLEET_STATE/fresh-$name-$(date +%Y%m%d-%H%M).src"
  {
    fresh_preamble "$why"
    printf '\n\n'
    [[ -n ${FRESH_HINT:-} ]] && printf 'Resume hint: %s\n\n' "$FRESH_HINT"
    [[ -n $carried ]] && printf 'AJ typed this to the previous agent while it waited at the limit; act on it:\n%s\n\n' "$carried"
    cat "$brief"
  } >"$txt"
  mkdir -p -- "$FLEET_STATE/log"
  out=$(FLEET_ACCOUNT=$account bash "$LAUNCH" "$name" "$txt" 2>>"$FLEET_STATE/log/launch.err" | head -1)
  new=$(grep -o 'pane=%[0-9]*' <<<"$out" | cut -d= -f2) got=$(grep -o 'brief=[A-Za-z-]*' <<<"$out" | cut -d= -f2)
  [[ -n $new && -n ${MOVE_NEW:-} ]] && printf '%s\n' "$new" >"$MOVE_NEW"
  if [[ -z $new ]]; then
    flog ERROR "fresh session not started; the old pane is kept" pane="$p" name="$name"
    return 3
  fi
  # The brief must have started a turn: not delivered, or (on a move to an
  # account said to have room) stopped by a limit, the old pane stays.
  if [[ $got == NOT-DELIVERED || ( -n $account && $got != started ) ]]; then
    flog ERROR "fresh session's brief did not start; the old pane stays and the new one goes" pane="$p" new_pane="$new" name="$name" brief="$got"
    rollback_fresh "$new" "$p" "$sid" "$cfg" "$name"
    [[ $got == blocked-by-limit ]] && return 5
    return 3
  fi
  # The launch took a while: AJ may have typed into the old pane or resumed it.
  local now_s
  now_s=$(screen "$p")
  if ! pane_runs "$p" "$sid" || busy "$now_s" || ! has_input_box "$now_s" || [[ $(input_text "$now_s") != "$box" || $(prompt_stamp "$p") != "$stamp" ]]; then
    flog ERROR "the old pane changed while its fresh session launched; the old one stays and the new one goes" pane="$p" new_pane="$new" name="$name"
    rollback_fresh "$new" "$p" "$sid" "$cfg" "$name"
    return 4
  fi
  # The old session ends only once its row names the new one, or its /exit
  # would record the agent itself as finished (#261 review 10). A launch that
  # could not register the row (its lock busy) leaves that to this step.
  if ! awk -F'\t' -v n="$new" -v nm="$name" '$1 == n && $2 == nm { f = 1 } END { exit !f }' "$REGISTRY"; then
    local nsid
    nsid=$(grep -o 'session=[^ ]*' <<<"$out" | head -1 | cut -d= -f2)
    if with_registry repoint_row "$p" "$sid" "$new" "$nsid"; then
      flog WARN "the launch left its row unregistered; the fresh session's row now names it" pane="$p" new_pane="$new" name="$name" session="$nsid"
    else
      flog ERROR "the fresh session's row could not be registered; the old pane stays and the new one goes" pane="$p" new_pane="$new" name="$name"
      retire "$new" interrupt
      return 3
    fi
  fi
  # The note went into the new brief; one C-c clears it from the old box, only
  # now that the old pane is sure to go (#261 review 11).
  if [[ -n $box ]]; then
    t send-keys -t "$p" C-c
    wait_for "$p" 5 idle_empty || true
  fi
  retire_into "$p" "$new" ||
    flog WARN "the old pane is left running beside its fresh session" pane="$p" new_pane="$new" name="$name"
  printf '%s' "$new"
}

# Point the row naming PANE and session SID at NEW, and at session NSID when
# that is a session id (launch.sh prints it), as launch.sh would have; fails
# when no row names them.
repoint_row() { # PANE SID NEW NSID
  local tmp
  tmp=$(mktemp "$REGISTRY.XXXXXX") || return 1
  if awk -F'\t' -v OFS='\t' -v p="$1" -v s="$2" -v n="$3" -v ns="${4:-}" '
      $1 == p && $4 == s && !f { $1 = n; if (ns ~ /^[0-9a-f-]{36}$/) $4 = ns; f = 1 } { print } END { exit !f }' "$REGISTRY" >"$tmp"; then
    mv -f -- "$tmp" "$REGISTRY"
  else
    rm -f -- "$tmp"; return 1
  fi
}

# Point row NAME, which launch.sh moved to NEW, back at PANE, session SID and
# config folder CFG (none: the column is left empty, the default). A row that
# never moved (launch.sh could not register it) needs nothing.
set_pane() { # NEW PANE SID CFG NAME
  local tmp
  tmp=$(mktemp "$REGISTRY.XXXXXX") || return 1
  awk -F'\t' -v OFS='\t' -v n="$1" -v p="$2" -v sid="$3" -v cfg="${4:-}" -v name="$5" \
    '$1 == n && $2 == name && !done { $1 = p; $4 = sid; if (NF >= 6 || cfg != "") $6 = cfg; done = 1 } { print }' "$REGISTRY" >"$tmp" && mv -f -- "$tmp" "$REGISTRY"
}

# Undo a fresh start that will not go on: the row back on the old pane first,
# then the new session ends, since its /exit records a finish for whichever row
# names it then (#261 reviews 10, 11). If the row cannot be put back (the
# registry lock stays busy), both panes stay running.
rollback_fresh() { # NEW PANE SID CFG NAME
  if with_registry set_pane "$@"; then
    retire "$1" interrupt
  else
    flog ERROR "the row could not be put back on the old pane; both panes stay running" pane="$2" new_pane="$1" name="$5"
  fi
}

# The prompt the last limit answered, when the limit is the only reply to it:
# the "❯ ..." lines (a long one wraps) right above the last limit message in
# SCREEN. A line AJ sent between two passes is only ever seen here. The
# fleet's own text (the continue message, a brief's first line) is not his; a
# paste placeholder is returned, so the caller keeps the pane for its reset.
answered_by_limit() { # SCREEN
  split_screen "$1"
  grep -v '^[[:space:]]*$' <<<"$ABOVE" | awk -v re="$LIMIT_RE" '
    $0 ~ re { hit = said; said = ""; inp = 0; next }
    /^❯ / { said = substr($0, length("❯ ") + 1); inp = 1; next }
    inp && /^  [^ ⎿]/ { sub(/^ +/, ""); said = said " " $0; next }
    { said = ""; inp = 0 }
    END { if (hit != "") print hit }' | tail -1 | grep -v -e '^The usage limit has reset\.' -e '^Fresh start:'
}

# The agent's own IMPL.md. With its last folder in a linked worktree: that
# worktree's, or none (a sibling's belongs to another agent). Otherwise the
# last IMPL.md it wrote that still exists (Write or Edit, or a shell redirect
# or tee on a command's first line, read against that call's folder or its
# leading `cd DIR &&` or `cd DIR;`), else,
# from a main checkout, the newest of the repo's and its worktrees'. Reads
# never count: a recovered agent reads every worktree's. A folder outside any
# repo with nothing written gives none.
newest_impl() { # TRANSCRIPT
  local cwd dir base p own="" roots
  cwd=$(jq -r 'select(.cwd != null) | .cwd' "$1" 2>/dev/null | tail -1)
  [[ -n $cwd && -d $cwd ]] || return 1
  dir=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
  if [[ -n $dir && $(git -C "$cwd" rev-parse --path-format=absolute --git-dir) != $(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir) ]]; then
    [[ -f $dir/IMPL.md && ! -L $dir/IMPL.md ]] || return 1
    echo "$dir/IMPL.md"; return
  fi
  while IFS=$'\t' read -r base p; do
    # shellcheck disable=SC2088,SC2016 # the transcript's text: a literal ~ or $HOME to expand here
    case $p in '~/'*) p=$HOME/${p#'~/'} ;; '$HOME/'*) p=$HOME/${p#'$HOME/'} ;; '${HOME}/'*) p=$HOME/${p#'${HOME}/'} ;; /*) ;; *) p=$base/$p ;; esac
    [[ -f $p && ! -L $p ]] && own=$p
  done < <(jq -r 'select(.type == "assistant" and .cwd != null) | .cwd as $c | .message.content[]? | select(.type == "tool_use")
      | if (.name | IN("Write", "Edit", "MultiEdit")) then (.input.file_path | strings | select(test("(^|/)IMPL\\.md$")) | [$c, .])
        else (.input.command | strings | split("\n")[0] | ((capture("^\\s*cd\\s+[\"\\x27]?(?<d>[^\\s;&|\"\\x27]+)[\"\\x27]?\\s*(&&|;)") | .d
            | if startswith("/") then . elif startswith("~/") then env.HOME + .[1:] else $c + "/" + . end) // $c) as $b
          | scan("(?:>>?|\\btee(?:\\s+(?:-a|--append))?)\\s*[\"\\x27]?((?:[^\\s\"'"'"';|&<>()]*/)?IMPL\\.md)(?![\\w.])") | [$b, .[0]])
        end | @tsv' "$1" 2>/dev/null)
  [[ -n $own ]] && { realpath -s "$own"; return; }
  [[ -n $dir ]] || return 1
  # Only folders that exist: under pipefail a find over a missing one fails the pick.
  roots=("$dir")
  [[ -d $dir/.claude/worktrees ]] && roots+=("$dir/.claude/worktrees")
  find "${roots[@]}" -maxdepth 2 -name IMPL.md -type f -printf '%T@ %p\n' 2>/dev/null | pick_file newest
}

# Whether session SID's Claude Code process still runs: its fleet file (the
# hook's) names this boot and a process with the same start time. A tmux
# restart reuses pane ids and a reboot reuses pids, so neither alone says so.
session_alive() { # SID
  local f pid start boot
  [[ $1 =~ ^[0-9a-f-]{36}$ ]] || return 1
  f=$KLEPSYDRA_DIR/fleet/$1.json
  [[ -f $f && ! -L $f ]] || return 1
  read -r pid start boot < <(jq -r 'select(.ended == null) | "\(.claude.pid // 0) \(.claude.start // 0) \(.host.boot // "")"' "$f" 2>/dev/null)
  [[ ${pid:-0} =~ ^[1-9][0-9]*$ && -n ${boot:-} && $boot == "$(cat "${FLEET_BOOT_ID:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)" ]] || return 1
  [[ $(proc_start "$pid") == "$start" ]]
}

# Whether session SID ended cleanly. While its fleet file exists, the file
# decides: Claude Code's SessionEnd named a final end, the user's /exit or
# ctrl-d at the prompt (prompt_input_exit) or a logout (code.claude.com/docs/
# en/hooks, SessionEnd), so a session resumed under the same id after a
# recorded finish is no longer finished. Once the file is gone (klepsydra drops
# it a day after the end; the wall's Clear at once), finished.tsv decides: the
# finish the fleet hook recorded at the end (registry-event.sh), `fleet done`,
# or one the doctor or recover recorded on first sight. The fleet hook also marks
# ended a session it finds dead ("gone", on every SessionStart after a hard
# shutdown), and SessionEnd says "clear" and "resume" for a session that goes
# on under a new id; those, "other" and any reason unknown here are no finish.
session_finished() { # SID
  local f
  [[ $1 =~ ^[0-9a-f-]{36}$ ]] || return 1
  f=$KLEPSYDRA_DIR/fleet/$1.json
  if [[ ! -e $f ]]; then
    awk -F'\t' -v s="$1" '$4 == s { f = 1 } END { exit !f }' "${FLEET_FINISHED:-$FLEET_STATE/finished.tsv}" 2>/dev/null
    return
  fi
  [[ -f $f && ! -L $f ]] || return 1
  jq -e '(.ended | type) == "object" and ((.ended.reason // "") | IN("prompt_input_exit", "logout"))' "$f" >/dev/null 2>&1
}

# Record a finished row in finished.tsv (the registry's columns, then the
# time), once: what `fleet done` writes, so the finish holds after the fleet
# file is gone. The row stays in panes.tsv until `fleet doctor --prune`, but
# holds no pane (column 1 becomes "-", #261 review 8): a restarted tmux server
# hands its pane id out again, and every pane-keyed lookup (reg_field, the
# resume service, fresh, done, relaunch) would then find the finished row
# beside the live agent's. A start of its session puts the pane back
# (restore_pane). Under the registry lock.
record_finished() { # ROW
  local fin=${FLEET_FINISHED:-$FLEET_STATE/finished.tsv} sid p
  sid=$(cut -f4 <<<"$1") p=$(cut -f1 <<<"$1")
  [[ -n $sid ]] || return 0
  if ! awk -F'\t' -v s="$sid" '$4 == s { f = 1 } END { exit !f }' "$fin" 2>/dev/null; then
    printf '%s\t%s\n' "$1" "$(date -Is)" >>"$fin" || return 1
  fi
  [[ $p =~ ^%[0-9]+$ ]] || return 0
  set_pane_of "$p" "$sid" -
}

# Set the pane (column 1) of the registry row that names pane FROM and session
# SID to TO. Under the registry lock. Fails when no row matches.
set_pane_of() { # FROM SID TO
  local tmp
  [[ -e $REGISTRY && -n $2 ]] || return 1
  awk -F'\t' -v p="$1" -v s="$2" '$1 == p && $4 == s { f = 1 } END { exit !f }' "$REGISTRY" || return 1
  tmp=$(mktemp "$REGISTRY.XXXXXX") || return 1
  if ! awk -F'\t' -v OFS='\t' -v p="$1" -v s="$2" -v to="$3" '!done && $1 == p && $4 == s { $1 = to; done = 1 } { print }' "$REGISTRY" >"$tmp" ||
    ! mv -f -- "$tmp" "$REGISTRY"; then
    rm -f -- "${tmp:?}"
    return 1
  fi
}

# A parked row's pane back, once its session SID runs again in PANE (a hand
# resume of a finished agent). Under the registry lock.
restore_pane() { # SID PANE
  [[ $2 =~ ^%[0-9]+$ ]] || return 1
  set_pane_of - "$1" "$2"
}

# Drop session SID's recorded finish (under the registry lock): a row still in
# panes.tsv whose own session runs again was resumed after its finish, so the
# record must not outlive that run once klepsydra drops the session's file
# (#261 review 4). `fleet done` rows leave panes.tsv, so they never meet this.
# Prints how many lines it dropped.
forget_finished() { # SID
  local fin=${FLEET_FINISHED:-$FLEET_STATE/finished.tsv} n
  [[ -n $1 && -e $fin ]] || { echo 0; return 0; }
  n=$(awk -F'\t' -v s="$1" '$4 == s { n++ } END { print n + 0 }' "$fin")
  (( n )) || { echo 0; return 0; }
  if ! { awk -F'\t' -v s="$1" '$4 != s' "$fin" >"$fin.$$" && mv -f -- "$fin.$$" "$fin"; }; then
    rm -f -- "$fin.$$"
    return 1
  fi
  echo "$n"
}

# Reconcile a row's side records (SID, NAME) with its own session's fleet
# file while the file exists: alive drops its finish and its unpause; a file
# that names no final end drops its finish.
forget_resumed() { # SID NAME
  local n why="the session runs again" f=$KLEPSYDRA_DIR/fleet/$1.json
  [[ $1 =~ ^[0-9a-f-]{36}$ && -f $f && ! -L $f ]] || return 0
  # Only a file that reads: an empty or broken one says nothing of the session.
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || return 0
  if session_alive "$1"; then
    unpaused "$1" && { with_registry drop_unpaused "$1" && flog INFO "unpause dropped: the session runs again" session="$1" name="$2"; }
    local live_pane
    live_pane=$(fleet_pane_of "$1") || live_pane=""
    if [[ $live_pane =~ ^%[0-9]+$ ]] && awk -F'\t' -v s="$1" '$1 == "-" && $4 == s { f = 1 } END { exit !f }' "$REGISTRY" 2>/dev/null &&
      with_registry restore_pane "$1" "$live_pane"; then
      flog INFO "a finished agent's session runs again; its row takes its pane back" session="$1" name="$2" pane="$live_pane"
    fi
  elif session_finished "$1"; then
    return 0
  else
    why="the session's file names no final end"
  fi
  n=$(with_registry forget_finished "$1") || { flog WARN "a recorded finish could not be dropped" session="$1" name="$2"; return 0; }
  (( n > 0 )) && flog INFO "recorded finish dropped: $why" session="$1" name="$2" lines="$n"
  return 0
}

# Whether `fleet unpause` put the row with session SID back: it is to be
# launched again, whatever its old session's end said. unpaused.tsv: name,
# session, time; written and rewritten under the registry lock.
unpaused() { # SID
  [[ -n $1 ]] && awk -F'\t' -v s="$1" '$2 == s { f = 1 } END { exit !f }' "${FLEET_UNPAUSED:-$FLEET_STATE/unpaused.tsv}" 2>/dev/null
}

# Forget the unpause of session SID once its agent runs again (under the
# registry lock: with_registry drop_unpaused SID).
drop_unpaused() { # SID
  local un=${FLEET_UNPAUSED:-$FLEET_STATE/unpaused.tsv} tmp
  [[ -e $un ]] || return 0
  tmp=$(mktemp "$un.XXXXXX") || return 1
  if awk -F'\t' -v s="$1" '$2 != s' "$un" >"$tmp" && mv -f -- "$tmp" "$un"; then return 0; fi
  rm -f -- "${tmp:?}"
  return 1
}

# The live fleet sessions, one "PANE<tab>SID<tab>ON_FLEET" each: alive by
# session_alive (this boot, the same process), ON_FLEET 1 when its socket is
# the fleet's (or not recorded).
live_fleet_sessions() {
  local f id row
  for f in "$KLEPSYDRA_DIR"/fleet/*.json; do
    [[ -f $f && ! -L $f ]] || continue
    id=$(basename "$f" .json)
    row=$(jq -r --arg s "/$FLEET_SOCK" 'select(.ended == null and .tmux.pane != null)
      | [.tmux.pane, (if .tmux.socket == null or (.tmux.socket | endswith($s)) then 1 else 0 end)] | @tsv' "$f" 2>/dev/null) || continue
    [[ -n $row ]] && session_alive "$id" && printf '%s\t%s\t%s\n' "${row%%$'\t'*}" "$id" "${row##*$'\t'}"
  done
}

# The one live fleet session in PANE that is neither OSID nor in AGENTS (the
# registry's session ids, one per line), from LIVE (live_fleet_sessions): what
# a row whose own session is gone may count as its successor (a /clear the row
# never recorded). recover's repair and row_state both ask this.
successor_in() { # PANE OSID LIVE AGENTS
  awk -F'\t' -v p="$1" -v h="$2" 'NR == FNR { if ($0 != "") a[$0] = 1; next } $1 == p && $3 == 1 && $2 != h && !($2 in a) { print $2 }' \
    <(printf '%s\n' "$4") <(printf '%s\n' "$3") | awk 'END { if (NR == 1) print prev } { prev = $0 }'
}

# The successor of the row in PANE with session SID: only for a row that names
# a session that started on the running tmux server (as recover's
# this_boot_row: a pane id from an earlier server, or a row with no session,
# means nothing).
row_successor() { # PANE SID
  local osid=""
  [[ -n $2 ]] && on_this_server "$2" || return 1
  { read -r osid <"$FLEET_STATE/orchestrator.session"; } 2>/dev/null
  successor_in "$1" "$osid" "$(live_fleet_sessions)" "$(cut -f4 "$REGISTRY" 2>/dev/null | grep .)" | grep .
}

# A registry row's state (#220): "running" (its session, or its successor
# after a /clear), "finished" (its session ended cleanly, and no unpause put
# it back), or "gone" (anything else: a hard shutdown, a killed pane, an end
# that was no finish, an unpaused agent waiting for fleet recover).
row_state() { # PANE SID
  if session_alive "$2" || row_successor "$1" "$2" >/dev/null; then
    echo running
  elif ! unpaused "$2" && session_finished "$2"; then
    echo finished
  else
    echo gone
  fi
}

# Whether session SID started on the running fleet tmux server: its fleet file
# names this boot and a process start (/proc ticks since boot, so a WSL clock
# step cannot skew it) no earlier than the server's. A tmux restart reuses pane
# ids, so only such a session's pane id means what its file says.
on_this_server() { # SID
  local f=$KLEPSYDRA_DIR/fleet/$1.json spid sstart boot
  spid=$(t display -p '#{pid}' 2>/dev/null)
  [[ $spid =~ ^[0-9]+$ ]] && sstart=$(proc_start "$spid") || return 1
  boot=$(cat "${FLEET_BOOT_ID:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)
  [[ -n $boot && $(jq -r '.host.boot // ""' "$f" 2>/dev/null) == "$boot" ]] &&
    (( $(jq -r '(.claude.start // 0) | floor' "$f" 2>/dev/null || echo 0) >= sstart ))
}

# When process PID started, in clock ticks since boot (/proc/PID/stat field 22,
# read after the last ") " so a name with spaces or parentheses parses); fails
# when there is no such process.
proc_start() { # PID
  local line fields
  line=$(cat "${FLEET_PROC:-/proc}/$1/stat" 2>/dev/null) || return 1
  read -ra fields <<<"${line##*) }"
  [[ -n ${fields[19]:-} ]] && printf '%s' "${fields[19]}"
}

# The transcript of session SID, in any config folder's projects.
transcript() { # SID
  local dir
  for dir in ${FLEET_PROJECTS:-$(for d in $FLEET_ACCOUNTS; do printf '%s/projects ' "$d"; done)}; do
    find "$dir" -mindepth 2 -maxdepth 2 -name "$1.jsonl" -type f 2>/dev/null
  done | head -1
}

# AJ's messages to the orchestrator session SID since HEPH.md was last written,
# as "- " lines (his typed prompts only: no meta, tool results or notices).
heph_asks() { # SID HEPH
  local tp since
  tp=$(transcript "$1")
  [[ -n $tp ]] || return 0
  since=$(stat -c %Y -- "$2" 2>/dev/null || echo 0)
  jq -r --argjson since "$since" '
    select(.type == "user" and (.isMeta | not) and (.message.content | type) == "string")
    | select((.timestamp // "" | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch 0) > $since)
    | .message.content | select(startswith("<") | not) | gsub("\n"; " ") | .[0:1000]' "$tp" 2>/dev/null | tail -20 | sed 's/^/- /'
}

# The note a fresh orchestrator starts from: why it replaces the last one, where
# its state is (HEPH.md, the queue), what the fleet does meanwhile, and AJ's
# messages to the last one since HEPH.md was written.
heph_note() { # WHY SID HEPH DOING
  local asks
  asks=$(heph_asks "$2" "$3")
  printf 'Fresh start: the orchestrator (Heph) %s; you replace it. Read %s first, then the "Running now" lines in /mnt/c/Users/ajbar/fleet-briefing/queue.md; %s Put anything below that changes the plan into HEPH.md now.\n\n' "$1" "$3" "$4"
  printf "AJ's messages to the last orchestrator after HEPH.md was last written:\n%s\n" "${asks:-- (none)}"
}
