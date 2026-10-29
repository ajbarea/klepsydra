#!/usr/bin/env bash
# fresh-now.sh [PANE...] : give each registered fleet pane (default: all in panes.tsv) a fresh
# conversation in place: /clear, then paste the fresh-start preamble plus its brief.
D=$(dirname "$0")
FRESH=$(sed -n "s/^FRESH='\(.*\)'$/\1/p" "$D/resume-at-reset.sh" | sed "s/'\"'\"'/'/g")
[[ -n $FRESH ]] || { echo "no preamble in resume-at-reset.sh" >&2; exit 1; }
FRESH=${FRESH/stopped at a usage limit over an hour ago, so its cached conversation expired and resuming it would re-cache everything/had grown too large to keep resuming}
want=" $* "
awk -F'\t' 'NF == 3' "$D/panes.tsv" | while IFS=$'\t' read -r p name brief; do
  [[ $# -gt 0 && $want != *" $p "* ]] && continue
  txt="$D/fresh-$name-$(date +%Y%m%d-%H%M).src"
  { printf '%s\n\n' "$FRESH"; cat "$brief"; } > "$txt"
  tmux -L klepsydra send-keys -t "$p" -l "/clear"; sleep 1; tmux -L klepsydra send-keys -t "$p" Enter; sleep 6
  # /clear keeps Remote Control connected but the new transcript records no link (attribution is
  # off), so the phone wall loses its Open in Claude button; /remote-control writes it again. The
  # second Enter connects, or picks the preselected Continue when it is already on.
  tmux -L klepsydra send-keys -t "$p" -l "/remote-control"; sleep 1; tmux -L klepsydra send-keys -t "$p" Enter
  sleep 4; tmux -L klepsydra send-keys -t "$p" Enter; sleep 2
  tmux -L klepsydra load-buffer -b "f$name" "$txt" && tmux -L klepsydra paste-buffer -p -d -b "f$name" -t "$p"
  sleep 2; tmux -L klepsydra send-keys -t "$p" Enter
  echo "$(date '+%F %T') fresh session for $name in $p via /clear" >> "$D/resume.log"
  echo "fresh: $name in $p"
done
