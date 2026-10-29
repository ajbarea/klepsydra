#!/usr/bin/env bash
# resume-at-reset.sh [--once]: every POLL_S seconds, look after the fleet's
# panes. A pane stopped on a usage limit is resumed after the reset its own
# message names (+2 min), or at once when AJ has since switched to an account
# with room; a registered pane (panes.tsv) idle past FRESH_AFTER_S is replaced
# by a fresh session from its brief instead, since its prompt cache expired.
# Whatever AJ typed at a limited pane is delivered, never typed over: still in
# the prompt, it is sent as it is; gone from the prompt without being sent (a
# /login redraws every session), it is typed again. Once per account, every
# registered pane and the orchestrator's get /remote-control while idle at an
# empty prompt. The orchestrator's pane is otherwise never touched. --once runs
# one pass. Each decision is one line in the fleet log; each pass touches
# resume.beat for `fleet doctor`.
set -u
FLEET_TARGET=fleet::resume
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
LAUNCH=${LAUNCH:-$here/launch.sh}
FRESH_AFTER_S=${FRESH_AFTER_S:-3300} # Claude Code's prompt cache lives an hour
POLL_S=${POLL_S:-60}
MSG='The usage limit has reset. Continue from where you stopped: re-run a subagent that failed on the limit only if you still need its result (each re-run starts cold and costs a full context), then carry on with your queue. Re-read PR comments before any merge.'

declare -A last due seen_on rc_on note
# What the service knows per pane survives its own restart (a cut-over, a
# reboot's unit start), for as long as the same tmux server holds the panes.
STATE_FILE=$FLEET_STATE/resume-state
US=$'\x1f' # the field separator: a tab is IFS whitespace, so empty fields would collapse

load_state() {
  local server p d s r l n
  [[ -r $STATE_FILE ]] || return 0
  server=$(t display-message -p '#{pid}' 2>/dev/null)
  [[ -n $server && $(head -1 "$STATE_FILE") == "#server $server" ]] || return 0
  while IFS=$US read -r p d s r l n; do
    [[ $p == %* ]] || continue
    [[ -n $d ]] && due[$p]=$d
    [[ -n $s ]] && seen_on[$p]=$s
    [[ -n $r ]] && rc_on[$p]=$r
    [[ -n $l ]] && last[$p]=$l
    [[ -n $n ]] && note[$p]=$(base64 -d <<<"$n")
  done <"$STATE_FILE"
}

