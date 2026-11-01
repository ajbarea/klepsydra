#!/usr/bin/env bash
# report.sh TEXT... (`fleet report`): a worker's report to the orchestrator,
# typed into his pane only while it sits idle at an empty prompt, never over a
# line AJ is typing (#246). It goes now when it can and no older report waits;
# else it waits in inbox/orchestrator/, which the resume service types in at
# the next idle, empty prompt, oldest first. Prints sent or queued.
set -u
FLEET_TARGET=fleet::report
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
(( $# )) || { err "usage: fleet report TEXT..."; exit 2; }
text="$*"
[[ -n ${text//[[:space:]]/} ]] || { err "fleet report: nothing to say"; exit 2; }
from=""
[[ -n ${TMUX_PANE:-} ]] && from=$(reg_field "$TMUX_PANE" 2)
[[ -n $from ]] && text="[from $from] $text"
box=$FLEET_STATE/inbox/orchestrator
mkdir -p -- "$box" || { err "fleet report: cannot write $box"; exit 1; }
tmp=$(mktemp "$FLEET_STATE/inbox/.report.XXXXXX") || exit 1
printf '%s' "$text" >"$tmp"
orch=$(orchestrator)
waiting=$(find "$box" -maxdepth 1 -name '*.txt' -type f | head -1)
got=not-pasted
if [[ -n $orch && -z $waiting ]] && idle_empty "$(screen "$orch")"; then
  got=$(inbox_deliver "$orch" "$tmp")
fi
case $got in
  sent | held | mixed)
    rm -f -- "${tmp:?}"
    flog INFO "report typed into the orchestrator's pane" pane="$orch" from="$from" result="$got"
    echo "$got"
    ;;
  *)
    dest=$box/$(date +%s.%N)-$$.txt
    mv -- "$tmp" "$dest" || { rm -f -- "${tmp:?}"; err "fleet report: could not queue it"; exit 1; }
    flog INFO "report queued for the orchestrator's next idle, empty prompt" pane="${orch:-none}" from="$from" file="${dest##*/}"
    echo queued
    ;;
esac
