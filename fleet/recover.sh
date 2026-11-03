#!/usr/bin/env bash
# recover.sh [--dry-run] [--no-orchestrator] (`fleet recover`): bring the
# fleet back after a hard shutdown. Each agent in panes.tsv whose session no
# longer runs (session_alive: not on this boot, or its process gone) is
# launched fresh from its brief, one at a time FLEET_STAGGER_S apart, with a
# resume hint: its transcript's last two replies and a pointer to its newest
# IMPL.md. The orchestrator, when its session is gone too, is launched from a
# note naming HEPH.md and holding AJ's messages to it since HEPH.md was last
# written. A running agent is left alone, so a second run does nothing; a
# pane that still runs a live session gets its row repaired, not a second
# agent. One run at a time (a lock), so AJ and Heph never both launch.
set -u
FLEET_TARGET=fleet::recover
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
LAUNCH=${LAUNCH:-$here/launch.sh}
STAGGER=${FLEET_STAGGER_S:-60} # launches far apart: a burst of new sessions jams WSL's network
dry=0 orch_too=1
for a in "$@"; do
  case $a in --dry-run) dry=1 ;; --no-orchestrator) orch_too=0 ;; *) err "usage: recover.sh [--dry-run] [--no-orchestrator]"; exit 2 ;; esac
done
if (( ! dry )); then
  exec 9>"$FLEET_STATE/.recover.lock"
  flock -n 9 || { err "another fleet recover is running"; exit 1; }
fi

