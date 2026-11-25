#!/usr/bin/env bash
# inbox.sh: list, acknowledge, or deliver undelivered reports in done-reports.tsv (#367).
#   fleet inbox [--json] [--all]
#   fleet inbox list [--json] [--all]
#   fleet inbox ack NAME... | --all
#   fleet inbox deliver [NAME...] | --all
set -u
FLEET_TARGET=fleet::inbox
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"

usage="usage: fleet inbox [--json] [--all] | fleet inbox ack NAME... | --all | fleet inbox deliver [NAME...] | --all"
cmd="list"
json=0
all=0

if (( $# > 0 )); then
  case $1 in
    list) cmd="list"; shift ;;
    ack) cmd="ack"; shift ;;
    deliver) cmd="deliver"; shift ;;
    --json) json=1; shift ;;
    --all) all=1; shift ;;
    -h | --help)
      echo "usage: fleet inbox [--json] [--all]"
      echo "       fleet inbox ack NAME... | --all"
      echo "       fleet inbox deliver [NAME...] | --all"
      exit 0
      ;;
    *)
      err "$usage"
      exit 2
      ;;
  esac
fi

if [[ $cmd == list ]]; then
  while (( $# > 0 )); do
    case $1 in
      --json) json=1; shift ;;
      --all) all=1; shift ;;
      *) err "$usage"; exit 2 ;;
    esac
  done
fi

read_reports_json() { # SHOW_ALL (0|1)
  local show_all=${1:-0} now
  [[ -s $DONE_REPORTS ]] || { echo "[]"; return 0; }
  now=$(date +%s)
  jq -Rsc --argjson now "$now" --argjson all "$show_all" '
    split("\n")
    | map(select(length > 0) | split("\t"))
    | map(select((.[0] // "") | test("^[0-9]+$")))
    | map(
        (.[0] | tonumber) as $at
        | (.[3] // "") as $res
        | (if $res == "acked" then "acked"
           elif ($res == "sent" or $res == "queued" or $res == "delivered") then "delivered"
           elif ($res == "pending" and ($now - $at) <= 300) then "inflight"
           else "pending" end) as $status
        | {
            at: $at,
            iso: ($at | strflocaltime("%Y-%m-%dT%H:%M:%S%z")),
            name: (.[1] // ""),
            pane: (.[2] // ""),
            result: $res,
            report: ((.[4] // "") | gsub("\\\\(?<c>[nt\\\\])"; if .c == "n" then "\n" elif .c == "t" then "\t" else "\\" end)),
            status: $status
          }
      )
    | if $all == 1 then . else map(select(.status == "pending")) end
  ' "$DONE_REPORTS" 2>/dev/null
}

case $cmd in
  list)
    items=$(read_reports_json "$all")
    count=$(jq 'length' <<<"$items" 2>/dev/null || echo 0)
    if (( count == 0 )); then
      if (( json )); then
        echo "[]"
      else
        echo "no unread reports"
      fi
      exit 0
    fi
    if (( json )); then
      jq -c '.[]' <<<"$items"
    elif (( all )); then
      jq -r '.[] | "[\(.status)] \(if .name != "" then .name else .pane end) (\(.pane), \(.iso), \(.result)): \(.report)"' <<<"$items"
    else
      jq -r '.[] | "\(if .name != "" then .name else .pane end) (\(.pane), \(.iso), \(.result)): \(.report)"' <<<"$items"
    fi
    ;;
  ack)
    (( $# > 0 )) || { err "usage: fleet inbox ack NAME... | --all"; exit 2; }
    if [[ $1 == --all ]]; then
      count=$(with_registry dr_ack --all) || { err "no unread reports to acknowledge"; exit 1; }
      flog INFO "inbox: acknowledged all unread reports" count="$count"
      echo "acknowledged: all ($count report$( (( count > 1 )) && echo s ))"
      exit 0
    fi
    for name in "$@"; do
      count=$(with_registry dr_ack "$name") || { err "no unread report for $name"; exit 1; }
      flog INFO "inbox: acknowledged report" name="$name" count="$count"
      echo "acknowledged: $name"
    done
    ;;
  deliver)
    orch=$(orchestrator)
    if [[ ! $orch =~ ^%[0-9]+$ ]]; then
      err "no orchestrator pane"
      exit 1
    fi
    items=$(read_reports_json 0)
    targets=("$@")
    if (( ${#targets[@]} == 0 )) || [[ ${targets[0]} == --all ]]; then
      mapfile -t targets < <(jq -r '.[].name' <<<"$items" 2>/dev/null | sort -u)
    fi
    if (( ${#targets[@]} == 0 )); then
      echo "no unread reports"
      exit 0
    fi
    failed=0
    for name in "${targets[@]}"; do
      mapfile -t rows < <(jq -c --arg name "$name" '.[] | select(.name == $name)' <<<"$items" 2>/dev/null)
      if (( ${#rows[@]} == 0 )); then
        err "no unread report for $name"
        failed=1
        continue
      fi
      for item in "${rows[@]}"; do
        at=$(jq -r '.at // 0' <<<"$item")
        res=$(jq -r '.result // ""' <<<"$item")
        rep=$(jq -r '.report // ""' <<<"$item")
        if [[ -n $rep ]]; then
          msg="$name finished: $rep"
        else
          qfile=${FLEET_QUEUE_MD:-$FLEET_BRIEFING/queue.md}
          msg="$name finished (see $qfile)"
        fi
        got=$(bash "$here/send.sh" "$orch" - <<<"$msg" 2>/dev/null) || true
        got=${got##*$'\n'}
        if [[ $got == sent || $got == queued ]]; then
          if with_registry dr_deliver_row "$at" "$name" "$res" "$rep" "$got"; then
            flog INFO "inbox: delivered report" name="$name" result="$got"
            echo "delivered: $name ($got)"
          else
            flog ERROR "inbox: done-reports.tsv cannot be updated" file="$DONE_REPORTS"
            err "could not record delivery for $name"
            failed=1
          fi
        else
          flog WARN "inbox: delivery failed" name="$name" result="$got"
          err "could not deliver $name: $got"
          failed=1
        fi
      done
    done
    exit $failed
    ;;
esac
