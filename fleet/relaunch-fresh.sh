#!/usr/bin/env bash
# relaunch-fresh.sh PANE NAME BRIEF HINT : /exit the pane's claude, then launch a new window with
# the fresh preamble + brief + a resume hint, and repoint panes.tsv at the new pane.
set -u
D=$(dirname "$0"); p=$1 name=$2 brief=$3 hint=$4
FRESH=$(sed -n "s/^FRESH='\(.*\)'$/\1/p" "$D/resume-at-reset.sh" | sed "s/'\"'\"'/'/g")
FRESH=${FRESH/stopped at a usage limit over an hour ago, so its cached conversation expired and resuming it would re-cache everything/saved its state and was retired so the fleet restarts on new budget settings with a lean context/}
txt="$D/fresh-$name-$(date +%Y%m%d-%H%M).src"
{ printf '%s\n\n%s\n\n' "$FRESH" "Resume hint: $hint"; cat "$brief"; } > "$txt"
tmux -L klepsydra send-keys -t "$p" -l "/exit"; sleep 1; tmux -L klepsydra send-keys -t "$p" Enter
for i in $(seq 30); do tmux -L klepsydra list-panes -s -t fleet -F '#{pane_id}' | grep -qx "$p" || break; sleep 1; done
out=$("$D/launch.sh" "$name" "$txt")
echo "$out"
new=$(sed -n 's/^pane=\(%[0-9]*\).*/\1/p' <<<"$out" | head -1)
[[ -n $new ]] && sed -i "s#^$p\t$name\t#$new\t$name\t#" "$D/panes.tsv"
echo "$(date '+%F %T') relaunched $name: $p -> ${new:-FAILED}" >> "$D/resume.log"
