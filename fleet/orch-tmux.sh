#!/usr/bin/env bash
# orch-tmux.sh: the run-time half of the orchestrator guard (#264). Installed
# as $FLEET_STATE/orch-bin/tmux, first on PATH in the orchestrator's session
# only (launch.sh puts it there for heph). It reads tmux's real arguments,
# after the shell expanded them, at the moment of the send, so no shell
# grammar, wait or script stands between the check and the keys. It refuses:
#   cold-limit     keys or a paste into a pane that stopped at a usage limit
#                  FRESH_AFTER_S ago or more (fresh-now.sh relaunches it)
#   pending-input  keys into an input line that holds text the orchestrator
#                  did not type there in the last ORCH_GUARD_OWN_S seconds
#   hidden         a tmux command that runs other commands the guard cannot
#                  read: source-file, run-shell, if-shell, -C, -c, -f, and a
#                  new pane's shell command that calls tmux
# Commands are resolved as tmux resolves them (name, alias, unique prefix, from
# tmux list-commands) and their flags are read from tmux's own usage text. A
# refusal runs none of the invocation's commands, prints its reason and exits 1.
# Anything else, and every call from another pane or from a fleet script
# (fresh-now.sh, relaunch-fresh.sh, the resume service: a bash running a file
# in fleet/), goes straight to the real tmux. ORCH_GUARD_ALLOW=pending-input in
# the environment lets that guard pass, logged.
self=$(readlink -f "$0")
here=$(dirname "$self")
real=""
IFS=: read -ra path_dirs <<<"${PATH:-}"
for d in "${path_dirs[@]}"; do
  [[ -n $d && -x $d/tmux && $(readlink -f "$d/tmux") != "$self" ]] && { real=$d/tmux; break; }
done
[[ -n $real ]] || real=/usr/bin/tmux
pass() { exec "$real" "$@"; }

state=${FLEET_STATE:-$HOME/.local/state/fleet-orchestrator}
orch=""
{ read -r orch <"$state/orchestrator.pane"; } 2>/dev/null
[[ -n ${TMUX_PANE:-} && $TMUX_PANE == "$orch" ]] || pass "$@"

# A fleet script the orchestrator runs (fresh-now.sh, relaunch-fresh.sh, ...)
# sends with the fleet's own checks: a bash running a file in fleet/ between
# this call and the orchestrator's Claude Code process (where the walk stops,
# so nothing above the session counts). The fleet's test suites are no senders.
from_fleet_script() {
  local pid=$PPID n a f cwd
  local -a argv
  for n in 1 2 3 4 5 6 7 8 9 10; do
    [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )) || return 1
    mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || return 1
    a=${argv[0]##*/}
    [[ $a == claude || $a == node || ${argv[1]:-} == */claude ]] && return 1
    if [[ $a =~ ^(bash|sh)$ ]] && (( ${#argv[@]} > 1 )) && [[ ${argv[1]} != -* ]]; then
      f=${argv[1]}
      cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null)
      [[ $f == /* ]] || f=$cwd/$f
      f=$(readlink -f -- "$f" 2>/dev/null)
      [[ -n $f && ${f%/*} == "$here" && $f == *.sh && ${f##*/} != test_* ]] && return 0
    fi
    pid=$(awk '{ print $4 }' "/proc/$pid/stat" 2>/dev/null)
  done
  return 1
}
from_fleet_script && pass "$@"

# lib.sh (16 ms) loads only when a send is checked or a refusal logged.
loaded=0
need_lib() {
  (( loaded )) && return 0
  FLEET_TARGET=fleet::orch-tmux
  # shellcheck source=fleet/lib.sh
  . "$here/lib.sh" 2>/dev/null || return 1
  loaded=1
}
OWN_S=${ORCH_GUARD_OWN_S:-120}
glog() { need_lib && flog "$@" 2>/dev/null; }
refuse() { # GUARD REASON [KEY=VALUE...]
  local g=$1 r=$2
  shift 2
  glog WARN "orchestrator guard refused a tmux call" guard="$g" "$@" argv="${argv_text:0:300}"
  printf 'orch-guard (%s): %s\n' "$g" "$r" >&2
  exit 1
}
argv_text="$*"

# tmux's global options: -L and -S pick the server; -C, -c and -f run commands
# the guard never sees.
G=()
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  a=${args[i]}
  [[ $a == -* && $a != - && $a != -- ]] || break
  j=1
  while (( j < ${#a} )); do
    c=${a:j:1}
    case $c in
      L | S | c | f | T)
        v=${a:j+1}
        if [[ -z $v ]]; then i=$((i + 1)); v=${args[i]:-}; fi
        case $c in
          L | S) G=(-"$c" "$v") ;;
          c | f) [[ $c == f && $v == /dev/null ]] || refuse hidden "tmux -$c runs commands the guard cannot read; send keys with tmux send-keys -t PANE instead." option="-$c" ;;
        esac
        break
        ;;
      C) refuse hidden "tmux -C reads commands the guard cannot see; send keys with tmux send-keys -t PANE instead." option=-C ;;
    esac
    j=$((j + 1))
  done
  i=$((i + 1))
