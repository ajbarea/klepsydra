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
sid=$(reg_field "$p" 4)
if ! pane_runs "$p" "$sid"; then
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
{ fresh_preamble "${FLEET_WHY:-saved its state and stopped so another brief could use its slot}"; printf '\n\nResume hint: %s\n\n' "$hint"; cat "$brief"; } >"$txt"
out=$(bash "$here/launch.sh" "$name" "$txt")
echo "$out"
new=$(sed -n 's/^pane=\(%[0-9]*\).*/\1/p' <<<"$out" | head -1)
if [[ -z $new ]]; then
  flog ERROR "relaunch: the new session did not start; the old pane is kept" old_pane="$p" name="$name"
  exit 1
fi
got=$(sed -n 's/.*brief=\([A-Za-z-]*\).*/\1/p' <<<"$out" | head -1)
if [[ $got != started ]]; then
  flog ERROR "relaunch: the new session's brief did not start; both are left running" old_pane="$p" new_pane="$new" name="$name" brief="$got"
  exit 1
fi
if pane_runs "$p" "$sid" && idle_empty "$(screen "$p")" && type_exactly "$p" "/exit"; then
  t send-keys -t "$p" Enter
  for _ in $(seq 30); do fleet_panes | grep -qx "$p" || break; sleep 1; done
  fleet_panes | grep -qx "$p" && t kill-pane -t "$p" 2>/dev/null
else
  flog ERROR "relaunch: the old pane changed while the new one started; both are left running" old_pane="$p" new_pane="$new" name="$name"
fi
flog INFO "relaunched" old_pane="$p" new_pane="$new" name="$name"