# Every session alive before any launch, as "pane<TAB>session<TAB>in-fleet"
# lines: what recover decides from, so a launch never changes who is who.
# In-fleet: on the fleet's tmux server (a file without a socket counts, so a
# live Heph is never missed).
live_now=$(for f in "$KLEPSYDRA_DIR"/fleet/*.json; do
  [[ -f $f && ! -L $f ]] || continue
  id=$(basename "$f" .json)
  row=$(jq -r --arg s "/$FLEET_SOCK" 'select(.ended == null and .tmux.pane != null)
    | [.tmux.pane, (if .tmux.socket == null or (.tmux.socket | endswith($s)) then 1 else 0 end)] | @tsv' "$f" 2>/dev/null) || continue
  [[ -n $row ]] && session_alive "$id" && printf '%s\t%s\t%s\n' "${row%%$'\t'*}" "$id" "${row##*$'\t'}"
done)
agents=$(cut -f4 "$REGISTRY" 2>/dev/null | grep .)
# A row whose own session's process started after the running fleet tmux
# server did: a live session in its pane is its successor (a /clear). A row
# from an earlier server (a reboot, or the server closed and started again)
# names a pane id the new server reuses, so a session there is someone else's.
# Both starts are /proc clock ticks since boot (stat field 22), so a WSL clock
# step cannot skew them, and a resumed session carries its new process's start.
# With no server running, no row counts.
this_boot_row() { on_this_server "$1"; } # SID

# Heph is a session the records name: the one whose id is orchestrator.session,
# or the one in orchestrator.pane (a pane id counts only when the record ran on
# this boot, or there is no record yet). A Claude session that runs `fleet
# recover` in the fleet's tmux is Heph unless the records name another live
# one. Any other live fleet session that is no agent's leaves Heph unsure:
# never launched and the records untouched, since a second orchestrator is the
# worst outcome.
orch=$(orchestrator) rec=$(cat "$FLEET_STATE/orchestrator.session" 2>/dev/null)
grep -qxF -- "${rec:-x}" <<<"$agents" && rec="" # a record naming an agent is no Heph's
heph_pane="" osid="" heph_unsure=0
unreg=$(awk -F'\t' 'NR == FNR { if ($0 != "") a[$0] = 1; next } $3 == 1 && !($2 in a)' <(printf '%s\n' "$agents") <(printf '%s\n' "$live_now"))
# A worker's new session after a /clear sits in its this-boot row's pane: no Heph.
rows=$(while IFS=$'\t' read -r rp _ _ rsid _; do [[ -n $rp ]] && this_boot_row "$rsid" && printf '%s\n' "$rp"; done <"$REGISTRY" 2>/dev/null)
loose=$(awk -F'\t' 'NR == FNR { if ($0 != "") r[$0] = 1; next } $0 != "" && !($1 in r)' <(printf '%s\n' "$rows") <(printf '%s\n' "$unreg"))
onrec=""
[[ -n $rec ]] && onrec=$(awk -F'\t' -v r="$rec" '$2 == r' <<<"$unreg")
if [[ -z $onrec && -n $orch ]] && ! grep -qxF -- "$orch" <<<"$rows" && { [[ -z $rec ]] || this_boot_row "$rec"; }; then
  onrec=$(awk -F'\t' -v o="$orch" '$1 == o' <<<"$unreg")
fi
[[ $(grep -c . <<<"$onrec") == 1 ]] || onrec=""
caller=""
if [[ -n ${CLAUDECODE:-} && -n ${TMUX_PANE:-} && ${TMUX:-} == *"/$FLEET_SOCK,"* ]] && ! grep -qxF -- "$TMUX_PANE" <<<"$rows"; then
  caller=$TMUX_PANE
fi
if [[ -n $onrec ]]; then
  heph_pane=$(cut -f1 <<<"$onrec") osid=$(cut -f2 <<<"$onrec")
elif [[ -n $caller ]]; then
  heph_pane=$caller
  osid=$(awk -F'\t' -v p="$caller" '$1 == p && $3 == 1 { print $2; exit }' <<<"$live_now")
elif [[ -n $loose ]]; then
  heph_unsure=$(grep -c . <<<"$loose")
else
  # Gone: its recorded session (the resume service keeps it), else the newest
  # file naming its pane that is no agent's, for its transcript.
  osid=$rec
  [[ -z $osid && -n $orch ]] && osid=$(for f in "$KLEPSYDRA_DIR"/fleet/*.json; do
    [[ -f $f && ! -L $f ]] || continue
    jq -r --arg p "$orch" 'select(.tmux.pane == $p) | "\(.started_at // 0) \(input_filename | split("/") | last | rtrimstr(".json"))"' "$f" 2>/dev/null
  done | sort -rn | while read -r _ id; do grep -qxF -- "$id" <<<"$agents" || { printf '%s' "$id"; break; }; done)
fi

# The one session that was alive in PANE before any launch, is not Heph's and
# no other row's: what a row whose own session is gone may be repaired to.
repair_to() { # PANE
  awk -F'\t' -v p="$1" -v h="$osid" 'NR == FNR { if ($0 != "") a[$0] = 1; next } $1 == p && $3 == 1 && $2 != h && !($2 in a) { print $2 }' \
    <(printf '%s\n' "$agents") <(printf '%s\n' "$live_now") | awk 'END { if (NR == 1) print prev } { prev = $0 }'
}

# Its last two replies, each cut to 500 characters, as quoted lines.
last_replies() { # TRANSCRIPT
  jq -r 'select(.type == "assistant") | [.message.content[]? | select(.type == "text") | .text] | join(" ") | select(length > 0)' "$1" 2>/dev/null |
    tail -2 | cut -c1-500 | sed 's/^/> /'
}

launched=0
# Wait out the stagger before every launch but the first.
stagger() { (( launched++ )) && sleep "$STAGGER"; return 0; }
launch() { # NAME TEXTFILE [env...]: one launch; prints "PANE SESSION"
  local name=$1 txt=$2 out
  shift 2
  # No stdin and no fd 3: the registry loop reads fd 3, and wt.exe drains
  # whatever it is handed (#242). No fd 9: the launch may start the fleet's
  # tmux server, which would keep the recover lock forever.
  out=$(env "$@" bash "$LAUNCH" "$name" "$txt" </dev/null 3<&- 9>&- 2>/dev/null | head -1)
  flog INFO "recovered" name="$name" result="$out"
  grep -q 'pane=%[0-9]' <<<"$out" || return 0
  printf '%s %s' "$(grep -o 'pane=%[0-9]*' <<<"$out" | cut -d= -f2)" "$(grep -o 'session=[^ ]*' <<<"$out" | cut -d= -f2)"
}

lost=0
# The registry comes in on fd 3, so nothing in the loop can read its rows away (#242).
while IFS=$'\t' read -r -u 3 p name brief sid _; do
  [[ -n $p && -n $name && -n $brief ]] || continue
  if session_alive "$sid"; then
    echo "running: $name ($p)"
    continue
  fi
  # The pane still runs a live session the row does not name (a /clear whose
  # new id was never recorded): repair the row, never start a second agent.
  if this_boot_row "$sid" && now=$(repair_to "$p") && [[ -n $now ]]; then
    echo "running: $name ($p, now session $now)"
    (( dry )) || { set_session "$p" "$now"; flog INFO "registry repaired" pane="$p" name="$name" session="$now"; }
    continue
  fi
  if [[ ! -r $brief ]]; then
    echo "not recovered: $name (brief $brief is gone)"
    flog ERROR "recovery skipped: brief missing" name="$name" brief="$brief"
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
  new=${new%% *}
  echo "recovered: $name -> ${new:-NOT STARTED}"
  [[ -n $new ]] || flog ERROR "recovery launch failed" name="$name" brief="$txt"
done 3< <(cat "$REGISTRY" 2>/dev/null)

# The orchestrator, by what was alive before the launches.
if (( orch_too && heph_unsure )); then
  echo "not recovered: orchestrator ($heph_unsure live sessions in the fleet belong to no agent and none is on record as Heph; write Heph's pane to orchestrator.pane)"
  flog WARN "orchestrator not relaunched: Heph unclear" candidates="$heph_unsure"
elif (( orch_too )) && [[ -n $heph_pane ]]; then
  echo "running: orchestrator ($heph_pane)"
  if (( ! dry )) && [[ $heph_pane != "$orch" || -n $osid && $osid != "$(cat "$FLEET_STATE/orchestrator.session" 2>/dev/null)" ]]; then
    printf '%s\n' "$heph_pane" >"$FLEET_STATE/orchestrator.pane"
    [[ -n $osid ]] && printf '%s\n' "$osid" >"$FLEET_STATE/orchestrator.session"
    flog INFO "orchestrator record follows the live Heph" pane="$heph_pane" session="$osid"
  fi
elif (( orch_too )) && [[ -n $orch$osid ]]; then
    lost=$((lost + 1))
    if (( dry )); then
      echo "would recover: orchestrator (session ${osid:-unknown}, $(heph_asks "$osid" "$HEPH" | grep -c .) messages since HEPH.md)"
    else
      txt="$FLEET_STATE/heph-recover-$(date +%Y%m%d-%H%M).md"
      # shellcheck disable=SC2016 # `fleet recover` is a command named in the text
      heph_note "was stopped by a hard shutdown of the PC" "$osid" "$HEPH" '`fleet recover` has relaunched the agents in panes.tsv.' >"$txt"
      stagger
      heph_on=$(FLEET_ACCOUNTS=$FLEET_HEPH_ACCOUNTS best_account "$(date +%s)")
      new=$(launch heph "$txt" FLEET_SETTINGS= FLEET_ACCOUNT="${heph_on:-$FLEET_DEFAULT_CONFIG}")
      if [[ -n $new ]]; then
        printf '%s\n' "${new%% *}" >"$FLEET_STATE/orchestrator.pane"
        [[ $new == *" "?* ]] && printf '%s\n' "${new#* }" >"$FLEET_STATE/orchestrator.session"
        printf '%s\n' "${heph_on:-$FLEET_DEFAULT_CONFIG}" >"$FLEET_STATE/orchestrator.config"
        echo "recovered: orchestrator -> ${new%% *}"
      else
        flog ERROR "recovery launch failed" name=orchestrator brief="$txt"
        echo "recovered: orchestrator -> NOT STARTED"
      fi
    fi
fi
(( lost )) || echo "nothing to recover"
flog INFO "recover ran" lost="$lost" dry="$dry"
