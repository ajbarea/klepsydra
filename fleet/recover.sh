#!/usr/bin/env bash
# recover.sh [--dry-run] [--no-orchestrator] (`fleet recover`): bring the
# fleet back after a hard shutdown. Each agent in panes.tsv whose session no
# longer runs (session_alive: not on this boot, or its process gone) is
# launched fresh from its brief, one at a time FLEET_STAGGER_S apart, with a
# resume hint: its transcript's last two replies and a pointer to its newest
# IMPL.md. The orchestrator, when its session is gone too, is launched from a
# note naming HEPH.md and holding AJ's messages to it since HEPH.md was last
# written. A running agent is left alone, so a second run does nothing.
set -u
FLEET_TARGET=fleet::recover
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
LAUNCH=${LAUNCH:-$here/launch.sh}
STAGGER=${FLEET_STAGGER_S:-60} # launches far apart: a burst of new sessions jams WSL's network
HEPH=${FLEET_HEPH:-$FLEET_STATE/HEPH.md}
dry=0 orch_too=1
for a in "$@"; do
  case $a in --dry-run) dry=1 ;; --no-orchestrator) orch_too=0 ;; *) err "usage: recover.sh [--dry-run] [--no-orchestrator]"; exit 2 ;; esac
done

# The transcript of session SID, in any config folder's projects.
transcript() { # SID
  local dir
  for dir in ${FLEET_PROJECTS:-$(for d in $FLEET_ACCOUNTS; do printf '%s/projects ' "$d"; done)}; do
    find "$dir" -mindepth 2 -maxdepth 2 -name "$1.jsonl" -type f 2>/dev/null
  done | head -1
}

# Its last two replies, each cut to 500 characters, as quoted lines.
last_replies() { # TRANSCRIPT
  jq -r 'select(.type == "assistant") | [.message.content[]? | select(.type == "text") | .text] | join(" ") | select(length > 0)' "$1" 2>/dev/null |
    tail -2 | cut -c1-500 | sed 's/^/> /'
}

# The newest IMPL.md of the repo the transcript last worked in: its folder's
# own and its worktrees'.
newest_impl() { # TRANSCRIPT
  local cwd top
  cwd=$(jq -r 'select(.cwd != null) | .cwd' "$1" 2>/dev/null | tail -1)
  [[ -n $cwd && -d $cwd ]] || return 1
  top=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) && top=${top%/.git}
  find "$cwd" "${top:-$cwd}" "${top:-$cwd}/.claude/worktrees" -maxdepth 2 -name IMPL.md -type f -printf '%T@ %p\n' 2>/dev/null |
    sort -rn | head -1 | cut -d' ' -f2- | grep .
}

launched=0
# Wait out the stagger before every launch but the first.
stagger() { (( launched++ )) && sleep "$STAGGER"; return 0; }
launch() { # NAME TEXTFILE [env...]: one launch; prints the new pane
  local name=$1 txt=$2 out
  shift 2
  out=$(env "$@" bash "$LAUNCH" "$name" "$txt" 2>/dev/null | head -1)
  flog INFO "recovered" name="$name" result="$out"
  printf '%s' "$(grep -o 'pane=%[0-9]*' <<<"$out" | cut -d= -f2)"
}

lost=0
while IFS=$'\t' read -r p name brief sid _; do
  [[ -n $p && -n $name && -n $brief ]] || continue
  if session_alive "$sid"; then
    echo "running: $name ($p)"
    continue
  fi
  lost=$((lost + 1))
  tp=$(transcript "$sid")
  replies="" impl=""
  [[ -n $tp ]] && replies=$(last_replies "$tp") && impl=$(newest_impl "$tp")
  if (( dry )); then
    echo "would recover: $name (session ${sid:-unknown}, transcript ${tp:-none}, IMPL.md ${impl:-none})"
    continue
  fi
  txt="$FLEET_STATE/fresh-$name-$(date +%Y%m%d-%H%M)-recover.src"
  {
    fresh_preamble "was stopped by a hard shutdown of the PC"
    printf '\n\nWhere it was, its last replies:\n%s\n' "${replies:-> (no transcript found)}"
    [[ -n $impl ]] && printf '\nIts newest IMPL.md: %s\n' "$impl"
    printf '\n'
    cat "$brief"
  } >"$txt"
  stagger
  new=$(launch "$name" "$txt")
  echo "recovered: $name -> ${new:-NOT STARTED}"
  [[ -n $new ]] || flog ERROR "recovery launch failed" name="$name" brief="$txt"
done < <(cat "$REGISTRY" 2>/dev/null)

# The orchestrator: its session is the newest file naming its pane.
orch=$(orchestrator)
if (( orch_too )) && [[ -n $orch ]]; then
  osid=$(for f in "$KLEPSYDRA_DIR"/fleet/*.json; do
    [[ -f $f && ! -L $f ]] || continue
    jq -r --arg p "$orch" 'select(.tmux.pane == $p) | "\(.started_at // 0) \(input_filename | split("/") | last | rtrimstr(".json"))"' "$f" 2>/dev/null
  done | sort -rn | head -1 | cut -d' ' -f2)
  if [[ -n $osid ]] && session_alive "$osid"; then
    echo "running: orchestrator ($orch)"
  else
    lost=$((lost + 1))
    tp=$(transcript "$osid")
    since=$(stat -c %Y -- "$HEPH" 2>/dev/null || echo 0)
    asks=""
    [[ -n $tp ]] && asks=$(jq -r --argjson since "$since" '
      select(.type == "user" and (.isMeta | not) and (.message.content | type) == "string")
      | select((.timestamp // "" | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch 0) > $since)
      | .message.content | select(startswith("<") | not) | gsub("\n"; " ") | .[0:1000]' "$tp" 2>/dev/null | tail -20 | sed 's/^/- /')
    if (( dry )); then
      echo "would recover: orchestrator (session ${osid:-unknown}, $(grep -c . <<<"$asks") messages since HEPH.md)"
    else
      txt="$FLEET_STATE/heph-recover-$(date +%Y%m%d-%H%M).md"
      {
        printf 'Fresh start: the orchestrator (Heph) was stopped by a hard shutdown of the PC; you replace it. Read %s first, then the "Running now" lines in /mnt/c/Users/ajbar/fleet-briefing/claude-queue.md; `fleet recover` has relaunched the agents in panes.tsv. Put anything below that changes the plan into HEPH.md now.\n\n' "$HEPH"
        printf "AJ's messages to the last orchestrator after HEPH.md was last written:\n%s\n" "${asks:-- (none)}"
      } >"$txt"
      stagger
      new=$(launch heph "$txt" FLEET_SETTINGS= FLEET_ACCOUNT="$FLEET_DEFAULT_CONFIG")
      if [[ -n $new ]]; then
        printf '%s\n' "$new" >"$FLEET_STATE/orchestrator.pane"
        echo "recovered: orchestrator -> $new"
      else
        flog ERROR "recovery launch failed" name=orchestrator brief="$txt"
        echo "recovered: orchestrator -> NOT STARTED"
      fi
    fi
  fi
fi
(( lost )) || echo "nothing to recover"
flog INFO "recover ran" lost="$lost" dry="$dry"
