#!/usr/bin/env bash
# fleet resume now: one pass of the resume service at once (#271), the same
# code as its timer's, then the decisions it logged. With the service running
# it is asked: a request in resume-now.req, then SIGUSR1, sent again every few
# seconds until a pass that started after the request records it in
# resume-now.done. With no service, one pass runs here (resume-at-reset.sh
# --once, under the same pass lock). Exit 0 once the pass ran, 1 when it did
# not within RESUME_NOW_WAIT_S, 75 when another pass holds the lock.
set -u
FLEET_TARGET=fleet::resume-now
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
WAIT_S=${RESUME_NOW_WAIT_S:-180}
SIGNAL_EVERY_S=${RESUME_NOW_SIGNAL_S:-5}
REQ=$FLEET_STATE/resume-now.req DONE=$FLEET_STATE/resume-now.done
mkdir -p -- "$FLEET_STATE"

since=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) asked_ns=$(date +%s%N)
if pid=$(service_pid); then
  token="$asked_ns-$$"
  printf '%s\n' "$token" >"$REQ.$$" && mv -f -- "$REQ.$$" "$REQ"
  flog INFO "resume pass asked of the service" pid="$pid" request="$token"
  start=$SECONDS next=0 ran=0
  while (( SECONDS - start < WAIT_S )); do
    # Done: a pass that started after this request (a later request may have
    # replaced it; that pass ran for both).
    read -r done_ns _ <"$DONE" 2>/dev/null && [[ $done_ns =~ ^[0-9]+$ ]] && (( done_ns > asked_ns )) && { ran=1; break; }
    if (( SECONDS >= next )); then
      kill -USR1 "$pid" 2>/dev/null || { flog ERROR "resume pass not run: the service stopped while asked" pid="$pid"; err "the resume service stopped; run fleet resume now again"; exit 1; }
      next=$((SECONDS + SIGNAL_EVERY_S))
    fi
    sleep 0.5
  done
  if (( !ran )); then
    flog ERROR "resume pass not run: the service did not answer in time" pid="$pid" wait_s="$WAIT_S"
    err "the resume service did not run a pass within ${WAIT_S}s (fleet doctor, fleet log)"
    exit 1
  fi
  flog INFO "resume pass run by the service" pid="$pid" request="$token" took_s="$((SECONDS - start))"
else
  flog INFO "resume pass run here: no resume service is running"
  bash "$here/resume-at-reset.sh" --once 2>/dev/null
  rc=$?
  (( rc == 0 )) || { err "the resume pass failed (exit $rc); see fleet log"; exit "$rc"; }
fi

# What the pass decided: the resume service's lines since the request.
lines=$(jq -r --arg since "$since" 'select(.target == "fleet::resume" and .ts >= $since)
  | [.ts[11:19], .level, .message] + ([to_entries[] | select(.key | IN("ts","level","target","message","run_id") | not) | "\(.key)=\(.value)"]) | join(" ")' "$FLEET_LOG" 2>/dev/null)
# The last line is the summary the tray shows.
n=0
[[ -n $lines ]] && { printf '%s\n' "$lines"; n=$(grep -c . <<<"$lines"); }
if (( n )); then
  echo "Resume pass done at $(date +%H:%M): $n decision$( (( n == 1 )) || echo s) logged (fleet log)"
else
  echo "Resume pass done at $(date +%H:%M): nothing to do"
fi
