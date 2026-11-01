#!/usr/bin/env bash
# fresh-now.sh [PANE...]: give each registered fleet pane (default: every one
# in panes.tsv) a fresh conversation in place: /clear, /remote-control (a
# cleared transcript records no Remote Control link, so the phone wall would
# lose its Open in Claude button), then the fresh-start preamble and its brief.
# A pane busy in a turn, or holding text AJ typed, is skipped and logged.
# When best_account (the first account with room) is another than the pane's, the pane is
# relaunched there instead (relaunch-fresh.sh), since /clear keeps its login.
set -u
FLEET_TARGET=fleet::fresh-now
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
want=" $* "
# The registry comes in on fd 3: a launch (wt.exe) drains stdin (#242).
while IFS=$'\t' read -r -u 3 p name brief sid _ account; do
  [[ -n $p && -n $name && -n $brief ]] || continue
  [[ $# -gt 0 && $want != *" $p "* ]] && continue
  if ! pane_runs "$p" "$sid"; then
    flog WARN "fresh session skipped: the pane no longer runs its registered session" pane="$p" name="$name" session_id="$sid"
    echo "skipped: $name in $p (not its registered session)"
    continue
  fi
  s=$(screen "$p")
  if ! idle_empty "$s"; then
    flog WARN "fresh session skipped: the pane is busy or holds typed text" pane="$p" name="$name"
    echo "skipped: $name in $p (busy, or text in its prompt)"
    continue
  fi
  account=${account:-$FLEET_DEFAULT_CONFIG}
  best=$(best_account "$(date +%s)")
  if [[ -n $best && $best != "$account" && $(account_of "$best") != "$(account_of "$account")" ]]; then
    out=$(FLEET_ACCOUNT=$best FLEET_WHY="had grown too large to keep resuming, and starts again on the preferred account with room" \
      bash "$here/relaunch-fresh.sh" "$p" "$name" "$brief" "none: carry on from the brief" </dev/null 3<&- 2>/dev/null | head -1)
    flog INFO "fresh session on the preferred account with room" pane="$p" name="$name" from="$account" to="$best" result="$out"
    echo "fresh: $name moved to $best: $out"
    continue
  fi
  txt="$FLEET_STATE/fresh-$name-$(date +%Y%m%d-%H%M).src"
  { fresh_preamble "had grown too large to keep resuming"; printf '\n\n'; cat "$brief"; } >"$txt"
  if ! type_exactly "$p" "/clear"; then
    flog WARN "fresh session skipped: AJ typed while /clear went in" pane="$p" name="$name"
    continue
  fi
  t send-keys -t "$p" Enter
  wait_for "$p" 30 idle_empty || flog WARN "/clear did not come back to an empty prompt" pane="$p" name="$name"
  # /clear starts a new session id in the same pane: the registry follows it.
  new_sid=""
  for _ in $(seq 20); do
    if new_sid=$(live_session "$p") && [[ $new_sid != "$sid" ]]; then
      set_session "$p" "$new_sid" && break
      flog WARN "the new session id could not be recorded in the registry" pane="$p" session_id="$new_sid"
      break
    fi
    new_sid=""
    sleep 0.5
  done
  [[ -n $new_sid ]] || flog WARN "no new session id after /clear; the registry keeps the old one" pane="$p" name="$name"
  remote_control "$p" || flog WARN "remote control did not settle after /clear" pane="$p" name="$name"
  got=$(deliver "$p" "$txt")
  flog INFO "fresh session via /clear" pane="$p" name="$name" brief="$got"
  echo "fresh: $name in $p: $got"
done 3< <(cat "$REGISTRY" 2>/dev/null)
