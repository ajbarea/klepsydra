#!/usr/bin/env bash
# launch.sh NAME TEXTFILE [claude args...]: open a fleet tmux window running
# claude, with a session id of its own, inside a memory- and task-capped systemd
# scope in the fleet's slice, whose cap holds every scope's total (#353): a
# runaway test or build is killed there instead of freezing WSL, and claude,
# ranked last for the OOM killer, outlives it (lib.sh, oom-tool.sh); turn
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
# The subagent cap enforces the briefs' rule of at most two at a time.
# FLEET_SETTINGS="" starts it without them (the orchestrator, fleet recover).
# Who speaks is keryx's own setting, which `fleet voices` keeps in line with
# the tray's Voices mode for running sessions too (#273), so no session is
# started with KERYX_ENABLED.
settings=${FLEET_SETTINGS-$FLEET_STATE/worker-settings.json}
# KLEPSYDRA_AGENT names the session's agent to the fleet hook, so its card keeps
# its face across relaunches (#172).
# No KERYX_ENABLED from the tmux server's environment either (a server started
# from a session with keryx off would pass it on and outrank keryx's setting).
# FLEET_SUCCEEDS (a session id) names the orchestrator a move replaces (#226).
# KLEPSYDRA_WORKER marks a session started with worker settings, so start-up
# hooks meant for the orchestrator (the stale-PR list) skip it (#309).
# Subscription only (#260): an interactive session never starts on an API
# credential. A key, token or named profile in this environment is dropped
# (NO_KEY_ENV), and a config folder or settings that set one are refused, since
# a session on a key loses the claude.ai login, its connectors and Remote
# Control, and the promotional credit does not cover interactive use (#241).
for s in "$account/settings.json" ${settings:+"$settings"}; do
  if key_settings "$s"; then
    flog ERROR "launch refused: its settings hold an API key helper or key; interactive sessions run on the subscription only (fleet headless runs key jobs)" name="$name" settings="$s"
    echo "launch refused: $s sets an API credential" # logcheck: ignore[stderr-for-errors] # the result line
    exit 2
  fi
done
prev=""
for a in "$@"; do
  v=""
  [[ $prev == --settings ]] && v=$a
  [[ $a == --settings=* ]] && v=${a#--settings=}
  if [[ -n $v ]] && key_settings "$v"; then
    flog ERROR "launch refused: --settings holds an API key helper or key" name="$name"
    echo "launch refused: --settings sets an API credential" # logcheck: ignore[stderr-for-errors] # the result line
    exit 2
  fi
  prev=$a
done
succeeds=""
[[ ${FLEET_SUCCEEDS:-} =~ ^[0-9a-f-]{36}$ ]] && succeeds="KLEPSYDRA_SUCCEEDS=$FLEET_SUCCEEDS "
cmd="$(fleet_oom_floor)env ${NO_KEY_ENV}-u KERYX_ENABLED -u KLEPSYDRA_WORKER $(config_env "$account")$(fleet_oom_env)KLEPSYDRA_AGENT=$(printf '%q' "$name") ${succeeds}${settings:+KLEPSYDRA_WORKER=1 }CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=2 ${FLEET_CLAUDE:-claude} --session-id $sid${settings:+ --settings $(printf '%q' "$settings")} $*"
tmax="" role=""
if [[ ${FLEET_SCOPE:-1} != 0 ]]; then
  # A task cap of its own (#289): inherited, it was DefaultTasksMax, and on
  # 11-03 one worker's scope filled it and its claude aborted.
  tasks=""
  if tmax=$(fleet_tasks_max); then
    tasks="-p TasksMax=$tmax "
  else
    flog WARN "no task cap readable; the scope inherits DefaultTasksMax" name="$name"
  fi
  # The orchestrator (launched under FLEET_ORCH_NAME, as doctor and the fleet
  # hook know it) sits in the fleet's slice beside the workers' (#353). No
  # MemoryHigh: past it the kernel throttles the scope, claude too, and never
  # kills (11-11: a worker froze there, load 110).
  role=worker
  [[ $name == "$FLEET_ORCH_NAME" ]] && role=orchestrator
  cmd="${FLEET_SYSTEMD_RUN:-systemd-run} --user --scope --collect --unit=fleet-$name-$(date +%s) $(fleet_slice_opts "$role") -p MemoryMax=${MEM_MAX:-5G} -p MemorySwapMax=${MEM_SWAP:-1G} ${tasks}$cmd"
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
# Every fleet launch opens behind the window in view (#216). Its caller brings
# a replacement forward only where AJ was watching the window it replaces
# (fresh, heph_move, relaunch-fresh) or nothing has moved since a cold recover.
# No stdin for the launcher: a caller reading a list on it would lose the rest (#242).
# Nor this launch's own FLEET_* settings: a tmux server the launcher starts copies
# its environment into every later pane, so Heph's FLEET_SETTINGS='' would start
# each worker after him unmarked, on his account (#310 review 1).
if ! out=$(cd ~ && env -u FLEET_SETTINGS -u FLEET_ACCOUNT -u FLEET_SUCCEEDS KLEPSYDRA_CLAUDE="$cmd" KLEPSYDRA_TMUX_SOCKET="$FLEET_SOCK" KLEPSYDRA_BACKGROUND=1 bash "${FLEET_LAUNCHER:-$HOME/.claude/klepsydra-launch.sh}" new "$dir" </dev/null 2>&1 7>&- 8>&-); then
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
flog INFO "window opened" name="$name" pane="$pane" account="$account" tasks_max="${tmax:-none}" slice="${role:-none}" took_s="$(took)"
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
