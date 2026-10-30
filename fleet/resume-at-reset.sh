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
# after a long idle. Each role prefers an account (#175): workers the first
# folder in FLEET_ACCOUNTS, Heph the first in FLEET_HEPH_ACCOUNTS; a pane on
# another moves back once its preferred one has FLEET_BACK_ROOM_PCT room, at a
# finished turn and an empty prompt; a worker whose account has used
# FLEET_PREMOVE_PCT of a window moves to one with room at its next finished
# turn, before the limit stops it mid-turn (#187). Each move runs in the
# background, one per pane, so a slow launch never holds the others; the pass
# after it ends applies its result. A failed move at a limit or before it is
# tried again at the next pass once, then every 15 min; a move back waits
# 15 min; a failed fresh start is resumed in place. A CI red the CI watch routed to an agent
# (inbox/NAME/*.txt) is typed into its pane at an idle, empty prompt, oldest
# first. --once runs one pass (and waits for the moves it started). Each
# decision is one line in the fleet log; each pass touches resume.beat for
# `fleet doctor`.
set -u
FLEET_TARGET=fleet::resume
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
LAUNCH=${LAUNCH:-$here/launch.sh}
FRESH_AFTER_S=${FRESH_AFTER_S:-3300} # Claude Code's prompt cache lives an hour
POLL_S=${POLL_S:-60}
MOVE_MIN_S=${MOVE_MIN_S:-900} # a nearer reset is waited for: a fresh start costs more than the wait
FLEET_PREMOVE_PCT=${FLEET_PREMOVE_PCT:-95} # a window used this far moves a worker at its next finished turn
DOCTOR=${DOCTOR:-$here/doctor.sh}
MSG='The usage limit has reset. Continue from where you stopped: re-run a subagent that failed on the limit only if you still need its result (each re-run starts cold and costs a full context), then carry on with your queue. Re-read PR comments before any merge.'

declare -A last due seen_on rc_on note move_failed move_tries fresh_failed job_kind job_ctx
declare -A job=() # set, so ${#job[@]} reads 0 under set -u
# What the service knows per pane survives its own restart (a cut-over, a
# reboot's unit start), for as long as the same tmux server holds the panes.
STATE_FILE=$FLEET_STATE/resume-state
US=$'\x1f' # the field separator: a tab is IFS whitespace, so empty fields would collapse

load_state() {
  local server p d s r l n m k f
  [[ -r $STATE_FILE ]] || return 0
  server=$(t display-message -p '#{pid}' 2>/dev/null)
  [[ -n $server && $(head -1 "$STATE_FILE") == "#server $server" ]] || return 0
  while IFS=$US read -r p d s r l n m k f; do
    [[ $p == %* ]] || continue
    [[ -n $d ]] && due[$p]=$d
    [[ -n $s ]] && seen_on[$p]=$s
    [[ -n $r ]] && rc_on[$p]=$r
    [[ -n $l ]] && last[$p]=$l
    [[ -n $n ]] && note[$p]=$(base64 -d <<<"$n")
    [[ -n $m ]] && move_failed[$p]=$m
    [[ -n $k ]] && move_tries[$p]=$k
    [[ -n $f ]] && fresh_failed[$p]=$f
  done <"$STATE_FILE"
}