save_state() {
  local p tmp server
  server=$(t display-message -p '#{pid}' 2>/dev/null) || return 0
  tmp=$(mktemp "$STATE_FILE.XXXXXX") || return 0
  {
    printf '#server %s\n' "$server"
    for p in $(fleet_panes); do
      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$p" "${due[$p]:-}" "${seen_on[$p]:-}" "${rc_on[$p]:-}" "${last[$p]:-}" \
        "$(printf '%s' "${note[$p]:-}" | base64 -w0)"
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

# The active account's newest reading shows a window at 100% that has not
# reset yet: switching to it brings no usage back.
exhausted() {
  local f
  f=$(newest_reading)
  [[ -n $f ]] || return 1
  jq -e --argjson now "$NOW" '[.windows.five_hour, .windows.seven_day][]
    | select(. != null and (.used_percentage // 0) >= 100 and (.resets_at // 0) > $now)' "$f" >/dev/null 2>&1
}

# Press Enter on PANE's input and say whether a turn (or the limit again) followed.
submit() { # PANE
  t send-keys -t "$1" Enter
  if wait_for "$1" "${FLEET_START_WAIT:-30}" started; then echo yes; else echo no; fi
}

# Replace PANE (registry NAME, BRIEF) with a fresh session from its brief;
# prints the new pane. Gives up, typing nothing, if AJ has typed meanwhile.
fresh() { # PANE NAME BRIEF
  local p=$1 name=$2 brief=$3 txt new
  [[ -z $(input_text "$(screen "$p")") ]] || return 1
  txt="$FLEET_STATE/fresh-$name-$(date +%Y%m%d-%H%M).src"
  { fresh_preamble "stopped at a usage limit over an hour ago, so its cached conversation expired and resuming it would re-cache everything"; printf '\n\n'; cat "$brief"; } >"$txt"
  t send-keys -t "$p" -l "/exit"
  wait_for "$p" 5 holds_input && t send-keys -t "$p" Enter
  for _ in $(seq 30); do fleet_panes | grep -qx "$p" || break; sleep 1; done
  t kill-pane -t "$p" 2>/dev/null
  new=$(bash "$LAUNCH" "$name" "$txt" 2>/dev/null | grep -o 'pane=%[0-9]*' | head -1 | cut -d= -f2)
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

forget() { unset "due[$1]" "seen_on[$1]" "note[$1]"; }

one() { # PANE
  local p=$1 s ps typed orch=0 armed at limit reset reg name brief idle new got tmp
  [[ -n $ORCH && $p == "$ORCH" ]] && orch=1
  (( NOW - ${last[$p]:-0} < 900 )) && return
  s=$(screen "$p") || return
  ps=$(plain <<<"$s")
  typed=$(input_text "$s")

  # Claude Code's limit menu: take option 1, "Stop and wait for limit to reset";
  # on the next pass the pane reads as an ordinary limited one.
  if (( !orch )) && grep -q 'Stop and wait for limit to reset' <<<"$ps" && grep -q 'Enter to confirm' <<<"$ps"; then
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
  (( orch )) && return

  # Limited: the limit message is the last thing on screen, or the pane was
  # seen limited and still sits idle at its prompt (the status line's banner
  # clears itself at the reset, before the resume is due).
  if busy "$s" || ! has_input_box "$s" || [[ -z $limit && -z ${due[$p]:-} ]]; then
    forget "$p"
    return
  fi
  if [[ -n $typed && $typed != "${note[$p]:-}" ]]; then
    note[$p]=$typed
    flog INFO "AJ typed at a limited pane; it goes out at the resume" pane="$p" chars="${#typed}" text="${typed:0:200}"
  fi
  if [[ -z ${due[$p]:-} ]]; then
    if reset=$(reset_epoch "$ps" "$NOW"); then :; else reset=$((NOW + 1800)); fi
    due[$p]=$((reset + 120)) seen_on[$p]=${ACTIVE:-unknown}
    flog INFO "limit seen" pane="$p" account="${seen_on[$p]}" resets="$(date -d @"$reset" '+%a %F %H:%M')" message="$limit"
  fi
  local switched=0
  [[ ${seen_on[$p]} != "${ACTIVE:-unknown}" ]] && ! exhausted && switched=1
  (( NOW >= due[$p] || switched )) || return

  reg=$(awk -F'\t' -v p="$p" '$1 == p { print $2 "\t" $3 }' "$REGISTRY" 2>/dev/null)
  name=${reg%%$'\t'*} brief=${reg#*$'\t'}
  if [[ -n $typed ]]; then
    got=$(submit "$p")
    flog INFO "resumed: sent what AJ typed" pane="$p" account="${ACTIVE:-unknown}" switched="$switched" started="$got" text="${typed:0:200}"
  elif [[ -n ${note[$p]:-} ]] && { split_screen "$s"; ! grep -qF -- "${note[$p]%%$'\n'*}" <<<"$ABOVE"; }; then
    # Typed, then gone from the prompt without being sent (not in the
    # transcript above it): type it again.
    tmp=$(mktemp)
    printf '%s' "${note[$p]}" >"$tmp"
    got=$(deliver "$p" "$tmp")
    rm -f -- "${tmp:?}"
    flog WARN "resumed: AJ's line had left the prompt unsent, so it was typed again" pane="$p" account="${ACTIVE:-unknown}" switched="$switched" delivered="$got" text="${note[$p]:0:200}"
  elif [[ -n $reg ]] && idle=$((NOW - $(stopped_at "$p" "$ps"))) && (( idle >= FRESH_AFTER_S )); then
    if new=$(fresh "$p" "$name" "$brief"); then
      flog INFO "fresh session after a long idle" pane="$p" name="$name" new_pane="${new:-none}" idle_min="$((idle / 60))" account="${ACTIVE:-unknown}"
      [[ -n $new ]] && last[$new]=$NOW
    else
      flog INFO "AJ typed just now; leaving the pane to the next pass" pane="$p"
      return
    fi
  else
    t send-keys -t "$p" -l "$MSG"
    if wait_for "$p" 5 holds_input; then got=$(submit "$p"); else got=no; fi
    flog INFO "resumed with the continue message" pane="$p" account="${ACTIVE:-unknown}" switched="$switched" started="$got"
  fi
  last[$p]=$NOW
  forget "$p"
}

pass() {
  NOW=$(clock) ACTIVE=$(active_account) ORCH=$(orchestrator)
  local p
  for p in $(fleet_panes); do one "$p"; done
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
