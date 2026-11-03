#!/usr/bin/env bash
# done.sh [NAME]: mark a fleet agent finished. Its row leaves panes.tsv for
# finished.tsv (with the time), so no relaunch path takes it again: the resume
# service, fleet recover, fresh-now and the doctor all read panes.tsv only, and
# an expected exit is never restarted (#269). With no NAME, the row of the pane
# it runs in (TMUX_PANE): an agent's wrap-up runs it last. The pane itself
# stays, so its final report can still be read. Exits 1 when no row matches.
set -u
FLEET_TARGET=fleet::done
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
FINISHED=${FLEET_FINISHED:-$FLEET_STATE/finished.tsv}
(( $# <= 1 )) || { err "usage: fleet done [NAME]"; exit 2; }
name=${1:-} pane=""
if [[ -z $name ]]; then
  pane=${TMUX_PANE:-}
  [[ $pane =~ ^%[0-9]+$ ]] || { err "not in a tmux pane: give the agent's NAME"; exit 2; }
fi

# Move the matching rows; prints how many moved.
finish_now() { # NAME PANE
  local tmp moved
  [[ -e $REGISTRY ]] || { echo 0; return; }
  tmp=$(mktemp "$REGISTRY.XXXXXX") || return 1
  moved=$(awk -F'\t' -v n="$1" -v p="$2" -v out="$tmp" -v fin="$FINISHED" -v at="$(date -Is)" '
    (n != "" && $2 == n) || (n == "" && $1 == p) { print $0 "\t" at >> fin; c++; next }
    { print > out }
    END { close(out); print c + 0 }' "$REGISTRY") || { rm -f -- "${tmp:?}"; return 1; }
  if (( moved > 0 )); then mv -f -- "$tmp" "$REGISTRY"; else rm -f -- "${tmp:?}"; fi
  echo "$moved"
}
moved=$(with_registry finish_now "$name" "$pane") || { err "panes.tsv is locked or unwritable"; exit 1; }
if (( moved == 0 )); then
  flog WARN "done: no registered agent matched" name="${name:-}" pane="${pane:-}"
  err "no registered agent ${name:+named $name}${pane:+in $pane}"
  exit 1
fi
flog INFO "agent marked finished: its row left panes.tsv for finished.tsv" name="${name:-}" pane="${pane:-}" rows="$moved"
echo "finished: ${name:-$pane} ($moved row$( (( moved > 1 )) && echo s)); it will not be relaunched"
