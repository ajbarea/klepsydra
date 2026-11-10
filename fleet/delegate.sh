#!/usr/bin/env bash
# delegate.sh (`fleet delegate`): hand read-only research, drafts, a first-pass
# PR review or CI triage to another engine (Antigravity's agy, GitHub's
# Copilot) so the orchestrator's Claude quota goes to orchestration, final
# review and anything entering a paper or a team repo.
#
#   fleet delegate [--engine auto|agy|copilot] [--kind research|draft|review|ci]
#                  [--model M] [--dir REPO] [--timeout S] [--notify PANE]
#                  [--interactive] TASK-FILE
#   fleet delegate msg ID TEXT     a follow-up to an interactive lane (TEXT - reads stdin)
#   fleet delegate read ID         the lane's latest answer
#   fleet delegate stop ID         end the lane, remove its snapshot
#   fleet delegate ls              the lanes and their state
#
# Print mode (default) runs one locked, timed, memory-capped one-shot and prints
# one line: engine, model, status, path. `auto` falls back to the other engine
# on a quota, limit or auth failure and never to Claude: with both out the line
# says so and the orchestrator decides. --interactive opens a locked window of
# tmux session "engines" on the fleet's server, sends the task, and a watcher
# outside the model detects each turn's end (or a limit, timeout, or the window
# gone), saves the answer and tells the orchestrator through `fleet send`, so a
# locked engine never needs write or shell access to report back.
# The engine gets a read-only snapshot of the repo's committed files with
# secret-looking files removed, never the working tree. Every answer is stamped
# an unverified lead. Docs: docs/engines.md.
set -u
FLEET_TARGET=fleet::delegate
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
# shellcheck source=fleet/engines.sh
. "$here/engines.sh"

DEL_ROOT=$FLEET_STATE/delegate
ENG_SESSION=engines
SEND=${FLEET_SEND_CMD:-$here/send.sh}
TASK_MAX=${FLEET_DELEGATE_TASK_MAX:-65536}  # bytes of task text
SNAP_MAX_MB=${FLEET_DELEGATE_SNAP_MB:-300}  # a snapshot over this is refused
PRINT_TIMEOUT=${FLEET_DELEGATE_TIMEOUT:-600}
TURN_TIMEOUT=${FLEET_DELEGATE_TURN_TIMEOUT:-900}
POLL=${FLEET_DELEGATE_POLL:-2}
# Files that look like secrets never reach an engine, tracked or not.
SECRET_FILES=(-name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' -o -name 'id_rsa*' -o -name 'id_ed25519*'
  -o -name '.netrc' -o -name '.npmrc' -o -name '.pypirc' -o -name 'credentials*' -o -name '*.kdbx' -o -name 'secrets*' -o -name '.git-credentials')

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { err "$*"; exit 2; }

# A scope with a memory and task cap around a command, as launch.sh gives a
# worker; FLEET_SYSTEMD_RUN=none runs it bare (the suite, a box with no user manager).
scoped() { # NAME CMD...
  local name=$1 run=${FLEET_SYSTEMD_RUN:-systemd-run}
  shift
  if [[ $run == none ]] || ! command -v "$run" >/dev/null 2>&1; then "$@"; return; fi
  "$run" --user --scope --collect -q --unit="fleet-delegate-$name-$(date +%s)" \
    -p MemoryHigh="${FLEET_DELEGATE_MEM_HIGH:-2G}" -p MemoryMax="${FLEET_DELEGATE_MEM_MAX:-3G}" -p MemorySwapMax=0 -p TasksMax=256 "$@"
}

new_id() { printf '%s-%s' "$(date +%m%d-%H%M%S)" "$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"; }

valid_id() { [[ $1 =~ ^[0-9]{4}-[0-9]{6}-[0-9a-f]{4}$ && -d $DEL_ROOT/$1 ]]; }

meta_set() { # ID KEY=VALUE...: merge string fields into meta.json
  local id=$1 kv f=$DEL_ROOT/$1/meta.json
  shift
  local -a a=()
  for kv in "$@"; do a+=(--arg "${kv%%=*}" "${kv#*=}"); done
  [[ -f $f ]] || echo '{}' >"$f"
  jq -c "${a[@]}" '. + $ARGS.named' "$f" >"$f.tmp" && mv -f -- "$f.tmp" "$f"
}
meta_get() { jq -r --arg k "$2" '.[$k] // empty' "$DEL_ROOT/$1/meta.json" 2>/dev/null; } # ID KEY

