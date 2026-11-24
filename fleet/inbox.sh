#!/usr/bin/env bash
# inbox.sh: list or acknowledge undelivered reports in the orchestrator's inbox (#367).
#   fleet inbox [--json] [--all]
#   fleet inbox list [--json] [--all]
#   fleet inbox ack NAME... | --all
#   fleet inbox deliver [NAME...] | --all
set -u
FLEET_TARGET=fleet::inbox
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"

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
      err "usage: fleet inbox [--json] [--all] | fleet inbox ack NAME... | --all"
      exit 2
      ;;
  esac
fi

# Parse remaining options for list
if [[ $cmd == list ]]; then
  while (( $# > 0 )); do
    case $1 in
      --json) json=1; shift ;;
      --all) all=1; shift ;;
      *) break ;;
    esac
  done
fi

case $cmd in
  list)
    if [[ ! -f $FLEET_INBOX ]]; then
      if (( json )); then
        echo "[]"
      else
        echo "no unread reports"
      fi
      exit 0
    fi
    filter='select(.status == "pending")'
    (( all )) && filter='.'
    items=$(jq -s "[.[] | $filter]" "$FLEET_INBOX" 2>/dev/null)
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
    else
      if (( all )); then
        jq -r '.[] | "[\(.status)] \(.name // .pane) (\(.pane), \(.iso), \(.result)): \(.report)"' <<<"$items"
      else
        jq -r '.[] | "\(.name // .pane) (\(.pane), \(.iso), \(.result)): \(.report)"' <<<"$items"
      fi
    fi
    ;;
  ack)
    (( $# > 0 )) || { err "usage: fleet inbox ack NAME... | --all"; exit 2; }
    target=$1
    if [[ $target == --all ]]; then
      count=$(with_inbox inbox_ack --all) || { err "no unread reports to acknowledge"; exit 1; }
      with_registry dr_ack --all
      flog INFO "inbox: acknowledged all unread reports" count="$count"
      echo "acknowledged: all ($count report$( (( count > 1 )) && echo s ))"
      exit 0
    fi
    for name in "$@"; do
      count=$(with_inbox inbox_ack "$name") || { err "no unread report for $name"; exit 1; }
      with_registry dr_ack "$name"
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
    if [[ ! -f $FLEET_INBOX ]]; then
      echo "no unread reports"
      exit 0
    fi
    targets=("$@")
    if (( ${#targets[@]} == 0 )) || [[ ${targets[0]} == --all ]]; then
      mapfile -t targets < <(jq -r 'select(.status == "pending") | .name' "$FLEET_INBOX" 2>/dev/null | sort -u)
    fi
    if (( ${#targets[@]} == 0 )); then
      echo "no unread reports"
      exit 0
    fi
    failed=0
    for name in "${targets[@]}"; do
      row=$(jq -r --arg name "$name" 'select(.name == $name and .status == "pending") | "\(.at // 0)\t\(.report)"' "$FLEET_INBOX" 2>/dev/null | head -1)
      if [[ -z $row ]]; then
        err "no unread report for $name"
        failed=1
        continue
      fi
      at=${row%%$'\t'*}
      rep=${row#*$'\t'}
      msg="$name finished: $rep"
      got=$(bash "$here/send.sh" "$orch" - <<<"$msg" 2>/dev/null) || true
      got=${got##*$'\n'}
      if [[ $got == sent || $got == queued ]]; then
        with_inbox inbox_mark_delivered "$name" "$rep"
        [[ $at != 0 ]] && with_registry dr_set "$at" "$name" "$got"
        flog INFO "inbox: delivered report" name="$name" result="$got"
        echo "delivered: $name ($got)"
      else
        flog WARN "inbox: delivery failed" name="$name" result="$got"
        err "could not deliver $name: $got"
        failed=1
      fi
    done
    exit $failed
    ;;
esac
