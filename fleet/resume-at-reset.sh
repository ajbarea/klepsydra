#!/usr/bin/env bash
# resume-at-reset.sh [--once]: every POLL_S seconds, look after the fleet's
# panes. A pane stopped on a usage limit is resumed after the reset its own
# message names (+2 min), or at once when AJ has since switched to an account
# with room; a registered pane (panes.tsv) idle past FRESH_AFTER_S is replaced
# by a fresh session from its brief instead, since its prompt cache expired.
# Each pane's account is its config folder's login (panes.tsv column 6, else
# the default folder); with a second folder logged in, a registered pane that
# hits a limit with over MOVE_MIN_S to wait moves at once: a fresh session from
# its brief on the other account, when that one has room, carrying what AJ typed.
# Whatever AJ typed at a limited pane is delivered, never typed over: still in
# the prompt, it is sent as it is; gone from the prompt without being sent (a
# /login redraws every session), it is typed again. Once per account, every
# registered pane and the orchestrator's get /remote-control while idle at an
# empty prompt. The orchestrator is looked after like a registered pane at a
# limit (resumed at its reset, or moved to the account with room as a fresh Heph
# from HEPH.md: heph_move), and is otherwise never typed into, nor replaced
# after a long idle. --once runs one pass. Each decision is one line in the fleet log; each pass touches
# resume.beat for `fleet doctor`.
set -u
FLEET_TARGET=fleet::resume
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
LAUNCH=${LAUNCH:-$here/launch.sh}
FRESH_AFTER_S=${FRESH_AFTER_S:-3300} # Claude Code's prompt cache lives an hour
POLL_S=${POLL_S:-60}
MOVE_MIN_S=${MOVE_MIN_S:-900} # a nearer reset is waited for: a fresh start costs more than the wait
DOCTOR=${DOCTOR:-$here/doctor.sh}
MSG='The usage limit has reset. Continue from where you stopped: re-run a subagent that failed on the limit only if you still need its result (each re-run starts cold and costs a full context), then carry on with your queue. Re-read PR comments before any merge.'

declare -A last due seen_on rc_on note move_failed
# What the service knows per pane survives its own restart (a cut-over, a
# reboot's unit start), for as long as the same tmux server holds the panes.
STATE_FILE=$FLEET_STATE/resume-state
US=$'\x1f' # the field separator: a tab is IFS whitespace, so empty fields would collapse

load_state() {
  local server p d s r l n m
  [[ -r $STATE_FILE ]] || return 0
  server=$(t display-message -p '#{pid}' 2>/dev/null)
  [[ -n $server && $(head -1 "$STATE_FILE") == "#server $server" ]] || return 0
  while IFS=$US read -r p d s r l n m; do
    [[ $p == %* ]] || continue
    [[ -n $d ]] && due[$p]=$d
    [[ -n $s ]] && seen_on[$p]=$s
    [[ -n $r ]] && rc_on[$p]=$r
    [[ -n $l ]] && last[$p]=$l
    [[ -n $n ]] && note[$p]=$(base64 -d <<<"$n")
    [[ -n $m ]] && move_failed[$p]=$m
  done <"$STATE_FILE"
}

save_state() {
  local p tmp server
  server=$(t display-message -p '#{pid}' 2>/dev/null) || return 0
  tmp=$(mktemp "$STATE_FILE.XXXXXX") || return 0
  {
    printf '#server %s\n' "$server"
    for p in $(fleet_panes); do
      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$p" "${due[$p]:-}" "${seen_on[$p]:-}" "${rc_on[$p]:-}" "${last[$p]:-}" \
        "$(printf '%s' "${note[$p]:-}" | base64 -w0)" "${move_failed[$p]:-}"
    done
  } >"$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
}

clock() { printf '%s' "${FLEET_NOW:-$(date +%s)}"; }

# The account of klepsydra's newest usage reading: a /login moves every session.
active_account() {
  local f
  f=$(newest_reading)
  [[ -n $f ]] && jq -r '.label // empty' "$f" 2>/dev/null
}