# A read-only copy of REPO's committed files without anything secret-looking, in
# SNAP, with TASK-FILE as TASK.md and the helper rules in AGENTS.md. The working
# tree is never exposed: .env files are usually untracked, and a tracked one
# is filtered out anyway.
snapshot() { # REPO TASK SNAP SUBDIR-OUT
  local repo=$1 task=$2 snap=$3 top mb
  top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || { err "$repo is not inside a git repository"; return 1; }
  [[ $top != "$HOME" && $top != / ]] || { err "refusing to snapshot $top"; return 1; }
  mkdir -p -- "$snap" || return 1
  timeout 120 git -C "$top" archive --format=tar HEAD | tar -x -C "$snap" 2>/dev/null || { err "git archive of $top failed"; return 1; }
  # A tracked symlink can point at a file outside the snapshot, which a read tool follows.
  find "$snap" -type l -delete 2>/dev/null
  find "$snap" -depth \( "${SECRET_FILES[@]}" \) ! -name '.env.example' ! -name '.env.sample' -delete 2>/dev/null
  mb=$(du -sm -- "$snap" | cut -f1)
  (( mb <= SNAP_MAX_MB )) || { err "the snapshot of $top is ${mb} MB, over the ${SNAP_MAX_MB} MB limit"; return 1; }
  if ! { { if [[ -f $snap/AGENTS.md ]]; then cat -- "$snap/AGENTS.md"; printf '\n\n'; fi
           cat -- "${FLEET_ENGINE_RULES:-$FLEET_HOOK_DIR/klepsydra-engine-rules.md}"; } >"$snap/AGENTS.md.new" 2>/dev/null &&
         mv -f -- "$snap/AGENTS.md.new" "$snap/AGENTS.md"; }; then
    err "the helper rules cannot be read"; return 1
  fi
  cp -- "$task" "$snap/TASK.md" || return 1
  local rel=${repo#"$top"}
  printf '%s' "${rel#/}" >"$snap/.klepsydra-subdir"
  chmod -R a-w -- "$snap"
}
drop_snapshot() { # DIR (a snapshot is read-only; it is made writable only to be removed)
  [[ -n ${1:-} && $1 == "$DEL_ROOT"/*/work && $1 != *..* ]] || return 0
  chmod -R u+w -- "$1" 2>/dev/null
  rm -rf -- "${1:?}"
}

stamp() { # ENGINE MODEL: the header of every answer
  printf '> Unverified lead from %s (%s) on %s. Read-only helper: check what you use against the source.\n\n' "$1" "$2" "$(date '+%F %T')"
}

# The one line a caller reads.
report() { # ID ENGINE MODEL STATUS PATH [NOTE]
  printf 'engine=%s model=%s status=%s path=%s id=%s%s\n' "$2" "$3" "$4" "$5" "$1" "${6:+ note=$6}"
}

notify() { # ID TEXT: tell the orchestrator (or the pane that asked) through fleet send
  local id=$1 pane got
  pane=$(meta_get "$id" notify)
  [[ -n $pane ]] || return 0
  got=$("$SEND" "$pane" - <<<"$2" 2>/dev/null) || true
  meta_set "$id" notified="${got:-failed}"
  flog INFO "delegate notified" id="$id" pane="$pane" result="${got:-failed}"
}

# Where a notification goes: the pane that asked if it is on the fleet's tmux
# server, else the orchestrator's.
notify_target() { # EXPLICIT
  if [[ -n $1 ]]; then printf '%s' "$1"; return; fi
  if [[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] && fleet_socket "${TMUX%%,*}"; then printf '%s' "$TMUX_PANE"; return; fi
  orchestrator
}

# ---- print mode -----------------------------------------------------------

run_print() { # ID ENGINE MODEL KIND SNAP TIMEOUT  -> sets RUN_STATUS, RUN_TEXT
  local id=$1 engine=$2 model=$3 kind=$4 snap=$5 timeout=$6 dir=$DEL_ROOT/$1 settings="" rc
  local prompt="Read TASK.md in the working folder and carry it out. Follow AGENTS.md."
  if [[ $engine == agy ]]; then
    settings=$dir/agy-settings.json
    eng_settings "$kind" "$snap" "$settings" || { RUN_STATUS=error RUN_TEXT="the lock policy ($ENG_LOCK) cannot be read; nothing was started"; return; }
  fi
  eng_argv "$engine" print "$model" "$kind" "$settings" "$prompt" || { RUN_STATUS=error RUN_TEXT="no print lane for $engine"; return; }
  (cd "$snap" && scoped "$id" timeout -k 10 "$timeout" "${ENG_ARGV[@]}" </dev/null >"$dir/$engine.out" 2>"$dir/$engine.err")
  rc=$?
  RUN_TEXT=$(head -c "${FLEET_DELEGATE_OUT_MAX:-1048576}" "$dir/$engine.out" 2>/dev/null)
  if (( rc == 124 || rc == 137 )); then RUN_STATUS=timeout; return; fi
  RUN_STATUS=$(eng_classify "$rc" "$RUN_TEXT" "$(head -c 4000 "$dir/$engine.err" 2>/dev/null)")
}

cmd_print() { # args after option parsing
  local id dir snap engine model kind order e t0 status="" text="" used="" note=""
  id=$(new_id) kind=$KIND
  dir=$DEL_ROOT/$id snap=$DEL_ROOT/$id/work
  mkdir -p -- "$dir" || die "cannot write in $DEL_ROOT"
  meta_set "$id" kind="$kind" mode=print dir="$REPO" notify="$NOTIFY"
  snapshot "$REPO" "$TASK" "$snap" || { flog WARN "delegate refused" id="$id" why="snapshot"; drop_snapshot "$snap"; report "$id" - - refused "$dir" "snapshot"; return 1; }
  if [[ $ENGINE == auto ]]; then order=$(eng_order "$kind"); else order=$ENGINE; fi
  t0=$SECONDS
  for e in $order; do
    eng_can "$e" print || continue
    eng_has "$e" || { note+="$e:missing,"; continue; }
    model=${MODEL:-$(eng_model "$e" "$kind")}
    run_print "$id" "$e" "$model" "$kind" "$snap" "$TIMEOUT"
    status=$RUN_STATUS text=$RUN_TEXT used=$e
    note+="$e:$status,"
    [[ $ENGINE == auto && ( $status == limit || $status == auth ) ]] && continue
    break
  done
  drop_snapshot "$snap"
  if [[ -z $used ]]; then
    flog WARN "delegate: no engine available" id="$id" kind="$kind" note="$note"
    report "$id" - - unavailable "$dir" "${note:-none}"
    return 3
  fi
  local out=$dir/answer.md
  if [[ $status == ok ]]; then
    { stamp "$used" "$model"; printf '%s\n' "$text"; } >"$out"
  else
    { stamp "$used" "$model"; printf 'No answer: %s.\n' "$status"; [[ -s $dir/$used.err ]] && { printf '\n```\n'; head -c 2000 "$dir/$used.err"; printf '\n```\n'; }; } >"$out"
  fi
  # Both engines out: say so, never fall to Claude.
  if [[ $ENGINE == auto && ( $status == limit || $status == auth ) ]]; then status="both-out"; fi
  meta_set "$id" engine="$used" model="$model" status="$status" secs="$((SECONDS - t0))" tried="${note%,}"
  flog INFO "delegate call" id="$id" engine="$used" model="$model" kind="$kind" mode=print status="$status" secs="$((SECONDS - t0))" path="$out"
  report "$id" "$used" "$model" "$status" "$out" "${note%,}"
  [[ -n $NOTIFY ]] && notify "$id" "[fleet delegate] $id engine=$used status=$status answer=$out (an unverified lead: read it, verify what you use)"
  [[ $status == ok ]]
}

# ---- interactive lanes ----------------------------------------------------

pane_screen() { t capture-pane -p -J -S -3000 -t "$1" 2>/dev/null; }
pane_alive() { [[ $(t display-message -p -t "$1" '#{pane_id}' 2>/dev/null) == "$1" ]]; }

# Paste TEXT into PANE as a bracketed paste, then Enter, and confirm the engine
# started a turn; one more Enter if it did not. Only into an idle prompt.
deliver() { # ENGINE PANE TEXT
  local engine=$1 pane=$2 text=$3 f st
  st=$(eng_state "$engine" "$(pane_screen "$pane")")
  [[ $st == idle ]] || { echo "not-idle:$st"; return 1; }
  f=$(mktemp "$FLEET_STATE/send/dlg-XXXXXX" 2>/dev/null || mktemp) || return 1
  printf '%s' "$text" >"$f"
  t load-buffer -b "dlg$$" "$f" && t paste-buffer -p -d -b "dlg$$" -t "$pane"
  rm -f -- "${f:?}"
  sleep 0.5
  local pre now
  for _ in 1 2; do
    pre=$(pane_screen "$pane")
    t send-keys -t "$pane" Enter
    for _ in $(seq 20); do
      sleep 0.5
      now=$(pane_screen "$pane")
      st=$(eng_state "$engine" "$now")
      # Sent: the turn shows busy, or a reply so quick it never did has changed the screen.
      if [[ $st == busy ]] || { [[ $st == idle || $st == limit ]] && [[ $now != "$pre" ]]; }; then echo sent; return 0; fi
    done
  done
  echo not-delivered
  return 1
}

cmd_interactive() {
  local id dir snap engine model kind order e pane name settings st=""
  id=$(new_id) kind=$KIND
  dir=$DEL_ROOT/$id snap=$DEL_ROOT/$id/work
  mkdir -p -- "$dir" "$FLEET_STATE/send" || die "cannot write in $DEL_ROOT"
  if [[ $ENGINE == auto ]]; then order=$(eng_order "$kind"); else order=$ENGINE; fi
  engine=""
  for e in $order; do eng_can "$e" interactive && eng_has "$e" && { engine=$e; break; }; done
  [[ -n $engine ]] || { report "$id" - - unavailable "$dir" "no interactive lane for: $order"; return 3; }
  model=${MODEL:-$(eng_model "$engine" "$kind")}
  meta_set "$id" kind="$kind" mode=interactive dir="$REPO" engine="$engine" model="$model" status=starting notify="$(notify_target "$NOTIFY")"
  snapshot "$REPO" "$TASK" "$snap" || { drop_snapshot "$snap"; report "$id" - - refused "$dir" snapshot; return 1; }
  settings=$dir/agy-settings.json
  eng_settings "$kind" "$snap" "$settings" || { drop_snapshot "$snap"; report "$id" "$engine" "$model" refused "$dir" "lock policy unreadable"; return 1; }
  eng_argv "$engine" interactive "$model" "$kind" "$settings" "" || { drop_snapshot "$snap"; return 1; }
  name=eng-$engine-$id
  local cmd
  printf -v cmd '%q ' "${ENG_ARGV[@]}"
  if t has-session -t "=$ENG_SESSION" 2>/dev/null; then
    pane=$(t new-window -d -P -F '#{pane_id}' -t "=$ENG_SESSION:" -n "$name" -c "$snap" "$cmd")
  else
    pane=$(t new-session -d -P -F '#{pane_id}' -s "$ENG_SESSION" -n "$name" -c "$snap" "$cmd")
  fi
  t resize-window -t "$pane" -x 200 -y 50 2>/dev/null
  [[ $pane =~ ^%[0-9]+$ ]] || { drop_snapshot "$snap"; report "$id" "$engine" "$model" error "$dir" "tmux could not open a window"; return 1; }
  meta_set "$id" pane="$pane" window="$name"
  # The engine's prompt must show before the task goes in.
  local trusted=0
  for _ in $(seq 60); do
    st=$(eng_state "$engine" "$(pane_screen "$pane")")
    if [[ $st == trust ]] && (( ! trusted )); then t send-keys -t "$pane" "$(eng_trust_key "$engine")"; trusted=1; fi
    [[ $st == idle || $st == limit || $st == auth ]] && break
    sleep 1
  done
  if [[ $st != idle ]]; then
    meta_set "$id" status="$st"
    pane_screen "$pane" >"$dir/screen.txt"
    flog WARN "delegate: lane did not reach its prompt" id="$id" engine="$engine" state="$st"
    t kill-window -t "$pane" 2>/dev/null; drop_snapshot "$snap"
    report "$id" "$engine" "$model" "${st/unknown/error}" "$dir/screen.txt"
    return 1
  fi
  deliver "$engine" "$pane" "Read TASK.md in the working folder and carry it out. Follow AGENTS.md." >"$dir/deliver.txt" || {
    meta_set "$id" status=not-delivered; t kill-window -t "$pane" 2>/dev/null; drop_snapshot "$snap"
    report "$id" "$engine" "$model" not-delivered "$dir"; return 1; }
  meta_set "$id" status=working turn=0
  flog INFO "delegate lane started" id="$id" engine="$engine" model="$model" kind="$kind" pane="$pane" window="$name"
  start_watcher "$id"
  report "$id" "$engine" "$model" working "$dir/answer.md" "pane=$pane window=$name"
}

start_watcher() { # ID
  local id=$1
  # The watcher outlives this call: its own session, no inherited descriptor but stderr.
  setsid nohup bash "$here/delegate.sh" __watch "$id" </dev/null >>"$DEL_ROOT/$id/watch.log" 2>&1 &
  echo $! >"$DEL_ROOT/$id/watch.pid"
}

# The watcher: one pass every POLL seconds until the lane ends. A turn ends when
# the engine is idle again after a busy spell; a limit, a timeout or a closed
# window ends the watch (the lane stays for the orchestrator to read or stop).
cmd_watch() { # ID
  # Started right after a prompt went in (deliver saw the turn begin), so a reply
  # that finished before the first poll is still a turn end: seen_busy starts at 1.
  local id=$1 pane engine st seen_busy=1 turn started screen ans dir=$DEL_ROOT/$1
  pane=$(meta_get "$id" pane) engine=$(meta_get "$id" engine)
  turn=$(meta_get "$id" turn); turn=${turn:-0}
  started=$SECONDS
  FLEET_TARGET=fleet::delegate-watch
  while :; do
    sleep "$POLL"
    if ! pane_alive "$pane"; then
      meta_set "$id" status=gone
      flog WARN "delegate lane gone" id="$id" engine="$engine"
      notify "$id" "[fleet delegate] $id engine=$engine status=gone: the window closed (answer so far: $dir/answer.md)"
      return 0
    fi
    screen=$(pane_screen "$pane")
    st=$(eng_state "$engine" "$screen")
    case $st in
      busy) seen_busy=1 ;;
      limit | auth)
        printf '%s\n' "$screen" >"$dir/screen.txt"
        meta_set "$id" status="$st"
        flog WARN "delegate lane stopped on a limit" id="$id" engine="$engine" state="$st"
        notify "$id" "[fleet delegate] $id engine=$engine status=$st: the lane stopped (screen: $dir/screen.txt). Re-run with the other engine."
        return 0 ;;
      idle)
        if (( seen_busy )); then
          turn=$((turn + 1))
          ans=$(eng_answer "$engine" "$screen")
          { stamp "$engine" "$(meta_get "$id" model)"; printf '%s\n' "$ans"; } >"$dir/answer-$turn.md"
          cp -f -- "$dir/answer-$turn.md" "$dir/answer.md"
          printf '%s\n' "$screen" >"$dir/screen.txt"
          meta_set "$id" status=idle turn="$turn"
          flog INFO "delegate turn done" id="$id" engine="$engine" turn="$turn" path="$dir/answer.md"
          notify "$id" "[fleet delegate] $id engine=$engine status=ok turn=$turn answer=$dir/answer.md (an unverified lead: read it, verify what you use; follow up: fleet delegate msg $id TEXT)"
          return 0
        fi ;;
    esac
    if (( SECONDS - started > TURN_TIMEOUT )); then
      t send-keys -t "$pane" Escape 2>/dev/null
      printf '%s\n' "$screen" >"$dir/screen.txt"
      meta_set "$id" status=timeout
      flog WARN "delegate lane timed out" id="$id" engine="$engine" secs="$((SECONDS - started))"
      notify "$id" "[fleet delegate] $id engine=$engine status=timeout after ${TURN_TIMEOUT}s (screen: $dir/screen.txt)"
      return 0
    fi
  done
}

cmd_msg() { # ID TEXT
  local id=$1 text engine pane got
  shift
  valid_id "$id" || die "no lane $id"
  if [[ ${1:-} == - && $# -eq 1 ]]; then text=$(cat); else text="$*"; fi
  [[ -n ${text//[[:space:]]/} ]] || die "nothing to send"
  pane=$(meta_get "$id" pane) engine=$(meta_get "$id" engine)
  if [[ -z $pane ]] || ! pane_alive "$pane"; then echo gone; return 1; fi
  got=$(deliver "$engine" "$pane" "$text") || { echo "$got"; return 1; }
  meta_set "$id" status=working
  start_watcher "$id"
  echo sent
}

cmd_read() { # ID
  valid_id "$1" || die "no lane $1"
  if [[ -f $DEL_ROOT/$1/answer.md ]]; then cat -- "$DEL_ROOT/$1/answer.md"; else echo "no answer yet ($(meta_get "$1" status))"; return 1; fi
}

cmd_stop() { # ID
  local id=$1 pane wpid
  valid_id "$id" || die "no lane $id"
  wpid=$(cat "$DEL_ROOT/$id/watch.pid" 2>/dev/null)
  [[ $wpid =~ ^[0-9]+$ ]] && kill "$wpid" 2>/dev/null
  pane=$(meta_get "$id" pane)
  [[ -n $pane ]] && pane_alive "$pane" && t kill-window -t "$pane" 2>/dev/null
  drop_snapshot "$DEL_ROOT/$id/work"
  meta_set "$id" status=stopped
  flog INFO "delegate lane stopped by request" id="$id"
  echo stopped
}

cmd_ls() {
  local m id
  for m in "$DEL_ROOT"/*/meta.json; do
    [[ -f $m ]] || continue
    id=${m%/meta.json}; id=${id##*/}
    jq -r --arg id "$id" '"\($id) \(.mode // "?") \(.engine // "-") \(.model // "-") \(.status // "?") turn=\(.turn // 0)"' "$m"
  done
}

# ---- entry ----------------------------------------------------------------

sub=${1:-}
case $sub in
  msg) shift; (( $# >= 2 )) || die "usage: fleet delegate msg ID TEXT"; cmd_msg "$@"; exit ;;
  read) shift; (( $# == 1 )) || die "usage: fleet delegate read ID"; cmd_read "$1"; exit ;;
  stop) shift; (( $# == 1 )) || die "usage: fleet delegate stop ID"; cmd_stop "$1"; exit ;;
  ls) cmd_ls; exit ;;
  __watch) shift; valid_id "${1:-}" || exit 2; cmd_watch "$1"; exit ;;
  -h | --help | help) usage; exit 0 ;;
esac

ENGINE=auto KIND=research MODEL="" REPO=$PWD TIMEOUT=$PRINT_TIMEOUT NOTIFY="" INTERACTIVE=0 TASK=""
while (( $# )); do
  case $1 in
    --engine) ENGINE=${2:-}; shift 2 || die "--engine needs a value" ;;
    --kind) KIND=${2:-}; shift 2 || die "--kind needs a value" ;;
    --model) MODEL=${2:-}; shift 2 || die "--model needs a value" ;;
    --dir) REPO=${2:-}; shift 2 || die "--dir needs a value" ;;
    --timeout) TIMEOUT=${2:-}; shift 2 || die "--timeout needs a value" ;;
    --notify) NOTIFY=${2:-}; shift 2 || die "--notify needs a value" ;;
    --interactive) INTERACTIVE=1; shift ;;
    -*) die "unknown option $1 (fleet delegate --help)" ;;
    *) [[ -z $TASK ]] || die "one task file only"; TASK=$1; shift ;;
  esac
