#!/usr/bin/env bash
# relaunch-fresh.sh PANE NAME BRIEF HINT: replace the agent in PANE with a
# fresh session from its brief, the fresh preamble and a resume hint, on
# FLEET_ACCOUNT when set (else launch.sh's pick); FLEET_WHY says why. It goes
# through the resume service's fresh(), so two agents never run on one row: a
# pane in a turn is waited on for RELAUNCH_WAIT_S (default 120) and refused if
# it is still busy, launching nothing; if the old pane takes a prompt or a turn
# while the new one starts, the new one goes and the old one stays (#274).
# Prints pane=NEW on success. Exits 1 when refused or failed, 2 on bad usage.
set -u
FLEET_TARGET=fleet::relaunch
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
(( $# == 4 )) || { err "usage: relaunch-fresh.sh PANE NAME BRIEF HINT"; exit 2; }
p=$1 name=$2 brief=$3 hint=$4
wait_s=${RELAUNCH_WAIT_S:-120}
sid=$(reg_field "$p" 4)
if ! pane_runs "$p" "$sid"; then
  flog WARN "relaunch refused: the pane no longer runs its registered session" pane="$p" name="$name"
  err "$p does not run $name's registered session (a stale panes.tsv row?)"
  exit 1
fi
s=$(screen "$p")
if [[ -n $(input_text "$s") ]]; then
  flog WARN "relaunch refused: AJ's typed text is in the prompt" pane="$p" name="$name"
  err "$p holds typed text; send or clear it first"
  exit 1
fi
if ! idle_empty "$s"; then
  flog INFO "relaunch waits for the old pane's turn to end" pane="$p" name="$name" wait_s="$wait_s"
  if ! wait_for "$p" "$wait_s" idle_empty; then
    flog WARN "relaunch refused: the old pane was still busy; nothing launched" pane="$p" name="$name" waited_s="$wait_s"
    err "$p is still in a turn after ${wait_s}s; nothing launched"
    exit 1
  fi
fi
why=${FLEET_WHY:-saved its state and stopped so another brief could use its slot}
new=$(FRESH_HINT=$hint fresh "$p" "$name" "$brief" "$why" "${FLEET_ACCOUNT:-}")
rc=$?
if (( rc != 0 )) || [[ -z $new ]]; then
  flog ERROR "relaunch failed; the old pane is kept and no second one runs" pane="$p" name="$name" rc="$rc"
  err "relaunch of $name in $p failed (fresh: $rc); the old pane is kept"
  exit 1
fi
flog INFO "relaunched" old_pane="$p" new_pane="$new" name="$name" account="${FLEET_ACCOUNT:-launch pick}"
echo "pane=$new name=$name"
