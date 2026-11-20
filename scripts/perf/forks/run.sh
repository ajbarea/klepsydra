#!/usr/bin/env bash
# run.sh OUT PANE...: the fork counts of the fleet's recurring shell paths,
# run from this checkout on the live panes PANE... (sandboxed: sandbox.sh).
# Prints one count.sh line per path. Rows:
#   hook-*       one fleet-hook event (hooks/klepsydra-fleet.sh), the payload
#                from a real session of PANE[0]'s (its file in the copy)
#   resume-pass  one resume-at-reset.sh --once pass over every fleet pane
#   watch-30s    watch-panes.sh on PANE... for 30 s at WATCH_TICK=1
#   doctor       one doctor.sh --json run
#   tmux-watch   one tmux-watch.sh run
set -u
out=$1
shift
here=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
repo=${here%/scripts/perf/forks}
export OUT=$out
sb=$here/sandbox.sh
bash "$sb" "$out" tmux-watch.sh >/dev/null 2>&1 # makes the copies
sid=$(jq -r --arg p "$1" 'select(.tmux.pane == $p and .ended == null) | .session_id' "$out"/kdir/fleet/*.json 2>/dev/null | head -1)
for ev in PostToolUse UserPromptSubmit Stop; do
  jq -nc --arg ev "$ev" --arg sid "$sid" --arg cwd "$repo" '{session_id: $sid, transcript_path: "/nonexistent.jsonl",
    cwd: $cwd, permission_mode: "default", hook_event_name: $ev, tool_name: "Bash", tool_input: {command: "ls"},
    tool_response: {stdout: "x", stderr: "", interrupted: false}, tool_use_id: "toolu_01X", duration_ms: 20,
    prompt: "hi", last_assistant_message: "done", stop_hook_active: false}' >"$out/ev-$ev.json"
  # The read-only tmux shim too: the hook colours its window.
  STDIN=$out/ev-$ev.json KLEPSYDRA_DIR=$out/kdir XDG_RUNTIME_DIR=$out PATH=$out/shim:$PATH SHIM_LOG=$out/shim.log bash "$here/count.sh" "hook-$ev" bash "$repo/hooks/klepsydra-fleet.sh"
done
bash "$here/count.sh" resume-pass bash "$sb" "$out" resume-at-reset.sh --once
WATCH_TICK=1 IDLE_S=99999 bash "$here/count.sh" watch-30s timeout 30 bash "$sb" "$out" watch-panes.sh "$@"
bash "$here/count.sh" doctor bash "$sb" "$out" doctor.sh --json "$out/fh.json"
bash "$here/count.sh" tmux-watch bash "$sb" "$out" tmux-watch.sh
# Forks between one tick's sleep and the next, per tick, and before the first.
awk '/ (clone|clone3|fork|vfork)\(/ { n++ } /execve\("[^"]*\/sleep"/ { if (seen) t = t " " n; else s = n; seen = 1; n = 0 }
  END { printf "watch-30s start forks: %d; per-tick forks:%s\n", s, t }' "$out/strace-watch-30s.log"
echo "refused tmux writes: $(wc -l <"$out/shim.log" 2>/dev/null || echo 0)"