done
[[ $ENGINE == auto || $ENGINE == agy || $ENGINE == copilot ]] || die "--engine is auto, agy or copilot"
[[ $KIND =~ ^(research|draft|review|ci)$ ]] || die "--kind is research, draft, review or ci"
[[ -z $MODEL || $MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "that is not a model id: $MODEL"
[[ $TIMEOUT =~ ^[1-9][0-9]{0,4}$ ]] || die "--timeout is seconds"
[[ -z $NOTIFY || $NOTIFY =~ ^%[0-9]+$ ]] || die "--notify is a pane (%N)"
[[ -n $TASK ]] || { usage >&2; exit 2; }
[[ -f $TASK && -r $TASK ]] || die "no task file $TASK"
(( $(stat -c %s -- "$TASK") <= TASK_MAX )) || die "the task file is over $TASK_MAX bytes"
[[ -d $REPO ]] || die "no folder $REPO"
REPO=$(cd "$REPO" && pwd -P)
# The task goes to another vendor's service: a file that looks like a secret is refused.
if grep -Eq -- '(AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{30,}|(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' "$TASK"; then
  die "the task file holds what looks like a secret; nothing was sent"
fi

avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
if (( avail < ${FLEET_MIN_AVAIL_MB:-3000} )); then
  flog WARN "delegate held: too little memory" avail_mb="$avail"
  echo "HOLD: only ${avail} MiB available" # logcheck: ignore[stderr-for-errors] # the result line callers read; flog has it on stderr
  exit 2
fi

if (( INTERACTIVE )); then cmd_interactive; else cmd_print; fi
