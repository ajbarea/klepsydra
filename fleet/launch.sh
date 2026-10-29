#!/usr/bin/env bash
# launch.sh NAME TEXTFILE [claude args...] : open a fleet tmux window running claude inside a
# memory-capped systemd scope, wait for its prompt, paste TEXTFILE and submit it.
# A runaway child (test, fuzz, build) is OOM-killed inside the scope instead of freezing WSL.
set -u
name=$1 txt=$2; shift 2
avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
(( avail < 3000 )) && { echo "HOLD: only ${avail} MiB available"; exit 2; }
before=$(tmux -L klepsydra list-panes -s -t fleet -F '#{pane_id}' 2>/dev/null | sort)
# Workers bypass permissions and Heph does not, so by default Heph's SendMessage is held for AJ's
# approval and expires; worker-settings.json accepts it (AJ approved 2026-10-27). The subagent cap
# enforces the briefs' rule of at most two at a time.
cd ~ && KLEPSYDRA_CLAUDE="systemd-run --user --scope --collect --unit=fleet-$name-$(date +%s) -p MemoryHigh=${MEM_HIGH:-4G} -p MemoryMax=${MEM_MAX:-5G} -p MemorySwapMax=${MEM_SWAP:-1G} env CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=2 claude --settings $HOME/.local/state/fleet-orchestrator/worker-settings.json $*" \
  bash ~/.claude/klepsydra-launch.sh new ~/ajsoftworks || exit 1
pane=$(comm -13 <(echo "$before") <(tmux -L klepsydra list-panes -s -t fleet -F '#{pane_id}' | sort) | head -1)
[[ -n $pane ]] || { echo "no new pane"; exit 1; }
for i in $(seq 60); do tmux -L klepsydra capture-pane -t "$pane" -p | grep -q 'bypass permissions' && break; sleep 2; done
sleep 3
# Remote Control connects at startup, but the transcript records its link only after an explicit
# /remote-control; without it the phone wall shows no Open in Claude button.
tmux -L klepsydra send-keys -t "$pane" -l "/remote-control"; sleep 1; tmux -L klepsydra send-keys -t "$pane" Enter
sleep 4; tmux -L klepsydra send-keys -t "$pane" Enter; sleep 2
# Deliver the brief and confirm a turn started (a spinner line). The prompt can still be busy with
# the /remote-control menu or not yet accept input, so retry up to three times, clearing the input
# first. A usage-limit screen means the brief cannot run now: report it and leave the pane to
# resume-at-reset.sh (it is registered in panes.tsv by the caller).
started=0
for attempt in 1 2 3; do
  tmux -L klepsydra send-keys -t "$pane" Escape; sleep 1
  tmux -L klepsydra load-buffer -b "b$name" "$txt" && tmux -L klepsydra paste-buffer -p -d -b "b$name" -t "$pane"
  sleep 1.5; tmux -L klepsydra send-keys -t "$pane" Enter
  for i in $(seq 10); do
    cap=$(tmux -L klepsydra capture-pane -t "$pane" -p)
    grep -q '… (' <<<"$cap" && { started=1; break; }
    grep -Eq 'hit your (session|weekly) limit|Usage limit reached' <<<"$cap" && { started=limit; break; }
    sleep 2
  done
  [[ $started != 0 ]] && break
done
echo "pane=$pane avail=${avail}MiB brief=$([[ $started == 1 ]] && echo started || { [[ $started == limit ]] && echo blocked-by-limit || echo NOT-DELIVERED; })"
tmux -L klepsydra capture-pane -t "$pane" -p | grep -v '^\s*$' | tail -6
