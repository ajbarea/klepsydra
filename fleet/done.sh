#!/usr/bin/env bash
# done.sh [NAME]: mark a fleet agent finished. Its row leaves panes.tsv for
# finished.tsv (with the time; the doctor and recover also record there a
# finish they see, while the row stays until `fleet doctor --prune`), so no
# relaunch path takes it again: the resume
# service, fleet recover, fresh-now and the doctor all need a panes.tsv row
# before they act, and an expected exit is never restarted (#269). With no
# NAME, the row of the fleet pane it runs in (TMUX_PANE on the fleet's tmux
# server, whose registered session runs there): an agent's wrap-up runs it
# last. The pane itself stays, so its final report can still be read. Exits 1
# when no row matches, 2 on bad usage or outside a fleet pane.
set -u
FLEET_TARGET=fleet::done
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
FINISHED=${FLEET_FINISHED:-$FLEET_STATE/finished.tsv}
(( $# <= 1 )) || { err "usage: fleet done [NAME]"; exit 2; }
name=${1:-} pane="" sid=""
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
    err "$pane does not run a registered agent's session"
    exit 1
  fi
fi

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
moved=$(with_registry finish_now "$name" "$pane" "$sid") || { err "panes.tsv or finished.tsv could not be written; see fleet log"; exit 1; }
if (( moved == 0 )); then
  if [[ -n $name ]] && awk -F'\t' -v n="$name" '$2 "" == n "" { f = 1 } END { exit !f }' "$FINISHED" 2>/dev/null; then
    echo "already finished: $name"
    exit 0
  fi
  flog WARN "done: no registered agent matched" name="${name:-}" pane="${pane:-}"
  err "no registered agent ${name:+named $name}${pane:+in $pane}"
  exit 1
fi
flog INFO "agent marked finished: its row left panes.tsv for finished.tsv" name="${name:-}" pane="${pane:-}" session="${sid:-}" rows="$moved"
echo "finished: ${name:-$pane} ($moved row$( (( moved > 1 )) && echo s)); it will not be relaunched"
