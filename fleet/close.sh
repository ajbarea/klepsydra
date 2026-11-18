#!/usr/bin/env bash
# close.sh NAME: close the pane of a finished agent once its report is read
# (#445). `fleet done` leaves the pane open so the report can be read; the
# orchestrator runs this after reading it. NAME must be in finished.tsv (a
# running agent is never closed), and its pane must still run the session that
# finished there: panes ids are reused by a restarted tmux server. The pane gets
# /exit and is killed when it does not go (retire, lib.sh). The agent's record in
# done-reports.tsv is dropped, which also clears the doctor's flag. Exits 1 when
# NAME has not finished, 2 on bad usage.
set -u
FLEET_TARGET=fleet::close
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
FINISHED=${FLEET_FINISHED:-$FLEET_STATE/finished.tsv}
(( $# == 1 )) && [[ -n $1 ]] || { err "usage: fleet close NAME"; exit 2; }
name=$1
# The newest finished row of that name (names compare as text).
mapfile -t row < <(awk -F'\t' -v n="$name" '$2 "" == n "" { p = $1; s = $4 } END { if (p != "") { print p; print s } }' "$FINISHED" 2>/dev/null)
pane=${row[0]:-} sid=${row[1]:-}
if [[ -z ${pane:-} ]]; then
  flog WARN "close: no finished agent of that name" name="$name"
  err "no finished agent named $name (fleet done marks one finished first)"
  exit 1
fi
drop_report() { # NAME: forget its reports, under the registry lock
  local tmp
  [[ -e $DONE_REPORTS ]] || return 0
  tmp=$(mktemp "$DONE_REPORTS.XXXXXX") || return 1
  if awk -F'\t' -v n="$1" '$2 "" != n ""' "$DONE_REPORTS" >"$tmp"; then
    mv -f -- "$tmp" "$DONE_REPORTS"
  else
    rm -f -- "${tmp:?}"
    return 1
  fi
}
if fleet_panes | grep -qx -- "$pane" && pane_runs "$pane" "$sid"; then
  if retire "$pane"; then
    flog INFO "close: finished agent's pane closed" name="$name" pane="$pane"
    echo "closed: $name ($pane)"
  else
    err "could not close $pane (/exit would not go in); it is left open"
    exit 1
  fi
else
  flog INFO "close: the pane no longer runs that session; nothing to close" name="$name" pane="$pane"
  echo "already closed: $name"
fi
with_registry drop_report "$name" || { err "done-reports.tsv could not be updated"; exit 1; }
