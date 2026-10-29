#!/usr/bin/env bash
# relaunch-fresh.sh PANE NAME BRIEF HINT: /exit the pane's claude, then launch
# a new window with the fresh preamble, a resume hint and the brief; launch.sh
# repoints panes.tsv at the new pane.
set -u
FLEET_TARGET=fleet::relaunch
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
(( $# == 4 )) || { err "usage: relaunch-fresh.sh PANE NAME BRIEF HINT"; exit 2; }
p=$1 name=$2 brief=$3 hint=$4
if ! pane_runs "$p" "$(reg_field "$p" 4)"; then
  flog WARN "relaunch refused: the pane no longer runs its registered session" pane="$p" name="$name"
  err "$p does not run $name's registered session (a stale panes.tsv row?)"
  exit 1
fi
if [[ -n $(input_text "$(screen "$p")") ]]; then
  flog WARN "relaunch refused: AJ's typed text is in the prompt" pane="$p" name="$name"
  err "$p holds typed text; send or clear it first"
  exit 1
fi
txt="$FLEET_STATE/fresh-$name-$(date +%Y%m%d-%H%M).src"
{ fresh_preamble "saved its state and stopped so another brief could use its slot"; printf '\n\nResume hint: %s\n\n' "$hint"; cat "$brief"; } >"$txt"
t send-keys -t "$p" -l "/exit"
wait_for "$p" 5 holds_input && t send-keys -t "$p" Enter
for _ in $(seq 30); do fleet_panes | grep -qx "$p" || break; sleep 1; done
out=$(bash "$here/launch.sh" "$name" "$txt")
echo "$out"
flog INFO "relaunched" old_pane="$p" name="$name" result="$(head -1 <<<"$out")"
