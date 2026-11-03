#!/usr/bin/env bash
# registry-event.sh EVENT SID WHY [PANE] [CLEARED_SID] [SOCKET]: the fleet hook's call
# at a session's start or end (#261), so panes.tsv, finished.tsv and
# unpaused.tsv follow a session when it happens, not when a later poll reads a
# file that the wall's Clear or the day's prune may already have removed.
#   SessionEnd SID prompt_input_exit|logout  the row naming SID records its finish
#   SessionStart SID SOURCE (not compact)    SID runs again: its recorded finish
#       and unpause go; with SOURCE clear, the row naming CLEARED_SID in PANE
#       names SID from now on (what recover's repair does, at once)
# Under the registry lock; each change is one line in the fleet log. The doctor
# and recover still reconcile on every read, for an event this missed.
set -u
FLEET_TARGET=fleet::registry-event
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
event=${1:-} sid=${2:-} why=${3:-} pane=${4:-} cleared=${5:-} socket=${6:-}
# A pane id means something here only on the fleet's own server (#261 review 9).
fleet_socket "$socket" || pane=""
[[ $sid =~ ^[0-9a-f-]{36}$ && -s $REGISTRY ]] || exit 0

# shellcheck disable=SC2329 # run through with_registry
on_event() {
  local row name n
  case $event in
    SessionEnd)
      [[ $why == prompt_input_exit || $why == logout ]] || return 0
      row=$(awk -F'\t' -v s="$sid" '$4 == s { print; exit }' "$REGISTRY")
      [[ -n $row ]] || return 0
      name=$(cut -f2 <<<"$row")
      record_finished "$row" && flog INFO "finish recorded at the session's end" name="$name" session="$sid" reason="$why"
      ;;
    SessionStart)
      [[ $why != compact ]] || return 0
      if [[ $why == clear && $cleared =~ ^[0-9a-f-]{36}$ && $pane =~ ^%[0-9]+$ ]]; then
        name=$(awk -F'\t' -v p="$pane" -v s="$cleared" '$1 == p && $4 == s { print $2; exit }' "$REGISTRY")
        if [[ -n $name ]] && set_session_now "$pane" "$cleared" "$sid"; then
          flog INFO "registry follows a /clear" name="$name" pane="$pane" from="$cleared" session="$sid"
        fi
      fi
      # Only an agent's row: a `fleet done` record (its row gone) stays, so a
      # done agent resumed by hand is still never typed into or relaunched.
      awk -F'\t' -v s="$sid" '$4 == s { f = 1 } END { exit !f }' "$REGISTRY" || return 0
      # A finished row runs again: it takes its pane back.
      if [[ $pane =~ ^%[0-9]+$ ]] && restore_pane "$sid" "$pane"; then
        flog INFO "a finished agent's session started again; its row takes its pane back" session="$sid" pane="$pane"
      fi
      n=$(forget_finished "$sid") && (( n > 0 )) && flog INFO "recorded finish dropped: the session started again" session="$sid" source="$why" lines="$n"
      if unpaused "$sid" && drop_unpaused "$sid"; then
        flog INFO "unpause dropped: the session started again" session="$sid" source="$why"
      fi
      ;;
  esac
  return 0
}
with_registry on_event || flog WARN "registry event not applied: the registry lock was held" event="$event" session="$sid"
exit 0
