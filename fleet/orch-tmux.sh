#!/usr/bin/env bash
# orch-tmux.sh: the run-time half of the orchestrator guard (#264). Installed
# as $FLEET_STATE/orch-bin/tmux, ahead of the real tmux on PATH in the
# orchestrator's session only (launch.sh puts it there for heph). It reads
# tmux's real arguments, after the shell expanded them, at the moment of the
# call, so no shell grammar, wait or script stands between the check and the
# keys. In the orchestrator's session it runs only a known set of commands
# (ALLOWED), and refuses:
#   cold-limit     keys or a paste into a pane that stopped at a usage limit
#                  FRESH_AFTER_S ago or more (fresh-now.sh relaunches it)
#   pending-input  keys into an input line holding anything but the exact text
#                  the orchestrator typed there in the last ORCH_GUARD_OWN_S seconds
#   hidden         any other command, a #() format (it runs a shell), and the
#                  -C, -c and -f options: each can run commands the guard never reads
# The session is the orchestrator's when its Claude Code process (the nearest
# claude ancestor) runs in orchestrator.pane, read from that process's own
# environment, which no child can change. Commands resolve as tmux resolves
# them (name, alias, unique prefix, from tmux list-commands), and flags are read
# from tmux's usage text. A refusal runs none of the invocation's commands,
# prints its reason and exits 1. Calls from other sessions, from no Claude Code
# session, and from a fleet script (a bash running a file in fleet/:
# fresh-now.sh, relaunch-fresh.sh, the resume service) go straight to tmux.
# ORCH_GUARD_ALLOW=pending-input in the environment lets that guard pass, logged.
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
[[ -n $orch ]] || pass "$@"

# Walk up to the nearest Claude Code process: a fleet script on the way sends
# with the fleet's own checks; the session is the orchestrator's when that
# process runs in orchestrator.pane. The fleet's test suites are no senders.
whose() {
  local pid=$PPID n a f cwd p
  local -a argv
  for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )) || return 1
    mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || return 1
    a=${argv[0]##*/}
    if [[ $a == claude || ( $a == node && ${argv[1]:-} == */claude* ) ]]; then
      p=$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | sed -n 's/^TMUX_PANE=//p' | head -1)
      [[ -n $p && $p == "$orch" ]]
      return
    fi
    if [[ $a =~ ^(bash|sh)$ ]] && (( ${#argv[@]} > 1 )) && [[ ${argv[1]} != -* ]]; then
      f=${argv[1]}
      cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null)
      [[ $f == /* ]] || f=$cwd/$f
      f=$(readlink -f -- "$f" 2>/dev/null)
      [[ -n $f && ${f%/*} == "$here" && $f == *.sh && ${f##*/} != test_* ]] && return 1
    fi
    pid=$(awk '{ print $4 }' "/proc/$pid/stat" 2>/dev/null)
  done
  return 1
}
whose || pass "$@"

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
argv_text="$*"
refuse() { # GUARD REASON [KEY=VALUE...]
  local g=$1 r=$2
  shift 2
  glog WARN "orchestrator guard refused a tmux call" guard="$g" "$@" argv="${argv_text:0:300}"
  printf 'orch-guard (%s): %s\n' "$g" "$r" >&2
  exit 1
}
hidden_why="it can run commands the guard never reads. The orchestrator's tmux runs only capture, list, display, select, kill-pane, buffers and sends; launch agents with fleet/launch.sh, and run anything else from AJ's terminal."

# A #() format runs a shell command, in any tmux command.
for a in "$@"; do
  [[ $a == *'#('* ]] && refuse hidden "a #() format runs a shell command, so $hidden_why" argument="${a:0:120}"
done

# tmux's global options: -L and -S pick the server; -C, -c and -f run commands.
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
          c | f) [[ $c == f && $v == /dev/null ]] || refuse hidden "tmux -$c: $hidden_why" option="-$c" ;;
        esac
        break
        ;;
      C) refuse hidden "tmux -C reads commands from its input, so $hidden_why" option=-C ;;
    esac
    j=$((j + 1))
  done
  i=$((i + 1))
