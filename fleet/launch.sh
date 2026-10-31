#!/usr/bin/env bash
# launch.sh NAME TEXTFILE [claude args...]: open a fleet tmux window running
# claude, with a session id of its own, inside a memory-capped systemd scope
# (a runaway test or build is OOM-killed there instead of freezing WSL); turn
# Remote Control on and wait for it to settle; then paste TEXTFILE, check it
# reached the prompt, and submit it. A retry never sends Escape, so it cannot
# cancel a turn that started. Registers the pane, session and folder in
# panes.tsv for NAME when NAME is a fleet agent (a row exists, or task-NAME.src).
# The session runs on FLEET_ACCOUNT's config folder when set, else on the
# first logged-in account with room in FLEET_ACCOUNTS order (best_account).
# The whole launch has FLEET_LAUNCH_DEADLINE seconds (a session that takes no
# keys, as on 10-29, fails in bounded time instead of holding its caller), and
# only the window's creation is serialised with other launches.
# Prints one line: pane=%N session=UUID account=DIR avail=MiB brief=started|blocked-by-limit|NOT-DELIVERED.
set -u
FLEET_TARGET=fleet::launch
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
(( $# >= 2 )) || { err "usage: launch.sh NAME TEXTFILE [claude args...]"; exit 2; }
name=$1 txt=$2
shift 2
[[ -r $txt ]] || { err "no brief at $txt"; exit 2; }
avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
if (( avail < ${FLEET_MIN_AVAIL_MB:-3000} )); then
  flog WARN "launch held: too little memory" name="$name" avail_mb="$avail"
  echo "HOLD: only ${avail} MiB available" # logcheck: ignore[stderr-for-errors] # the result line callers read; flog has it on stderr
  exit 2
fi
dir=${FLEET_DIR:-$HOME/ajsoftworks}
sid=$(cat /proc/sys/kernel/random/uuid)
account=${FLEET_ACCOUNT:-$(best_account "$(date +%s)")}
account=${account:-$FLEET_DEFAULT_CONFIG}
account=$(nodir "$account") # "~/.claude/" is the default too, which must not set CLAUDE_CONFIG_DIR
# Workers bypass permissions and Heph does not, so Heph's SendMessage would wait
# for AJ's approval; worker-settings.json accepts it (AJ approved 2026-10-27).
# The subagent cap enforces the briefs' rule of at most two at a time. Its env
# turns keryx off, so only Heph speaks and no worker loads a voice model (#183).
# FLEET_SETTINGS="" starts it without them (the orchestrator, fleet recover).
settings=${FLEET_SETTINGS-$FLEET_STATE/worker-settings.json}
# The tray's Voices setting (#183), from klepsydra's prefs.json: "heph" (the
# default, and anything else) keeps the worker settings' keryx off, "everyone"
# drops that line, and "off" gives a session started without them (Heph) keryx
# off too. --settings takes a JSON string as well as a file, and outranks the
# user's and the project's settings.
voices=$(jq -ser 'if length == 1 then .[0].voices else empty end | select(. == "everyone" or . == "off")' "$KLEPSYDRA_DIR/prefs.json" 2>/dev/null) || voices=heph
if [[ -n $settings && $voices == everyone ]]; then
  settings=$(jq -c 'del(.env.KERYX_ENABLED) | if .env == {} then del(.env) else . end' "$settings" 2>/dev/null) || settings=${FLEET_SETTINGS-$FLEET_STATE/worker-settings.json}
elif [[ -z $settings && $voices == off ]]; then
  settings='{"env":{"KERYX_ENABLED":"false"}}'
fi
# KLEPSYDRA_AGENT names the session's agent to the fleet hook, so its card keeps
# its face across relaunches (#172).
# keryx's switch comes from --settings alone, never from the tmux server's
# environment (a server started from a session with keryx off would pass it on).
cmd="env -u KERYX_ENABLED $(config_env "$account")KLEPSYDRA_AGENT=$(printf '%q' "$name") CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=2 ${FLEET_CLAUDE:-claude} --session-id $sid${settings:+ --settings $(printf '%q' "$settings")} $*"
if [[ ${FLEET_SCOPE:-1} != 0 ]]; then
  cmd="systemd-run --user --scope --collect --unit=fleet-$name-$(date +%s) -p MemoryHigh=${MEM_HIGH:-4G} -p MemoryMax=${MEM_MAX:-5G} -p MemorySwapMax=${MEM_SWAP:-1G} $cmd"
fi
began=$SECONDS
DELIVER_DEADLINE=$((SECONDS + ${FLEET_LAUNCH_DEADLINE:-120}))
# Seconds since the launch began, for each line's timing.
took() { printf '%s' "$((SECONDS - began))"; }
# The lock covers only the window's creation, so the new pane is the one that
# appeared; each launch then waits on its own session in parallel.
exec 8>>"$FLEET_STATE/.launch.lock"
flock -w 120 8 || { flog ERROR "launch held: another launch kept the lock for 2 min" name="$name"; exit 1; }
before=$(fleet_panes | sort)
# Every fleet launch opens behind the window in view (#216). A new orchestrator
# is brought forward by his caller once the old one has gone (heph_move, recover).
# No stdin for the launcher: a caller reading a list on it would lose the rest (#242).
if ! out=$(cd ~ && KLEPSYDRA_CLAUDE="$cmd" KLEPSYDRA_TMUX_SOCKET="$FLEET_SOCK" KLEPSYDRA_BACKGROUND=1 bash "${FLEET_LAUNCHER:-$HOME/.claude/klepsydra-launch.sh}" new "$dir" </dev/null 2>&1 7>&- 8>&-); then
  flog ERROR "launch failed: the launcher refused" name="$name" said="$out"
  echo "launch failed: $out" # logcheck: ignore[stderr-for-errors] # the result line
  exit 1
fi
pane=$(comm -13 <(printf '%s\n' "$before") <(fleet_panes | sort) | grep . | head -1)
if [[ -z $pane ]]; then
  flog ERROR "launch failed: no new pane" name="$name"
  echo "no new pane" # logcheck: ignore[stderr-for-errors] # the result line
  exit 1
fi
# The resume service leaves a pane alone while its launch runs.
mkdir -p -- "$FLEET_STATE/launching"
marker=$FLEET_STATE/launching/$pane
: >"$marker"
# A mover (the resume service) keeps the mark until it is done with the pane.
[[ ${FLEET_KEEP_MARK:-0} == 1 ]] || trap 'rm -f -- "${marker:?}"' EXIT
trap 'exit 143' TERM INT
exec 8>&-
flog INFO "window opened" name="$name" pane="$pane" account="$account" voices="$voices" took_s="$(took)"
ready() { idle_empty "$1" || limit_line "$1" >/dev/null; }
if wait_for "$pane" "$(capped "${FLEET_READY_WAIT:-60}")" ready; then
  flog INFO "prompt showed" name="$name" pane="$pane" took_s="$(took)"
else
  flog WARN "the prompt never showed; trying anyway" name="$name" pane="$pane" took_s="$(took)"
fi
# Remote Control connects at startup, but the transcript records its link only
# after an explicit /remote-control; without it the phone wall shows no Open in
# Claude button. The brief waits until the command has settled, so the two
# never interleave (10-28: "SE/remote-control" typed into the prompt).
if remote_control "$pane"; then
  flog INFO "remote control on" name="$name" pane="$pane" took_s="$(took)"
else
  flog WARN "remote control did not settle before the brief" name="$name" pane="$pane" took_s="$(took)"
fi
brief=$(deliver "$pane" "$txt")
case $brief in
  started) flog INFO "brief delivered: a turn started" name="$name" pane="$pane" session_id="$sid" account="$account" took_s="$(took)" ;;
  blocked-by-limit) flog WARN "brief delivered, but the account is at its limit; the resume service takes it from here" name="$name" pane="$pane" session_id="$sid" account="$account" took_s="$(took)" ;;
  *) brief=NOT-DELIVERED; flog ERROR "brief not delivered" name="$name" pane="$pane" session_id="$sid" account="$account" took_s="$(took)" screen="$(screen "$pane" | plain | grep -v '^[[:space:]]*$' | tail -6)" ;;
