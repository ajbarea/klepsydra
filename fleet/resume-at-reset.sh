#!/usr/bin/env bash
# resume-at-reset.sh : every 60s, find fleet panes stopped on a usage limit with no auto-continue
# armed, and type a continue message into each, on whichever account is active: after the
# reset time the pane itself showed (+2 min), or at once when AJ has switched since the limit
# hit to an account whose newest snapshot has room. Claude Code's limit menu gets option 1.
# The active account is the label of klepsydra's newest account snapshot (a /login moves
# every running session). A pane listed in panes.tsv (pane, name, brief) that has waited past
# FRESH_AFTER_S is replaced instead: /exit, then launch.sh starts a fresh session from its
# brief, since its prompt cache has expired and resuming would re-cache the whole transcript.
# Exits when the fleet tmux session goes away. Log: resume.log.
F=${KLEPSYDRA_DIR:-/mnt/c/Users/ajbar/AppData/Local/dev.ajsoftworks.klepsydra}
D=${RESUME_LOG_DIR:-$(dirname "$0")}
SOCK=${FLEET_SOCK:-klepsydra}
LAUNCH=${LAUNCH:-$(dirname "$0")/launch.sh}
FRESH_AFTER_S=${FRESH_AFTER_S:-3300}   # Claude Code's prompt cache lives an hour
FRESH='Fresh start: a previous agent with the brief below stopped at a usage limit over an hour ago, so its cached conversation expired and resuming it would re-cache everything; you replace it. Before acting, rebuild state from disk and GitHub: IMPL.md in the repo and in each worktree, git log and git status per worktree, open PRs with their comments and reviews, and your repo'"'"'s lines under "Running now" in /mnt/c/Users/ajbar/fleet-briefing/claude-queue.md. Where those are newer than the brief, they win; never redo merged work. No /code-review high (nor xhigh or max); low or medium is fine.'
MSG='The usage limit has reset. Continue from where you stopped: re-run a subagent that failed on the limit only if you still need its result (each re-run starts cold and costs a full context), then carry on with your queue. Re-read PR comments before any merge.'
log() { echo "$(date '+%F %T') $*" >> "$D/resume.log"; }
# Text typed at pane $1's prompt: AJ's unsent message. The prompt line is "❯" plus a no-break
# space; dim text there is Claude Code's suggestion, not typed, so drop it. The capture goes
# through $( ) first, which trims the pane's empty bottom rows before tail picks the last lines.
typed_at_prompt() {
  local cap; cap=$(tmux -L "$SOCK" capture-pane -e -t "$1" -p)
  tail -8 <<<"$cap" | grep $'^\e\[[0-9;]*m❯\|^❯' | tail -1 |
    sed -E $'s/\e\\[2m[^\e]*//g; s/\e\\[[0-9;]*m//g' | sed 's/^❯//; s/\xc2\xa0/ /g; s/^ *//; s/ *$//'
}
# The active account's newest snapshot shows a 5-hour or weekly window at 100% that has
# not reset yet: switching to it brings no usage back.
exhausted() {
  local f; f=$(ls -t "$F"/accounts/*/*.json 2>/dev/null | head -1); [[ -n $f ]] || return 1
  jq -e --argjson now "$(date +%s)" '[.windows.five_hour, .windows.seven_day][]
    | select(. != null and (.used_percentage // 0) >= 100 and (.resets_at // 0) > $now)' "$f" >/dev/null 2>&1
}
# Replace pane $1 (registry name $2, brief $3) with a fresh session; prints the new pane id.
fresh() {
  local p=$1 name=$2 brief=$3 txt i new
  txt="$D/fresh-$name-$(date +%Y%m%d-%H%M).src"
  { printf '%s\n\n' "$FRESH"; cat "$brief"; } > "$txt"
  tmux -L "$SOCK" send-keys -t "$p" -l "/exit"; sleep 1; tmux -L "$SOCK" send-keys -t "$p" Enter
  for i in $(seq 30); do tmux -L "$SOCK" list-panes -s -t fleet -F '#{pane_id}' | grep -qx "$p" || break; sleep 1; done
  tmux -L "$SOCK" kill-pane -t "$p" 2>/dev/null
  new=$(bash "$LAUNCH" "$name" "$txt" 2>&1 | grep -o 'pane=%[0-9]*' | head -1 | cut -d= -f2)
  [[ -n $new ]] && sed -i "s|^$p\t|$new\t|" "$D/panes.tsv"
  echo "$new"
}
# Limit screens: the old "hit your session limit" line and, from 10-27, the banner
# "Usage limit reached · limit resets 11:10pm". The orchestrator's own pane (orchestrator.pane) is never touched.
LIMIT_RE='hit your (session|weekly) limit|Usage limit reached'
ORCH=$(cat "$D/orchestrator.pane" 2>/dev/null)
declare -A last due seen_on rc_on
while tmux -L "$SOCK" has-session -t fleet 2>/dev/null; do
  active=$(ls -t "$F"/accounts/*/*.json 2>/dev/null | head -1 | xargs -r jq -r '.label // empty' 2>/dev/null)
  now=$(date +%s)
  for p in $(tmux -L "$SOCK" list-panes -s -t fleet -F '#{pane_id}'); do
    [[ -n $ORCH && $p == "$ORCH" ]] && continue
    (( now - ${last[$p]:-0} < 900 )) && continue
    txt=$(tmux -L "$SOCK" capture-pane -t "$p" -p | tail -25)
    # Claude Code's limit menu: option 1 ("Stop and wait for limit to reset") is selected; take
    # it, then the pane reads as an ordinary limited one on the next pass.
    if grep -q "Stop and wait for limit to reset" <<<"$txt" && grep -q "Enter to confirm" <<<"$txt"; then
      tmux -L "$SOCK" send-keys -t "$p" Enter; log "limit menu on $p: chose stop and wait"; continue
    fi
    # Claude Code's own auto-continue resumes the whole transcript; on a registered pane with
    # over FRESH_AFTER_S to wait, cancel it (its banner says "esc to cancel") so the pane
    # gets a fresh session at the reset instead.
    armed=$(tail -8 <<<"$txt" | grep -o 'Continuing automatically at [^·]*' | tail -1 | sed 's/^Continuing automatically at //; s/ *$//')
    if [[ -n $armed ]] && awk -F'\t' -v p="$p" '$1 == p { f = 1 } END { exit !f }' "$D/panes.tsv" 2>/dev/null; then
      at=$(date -d "${armed//,/}" +%s 2>/dev/null) || at=0
      (( at > 0 && now - at > 21600 )) && at=$(( at + 86400 ))
      if (( at - now >= FRESH_AFTER_S )); then
        tmux -L "$SOCK" send-keys -t "$p" Escape; log "cancelled built-in auto-continue on $p (resets $armed): fresh session at the reset"; continue
      fi
    fi
    # Remote Control: a /login disconnects it in every session, and the RIT account never starts
    # it on its own, so once per account give each registered pane /remote-control while it sits
    # idle at an empty prompt. A second Enter connects, or picks the preselected Continue when it
    # is already on; on an empty prompt it does nothing.
    # A limited pane is left to the resume logic below: typing here would scroll its limit
    # message away and strand it (10-26).
    if [[ -n $active && ${rc_on[$p]:-} != "$active" && -z ${due[$p]:-} ]] && ! grep -q '… (' <<<"$txt" &&
       tail -8 <<<"$txt" | grep -q '^❯' && ! grep -Eq "$LIMIT_RE" <<<"$txt" &&
       awk -F'\t' -v p="$p" '$1 == p { f = 1 } END { exit !f }' "$D/panes.tsv" 2>/dev/null; then
      if [[ -z $(typed_at_prompt "$p") ]]; then
        tmux -L "$SOCK" send-keys -t "$p" -l "/remote-control"; sleep 1; tmux -L "$SOCK" send-keys -t "$p" Enter
        sleep 4; tmux -L "$SOCK" send-keys -t "$p" Enter
        rc_on[$p]=$active; log "remote control on $p for $active"
        continue
      fi
    fi
    limited=1
    # The newer banner sits in the status line and clears itself at the reset, before due; a pane
    # already logged as limited stays limited until resumed, while it is still idle at the prompt.
    grep -Eq "$LIMIT_RE" <<<"$txt" || [[ -n ${due[$p]:-} ]] || limited=0
    tail -8 <<<"$txt" | grep -qi "continuing automatically" && limited=0   # a live auto-continue shows in the bottom banner; an old one in scrollback does not count
    grep -q '… (' <<<"$txt" && limited=0   # spinner line: mid-turn
    tail -8 <<<"$txt" | grep -q '^❯' || limited=0
    if (( ! limited )); then unset "due[$p]" "seen_on[$p]"; continue; fi
    if [[ -z ${due[$p]:-} ]]; then
      # Reset time from the pane's own message ("resets 1:10pm (America/New_York)"); a time
      # more than 6h in the past means tomorrow. Unparsed: try again in 30 min.
      when=$(grep -oE 'resets [0-9]{1,2}(:[0-9]{2})? ?[ap]m' <<<"$txt" | tail -1 | sed 's/^resets //')
      reset=$(date -d "$when" +%s 2>/dev/null) || reset=$(( now + 1800 ))
      (( now - reset > 21600 )) && reset=$(( reset + 86400 ))
      due[$p]=$(( reset + 120 )) seen_on[$p]=${active:-unknown}
      log "limit on $p (account ${seen_on[$p]}, resets $(date -d @"$reset" '+%a %H:%M'))"
    fi
    switched=0
    [[ ${seen_on[$p]} != "${active:-unknown}" ]] && ! exhausted && switched=1
    (( now >= ${due[$p]} || switched )) || continue
    typed=$(typed_at_prompt "$p")
    reg=$(awk -F'\t' -v p="$p" '$1 == p { print $2 "\t" $3 }' "$D/panes.tsv" 2>/dev/null)
    # The agent stopped at the "done 4:21 PM" its last turn printed; a time more than 12h ahead
    # means yesterday. Without one, fall back to the window's last activity, which status line
    # redraws keep fresh, so it under-counts.
    stop_at=$(grep -o 'done [0-9]\{1,2\}:[0-9][0-9] [AP]M' <<<"$txt" | tail -1 | cut -c6-)
    if stopped=$(date -d "$stop_at" +%s 2>/dev/null) && [[ -n $stop_at ]]; then
      (( stopped - now > 43200 )) && stopped=$(( stopped - 86400 ))
    else
      stopped=$(tmux -L "$SOCK" display-message -p -t "$p" '#{window_activity}')
    fi
    idle=$(( now - stopped ))
    if [[ -z $typed && -n $reg ]] && (( idle >= FRESH_AFTER_S )); then
      new=$(fresh "$p" "${reg%%$'\t'*}" "${reg#*$'\t'}")
      unset "due[$p]" "seen_on[$p]"
      log "fresh session for ${reg%%$'\t'*} after $(( idle / 60 )) min idle: $p -> ${new:-launch failed} on $active"
      [[ -n $new ]] && last[$new]=$(date +%s)
      continue
    fi
    [[ -z $typed ]] && { tmux -L "$SOCK" send-keys -t "$p" -l "$MSG"; sleep 1; }
    tmux -L "$SOCK" send-keys -t "$p" Enter
    last[$p]=$(date +%s); unset "due[$p]" "seen_on[$p]"
    log "resumed $p on $active${typed:+ (sent typed: $typed)}"
  done
  sleep "${POLL_S:-60}"
done