# The pane's account's newest reading (the newest of any account when the
# pane's folder has no known login) shows a window at 100% that has not reset
# yet: switching to it brings no usage back.
exhausted() {
  local f
  if [[ -n $PANE_ID ]]; then f=$(reading_of "$PANE_ID"); else f=$(newest_reading); fi
  [[ -n $f ]] || return 1
  jq -e --argjson now "$NOW" '[.windows.five_hour, .windows.seven_day][]
    | select(. != null and (.used_percentage // 0) >= 100 and (.resets_at // 0) > $now)' "$f" >/dev/null 2>&1
}

# Press Enter on PANE's input and say whether a turn (or the limit again) followed.
submit() { # PANE
  t send-keys -t "$1" Enter
  if wait_for "$1" "${FLEET_START_WAIT:-30}" started; then echo yes; else echo no; fi
}

# Replace PANE (registry NAME, BRIEF) with a fresh session from its brief,
# on config folder ACCOUNT when given (else launch.sh's pick), WHY in its
# preamble; prints the new pane. NOTE, what AJ typed at the pane, goes into the
# new brief, and the old box may hold exactly it. Gives up, typing nothing, if
# AJ has typed anything else meanwhile.
fresh() { # PANE NAME BRIEF [WHY] [ACCOUNT] [NOTE]
  local p=$1 name=$2 brief=$3 txt new
  local why=${4:-stopped at a usage limit over an hour ago, so its cached conversation expired and resuming it would re-cache everything}
  local account=${5:-} carried=${6:-} box
  box=$(input_text "$(screen "$p")")
  [[ -z $box || ( -n $carried && $box == "$carried" ) ]] || return 1
  local sid cfg out got
  exec 7>>"$FLEET_STATE/.fresh.lock"
  flock 7
  sid=$(reg_field "$p" 4) cfg=$(reg_field "$p" 6)
  if ! pane_runs "$p" "$sid"; then
    flog WARN "fresh session refused: the pane no longer runs its registered session" pane="$p" name="$name" session_id="$sid"
    return 2
  fi
  txt="$FLEET_STATE/fresh-$name-$(date +%Y%m%d-%H%M).src"
  {
    fresh_preamble "$why"
    printf '\n\n'
    [[ -n $carried ]] && printf 'AJ typed this to the previous agent while it waited at the limit; act on it:\n%s\n\n' "$carried"
    cat "$brief"
  } >"$txt"
  mkdir -p -- "$FLEET_STATE/log"
  out=$(FLEET_ACCOUNT=$account bash "$LAUNCH" "$name" "$txt" 2>>"$FLEET_STATE/log/launch.err" | head -1)
  new=$(grep -o 'pane=%[0-9]*' <<<"$out" | cut -d= -f2) got=$(grep -o 'brief=[A-Za-z-]*' <<<"$out" | cut -d= -f2)
  if [[ -z $new ]]; then
    flog ERROR "fresh session not started; the old pane is kept" pane="$p" name="$name"
    return 3
  fi
  # The brief must have started a turn: not delivered, or (on a move to an
  # account said to have room) stopped by a limit, the old pane stays.
  if [[ $got == NOT-DELIVERED || ( -n $account && $got != started ) ]]; then
    flog ERROR "fresh session's brief did not start; the old pane stays and the new one goes" pane="$p" new_pane="$new" name="$name" brief="$got"
    retire "$new" interrupt
    with_registry set_pane "$new" "$p" "$sid" "$cfg"
    return 3
  fi
  # The launch took a while: AJ may have typed into the old pane or resumed it.
  local now_s
  now_s=$(screen "$p")
  if ! pane_runs "$p" "$sid" || busy "$now_s" || ! has_input_box "$now_s" || [[ $(input_text "$now_s") != "$box" ]]; then
    flog ERROR "the old pane changed while its fresh session launched; the old one stays and the new one goes" pane="$p" new_pane="$new" name="$name"
    retire "$new" interrupt
    with_registry set_pane "$new" "$p" "$sid" "$cfg"
    return 4
  fi
  # The note went into the new brief; one C-c clears it from the old box.
  if [[ -n $box ]]; then
    t send-keys -t "$p" C-c
    wait_for "$p" 5 idle_empty || true
  fi
  retire "$p" || flog WARN "the old pane is left running beside its fresh session" pane="$p" new_pane="$new" name="$name"
  printf '%s' "$new"
}

# When the agent in PANE (screen PLAIN) stopped: the "done 4:21 PM" its last
# turn printed (more than 12 h ahead means yesterday), else the window's last
# activity, which status line redraws keep fresh, so it under-counts.
stopped_at() { # PANE PLAIN
  local at stopped
  at=$(grep -o 'done [0-9]\{1,2\}:[0-9][0-9] [AP]M' <<<"$2" | tail -1 | cut -c6-)
  if [[ -n $at ]] && stopped=$(date -d "$at" +%s 2>/dev/null); then
    (( stopped - NOW > 43200 )) && stopped=$((stopped - 86400))
    printf '%s' "$stopped"
  else
    t display-message -p -t "$1" '#{window_activity}'
  fi
}

# Whether the transcript above the box already shows LINE as sent ("❯ LINE"),
# compared without whitespace, since a long line wraps there.
sent_already() { # SCREEN LINE
  local above want
  split_screen "$1"
  above=$(tr -d '[:space:]' <<<"$ABOVE") want=$(tr -d '[:space:]' <<<"❯$2")
  [[ $above == *"$want"* ]]
}

forget() { unset "due[$1]" "seen_on[$1]" "note[$1]"; }

# Replace the orchestrator in PANE with a fresh Heph on config folder TO, from
# a note naming HEPH.md and AJ's messages since (heph_note); WHY ends "the
# orchestrator (Heph) ..."; NOTE, what AJ typed at the old pane and never sent,
# goes with it. The old pane goes only once the new one's turn has started and
# the old one is as it was; gives up, typing nothing, if AJ typed anything else.
# Prints the new pane; fails as fresh does (1 AJ has it, 3 no start, 4 changed).
heph_move() { # PANE TO WHY [NOTE]
  local p=$1 to=$2 why=$3 carried=${4:-} box osid txt out new nsid got now_s
  box=$(input_text "$(screen "$p")")
  [[ -z $box || ( -n $carried && $box == "$carried" ) ]] || return 1
  exec 7>>"$FLEET_STATE/.fresh.lock"
  flock 7
  osid=$(cat "$FLEET_STATE/orchestrator.session" 2>/dev/null)
  txt="$FLEET_STATE/heph-move-$(date +%Y%m%d-%H%M).md"
  {
    heph_note "$why" "$osid" "$HEPH" "the resume service started you on $to and the agents run on meanwhile."
    [[ -n $carried ]] && printf '\nAJ typed this to the last orchestrator and it was never sent; act on it:\n%s\n' "$carried"
  } >"$txt"
  mkdir -p -- "$FLEET_STATE/log"
  out=$(FLEET_SETTINGS='' FLEET_ACCOUNT=$to bash "$LAUNCH" heph "$txt" 2>>"$FLEET_STATE/log/launch.err" | head -1)
  new=$(grep -o 'pane=%[0-9]*' <<<"$out" | cut -d= -f2) got=$(grep -o 'brief=[A-Za-z-]*' <<<"$out" | cut -d= -f2)
  nsid=$(grep -o 'session=[0-9a-f-]*' <<<"$out" | cut -d= -f2)
  if [[ -z $new ]]; then
    flog ERROR "orchestrator not moved: the new session did not start" pane="$p" to="$to"
    return 3
  fi
  if [[ $got != started ]]; then
    flog ERROR "orchestrator not moved: its note did not start a turn; the new pane goes" pane="$p" new_pane="$new" to="$to" brief="$got"
    retire "$new" interrupt
    return 3
  fi
  now_s=$(screen "$p")
  if busy "$now_s" || ! has_input_box "$now_s" || [[ $(input_text "$now_s") != "$box" ]]; then
    flog ERROR "the orchestrator's pane changed while its successor launched; the old one stays and the new one goes" pane="$p" new_pane="$new"
    retire "$new" interrupt
    return 4
  fi
  printf '%s\n' "$new" >"$FLEET_STATE/orchestrator.pane"
  [[ -n $nsid ]] && printf '%s\n' "$nsid" >"$FLEET_STATE/orchestrator.session"
  printf '%s\n' "$to" >"$FLEET_STATE/orchestrator.config"
  if [[ -n $box ]]; then
    t send-keys -t "$p" C-c
    wait_for "$p" 5 idle_empty || true
  fi
  retire "$p" || flog WARN "the old orchestrator pane is left running beside its successor" pane="$p" new_pane="$new"
  printf '%s' "$new"
}

# Record a move PANE -> NEW (or a failed try, with no NEW) for the hold-downs.
moved() { # PANE [NEW]
  if [[ -n ${2:-} ]]; then
    last[$2]=$NOW last[$1]=$NOW
    forget "$1"
  else
    move_failed[$1]=$NOW
  fi
}


one() { # PANE
  local p=$1 s ps typed orch=0 armed at limit reset reg name brief idle new got tmp
  [[ -n $ORCH && $p == "$ORCH" ]] && orch=1
  # The pane's account: its config folder's login, named as the gauge names
  # it; a folder with no known login falls back to the newest reading's.
  local cfg PANE_ID ACTIVE=$ACTIVE
  cfg=$(pane_config "$p")
  (( orch )) && cfg=$(heph_config)
  PANE_ID=${ACCT_ID[$cfg]:-}
  [[ -n $PANE_ID ]] && ACTIVE=$(account_label "$PANE_ID")
  (( NOW - ${last[$p]:-0} < 900 )) && return
  s=$(screen "$p") || return
  ps=$(plain <<<"$s")
  typed=$(input_text "$s")

  # Claude Code's limit menu: take option 1, "Stop and wait for limit to reset";
  # on the next pass the pane reads as an ordinary limited one.
  if limit_menu "$s"; then
    t send-keys -t "$p" Enter
    flog INFO "limit menu: chose stop and wait" pane="$p" account="${ACTIVE:-unknown}"
    return
  fi

  # Claude Code's own auto-continue resumes the whole transcript; on a
  # registered pane with over FRESH_AFTER_S to wait, cancel it ("esc to
  # cancel") so the pane gets a fresh session at the reset. Never over typed text.
  armed=$(split_screen "$s"; printf '%s\n' "$BELOW" | grep -o 'Continuing automatically at [^·]*' | tail -1 | sed 's/^Continuing automatically at //; s/ *$//')
  if (( !orch )) && [[ -n $armed && -z $typed ]] && registered "$p"; then
    at=$(date -d "${armed//,/}" +%s 2>/dev/null) || at=0
    (( at > 0 && NOW - at > 21600 )) && at=$((at + 86400))
    if (( at - NOW >= FRESH_AFTER_S )); then
      t send-keys -t "$p" Escape
      flog INFO "cancelled the built-in auto-continue: a fresh session at the reset instead" pane="$p" resets="$armed"
      return
    fi
  fi

  limit=$(limit_line "$s")
  # Remote Control: a /login disconnects it in every session, and the RIT
  # account never starts it on its own, so once per account each registered
  # pane and the orchestrator's get /remote-control while idle at an empty
  # prompt. A limited pane is left alone: typing would scroll its limit away.
  if [[ -n $ACTIVE && ${rc_on[$p]:-} != "$ACTIVE" && -z ${due[$p]:-} && -z $limit ]] && { (( orch )) || registered "$p"; } && idle_empty "$s"; then
    if remote_control "$p"; then
      rc_on[$p]=$ACTIVE
      flog INFO "remote control on" pane="$p" account="$ACTIVE" orchestrator="$orch"
    else
      flog WARN "remote control did not settle; trying again next pass" pane="$p" account="$ACTIVE" orchestrator="$orch"
    fi
    return
  fi
  if (( orch )); then
    # Keep Heph's session on record, so `fleet recover` finds his transcript after a power cut.
    local osid
    # Only a live session no agent's row names: a worker relaunched into Heph's old pane is not him.
    if ! registered "$p" && osid=$(live_session "$p") && session_alive "$osid" && ! cut -f4 "$REGISTRY" 2>/dev/null | grep -qxF -- "$osid" &&
      [[ $osid != "$(cat "$FLEET_STATE/orchestrator.session" 2>/dev/null)" ]]; then
      printf '%s\n' "$osid" >"$FLEET_STATE/orchestrator.session"
      flog INFO "orchestrator session recorded" pane="$p" session="$osid"
    fi
  fi

  # Limited: the limit message is the last thing on screen, or the pane was
  # seen limited and still sits idle at its prompt (the status line's banner
  # clears itself at the reset, before the resume is due).
  if busy "$s" || ! has_input_box "$s" || [[ -z $limit && -z ${due[$p]:-} ]]; then
    forget "$p"
    return
  fi
  local fresh_typing=0
  if [[ -n $typed && $typed != "${note[$p]:-}" ]]; then
    note[$p]=$typed fresh_typing=1
    flog INFO "AJ typed at a limited pane; it goes out at the resume" pane="$p" chars="${#typed}" text="${typed:0:200}"
  fi
  if [[ -z ${due[$p]:-} ]]; then
    if reset=$(reset_epoch "$limit" "$NOW") || reset=$(reset_epoch "$ps" "$NOW"); then :; else reset=$((NOW + 1800)); fi
    due[$p]=$((reset + 120)) seen_on[$p]=${ACTIVE:-unknown}
    flog INFO "limit seen" pane="$p" account="${seen_on[$p]}" resets="$(date -d @"$reset" '+%a %F %H:%M')" message="$limit"
  fi
  reg=$(awk -F'\t' -v p="$p" '$1 == p { print $2 "\t" $3 }' "$REGISTRY" 2>/dev/null)
  name=${reg%%$'\t'*} brief=${reg#*$'\t'}

  local switched=0
  [[ ${seen_on[$p]} != "${ACTIVE:-unknown}" ]] && ! exhausted && switched=1

  # Two accounts: a registered pane with a long wait (and no switch of its own) moves to the other one
  # now, if it has room, carrying what AJ typed (still in the box, or gone
  # from it unsent). A failed move waits 15 min before the next try.
  local other carry="" rc
  if (( !fresh_typing && !switched )) && { [[ -n $reg ]] || (( orch )); } && (( due[$p] - NOW >= MOVE_MIN_S && NOW - ${move_failed[$p]:-0} >= 900 )) &&
    other=$(room_elsewhere "$cfg" "$NOW"); then
    # What AJ typed while it waited is carried even when he sent it: the
    # session answered only with the limit, so it never acted on it. (Heph's
    # note carries AJ's sent messages from his transcript itself.)
    if [[ -n $typed ]]; then
      carry=$typed
    elif [[ -n ${note[$p]:-} ]]; then
      carry=${note[$p]}
    elif (( !orch )); then
      carry=$(answered_by_limit "$s")
    fi
    # A pasted block or an image shows in the box only as its placeholder: its
    # content cannot be carried, so the pane keeps it and waits for its reset.
    if [[ $carry == *"[Pasted text #"* || $carry == *"[Image #"* ]]; then
      flog WARN "a pasted block cannot be carried to the other account; the pane waits for its reset" pane="$p" text="$carry"
    elif [[ -z $typed || -n $carry ]]; then
      if (( orch )); then
        new=$(heph_move "$p" "$other" "stopped at a usage limit on one account, and moves to the other, which has room" "$carry")
      else
        new=$(fresh "$p" "$name" "$brief" "stopped at a usage limit on one account, and you continue on the other, which has room" "$other" "$carry")
      fi
      rc=$?
      case $rc in
        0)
          flog INFO "moved to the other account at a limit" pane="$p" name="${name:-orchestrator}" orchestrator="$orch" from="$cfg" to="$other" new_pane="${new:-none}" carried_chars="${#carry}" resets="$(date -d @"$((due[$p] - 120))" '+%a %F %H:%M')"
          moved "$p" "$new"
          return
          ;;
        1 | 4)
          # A launch that AJ undid (4) cost a session: wait as after a failure.
          (( rc == 4 )) && move_failed[$p]=$NOW
          flog INFO "AJ has the pane; leaving it to the next pass" pane="$p" why="$rc"
          return
          ;;
        *)
          move_failed[$p]=$NOW
          flog WARN "could not move to the other account; waiting for the reset" pane="$p" name="$name" to="$other" why="$rc"
          ;;
      esac
    fi
  fi

  (( NOW >= due[$p] || switched )) || return
  # AJ's line changed since the last pass: he may still be typing it.
  (( fresh_typing )) && return

  if [[ -n $typed ]]; then
    got=$(submit "$p")
    flog INFO "resumed: sent what AJ typed" pane="$p" account="${ACTIVE:-unknown}" switched="$switched" started="$got" text="${typed:0:200}"
  elif [[ ${note[$p]:-} == "[Pasted text #"* ]] && { split_screen "$s"; ! grep -qF -- "❯ ${note[$p]}" <<<"$ABOVE"; }; then
    flog WARN "a pasted block left the prompt unsent and cannot be typed again; resuming without it" pane="$p" text="${note[$p]}"
    unset "note[$p]"
    return
  elif [[ -n ${note[$p]:-} ]] && ! sent_already "$s" "${note[$p]}"; then
    # Typed, then gone from the prompt without being sent (not in the
    # transcript above it): type it again.
    tmp=$(mktemp)
    printf '%s' "${note[$p]}" >"$tmp"
    got=$(deliver "$p" "$tmp")
    rm -f -- "${tmp:?}"
    flog WARN "resumed: AJ's line had left the prompt unsent, so it was typed again" pane="$p" account="${ACTIVE:-unknown}" switched="$switched" delivered="$got" text="${note[$p]:0:200}"
  else
    # Past an hour idle a registered pane starts fresh from its brief; a pane
    # that no longer runs its registered session (2) is resumed in place instead.
    local rc=3
    if [[ -n $reg ]] && idle=$((NOW - $(stopped_at "$p" "$ps"))) && (( idle >= FRESH_AFTER_S )); then
      new=$(fresh "$p" "$name" "$brief")
      rc=$?
    fi
    case $rc in
      0)
        flog INFO "fresh session after a long idle" pane="$p" name="$name" new_pane="${new:-none}" idle_min="$((idle / 60))" account="${ACTIVE:-unknown}"
        [[ -n $new ]] && last[$new]=$NOW
        ;;
      1 | 4)
        flog INFO "AJ has the pane; leaving it to the next pass" pane="$p" why="$rc"
        return
        ;;
      *)
        if type_exactly "$p" "$MSG"; then got=$(submit "$p"); else got="no: AJ typed meanwhile"; fi
        flog INFO "resumed with the continue message" pane="$p" account="${ACTIVE:-unknown}" switched="$switched" started="$got"
        ;;
    esac
  fi
  last[$p]=$NOW
  forget "$p"
}

