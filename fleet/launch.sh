#!/usr/bin/env bash
# launch.sh NAME TEXTFILE [claude args...]: open a fleet tmux window running
# claude, with a session id of its own, inside a memory-capped systemd scope
# (a runaway test or build is OOM-killed there instead of freezing WSL); turn
# Remote Control on and wait for it to settle; then paste TEXTFILE, check it
# reached the prompt, and submit it. A retry never sends Escape, so it cannot
# cancel a turn that started. Registers the pane, session and folder in
# panes.tsv for NAME when NAME is a fleet agent (a row exists, or task-NAME.src).
# The session runs on FLEET_ACCOUNT's config folder when set, else on the
# logged-in account with the most room (best_account).
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
# Workers bypass permissions and Heph does not, so Heph's SendMessage would wait
# for AJ's approval; worker-settings.json accepts it (AJ approved 2026-10-27).
# The subagent cap enforces the briefs' rule of at most two at a time.
cmd="env $(config_env "$account")CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=2 ${FLEET_CLAUDE:-claude} --session-id $sid --settings $FLEET_STATE/worker-settings.json $*"
if [[ ${FLEET_SCOPE:-1} != 0 ]]; then
  cmd="systemd-run --user --scope --collect --unit=fleet-$name-$(date +%s) -p MemoryHigh=${MEM_HIGH:-4G} -p MemoryMax=${MEM_MAX:-5G} -p MemorySwapMax=${MEM_SWAP:-1G} $cmd"
fi
exec 8>>"$FLEET_STATE/.launch.lock"
flock -w 600 8 || { flog ERROR "launch held: another launch kept the lock for 10 min" name="$name"; exit 1; }
before=$(fleet_panes | sort)
if ! out=$(cd ~ && KLEPSYDRA_CLAUDE="$cmd" KLEPSYDRA_TMUX_SOCKET="$FLEET_SOCK" bash "${FLEET_LAUNCHER:-$HOME/.claude/klepsydra-launch.sh}" new "$dir" 2>&1 7>&- 8>&-); then
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
ready() { idle_empty "$1" || limit_line "$1" >/dev/null; }
wait_for "$pane" "${FLEET_READY_WAIT:-120}" ready || flog WARN "the prompt never showed; trying anyway" name="$name" pane="$pane"
# Remote Control connects at startup, but the transcript records its link only
# after an explicit /remote-control; without it the phone wall shows no Open in
# Claude button. The brief waits until the command has settled, so the two
# never interleave (10-28: "SE/remote-control" typed into the prompt).
if remote_control "$pane"; then
  flog INFO "remote control on" name="$name" pane="$pane"
else
  flog WARN "remote control did not settle before the brief" name="$name" pane="$pane"
fi
brief=$(deliver "$pane" "$txt")
case $brief in
  started) flog INFO "brief delivered: a turn started" name="$name" pane="$pane" session_id="$sid" account="$account" ;;
  blocked-by-limit) flog WARN "brief delivered, but the account is at its limit; the resume service takes it from here" name="$name" pane="$pane" session_id="$sid" account="$account" ;;
  *) brief=NOT-DELIVERED; flog ERROR "brief not delivered" name="$name" pane="$pane" session_id="$sid" account="$account" screen="$(screen "$pane" | plain | grep -v '^[[:space:]]*$' | tail -6)" ;;
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
