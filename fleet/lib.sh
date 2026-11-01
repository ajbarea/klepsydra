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
# What every session reads from ~/.claude (both config folders' hooks point
# there): "repo path, installed name" per entry. install.sh copies them, and
# doctor checks the copies still match the checkout.
FLEET_HOOK_DIR=${FLEET_HOOK_DIR:-$HOME/.claude}
# shellcheck disable=SC2034 # read by install.sh and doctor.sh
HOOK_COPIES=(
  "hooks/klepsydra-fleet.sh klepsydra-fleet.sh"
  "hooks/klepsydra-launch.sh klepsydra-launch.sh"
  "hooks/klepsydra-tmux.conf klepsydra-tmux.conf"
  "hooks/klepsydra-wrapup.sh klepsydra-wrapup.sh"
  "hooks/klepsydra-wrapup.md skills/klepsydra-wrapup/SKILL.md"
  "statusline/klepsydra-statusline.sh klepsydra-statusline.sh"
  "src/fleet/themes/kourai.json klepsydra-cast.json"
)

# The preamble a fresh session's brief starts with; WHY says why it replaces the last one.
fresh_preamble() { # WHY
  printf 'Fresh start: a previous agent with the brief below %s; you replace it. Before acting, rebuild state from disk and GitHub: IMPL.md in the repo and in each worktree, git log and git status per worktree, open PRs with their comments and reviews, and your repo'"'"'s lines under "Running now" in /mnt/c/Users/ajbar/fleet-briefing/claude-queue.md. Where those are newer than the brief, they win; never redo merged work. No /code-review high (nor xhigh or max); low or medium is fine.' "$1"
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
deliver() { # PANE FILE
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
# take his characters with it) or held (still in the box after three Enters).
inbox_deliver() { # PANE FILE
  local p=$1 file=$2 box want text
  idle_empty "$(screen "$p")" || { echo not-pasted; return; }
  t load-buffer -b "fleet-$$" "$file" && t paste-buffer -p -d -b "fleet-$$" -t "$p"
  wait_for "$p" 5 holds_input || { echo not-pasted; return; }
  box=$(input_text "$(screen "$p")")
  # Both sides lose their whitespace the same way: a long line wraps in the box.
  text=$(<"$file")
  want=${text//[[:space:]]/}
  if [[ ${box//[[:space:]]/} != "$want" && ! $box =~ ^\[Pasted\ text\ \#[0-9]+(\ \+[0-9]+\ lines)?\]$ ]]; then
    echo mixed
    return
  fi
  for _ in 1 2 3; do
    t send-keys -t "$p" Enter
    if wait_for "$p" "${FLEET_START_WAIT:-10}" sent_or_started; then
      echo sent
      return
    fi
  done
  echo held
}

# klepsydra's newest usage reading (one file per session under accounts/<id>/).
newest_reading() {
  find "$KLEPSYDRA_DIR/accounts" -mindepth 2 -maxdepth 2 -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
}

# The registry, panes.tsv: pane, name, brief, then (from launch.sh) session id,
# working folder and Claude Code config folder (its account).
REGISTRY=${REGISTRY:-$FLEET_STATE/panes.tsv}
registered() { awk -F'\t' -v p="$1" '$1 == p { f = 1 } END { exit !f }' "$REGISTRY" 2>/dev/null; }
reg_field() { awk -F'\t' -v p="$1" -v n="$2" '$1 == p { print $n; exit }' "$REGISTRY" 2>/dev/null; }
orchestrator() { cat "$FLEET_STATE/orchestrator.pane" 2>/dev/null; }
# shellcheck disable=SC2034 # read by recover.sh and resume-at-reset.sh
HEPH=${FLEET_HEPH:-$FLEET_STATE/HEPH.md}
fleet_panes() { t list-panes -s -t "$FLEET_SESSION" -F '#{pane_id}' 2>/dev/null; }

# The live session id klepsydra's fleet file shows in pane PANE, or nothing.
# Two live files naming one pane (a killed pane never writes "ended", and
# tmux reuses its id) is no answer at all.
live_session() { # PANE
  local f found=()
  for f in "$KLEPSYDRA_DIR"/fleet/*.json; do
    [[ -f $f && ! -L $f ]] || continue
    jq -e --arg p "$1" '.tmux.pane == $p and .ended == null' "$f" >/dev/null 2>&1 && found+=("$(basename "$f" .json)")
  done
  (( ${#found[@]} == 1 )) || return 1
  printf '%s' "${found[0]}"
}

# Run COMMAND... holding the registry's lock: every writer of panes.tsv does.
with_registry() {
  ( flock -w 60 9 || exit 1; "$@" ) 9>>"$FLEET_STATE/.registry.lock"
}

# Set the registry's session id for pane PANE (column 4) to SID.
set_session() { with_registry set_session_now "$@"; }
set_session_now() { # PANE SID
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
  find "$KLEPSYDRA_DIR/accounts/$1" -maxdepth 1 -name '*.json' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- | grep .
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
headroom() { # ID NOW
  local f
  f=$(reading_of "$1") || { echo "100 100"; return; }
  jq -r --argjson now "$2" 'def room(w): if w == null or (w.resets_at // 0) <= $now then 100
      else 100 - (w.used_percentage // 0) end;
    "\(room(.windows.five_hour) | floor) \(room(.windows.seven_day) | floor)"' "$f" 2>/dev/null || echo "100 100"
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
  if ! type_exactly "$1" "/exit"; then
    flog ERROR "could not type /exit; the pane is left running" pane="$1"
    return 1
  fi
  t send-keys -t "$1" Enter
  for _ in $(seq 30); do fleet_panes | grep -qx "$1" || return 0; sleep 1; done
  t kill-pane -t "$1" 2>/dev/null
}

# Point the registry row launch.sh moved to NEW back at PANE, session SID
# and config folder CFG (none: the column is left empty, the default).
set_pane() { # NEW PANE SID CFG
  local tmp
  tmp=$(mktemp "$REGISTRY.XXXXXX") || return 1
  awk -F'\t' -v OFS='\t' -v n="$1" -v p="$2" -v sid="$3" -v cfg="${4:-}" \
    '$1 == n { $1 = p; $4 = sid; if (NF >= 6 || cfg != "") $6 = cfg } { print }' "$REGISTRY" >"$tmp" && mv -f -- "$tmp" "$REGISTRY"
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
  find "${roots[@]}" -maxdepth 2 -name IMPL.md -type f -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | sed -n '1s/^[^ ]* //p' | grep .
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
  printf 'Fresh start: the orchestrator (Heph) %s; you replace it. Read %s first, then the "Running now" lines in /mnt/c/Users/ajbar/fleet-briefing/claude-queue.md; %s Put anything below that changes the plan into HEPH.md now.\n\n' "$1" "$3" "$4"
  printf "AJ's messages to the last orchestrator after HEPH.md was last written:\n%s\n" "${asks:-- (none)}"
}