esac

# The registry row for NAME, repointed at this pane and session; a new row when
# task-NAME.src exists. Other rows are kept as they are.
row_brief=$(awk -F'\t' -v n="$name" '$2 == n { print $3; exit }' "$REGISTRY" 2>/dev/null)
[[ -z $row_brief && -f $FLEET_STATE/task-$name.src ]] && row_brief=$FLEET_STATE/task-$name.src
exec 9>>"$FLEET_STATE/.registry.lock"
if ! flock -w 60 9; then
  flog ERROR "registry not updated: its lock was held for a minute" name="$name" pane="$pane" session_id="$sid"
  row_brief=""
fi
if [[ -n $row_brief ]]; then
  [[ -e $REGISTRY ]] || : >"$REGISTRY"
  tmp=$(mktemp "$REGISTRY.XXXXXX")
  awk -F'\t' -v OFS='\t' -v n="$name" -v row="$pane	$name	$row_brief	$sid	$dir	$account" '
    $2 == n { if (!done) print row; done = 1; next } { print } END { if (!done) print row }' "$REGISTRY" 2>/dev/null >"$tmp"
  mv -- "$tmp" "$REGISTRY"
fi
echo "pane=$pane session=$sid account=$account avail=${avail}MiB brief=$brief"
screen "$pane" | plain | grep -v '^[[:space:]]*$' | tail -6
