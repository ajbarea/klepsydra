#!/usr/bin/env bash
# fresh-now.sh [PANE...]: give each registered fleet pane (default: every one
# in panes.tsv) a fresh conversation in place: /clear, /remote-control (a
# cleared transcript records no Remote Control link, so the phone wall would
# lose its Open in Claude button), then the fresh-start preamble and its brief.
# A pane busy in a turn, or holding text AJ typed, is skipped and logged.
set -u
FLEET_TARGET=fleet::fresh-now
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
want=" $* "
while IFS=$'\t' read -r p name brief _; do
  [[ -n $p && -n $name && -n $brief ]] || continue
  [[ $# -gt 0 && $want != *" $p "* ]] && continue
  s=$(screen "$p")
  if ! idle_empty "$s"; then
    flog WARN "fresh session skipped: the pane is busy or holds typed text" pane="$p" name="$name"
    echo "skipped: $name in $p (busy, or text in its prompt)"
    continue
  fi
  txt="$FLEET_STATE/fresh-$name-$(date +%Y%m%d-%H%M).src"
  { fresh_preamble "had grown too large to keep resuming"; printf '\n\n'; cat "$brief"; } >"$txt"
  t send-keys -t "$p" -l "/clear"
  wait_for "$p" 5 holds_input && t send-keys -t "$p" Enter
  wait_for "$p" 30 idle_empty || flog WARN "/clear did not come back to an empty prompt" pane="$p" name="$name"
  remote_control "$p" || flog WARN "remote control did not settle after /clear" pane="$p" name="$name"
  got=$(deliver "$p" "$txt")
  flog INFO "fresh session via /clear" pane="$p" name="$name" brief="$got"
  echo "fresh: $name in $p: $got"
done < <(cat "$REGISTRY" 2>/dev/null)