done
[[ ${args[i]:-} == -- ]] && i=$((i + 1))
(( i < ${#args[@]} )) || pass "$@"

# The command table: name, alias, usage, cached per tmux binary. The probe
# starts no server it leaves behind and reads no config.
table=$state/guard/tmux-commands
stamp="$real $(stat -Lc '%Y %s' "$real" 2>/dev/null)"
if [[ $(head -1 "$table" 2>/dev/null) != "$stamp" ]]; then
  probe=orch-guard-probe-$$
  listing=$("$real" -f /dev/null -L "$probe" list-commands 2>/dev/null)
  "$real" -L "$probe" kill-server 2>/dev/null
  rm -f -- "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/${probe:?}"
  if [[ -n $listing ]] && mkdir -p -- "$state/guard" 2>/dev/null && printf '%s\n%s\n' "$stamp" "$listing" >"$table.$$"; then
    mv -f -- "$table.$$" "$table"
  else
    rm -f -- "$table.$$"
    table=$(mktemp) && printf '%s\n%s\n' "$stamp" "$listing" >"$table"
  fi
fi
[[ $(wc -l <"$table" 2>/dev/null) -gt 10 ]] ||
  refuse hidden "tmux's command list could not be read, so the guard cannot tell what this call does." table="$table"
resolve() { # WORD: the command tmux runs for WORD, or nothing
  awk -v w="$1" 'NR > 1 {
      name = $1; alias = ($2 ~ /^\(.*\)$/) ? substr($2, 2, length($2) - 2) : ""
      if (w == name || w == alias) { exact = name }
      else if (index(name, w) == 1) { n++; pre = name }
    }
    END { if (exact != "") print exact; else if (n == 1) print pre }' "$table"
}
usage_of() { awk -v c="$1" 'NR > 1 && $1 == c { print; exit }' "$table"; }

# Commands that run no other command (sends are checked below).
ALLOWED=" capture-pane display-message has-session list-buffers list-clients list-commands list-keys list-panes list-sessions list-windows show-buffer show-environment show-hooks show-messages show-options show-window-options select-pane select-window last-pane last-window kill-pane kill-window set-buffer delete-buffer load-buffer save-buffer rename-window resize-pane clear-history wait-for send-keys send-prefix paste-buffer pipe-pane "
special_key='^([CMS]-.+|Escape|Tab|BTab|BSpace|Up|Down|Left|Right|Home|End|PageUp|PageDown|PgUp|PgDn|PPage|NPage|DC|IC|Delete|Insert|F[0-9]+|KP.*)$'

# Each command of the sequence (split at ";" as tmux does): what it sends where.
checks=() # "COMMAND|TARGET|ENTER|EXACT|TEXT": ENTER 1 when it submits; EXACT 0 when TEXT is unknown
cmd=()
flush() {
  (( ${#cmd[@]} )) || return 0
  local name usage valued k opt v c target="" lit=0 hex=0 tail_args=()
  name=$(resolve "${cmd[0]}")
  if [[ -z $name ]]; then cmd=(); return 0; fi # tmux itself refuses an unknown command
  [[ $ALLOWED == *" $name "* ]] || refuse hidden "tmux $name: $hidden_why" command="$name"
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
      [[ $c == l ]] && lit=1
      [[ $c == H ]] && hex=1
      m=$((m + 1))
    done
    k=$((k + 1))
  done
  tail_args=("${cmd[@]:k}")
  target=${target:-$TMUX_PANE}
  local text="" enter=0 exact=1 key
  case $name in
    send-keys)
      (( hex )) && exact=0
      for key in "${tail_args[@]}"; do
        if (( lit )); then text+=$key
        elif [[ $key =~ ^(Enter|C-m|C-j|KPEnter)$ ]]; then enter=1 text=""
        elif [[ $key == Space ]]; then text+=" "
        elif [[ $key =~ $special_key ]]; then exact=0
        else text+=$key; fi
      done
      checks+=("$name|$target|$enter|$exact|$text")
      ;;
    send-prefix | paste-buffer) checks+=("$name|$target|0|0|") ;;
    pipe-pane)
      # With a shell command, pipe-pane runs it; without one it stops a pipe.
      (( ${#tail_args[@]} )) && refuse hidden "tmux pipe-pane with a shell command: $hidden_why" command="$name"
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

need_lib || refuse hidden "the guard could not load fleet/lib.sh, so it cannot read the pane." here="$here"
now=$(clock)
t() { "$real" "${G[@]}" "$@"; }
squash() { tr -d '[:space:]' <<<"$1"; }
stamps=() # "PANE|TEXT": what this call leaves typed in each box, once every check passes
for ch in "${checks[@]}"; do
  IFS='|' read -r name target enter exact text <<<"$ch"
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
  box=$(input_text "$s") before=""
  if [[ -n $box ]]; then
    own_at="" own_text=""
    { IFS=$'\t' read -r own_at own_text <"$state/guard/typed-${p#%}"; } 2>/dev/null
    if [[ $own_at =~ ^[0-9]+$ ]] && (( now - own_at <= OWN_S )) && [[ -n $own_text && $(squash "$box") == "$(squash "$own_text")" ]]; then
      glog INFO "orchestrator guard: keys into a box holding exactly the orchestrator's own text" pane="$p" typed_s_ago="$((now - own_at))"
      before=$own_text
    elif [[ ${ORCH_GUARD_ALLOW:-} == pending-input ]]; then
      glog WARN "orchestrator guard: keys into a box holding text, allowed by ORCH_GUARD_ALLOW" pane="$p" box="${box:0:200}"
      exact=0
    else
      refuse pending-input "pane $p's input line already holds text the orchestrator did not type (\"${box:0:80}\"): AJ (phone or terminal) or a report. Typing now merges your text into it (11-01 07:30). Wait until it is sent or cleared, then try again. If AJ asked you to replace it, run the command with ORCH_GUARD_ALLOW=pending-input in front." \
        pane="$p" box="${box:0:200}"
    fi
  fi
  if (( exact )); then
    if (( enter )); then stamps+=("$p|$text"); else stamps+=("$p|$before$text"); fi
  else
    stamps+=("$p|")
  fi
  glog INFO "orchestrator guard: tmux send checked" pane="$p" command="$name" limit="${lim:+yes}" idle_min="${idle:+$((idle / 60))}" box_chars="${#box}"
done
# Every check passed: record what this call leaves in each box as the
# orchestrator's own text, so its own follow-up Enter is no collision.
if (( ${#stamps[@]} )) && mkdir -p -- "$state/guard" 2>/dev/null; then
  for st in "${stamps[@]}"; do
    p=${st%%|*} text=${st#*|}
    if [[ -n $text ]]; then printf '%s\t%s\n' "$now" "$text" >"$state/guard/typed-${p#%}"
    else rm -f -- "$state/guard/typed-${p#%}"; fi
  done
fi
pass "$@"
