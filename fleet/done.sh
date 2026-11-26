#!/usr/bin/env bash
# done.sh [NAME] REPORT: mark a fleet agent finished and tell the orchestrator. Its row leaves panes.tsv for
# finished.tsv (with the time; the doctor and recover also record there a
# finish they see, while the row stays until `fleet doctor --prune`), so no
# relaunch path takes it again: the resume
# service, fleet recover, fresh-now and the doctor all need a panes.tsv row
# before they act, and an expected exit is never restarted (#269). With no
# NAME, the row of the fleet pane it runs in (TMUX_PANE on the fleet's tmux
# server, whose registered session runs there): an agent's wrap-up runs it
# last. The pane itself stays, so its final report can still be read, until the
# orchestrator has read it and runs `fleet close NAME` (#445).
# REPORT (one line; "-" reads stdin) goes to the pane in orchestrator.pane as
# `fleet send` sends, so a finish no watcher saw still reaches the orchestrator.
# One that cannot be delivered (sent and queued are delivered; not-pasted,
# mixed, held, limited, no orchestrator pane are not) is written to the queue
# file's Running now section, and the doctor flags it. Every report is kept in
# done-reports.tsv until `fleet close` retires the pane; the doctor flags a
# pane left unread for over 30 minutes. A call with no REPORT is refused.
# Exits 1 when no row matches, 2 on bad usage or outside a fleet pane.
set -u
FLEET_TARGET=fleet::done
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
FINISHED=${FLEET_FINISHED:-$FLEET_STATE/finished.tsv}
usage='usage: fleet done [NAME] "REPORT" (a one-line report; - reads stdin), e.g. fleet done "PR #12 open, CI green"'
(( $# >= 1 && $# <= 2 )) || { err "$usage"; exit 2; }
name="" pane="" sid=""
(( $# == 2 )) && name=$1
# The files that name agents; only regular files (FLEET_FINISHED may be a device in a test, which reads forever).
named=("$REGISTRY")
[[ -f $FINISHED ]] && named+=("$FINISHED")
report=${!#}
[[ $report == - ]] && report=$(cat)
report=$(tr '\r\n' '  ' <<<"$report" | sed -E 's/^ +//; s/ +$//')
[[ -n $report ]] || { err "$usage"; exit 2; }
# The old one-argument form named an agent. A lone word that is one is refused, not sent as a report,
# and a worker names only itself (an unquoted two-word report must not finish another agent).
if (( $# == 1 )) && awk -F'\t' -v n="$report" '$2 "" == n "" { f = 1 } END { exit !f }' "${named[@]}" 2>/dev/null; then
  err "$report is an agent's name; fleet done takes the report: $usage"
  exit 2
fi
if [[ -n $name && ${TMUX:-} == *"/$FLEET_SOCK,"* && ${TMUX_PANE:-} =~ ^%[0-9]+$ ]]; then
  me=$(reg_field "$TMUX_PANE" 2)
  if [[ -n $me && $me != "$name" ]] && pane_runs "$TMUX_PANE" "$(reg_field "$TMUX_PANE" 4)"; then
    err "this pane is $me's; a worker marks itself done: fleet done \"REPORT\" (quote the report)"
    exit 2
  fi
fi
if [[ -z $name ]]; then
  pane=${TMUX_PANE:-}
  # Only a pane of the fleet's own server: AJ's terminals reuse pane ids.
  if [[ ! $pane =~ ^%[0-9]+$ || ${TMUX:-} != *"/$FLEET_SOCK,"* ]]; then
    err "not in a fleet pane; run fleet done from the agent's own pane"
    exit 2
  fi
  sid=$(reg_field "$pane" 4)
  # The row's session must be the one running there, not a stale row from an
  # earlier tmux server that reused the pane id.
  if [[ -z $sid ]] || ! pane_runs "$pane" "$sid"; then
    flog WARN "done: this pane does not run a registered agent's session" pane="$pane" session="${sid:-none}"
    err "$pane does not run a registered agent's session (a fleet done retried after a timeout lands here: its report may already be delivered; see done-reports.tsv and the queue file's Running now)"
    exit 1
  fi
fi

label=$name
[[ -n $label ]] || label=$(reg_field "$pane" 2)
rpane=$pane
[[ -n $name ]] && rpane=$(awk -F'\t' -v n="$name" '$2 "" == n "" { p = $1 } END { print p }' "${named[@]}" 2>/dev/null)

# Move the matching rows; prints how many moved. finished.tsv gets them only
# once panes.tsv is replaced, and a row finished.tsv refuses goes back.
finish_now() { # NAME PANE SID
  local tmp fin moved
  [[ -e $REGISTRY ]] || { echo 0; return; }
  # finished.tsv must take the rows before panes.tsv gives them up.
  if ! : >>"$FINISHED"; then
    flog ERROR "done: finished.tsv cannot be written; nothing changed" file="$FINISHED"
    return 1
  fi
  tmp=$(mktemp "$REGISTRY.XXXXXX") || return 1
  fin=$(mktemp "$REGISTRY.XXXXXX") || { rm -f -- "${tmp:?}"; return 1; }
  # Names compare as strings ("1" is not "01").
  moved=$(awk -F'\t' -v n="$1" -v p="$2" -v s="$3" -v out="$tmp" -v fo="$fin" -v at="$(date -Is)" '
    (n != "" && $2 "" == n "") || (n == "" && $1 == p && $4 == s) { print $0 "\t" at > fo; c++; next }
    { print > out }
    END { close(out); close(fo); print c + 0 }' "$REGISTRY") || { rm -f -- "${tmp:?}" "${fin:?}"; return 1; }
  if (( moved > 0 )); then
    mv -f -- "$tmp" "$REGISTRY" || { rm -f -- "${tmp:?}" "${fin:?}"; return 1; }
    if ! cat -- "$fin" >>"$FINISHED"; then
      # finished.tsv refused them: they go back to panes.tsv (the lock is
      # still held), less the time column, and the run fails.
      if sed 's/\t[^\t]*$//' -- "$fin" >>"$REGISTRY"; then
        flog ERROR "done: finished.tsv could not be written; the rows stay in panes.tsv" file="$FINISHED"
      else
        flog ERROR "done: rows left panes.tsv and could not be written anywhere" rows="$(tr '\n' ';' <"$fin")"
        cat -- "$fin" >&2
      fi
      rm -f -- "${fin:?}"
      return 1
    fi
  else
    rm -f -- "${tmp:?}"
  fi
  rm -f -- "${fin:?}"
  echo "$moved"
}
# Sends the report and keeps its record (done-reports.tsv: time, name, pane, result, report).
deliver_report() {
  local orch got msg at
  msg="$label finished: $report"
  orch=$(orchestrator)
  at=$(date +%s)
  # Recorded before the send: a call the tool's timeout kills mid-send still leaves a row the doctor flags.
  with_registry dr_append "$at" "$label" "$rpane" pending "$report" ||
    flog ERROR "done: done-reports.tsv cannot be written" file="$DONE_REPORTS"
  if [[ $orch =~ ^%[0-9]+$ && $orch == "${TMUX_PANE:-}" && ${TMUX:-} == *"/$FLEET_SOCK,"* ]]; then
    # The orchestrator closing an agent itself needs no message to itself.
    got=sent
    echo "report: not sent; you are the orchestrator"
  elif [[ $orch =~ ^%[0-9]+$ && $orch != "$rpane" ]]; then
    got=$(bash "$here/send.sh" "$orch" - <<<"$msg" 2>/dev/null) || true
    got=${got##*$'\n'}
    [[ -n $got ]] || got=not-sent
  else
    got=no-orchestrator-pane
  fi
  with_registry dr_set "$at" "$label" "$got" || flog ERROR "done: the report's result could not be recorded" result="$got"
  if [[ $got == sent || $got == queued ]]; then
    flog INFO "done: report delivered to the orchestrator" name="$label" result="$got"
    [[ $orch == "${TMUX_PANE:-}" ]] || echo "report: $got"
    with_registry dr_mark_delivered "$label" "$report" "$at" ||
      flog ERROR "done: done-reports.tsv cannot be updated" file="$DONE_REPORTS"
    return 0
  fi
  flog WARN "done: report not delivered; written to the queue file" name="$label" result="$got"
  if queue_note "$label" "$got" "$report"; then
    echo "report: $got; written to the queue file's Running now"
  else
    echo "report: $got; the queue file cannot be written, so it is here: $msg" >&2
  fi
  return 0
}
moved=$(with_registry finish_now "$name" "$pane" "$sid") || { err "panes.tsv or finished.tsv could not be written; see fleet log"; exit 1; }
if (( moved == 0 )); then
  if [[ -n $name ]] && awk -F'\t' -v n="$name" '$2 "" == n "" { f = 1 } END { exit !f }' "$FINISHED" 2>/dev/null; then
    echo "already finished: $name"
    deliver_report
    exit 0
  fi
  flog WARN "done: no registered agent matched" name="${name:-}" pane="${pane:-}"
  err "no registered agent ${name:+named $name}${pane:+in $pane}"
  exit 1
fi
flog INFO "agent marked finished: its row left panes.tsv for finished.tsv" name="${name:-}" pane="${pane:-}" session="${sid:-}" rows="$moved"
echo "finished: ${name:-$pane} ($moved row$( (( moved > 1 )) && echo s)); it will not be relaunched"
deliver_report
