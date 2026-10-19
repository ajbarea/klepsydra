#!/usr/bin/env bash
# The fleet as its session files have it, for the live check to compare with
# the strip and the wall: one line per session with its state, reason, voice,
# where it works, the state's age, and the heartbeat's name and age.
# Usage: bash scripts/fleet-status.sh
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
# The hook resolves KLEPSYDRA_DIR as Claude Code would run it.
# shellcheck source=hooks/klepsydra-fleet.sh
source "$repo/hooks/klepsydra-fleet.sh"
fleet="$KLEPSYDRA_DIR/fleet"
printf -v now '%(%s)T' -1

shopt -s nullglob
files=("$fleet"/*.json)
if (( ${#files[@]} == 0 )); then
  echo "no session files in $fleet"
  exit 0
fi
{
  printf 'session\tstate\treason\tvoice\twhere\tfor\tbeat\tbeat age\n'
  for f in "${files[@]}"; do
    beat=${f%.json}.beat
    name="-" age="-"
    if [[ -f $beat ]]; then
      IFS=$'\t' read -r name _ <"$beat" || true
      age="$(( now - $(stat -c %Y "$beat") ))s"
    fi
    jq -r --argjson now "$now" --arg name "${name:--}" --arg age "$age" '
      [ .session_id[0:8], .state, (.reason // "-"), (.voice // "-"),
        ([.where.repo, .where.worktree] | map(select(. != null)) | join("/") | if . == "" then "-" else . end),
        "\((($now - .state_at) / 60) | floor)m", $name, $age ] | @tsv' "$f" 2>/dev/null ||
      printf '%s\tunreadable\n' "${f##*/}"
  done
} | column -t -s $'\t'