# The account logged in at each config folder, for this pass.
declare -A ACCT_ID
accounts() {
  local dir id
  ACCT_ID=()
  for dir in $FLEET_ACCOUNTS; do
    id=$(account_of "$dir") && ACCT_ID[$dir]=$id
  done
}

# An account switch (a /login in the default folder, the orchestrator's) ends
# with `fleet doctor`, once the panes have had DOCTOR_AFTER_S to settle.
doctor_after_switch() {
  # The default folder's login only: a pass that cannot read it says nothing.
  local now_acct=${ACCT_ID[$FLEET_DEFAULT_CONFIG]:-}
  [[ -n $now_acct ]] || now_acct=$PREV_ACCT
  if [[ -n $now_acct && -n $PREV_ACCT && $now_acct != "$PREV_ACCT" ]]; then
    DOCTOR_DUE=$((NOW + ${DOCTOR_AFTER_S:-300}))
    flog INFO "account switch seen; fleet doctor follows" from="$PREV_ACCT" to="$now_acct"
  fi
  PREV_ACCT=$now_acct
  if (( DOCTOR_DUE && NOW >= DOCTOR_DUE )); then
    DOCTOR_DUE=0
    if bash "$DOCTOR" >/dev/null 2>&1; then
      flog INFO "fleet doctor after the account switch: healthy"
    else
      flog ERROR "fleet doctor after the account switch found a failure (fleet doctor for the list)"
    fi
  fi
}
PREV_ACCT="" DOCTOR_DUE=0

pass() {
  NOW=$(clock) ACTIVE=$(active_account) ORCH=$(orchestrator)
  accounts
  local p
  for p in $(fleet_panes); do one "$p"; done
  doctor_after_switch
  save_state
  : >>"$FLEET_STATE/resume.beat" && touch -- "$FLEET_STATE/resume.beat"
}

load_state
if [[ ${1:-} == --once ]]; then
  pass
  exit 0
fi
flog INFO "resume service started" poll_s="$POLL_S" fresh_after_s="$FRESH_AFTER_S" socket="$FLEET_SOCK"
while :; do
  pass
  sleep "$POLL_S"
done