save_state() {
  local p tmp server
  server=$(t display-message -p '#{pid}' 2>/dev/null) || return 0
  tmp=$(mktemp "$STATE_FILE.XXXXXX") || return 0
  {
    printf '#server %s\n' "$server"
    for p in $(fleet_panes); do
      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$p" "${due[$p]:-}" "${seen_on[$p]:-}" "${rc_on[$p]:-}" "${last[$p]:-}" \
        "$(printf '%s' "${note[$p]:-}" | base64 -w0)" "${move_failed[$p]:-}" "${move_tries[$p]:-}" "${fresh_failed[$p]:-}"
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
# (STAMP: the session's prompt.at when the caller judged the pane idle, so a
# prompt taken since, even one already answered, keeps the old pane.) Returns
# 5 when the new session's brief met a limit on ACCOUNT.
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
    retire "$new" interrupt
    with_registry set_pane "$new" "$p" "$sid" "$cfg"
    [[ $got == blocked-by-limit ]] && return 5
    return 3
  fi
  # The launch took a while: AJ may have typed into the old pane or resumed it.
  local now_s
  now_s=$(screen "$p")
  if ! pane_runs "$p" "$sid" || busy "$now_s" || ! has_input_box "$now_s" || [[ $(input_text "$now_s") != "$box" || $(prompt_stamp "$p") != "$stamp" ]]; then
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
# turn printed, read on NOW's day. More than 15 min past NOW is the day before;
# a turn that ended during this pass (NOW is its start) reads up to 15 min
# past NOW, or, across midnight, nearly a day back: that is now. In the hour
# that repeats when clocks go back, date reads the first; the second is taken
# when it is not ahead. Else the window's last activity, which status line
# redraws keep fresh, so it under-counts. Always a number: when unsure, NOW.
stopped_at() { # PANE PLAIN
  local at day stopped later
  at=$(grep -o 'done [0-9]\{1,2\}:[0-9][0-9] [AP]M' <<<"$2" | tail -1 | cut -c6-)
  if [[ -n $at ]] && day=$(date -d "@$NOW" +%F) && stopped=$(date -d "$day $at" +%s 2>/dev/null); then
    later=$((stopped + 3600))
    if [[ $(date -d "@$later" '+%F %R') == "$(date -d "@$stopped" '+%F %R')" ]] && (( later <= NOW + 900 )); then
      stopped=$later
    fi
    if (( stopped > NOW + 900 )); then
      stopped=$(date -d "$day $at -1 day" +%s 2>/dev/null) || stopped=$NOW
    elif (( stopped <= NOW + 900 - 86400 )); then
      stopped=$NOW
    fi
  else
    stopped=$(t display-message -p -t "$1" '#{window_activity}' 2>/dev/null)
  fi
  [[ $stopped =~ ^[0-9]+$ ]] || stopped=$NOW
  printf '%s' "$stopped"
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
# the old one is as it was (screen and session state), and the records follow
# only once it has gone; gives up, typing nothing, if AJ typed anything else.
# Prints the new pane; fails as fresh does (1 AJ has it, 2 not Heph, 3 no
# start or the old one stayed, 4 changed, 5 the note met a limit on TO).
heph_move() { # PANE TO WHY [NOTE] [STAMP]
  local p=$1 to=$2 why=$3 carried=${4:-} box osid txt out new nsid got now_s stamp
  box=$(input_text "$(screen "$p")")
  [[ -z $box || ( -n $carried && $box == "$carried" ) ]] || return 1
  exec 7>>"$FLEET_STATE/.fresh.lock"
  flock -s 7
  # Only Heph himself: a tmux restart reuses pane ids, so a registered agent or
  # a session other than the one on record in his pane is never replaced.
  osid=$(cat "$FLEET_STATE/orchestrator.session" 2>/dev/null)
  if registered "$p" || { [[ -n $osid ]] && [[ $(live_session "$p") != "$osid" ]]; }; then
    flog WARN "orchestrator not moved: the pane does not run the recorded orchestrator session" pane="$p" session="${osid:-none}"
    return 2
  fi
  if (( $# >= 5 )); then stamp=$5; else stamp=$(prompt_stamp "$p"); fi
  txt="$FLEET_STATE/heph-move-$(date +%Y%m%d-%H%M).md"
  {
    heph_note "$why" "$osid" "$HEPH" "the resume service started you on $to and the agents run on meanwhile."
    [[ -n $carried ]] && printf '\nAJ typed this to the last orchestrator and it was never sent; act on it:\n%s\n' "$carried"
  } >"$txt"
  mkdir -p -- "$FLEET_STATE/log"
  out=$(FLEET_SETTINGS='' FLEET_ACCOUNT=$to bash "$LAUNCH" heph "$txt" 2>>"$FLEET_STATE/log/launch.err" | head -1)
  new=$(grep -o 'pane=%[0-9]*' <<<"$out" | cut -d= -f2) got=$(grep -o 'brief=[A-Za-z-]*' <<<"$out" | cut -d= -f2)
  nsid=$(grep -o 'session=[0-9a-f-]*' <<<"$out" | cut -d= -f2)
  [[ -n $new && -n ${MOVE_NEW:-} ]] && printf '%s\n' "$new" >"$MOVE_NEW"
  if [[ -z $new ]]; then
    flog ERROR "orchestrator not moved: the new session did not start" pane="$p" to="$to"
    return 3
  fi
  if [[ $got != started ]]; then
    flog ERROR "orchestrator not moved: its note did not start a turn; the new pane goes" pane="$p" new_pane="$new" to="$to" brief="$got"
    drop "$new"
    [[ $got == blocked-by-limit ]] && return 5
    return 3
  fi
  # A phone message answered while the successor launched leaves the screen as
  # it was but is a new prompt in his session: the old Heph stays.
  now_s=$(screen "$p")
  if busy "$now_s" || ! has_input_box "$now_s" || [[ $(input_text "$now_s") != "$box" || $(prompt_stamp "$p") != "$stamp" ]]; then
    flog ERROR "the orchestrator's pane changed while its successor launched; the old one stays and the new one goes" pane="$p" new_pane="$new"
    drop "$new"
    return 4
  fi
  if [[ -n $box ]]; then
    t send-keys -t "$p" C-c
    wait_for "$p" 5 idle_empty || true
  fi
  # Two Hephs never run: the old one goes first, or the new one does (a pane
  # that exited just as retire gave up has gone all the same).
  if ! retire "$p" && fleet_panes | grep -qx -- "$p"; then
    flog ERROR "the old orchestrator pane would not exit; it stays and its successor goes" pane="$p" new_pane="$new"
    drop "$new"
    return 3
  fi
  printf '%s\n' "$new" >"$FLEET_STATE/orchestrator.pane"
  [[ -n $nsid ]] && printf '%s\n' "$nsid" >"$FLEET_STATE/orchestrator.session"
  printf '%s\n' "$to" >"$FLEET_STATE/orchestrator.config"
  printf '%s' "$new"
}

# When the live session in PANE last took a prompt (klepsydra's fleet file sets
# prompt.at for typed and phone prompts, not task notifications), or nothing.
prompt_stamp() { # PANE
  local sid
  sid=$(live_session "$1") || return 0
  jq -r '.prompt.at // ""' "$KLEPSYDRA_DIR/fleet/$sid.json" 2>/dev/null
}

# Retire a pane this pass launched, interrupting its turn; kill it if it will not exit.
drop() { # PANE
  retire "$1" interrupt || t kill-pane -t "$1" 2>/dev/null
}

# Moves back to an account that answered one with a limit its gauge did not
# show wait for its next reading, or BACK_HOLD_S at most: the limit then costs
# one session, not one per pane.
BACK_HOLD=$FLEET_STATE/back-hold
BACK_HOLD_S=${BACK_HOLD_S:-1800}
reading_mtime() { local f; f=$(reading_of "$1") && find "$f" -maxdepth 0 -printf '%T@' 2>/dev/null || echo 0; } # ID
back_hold() { # ID
  [[ -n $1 ]] || return 0
  { grep -v "^$1 " "$BACK_HOLD" 2>/dev/null; printf '%s %s %s\n' "$1" "$(reading_mtime "$1")" "$NOW"; } >"$BACK_HOLD.tmp" &&
    mv -f -- "$BACK_HOLD.tmp" "$BACK_HOLD"
  flog WARN "moves back to the account held until its next usage reading" account="$(account_label "$1")" max_s="$BACK_HOLD_S"
}
back_held() { # ID
  local held at
  [[ -n $1 ]] || return 1
  read -r held at < <(awk -v id="$1" '$1 == id { print $2, $3 }' "$BACK_HOLD" 2>/dev/null)
  [[ -n $held && -n $at ]] && (( NOW - at < BACK_HOLD_S )) && awk -v m="$(reading_mtime "$1")" -v h="$held" 'BEGIN { exit !(m <= h) }'
}

# Record a move PANE -> NEW (or a failed try, with no NEW) for the hold-downs.
moved() { # PANE [NEW]
  if [[ -n ${2:-} ]]; then
    last[$2]=$NOW last[$1]=$NOW
    unset "move_tries[$1]" "fresh_failed[$1]"
    forget "$1"
  else
    # A failure an hour after the last starts the count again (a new limit,
    # not the same one still failing): the next pass may then try once more.
    if (( NOW - ${move_failed[$1]:-0} >= MOVE_QUIET_S )); then move_tries[$1]=1; else move_tries[$1]=$((${move_tries[$1]:-0} + 1)); fi
    move_failed[$1]=$NOW
  fi
}
# Whether PANE may try a move now: none failed, or only one (tried again at
# the next pass: a launch can fail once on a slow start), or the last failed
# 15 min ago. Heph's failed moves always wait the 15 min: each try launches a
# second Heph.
move_hold_ok() { # PANE
  (( ${move_tries[$1]:-0} <= 1 || NOW - ${move_failed[$1]:-0} >= 900 ))
}

# Moves run in the background, at most one per pane and FLEET_MAX_MOVES at
# once (each starts a session beside the one it replaces, so memory bounds
# them): CMD (fresh or heph_move) prints the new pane; its exit code and
# output land in JOBS, and reap applies them to the records with done_move
# KIND CTX (kept beside, so a restart still applies a move that finished).
# A pane with a move in flight, or one being started (launching/<pane>), is
# left alone meanwhile; the mover keeps the new pane's mark until its job
# ends (FLEET_KEEP_MARK, MOVE_NEW), not just until launch.sh returns.
JOBS=$FLEET_STATE/moves
FLEET_MAX_MOVES=${FLEET_MAX_MOVES:-2}
MOVE_QUIET_S=${MOVE_QUIET_S:-3600}
spawn() { # PANE KIND CTX CMD...
  local p=$1 kind=$2 ctx=$3 out
  shift 3
  if (( ${#job[@]} >= FLEET_MAX_MOVES )); then
    flog INFO "move put off to a later pass: enough are running" pane="$p" kind="$kind" running="${#job[@]}"
    return 1
  fi
  mkdir -p -- "$JOBS"
  out=$JOBS/${p#%}.out
  rm -f -- "$out" "$out.new"
  # The tmux server it ran on: after a restart its pane ids belong to others.
  printf '%s%s%s%s%s\n' "$(t display-message -p '#{pid}' 2>/dev/null)" "$US" "$kind" "$US" "$ctx" >"$JOBS/${p#%}.ctx"
  (
    new=$(FLEET_KEEP_MARK=1 MOVE_NEW=$out.new "$@")
    rc=$?
    # The new pane's mark goes before the result shows, so a pass that reaps
    # it and starts another move for the pane cannot strand the mark.
    if [[ -s $out.new ]]; then
      rm -f -- "$FLEET_STATE/launching/$(<"$out.new")" "$out.new"
    fi
    printf '%s\t%s\n' "$rc" "$new" >"$out.tmp" && mv -f -- "$out.tmp" "$out"
  ) &
  job[$p]=$! job_kind[$p]=$kind job_ctx[$p]=$ctx
  flog INFO "move started" pane="$p" kind="$kind"
}
reap() {
  local p out rc new
  for p in "${!job[@]}"; do
    out=$JOBS/${p#%}.out
    if [[ -f $out ]]; then
      IFS=$'\t' read -r rc new <"$out"
      rm -f -- "$out"
    elif kill -0 "${job[$p]}" 2>/dev/null; then
      continue
    else
      rc=3 new=""
      flog ERROR "a move ended without a result" pane="$p" kind="${job_kind[$p]}"
    fi
    done_move "$p" "${job_kind[$p]}" "${rc:-3}" "$new" "${job_ctx[$p]}"
    rm -f -- "$JOBS/${p#%}.ctx"
    unset "job[$p]" "job_kind[$p]" "job_ctx[$p]"
  done
}
# At start: moves that finished while the service was down (a cut-over waits
# for running ones) are applied from their result and context, only on the
# tmux server they ran on (a restart reuses pane ids).
reap_left() {
  local f p rc new kind ctx server now_server
  now_server=$(t display-message -p '#{pid}' 2>/dev/null)
  for f in "$JOBS"/*.out; do
    [[ -f $f ]] || continue
    p=%$(basename "$f" .out)
    if [[ -f $JOBS/${p#%}.ctx ]] && IFS=$US read -r server kind ctx <"$JOBS/${p#%}.ctx" && IFS=$'\t' read -r rc new <"$f"; then
      if [[ -n $server && $server == "$now_server" ]]; then
        done_move "$p" "$kind" "${rc:-3}" "$new" "$ctx"
      else
        flog WARN "a move's result from another tmux server is dropped" pane="$p" kind="$kind"
      fi
    fi
    rm -f -- "$f" "$JOBS/${p#%}.ctx"
  done
}
# Wait for every move in flight, then apply them (--once).
reap_all() {
  local p
  for p in "${!job[@]}"; do wait "${job[$p]}" 2>/dev/null; done
  reap
}
launching() { # PANE: launch.sh is starting it (a marker under 15 min old)
  [[ -n $(find "$FLEET_STATE/launching/$1" -maxdepth 0 -mmin -15 2>/dev/null) ]]
}

# Apply the result RC (and NEW pane) of PANE's move of KIND, CTX as spawn got it.
done_move() { # PANE KIND RC NEW CTX
  local p=$1 kind=$2 rc=$3 new=$4 a b c d got
  IFS=$US read -r a b c d <<<"$5"
  case $kind in
    back | pre) # a=from b=to c=orch d=the preferred account's id (back)
      if (( rc == 0 )); then
        if [[ $kind == back ]]; then
          flog INFO "moved back to the preferred account" pane="$p" new_pane="${new:-none}" from="$a" to="$b" orchestrator="$c"
        else
          flog INFO "moved before the limit" pane="$p" new_pane="${new:-none}" from="$a" to="$b"
        fi
        moved "$p" "$new"
      else
        (( rc == 1 )) || moved "$p"
        # A launch AJ undid (4) cost a session: wait as after a second failure.
        (( rc == 4 && move_tries[$p] < 2 )) && move_tries[$p]=2
        if [[ $kind == back ]]; then
          flog WARN "could not move back to the preferred account; trying again later" pane="$p" to="$b" orchestrator="$c" why="$rc" tries="${move_tries[$p]:-0}"
        else
          flog WARN "could not move before the limit; trying again later" pane="$p" to="$b" why="$rc" tries="${move_tries[$p]:-0}"
        fi
        (( rc == 5 )) && back_hold "${d:-${ACCT_ID[$b]:-}}"
      fi
      ;;
    limit) # a=name b=orch c=from d=to
      case $rc in
        0)
          flog INFO "moved to the other account at a limit" pane="$p" name="${a:-orchestrator}" orchestrator="$b" from="$c" to="$d" new_pane="${new:-none}" resets="$(date -d @"$((${due[$p]:-$((NOW + 120))} - 120))" '+%a %F %H:%M')"
          moved "$p" "$new"
          ;;
        1 | 4)
          # A launch that AJ undid (4) cost a session: wait as after a failure.
          if (( rc == 4 )); then
            moved "$p"
            (( move_tries[$p] < 2 )) && move_tries[$p]=2
          fi
          flog INFO "AJ has the pane; leaving it to the next pass" pane="$p" why="$rc"
          ;;
        *)
          moved "$p"
          (( b == 1 && move_tries[$p] < 2 )) && move_tries[$p]=2
          (( rc == 5 )) && back_hold "${ACCT_ID[$d]:-}"
          if (( ${move_tries[$p]} <= 1 )); then
            flog WARN "could not move to the other account; trying again next pass" pane="$p" name="$a" to="$d" why="$rc"
          else
            flog WARN "could not move to the other account; waiting for the reset, and trying again in 15 min" pane="$p" name="$a" to="$d" why="$rc" tries="${move_tries[$p]}"
          fi
          ;;
      esac
      ;;
    idle) # a=name b=idle minutes c=account
      case $rc in
        0)
          flog INFO "fresh session after a long idle" pane="$p" name="$a" new_pane="${new:-none}" idle_min="$b" account="$c"
          [[ -n $new ]] && last[$new]=$NOW
          last[$p]=$NOW
          forget "$p"
          ;;
        1 | 4) flog INFO "AJ has the pane; leaving it to the next pass" pane="$p" why="$rc" ;;
        *)
          # Not started, or no longer its registered session (2): resumed in
          # place, now while it still sits idle at an empty prompt, else at
          # its next pass (never fresh again for this wait).
          fresh_failed[$p]=1
          if fleet_panes | grep -qx -- "$p" && idle_empty "$(screen "$p")"; then
            if type_exactly "$p" "$MSG"; then got=$(submit "$p"); else got="no: AJ typed meanwhile"; fi
            flog INFO "resumed with the continue message" pane="$p" account="$c" switched=0 started="$got"
            last[$p]=$NOW
            unset "fresh_failed[$p]"
            forget "$p"
          fi
          ;;
      esac
      ;;
  esac
}


one() { # PANE
  local p=$1 s ps typed orch=0 armed at limit reset reg name brief idle new got tmp rc
  # Heph is the session on record in the pane on record. A tmux restart reuses
  # pane ids, so another session there is him only when his recorded one has
  # ended on this same server (a /clear or a restart in place), or none is
  # recorded; a registered agent there never is.
  local cur
  if [[ -n $ORCH && $p == "$ORCH" ]] && ! registered "$p"; then
    cur=$(live_session "$p")
    if [[ -z $OSID ]] || { [[ -n $cur && $cur == "$OSID" ]] && session_alive "$OSID"; } || { ! session_alive "$OSID" && on_this_server "$OSID"; }; then
      orch=1
    elif [[ $HEPH_DOUBT != "$p $cur" ]]; then
      HEPH_DOUBT="$p $cur"
      flog WARN "the orchestrator's pane runs another session; it is not looked after as Heph until fleet recover or a new record" pane="$p" session="${cur:-none}" recorded="$OSID"
    fi
  fi
  # The pane's account: its config folder's login, named as the gauge names
  # it; a folder with no known login falls back to the newest reading's.
  local cfg PANE_ID ACTIVE=$ACTIVE
  cfg=$(pane_config "$p")
  (( orch )) && cfg=$(heph_config)
  PANE_ID=${ACCT_ID[$cfg]:-}
  [[ -n $PANE_ID ]] && ACTIVE=$(account_label "$PANE_ID")
  (( NOW - ${last[$p]:-0} < 900 )) && return
  [[ -n ${job[$p]:-} ]] && return
  launching "$p" && return
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
  # Back to the role's preferred account: at a finished turn (no background
  # work) and an empty prompt, so nothing in flight is lost; the 15 min
  # hold-down above and after a failed try keeps a pane from flapping.
  local pref pref_id back_why idle_stamp
  if (( orch )); then pref=${FLEET_HEPH_ACCOUNTS%% *}; else pref=${FLEET_ACCOUNTS%% *}; fi
  pref_id=${ACCT_ID[$pref]:-}
  if [[ -z $limit && -z ${due[$p]:-} && -n $pref_id && $cfg != "$pref" && $pref_id != "${PANE_ID:-}" ]] &&
    { (( orch )) || [[ -n $(reg_field "$p" 2) ]]; } && (( NOW - ${move_failed[$p]:-0} >= 900 )) &&
    ! back_held "$pref_id" && back_room "$pref_id" "$NOW" && idle_empty "$s" && idle_stamp=$(turn_done "$p"); then
    back_why="moved back to its preferred account, $(account_label "$pref_id"), which has room again"
    if (( orch )); then
      spawn "$p" back "$cfg$US$pref$US$orch$US$pref_id" heph_move "$p" "$pref" "$back_why" "" "$idle_stamp"
    else
      spawn "$p" back "$cfg$US$pref$US$orch$US$pref_id" fresh "$p" "$(reg_field "$p" 2)" "$(reg_field "$p" 3)" "was $back_why" "$pref" "" "$idle_stamp"
    fi
    return
  fi
  # Before the wall (#187): a worker on an account that has used
  # FLEET_PREMOVE_PCT of a window moves to one with room at a finished turn and
  # an empty prompt, rather than stopping at the limit mid-turn.
  local five=100 seven=100 ahead
  [[ -n ${PANE_ID:-} ]] && read -r five seven <<<"$(headroom "$PANE_ID" "$NOW")"
  if (( !orch && (five <= 100 - FLEET_PREMOVE_PCT || seven <= 100 - FLEET_PREMOVE_PCT) )) &&
    [[ -z $limit && -z ${due[$p]:-} && -n $(reg_field "$p" 2) ]] && move_hold_ok "$p" &&
    ahead=$(room_elsewhere "$cfg" "$NOW") && ! back_held "${ACCT_ID[$ahead]:-}" && idle_empty "$s" && idle_stamp=$(turn_done "$p"); then
    local left_txt="$five% of its five-hour window left"
    (( seven <= 100 - FLEET_PREMOVE_PCT )) && left_txt="$seven% of its weekly window left"
    spawn "$p" pre "$cfg$US$ahead$US$orch$US" fresh "$p" "$(reg_field "$p" 2)" "$(reg_field "$p" 3)" \
      "was near its usage limit on one account ($left_txt), and you continue on the other, which has room" "$ahead" "" "$idle_stamp" &&
      flog INFO "near the limit at a finished turn; moving before it" pane="$p" account="${ACTIVE:-unknown}" five_hour_left="$five" seven_day_left="$seven" to="$ahead"
    return
  fi

  # A CI red on this agent's branch (#180): its inbox, typed in at an idle,
  # empty prompt (never over AJ's line or into a running turn), oldest first.
  local inbox_name msg
  if (( !orch )) && [[ -z $limit && -z ${due[$p]:-} ]] && inbox_name=$(reg_field "$p" 2) && [[ -n $inbox_name ]] &&
    msg=$(find "$FLEET_STATE/inbox/$inbox_name" -maxdepth 1 -name '*.txt' -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 | cut -d' ' -f2-) &&
    [[ -n $msg ]] && idle_empty "$s"; then
    got=$(inbox_deliver "$p" "$msg")
    case $got in
      not-pasted) flog WARN "CI alert not delivered: the prompt was no longer idle and empty; trying again next pass" pane="$p" name="$inbox_name" alert="${msg##*/}" ;;
      mixed)
        flog WARN "CI alert pasted beside text typed meanwhile; left in the prompt unsent" pane="$p" name="$inbox_name" alert="${msg##*/}"
        rm -f -- "${msg:?}"
        ;;
      held)
        flog WARN "CI alert left in the prompt: Enter did not take" pane="$p" name="$inbox_name" alert="${msg##*/}"
        rm -f -- "${msg:?}"
        ;;
      *)
        flog INFO "CI alert delivered" pane="$p" name="$inbox_name" alert="${msg##*/}" result="$got"
        rm -f -- "${msg:?}"
        ;;
    esac
    return
  fi

  if (( orch )); then
    # Keep Heph's session on record, so `fleet recover` finds his transcript after a power cut.
    # Only a live session no agent's row names: a worker relaunched into Heph's old pane is not him.
    if [[ -n $cur && $cur != "$OSID" ]] && session_alive "$cur" && ! cut -f4 "$REGISTRY" 2>/dev/null | grep -qxF -- "$cur"; then
      printf '%s\n' "$cur" >"$FLEET_STATE/orchestrator.session"
      OSID=$cur
      flog INFO "orchestrator session recorded" pane="$p" session="$cur"
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
  # from it unsent). A failed move is tried again at the next pass, then every 15 min.
  local other carry="" rc
  if (( !fresh_typing && !switched )) && { [[ -n $reg ]] || (( orch )); } && (( due[$p] - NOW >= MOVE_MIN_S )) && move_hold_ok "$p" &&
    other=$(if (( orch )); then FLEET_ACCOUNTS=$FLEET_HEPH_ACCOUNTS room_elsewhere "$cfg" "$NOW"; else room_elsewhere "$cfg" "$NOW"; fi) &&
    ! back_held "${ACCT_ID[$other]:-}"; then
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
        spawn "$p" limit "$name$US$orch$US$cfg$US$other" heph_move "$p" "$other" "stopped at a usage limit on one account, and moves to the other, which has room" "$carry"
      else
        spawn "$p" limit "$name$US$orch$US$cfg$US$other" fresh "$p" "$name" "$brief" "stopped at a usage limit on one account, and you continue on the other, which has room" "$other" "$carry"
      fi
      return
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
    if [[ -n $reg && -z ${fresh_failed[$p]:-} ]] && idle=$((NOW - $(stopped_at "$p" "$ps"))) && (( idle >= FRESH_AFTER_S )); then
      spawn "$p" idle "$name$US$((idle / 60))$US${ACTIVE:-unknown}$US" fresh "$p" "$name" "$brief"
      return
    fi
    unset "fresh_failed[$p]"
    if type_exactly "$p" "$MSG"; then got=$(submit "$p"); else got="no: AJ typed meanwhile"; fi
    flog INFO "resumed with the continue message" pane="$p" account="${ACTIVE:-unknown}" switched="$switched" started="$got"
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
PREV_ACCT="" DOCTOR_DUE=0 HEPH_DOUBT=""

pass() {
  NOW=$(clock) ACTIVE=$(active_account) ORCH=$(orchestrator) OSID=$(cat "$FLEET_STATE/orchestrator.session" 2>/dev/null)
  accounts
  reap
  local p
  for p in $(fleet_panes); do one "$p"; done
  doctor_after_switch
  save_state
  : >>"$FLEET_STATE/resume.beat" && touch -- "$FLEET_STATE/resume.beat"
}

load_state
NOW=$(clock)
accounts
if [[ ${1:-} == --once ]]; then
  reap_left
  pass
  # One pass's moves end with it: their results are applied and saved.
  if (( ${#job[@]} )); then
    reap_all
    save_state
  fi
  exit 0
fi
flog INFO "resume service started" poll_s="$POLL_S" fresh_after_s="$FRESH_AFTER_S" socket="$FLEET_SOCK"
reap_left
while :; do
  pass
  sleep "$POLL_S"
done
