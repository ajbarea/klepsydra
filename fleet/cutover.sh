#!/usr/bin/env bash
# cutover.sh (`fleet cutover`): move the fleet's services onto the unit files
# install.sh wrote. A unit started with systemd-run is transient, and systemd
# refuses to enable a file of the same name while it exists, so each transient
# one is stopped first (which removes it), then the installed unit is enabled
# and started. Checks each is enabled and active, and that the resume service
# logged its start after the cut-over began. Exits non-zero on any failure.
set -u
FLEET_TARGET=fleet::cutover
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
SYSTEMCTL=${FLEET_SYSTEMCTL:-systemctl}
UNITS=(fleet-resume-at-reset.service fleet-memfrag-log.timer)
[[ -e ${FLEET_UNITS:-$HOME/.config/systemd/user}/wsl-mem-watch.service ]] && UNITS+=(wsl-mem-watch.service)
# The log's length now: the resume service's start must come after it.
began=$(wc -l <"$FLEET_LOG" 2>/dev/null || echo 0)
failed=0

sc() { $SYSTEMCTL --user "$@"; }

# Not in the middle of a fresh session: the resume service holds this lock then.
exec 7>>"$FLEET_STATE/.fresh.lock"
flock -w 900 7 || flog WARN "a fresh session held its lock for 15 min; cutting over anyway"
# Rows written before launch.sh recorded session ids get the live one now.
# shellcheck disable=SC2317,SC2329 # run through with_registry
fill_ids() {
  local p name sid
  while IFS=$'\t' read -r p name _ sid _; do
    [[ -n $p && -z $sid ]] || continue
    if sid=$(live_session "$p"); then
      set_session_now "$p" "$sid" && flog INFO "registry row given its live session id" pane="$p" name="$name" session_id="$sid"
    else
      flog WARN "registry row has no live session to record" pane="$p" name="$name"
    fi
  done < <(cat "$REGISTRY")
}
[[ -e $REGISTRY ]] && with_registry fill_ids

sc daemon-reload
# One unit at a time, so a guard (wsl-mem-watch) is down only for its own swap.
for u in "${UNITS[@]}"; do
  # A timer's service may be transient too; a failed transient one needs reset-failed.
  for part in "$u" "${u%.timer}.service"; do
    [[ $(sc show -p Transient --value "$part" 2>/dev/null) == yes ]] || continue
    sc reset-failed "$part" 2>/dev/null
    sc stop "$part" 2>/dev/null
    if [[ $(sc show -p Transient --value "$part" 2>/dev/null) != yes ]]; then
      flog INFO "transient unit stopped for its installed file" unit="$part"
    else
      flog ERROR "transient unit would not stop" unit="$part"
      failed=1
    fi
  done
  if ! out=$(sc enable --now "$u" 2>&1); then
    flog ERROR "unit not enabled" unit="$u" said="$out"
    echo "FAIL $u: $out"
    failed=1
    continue
  fi
  enabled=$(sc is-enabled "$u" 2>/dev/null) active=$(sc is-active "$u" 2>/dev/null)
  if [[ $enabled == enabled && $active == active ]]; then
    flog INFO "unit enabled and active" unit="$u"
    echo "ok   $u: enabled and active"
  else
    flog ERROR "unit not enabled and active" unit="$u" enabled="$enabled" active="$active"
    echo "FAIL $u: $enabled, $active"
    failed=1
  fi
done
# The resume service's own start line, written after this cut-over began.
for _ in $(seq "${FLEET_CUTOVER_WAIT:-15}"); do
  if tail -n +"$((began + 1))" "$FLEET_LOG" 2>/dev/null | jq -e 'select(.message == "resume service started")' >/dev/null 2>&1; then
    echo "ok   the resume service logged its start"
    exit "$failed"
  fi
  sleep 1
done
flog ERROR "the resume service did not log its start after the cut-over"
echo "FAIL the resume service did not log its start"
exit 1