done
[[ ${args[i]:-} == -- ]] && i=$((i + 1))
(( i < ${#args[@]} )) || pass "$@"

# The command table: name, alias, usage, cached per tmux binary.
table=$state/guard/tmux-commands
stamp="$real $(stat -Lc '%Y %s' "$real" 2>/dev/null)"
if [[ $(head -1 "$table" 2>/dev/null) != "$stamp" ]]; then
  mkdir -p -- "$state/guard" 2>/dev/null
  { printf '%s\n' "$stamp"; "$real" -L "orch-guard-probe-$$" list-commands 2>/dev/null; } >"$table.$$" && mv -f -- "$table.$$" "$table"
fi
resolve() { # WORD: the command tmux runs for WORD, or nothing
  awk -v w="$1" 'NR > 1 {
      name = $1; alias = ($2 ~ /^\(.*\)$/) ? substr($2, 2, length($2) - 2) : ""
      if (w == name || w == alias) { exact = name }
      else if (index(name, w) == 1) { n++; pre = name }
    }
    END { if (exact != "") print exact; else if (n == 1) print pre }' "$table"
}
usage_of() { awk -v c="$1" 'NR > 1 && $1 == c { print; exit }' "$table"; }

# Each command of the sequence (split at ";" as tmux does); targets to check.
checks=() # "COMMAND TARGET"
cmd=()
flush() {
  (( ${#cmd[@]} )) || return 0
  local name usage valued k opt v target="" input=0 tail_args=()
  name=$(resolve "${cmd[0]}")
  if [[ -z $name ]]; then cmd=(); return 0; fi
  usage=$(usage_of "$name")
  valued=$(grep -oE '\[-[A-Za-z] [^]]+\]' <<<"$usage" | cut -c3 | tr -d '\n')
  k=1
  while (( k < ${#cmd[@]} )); do
    opt=${cmd[k]}
    [[ $opt == -- ]] && { k=$((k + 1)); break; }
    [[ $opt == -?* ]] || break
    local m=1
    while (( m < ${#opt} )); do
      c=${opt:m:1}
      if [[ $valued == *"$c"* ]]; then
        v=${opt:m+1}
        if [[ -z $v ]]; then k=$((k + 1)); v=${cmd[k]:-}; fi
        [[ $c == t ]] && target=$v
        break
      fi
      [[ $c == I ]] && input=1
      m=$((m + 1))
    done
    k=$((k + 1))
  done
  tail_args=("${cmd[@]:k}")
  case $name in
    send-keys | send-prefix | paste-buffer) checks+=("$name ${target:-${TMUX_PANE}}") ;;
    pipe-pane) (( input )) && checks+=("$name ${target:-${TMUX_PANE}}") ;;
    source-file | run-shell | if-shell)
      refuse hidden "tmux $name runs commands the guard cannot read; send keys with tmux send-keys -t PANE instead." command="$name" ;;
    new-window | split-window | respawn-pane | respawn-window | new-session)
      if [[ " ${tail_args[*]} " =~ (^|[^A-Za-z0-9_.-])tmux([^A-Za-z0-9_-]|$) ]]; then
        refuse hidden "tmux $name starts a shell command that calls tmux, which the guard cannot read; run that tmux command directly." command="$name"
      fi
      ;;
  esac
  cmd=()
}
for a in "${args[@]:i}"; do
  if [[ $a == ";" ]]; then flush
  elif [[ $a == *";" && $a != *'\;' ]]; then cmd+=("${a%;}"); flush
  else cmd+=("$a"); fi
done
flush
(( ${#checks[@]} )) || pass "$@"

need_lib || pass "$@"
now=$(clock)
t() { "$real" "${G[@]}" "$@"; }
typed=()
for ch in "${checks[@]}"; do
  name=${ch%% *} target=${ch#* }
  p=$(t display-message -p -t "$target" '#{pane_id}' 2>/dev/null)
  if [[ -z $p ]]; then
    glog INFO "orchestrator guard: the target is no pane tmux knows; passed to tmux" command="$name" target="$target"
    continue
  fi
  [[ ${ORCH_TMUX_TRACE:-} ]] && printf '%s\n' "$p" >>"$ORCH_TMUX_TRACE"
  [[ $p == "$orch" ]] && continue
  s=$(screen "$p")
  lim="" idle=""
  if lim=$(limit_line "$s"); then
    idle=$((now - $(stopped_at "$p" "$(plain <<<"$s")")))
    if (( idle >= FRESH_AFTER_S )); then
      refuse cold-limit "pane $p stopped at a usage limit $((idle / 60)) min ago (\"${lim#"${lim%%[![:space:]]*}"}\"). Its prompt cache lives an hour, so keys typed into it now re-cache its whole transcript: five such nudges took 38% of a five-hour window on 11-02. Relaunch it fresh from its brief instead: bash $state/fresh-now.sh $p" \
        pane="$p" command="$name" idle_min="$((idle / 60))" limit="$lim"
    fi
  fi
  box=$(input_text "$s")
  if [[ -n $box ]]; then
    own=""
    { read -r own <"$state/guard/typed-${p#%}"; } 2>/dev/null
    if [[ $own =~ ^[0-9]+$ ]] && (( now - own <= OWN_S )); then
      glog INFO "orchestrator guard: keys into a box holding the orchestrator's own text" pane="$p" typed_s_ago="$((now - own))"
    elif [[ ${ORCH_GUARD_ALLOW:-} == pending-input ]]; then
      glog WARN "orchestrator guard: keys into a box holding text, allowed by ORCH_GUARD_ALLOW" pane="$p" box="${box:0:200}"
    else
      refuse pending-input "pane $p's input line already holds text (\"${box:0:80}\"), typed by AJ (phone or terminal) or a report. Typing now merges your text into it (11-01 07:30). Wait until it is sent or cleared, then try again. If AJ asked you to replace it, run the command with ORCH_GUARD_ALLOW=pending-input in front." \
        pane="$p" box="${box:0:200}"
    fi
  else
    typed+=("$p")
  fi
  glog INFO "orchestrator guard: tmux send checked" pane="$p" command="$name" limit="${lim:+yes}" idle_min="${idle:+$((idle / 60))}" box_chars="${#box}"
done
# Every check passed: what this call types into an empty box is the
# orchestrator's own, so its follow-up Enter is no collision.
if (( ${#typed[@]} )) && mkdir -p -- "$state/guard" 2>/dev/null; then
  for p in "${typed[@]}"; do printf '%s\n' "$now" >"$state/guard/typed-${p#%}"; done
fi
pass "$@"
