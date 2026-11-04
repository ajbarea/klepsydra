#!/usr/bin/env bash
# orch-tmux.sh: the run-time half of the orchestrator guard (#264). Installed
# as $FLEET_STATE/orch-bin/tmux, ahead of the real tmux on PATH in the
# orchestrator's session only (launch.sh puts it there for heph), so a call
# that reaches it is the orchestrator's (or a job it started), unless a fleet
# script makes it: a bash or python running a file in fleet/ (fresh-now.sh,
# relaunch-fresh.sh, the resume service) sends with the fleet's own checks.
# It reads tmux's real arguments, after the shell expanded them, at the
# moment of the call, so no shell grammar, wait or script stands between the
# check and the keys. It runs only listed tmux commands and flags (FLAGS) that
# run no other command, and refuses:
#   cold-limit     keys or a paste into a pane that stopped at a usage limit
#                  FRESH_AFTER_S ago or more, dated by its transcript's entries
#                  (fresh-now.sh relaunches it)
#   pending-input  keys into an input line holding anything but the exact text
#                  the orchestrator typed or pasted there in the last two minutes
#   hidden         any other command or flag, a #() format (it runs a shell), an
#                  E or T format modifier (it expands a value as a format again),
#                  and the -C, -c and -f options: each can run commands the guard never reads
#   unknown        whatever it cannot work out: a name tmux's list does not hold
#                  or the server aliases, a target no pane answers to, a send that
#                  is not the only command of its call, a pane at a limit whose
#                  stop no transcript dates, a pane with no input line
# Its state folder is the one above orch-bin/, and its clock and thresholds
# are its own: nothing in the caller's environment moves them. Commands resolve
# as tmux resolves them (name, alias, unique prefix, from tmux list-commands),
# and flags are read from tmux's usage text. A refusal runs none of the
# invocation's commands, prints its reason and exits 1. ORCH_GUARD_ALLOW=
# pending-input in the environment lets that guard pass, logged.
self=$(readlink -f "$0")
here=$(dirname "$self")
real=""
IFS=: read -ra path_dirs <<<"${PATH:-}"
for d in "${path_dirs[@]}"; do
  [[ -n $d && -x $d/tmux && $(readlink -f "$d/tmux") != "$self" ]] && { real=$d/tmux; break; }
done
[[ -n $real ]] || real=/usr/bin/tmux
pass() { exec "$real" "$@"; }

# Installed as <state>/orch-bin/tmux; run any other way, it is on no one's PATH.
bin=$(cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
[[ ${bin##*/} == orch-bin ]] || pass "$@"
state=${bin%/orch-bin}
orch=""
{ read -r orch <"$state/orchestrator.pane"; } 2>/dev/null

# A fleet script on the way up to pid 1 sends with the fleet's own checks; the
# fleet's test suites are no senders, and heavy.sh runs any command it is given.
# Every call walks this chain, so a step spawns nothing unless a script's name
# could be a sender's (the name as given and as resolved must both pass).
nonsender() { [[ ! ${1##*/} =~ \.(sh|py)$ || ${1##*/} == test_* || ${1##*/} == heavy.sh ]]; } # FILE
from_fleet_script() {
  local pid=$PPID n a f j st
  local -a argv
  for (( n = 0; n < 512; n++ )); do
    { [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )); } || return 1
    mapfile -d '' -t argv <"/proc/$pid/cmdline" 2>/dev/null || return 1
    a=${argv[0]##*/}
    if [[ $a =~ ^(bash|sh|python3?(\.[0-9]+)?)$ ]]; then
      for (( j = 1; j < ${#argv[@]} && j < 4; j++ )); do
        f=${argv[j]}
        [[ $f == -* ]] && continue
        nonsender "$f" && break
        [[ $f == /* ]] || f=$(readlink -f "/proc/$pid/cwd" 2>/dev/null)/$f
        f=$(readlink -f -- "$f" 2>/dev/null)
        [[ -n $f && ${f%/*} == "$here" ]] && ! nonsender "$f" && return 0
        break
      done
    fi
    # The parent pid: the field after the state, which follows the last ")"
    # (a command name can hold spaces and parentheses).
    { IFS= read -r st <"/proc/$pid/stat"; } 2>/dev/null || return 1
    st=${st##*) } st=${st#* } pid=${st%% *}
  done
  return 1
}
from_fleet_script && pass "$@"

# lib.sh (16 ms) loads only when a send is checked or a refusal logged, with
# the guard's own state folder, log and thresholds, whatever the caller set.
loaded=0
need_lib() {
  (( loaded )) && return 0
  unset FLEET_LOG FLEET_NOW FRESH_AFTER_S FLEET_LOG_MAX FLEET_RUN_ID
  # Where a pane's session and transcript are read (its stop time): lib.sh's
  # own folders, or the tests' (guard/test-env, KEY=VALUE lines), logged.
  unset KLEPSYDRA_DIR FLEET_ACCOUNTS FLEET_DEFAULT_CONFIG FLEET_PROJECTS
  local k v test_env=""
  while IFS='=' read -r k v; do
    case $k in KLEPSYDRA_DIR | FLEET_PROJECTS) export "$k=$v" && test_env+="$k " ;; esac
  done <"$state/guard/test-env" 2>/dev/null
  FLEET_STATE=$state FLEET_TARGET=fleet::orch-tmux
  # shellcheck source=fleet/lib.sh
  . "$here/lib.sh" 2>/dev/null || return 1
  loaded=1
  [[ -n $test_env ]] && flog WARN "orchestrator guard: folders from the test file" set="${test_env% }" 2>/dev/null
  # The tests' clock: a file in the guard's own folder, logged when used.
  local at=""
  { read -r at <"$state/guard/test-now"; } 2>/dev/null
  if [[ $at =~ ^[0-9]+$ ]]; then
    FLEET_NOW=$at
    flog WARN "orchestrator guard: the clock is the test file's" now="$at" 2>/dev/null
  fi
}
OWN_S=120 # the orchestrator's own typing is still its own this long
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
format_check() { # ARG...: a #() format runs a shell command
  local a
  for a in "$@"; do
    [[ $a == *'#('* ]] && refuse hidden "a #() format runs a shell command, so $hidden_why" argument="${a:0:120}"
    # #{E:...} and #{T:...} expand a value (a buffer, a title) as a format
    # again, so a #() inside it runs. tmux's modifier grammar nests (#{s/#{l:x}/y/;E:...}),
    # so it is not modelled: in a format, an E or T followed by ; or : anywhere is
    # refused (an E or T modifier is always followed by one), plain text too.
    [[ $a == *'#{'* && $a =~ [ET][\;:] ]] &&
      refuse hidden "a format holding an E or T modifier (#{E:...}, #{T:...}) expands a value as a format again, so a #() in a buffer or a title runs: $hidden_why" argument="${a:0:120}"
  done
  return 0
}

# tmux's global options: every -L and -S picks the server as tmux reads them;
# -C, -c and -f run commands.
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
          L | S) G+=(-"$c" "$v") ;;
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
t() { "$real" "${G[@]}" "$@"; }

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
  refuse unknown "tmux's command list could not be read, so the guard cannot tell what this call does." table="$table"
resolve() { # WORD: the command tmux runs for WORD, or nothing
  awk -v w="$1" 'NR > 1 {
      name = $1; alias = ($2 ~ /^\(.*\)$/) ? substr($2, 2, length($2) - 2) : ""
      if (w != "" && (w == name || w == alias)) { exact = name }
      else if (w != "" && index(name, w) == 1) { n++; pre = name }
    }
    END { if (exact != "") print exact; else if (n == 1) print pre }' "$table"
}
usage_of() { awk -v c="$1" 'NR > 1 && $1 == c { print; exit }' "$table"; }
# The server's own command aliases (command-alias), which tmux reads before names.
aliases=" $(t show-options -sv command-alias 2>/dev/null | sed -E 's/^"//; s/=.*//' | tr '\n' ' ') "

# The commands the orchestrator's tmux runs, each with the flags it may take:
# none of them runs another command. Left out on purpose: send-keys -K and -c
# (keys through a client's bindings, into whatever pane it shows), -X (a
# copy-mode command, which can pipe to a shell) and -M; display-message -I
# (its input into a pane); kill-pane -a and kill-window -a (every other one).
declare -A FLAGS=(
  [capture-pane]=aCeJNpPqTbESt [clear-history]=Ht [delete-buffer]=b [display-message]=alNpvcdFt
  [has-session]=t [kill-pane]=t [kill-window]=t [last-pane]=deZt [last-window]=t
  [list-buffers]=Ff [list-clients]=Fft [list-commands]=F [list-keys]=1aNPT [list-panes]=asFft
  [list-sessions]=Ff [list-windows]=aFft [load-buffer]=bt [paste-buffer]=dprsbt [pipe-pane]=IOot
  [rename-window]=t [resize-pane]=DLMRTUZxyt [save-buffer]=ab [select-pane]=DdeLlMmRUZTt
  [select-window]=lnpTt [send-keys]=FHlRNt [send-prefix]=2t [set-buffer]=awbnt [show-buffer]=b
  [show-environment]=hgst [show-hooks]=gpwt [show-messages]=JTt [show-options]=AgHpqsvwt
  [show-window-options]=gvt [wait-for]=LSU
)
special_key='^([CMS]-.+|Escape|Tab|BTab|BSpace|Up|Down|Left|Right|Home|End|PageUp|PageDown|PgUp|PgDn|PPage|NPage|DC|IC|Delete|Insert|F[0-9]+|KP.*)$'

# Each command of the sequence (split at ";" as tmux does): what it sends where.
checks=() # "COMMAND|TARGET|ENTER|EXACT|TEXT": ENTER 1 when it submits; EXACT 0 when TEXT is unknown
cmd=()
ncmds=0
flush() {
  (( ${#cmd[@]} )) || return 0
  ncmds=$((ncmds + 1))
  local name usage valued k opt v c target="" lit=0 hex=0 reps=1 buf="" tail_args=() vals=()
  [[ $aliases == *" ${cmd[0]} "* ]] && refuse unknown "tmux ${cmd[0]}: this server aliases that name (command-alias), so it could stand for any command. Use the command's full name." command="${cmd[0]}"
  name=$(resolve "${cmd[0]}")
  [[ -n $name ]] || refuse unknown "tmux ${cmd[0]}: no command of that name in tmux's list, and an alias could stand for any command. Use the command's full name." command="${cmd[0]}"
  [[ -n ${FLAGS[$name]+x} ]] || refuse hidden "tmux $name: $hidden_why" command="$name"
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
      [[ ${FLAGS[$name]} == *"$c"* ]] || refuse hidden "tmux $name -$c: that flag can reach commands or panes the guard does not check. $hidden_why" command="$name" flag="-$c"
      if [[ $valued == *"$c"* ]]; then
        v=${opt:m+1}
        if [[ -z $v ]]; then k=$((k + 1)); v=${cmd[k]:-}; fi
        vals+=("$v")
        case $c in t) target=$v ;; N) reps=$v ;; b) buf=$v ;; esac
        break
      fi
      [[ $c == l ]] && lit=1
      [[ $c == H || $c == F ]] && hex=1
      m=$((m + 1))
    done
    k=$((k + 1))
  done
  tail_args=("${cmd[@]:k}")
  # Formats are expanded in option values and in most operands, not in the
  # keys send-keys types or the data set-buffer stores.
  format_check "${vals[@]}"
  [[ $name == send-keys || $name == set-buffer ]] || format_check "${tail_args[@]}"
  target=${target:-$TMUX_PANE}
  local text="" enter=0 exact=1 key r
  case $name in
    send-keys)
      (( hex )) && exact=0
      [[ $reps =~ ^[0-9]+$ ]] || exact=0
      for key in "${tail_args[@]}"; do
        if (( lit )); then text+=$key
        elif [[ $key =~ ^(Enter|C-m|C-j|KPEnter)$ ]]; then enter=1 text=""
        elif [[ $key == Space ]]; then text+=" "
        elif [[ $key =~ $special_key ]]; then exact=0
        else text+=$key; fi
      done
      if (( exact && reps > 1 )); then
        (( enter )) && exact=0
        local one=$text
        for (( r = 1; r < reps; r++ )); do text+=$one; done
      fi
      checks+=("$name|$target|$enter|$exact|$text")
      ;;
    paste-buffer)
      # What it pastes is the buffer's text: the orchestrator's own once pasted.
      if text=$(t show-buffer ${buf:+-b "$buf"} 2>/dev/null); then
        checks+=("$name|$target|0|1|${text//[$'\n|']/ }")
      else
        checks+=("$name|$target|0|0|")
      fi
      ;;
    send-prefix) checks+=("$name|$target|0|0|") ;;
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
# A send is the only command of its call. In a sequence, an earlier command
# can move what its target names (select-window: fleet:, {last}, no -t) or
# hold it back past the check (wait-for, a load-buffer from a FIFO) while AJ
# types into the pane or it reaches a limit; the guard checks the pane as it
# is now, so nothing may come between the check and the keys.
(( ncmds > 1 )) &&
  refuse unknown "a send in a sequence of tmux commands: an earlier command in the sequence can change which pane it reaches or hold it back after the guard read the pane. Send in a tmux call of its own." commands="$ncmds"

need_lib || refuse unknown "the guard could not load fleet/lib.sh, so it cannot read the pane." here="$here"
now=$(clock)
t() { "$real" "${G[@]}" "$@"; } # again: lib.sh's t is the fleet socket's
squash() { tr -d '[:space:]' <<<"$1"; }
# The prompt cache's lifetime runs from the last request that succeeded (#264,
# Heph 11-03), so a stop is dated by the session's last good reply: a main-chain
# assistant entry that is no API error and no <synthetic> one (Claude Code writes
# a limit as an assistant entry with isApiErrorMessage, error rate_limit and
# model <synthetic>). Prints that reply's epoch; fails when there is none.
read -r -d '' STOP_JQ <<'JQ' || true
def good: .isSidechain != true and .isApiErrorMessage != true and ((.message.model? // "") != "<synthetic>");
last(inputs | fromjson? | objects | select(.type == "assistant" and (.timestamp | type) == "string" and good))
| select(. != null) | .timestamp | sub("[.][0-9]+Z$"; "Z") | fromdateiso8601
JQ
# Only the transcript's tail is read, through a grep prefilter (a long session's
# file runs to tens of MB, and the guard sits in front of every send); the
# window grows eightfold until a good reply is in it, up to the whole file.
stop_from_transcript() { # TP
  local tp=$1 size n=2097152 out
  size=$(stat -L -c %s -- "$tp" 2>/dev/null) || return 1
  while :; do
    out=$(tail -c "$n" -- "$tp" 2>/dev/null | LC_ALL=C grep -aF '"type":"assistant"' | jq -nRr "$STOP_JQ" 2>/dev/null)
    [[ $out =~ ^[0-9]+$ ]] && { printf '%s\n' "$out"; return 0; }
    (( n >= size )) && return 1
    n=$(( n * 8 ))
  done
}
placeholder='^\[Pasted text #[0-9]+( \+[0-9]+ lines?)?\]$'
stamps=() # "PANE|TEXT": what this call leaves typed in each box, once every check passes
for ch in "${checks[@]}"; do
  IFS='|' read -r name target enter exact text <<<"$ch"
  p=$(t display-message -p -t "$target" '#{pane_id}' 2>/dev/null)
  [[ -n $p ]] || refuse unknown "tmux $name -t ${target:-(none)}: no such pane on the server this call names, so the guard cannot read it first." command="$name" target="$target"
  [[ ${ORCH_TMUX_TRACE:-} ]] && printf '%s\n' "$p" >>"$ORCH_TMUX_TRACE"
  [[ $p == "$orch" ]] && continue
  s=$(screen "$p")
  lim="" idle="" mt=""
  if lim=$(limit_line "$s"); then
    # Only the session's transcript dates the stop, by its last good reply
    # (never the file's mtime, a later write; never "done H:MM", which has no
    # date). With none, the stop is unknown, a refusal: the way out is a fresh
    # relaunch, which is safe.
    sid="" tp="" stop=""
    if ! { sid=$(live_session "$p") && tp=$(transcript "$sid") && [[ -n $tp ]] &&
      read -r stop < <(stop_from_transcript "$tp") && [[ $stop =~ ^[0-9]+$ ]]; }; then
      refuse unknown "pane $p is at a usage limit and no transcript of its session holds a reply that succeeded, the time its cache started to age, so the guard cannot tell how long its cache has been cold. The resume service sends at the reset; relaunch it fresh now with: bash $state/fresh-now.sh $p" \
        pane="$p" command="$name" limit="$lim"
    fi
    mt=$stop
    idle=$((now - stop))
    if (( idle >= FRESH_AFTER_S )); then
      refuse cold-limit "pane $p stopped at a usage limit $((idle / 60)) min ago (\"${lim#"${lim%%[![:space:]]*}"}\"). Its prompt cache lives an hour, so keys typed into it now re-cache its whole transcript: five such nudges took 38% of a five-hour window on 11-02. Relaunch it fresh from its brief instead: bash $state/fresh-now.sh $p" \
        pane="$p" command="$name" idle_min="$((idle / 60))" limit="$lim"
    fi
  fi
  before=""
  if ! has_input_box "$s"; then
    if [[ ${ORCH_GUARD_ALLOW:-} == pending-input ]]; then
      glog WARN "orchestrator guard: keys into a pane with no input line, allowed by ORCH_GUARD_ALLOW" pane="$p"
      exact=0
    else
      refuse unknown "pane $p shows no input line (a menu, a dialog, or not Claude Code), so the guard cannot see what is typed there. Answer it from AJ's terminal, or, if AJ asked for these keys, run the command with ORCH_GUARD_ALLOW=pending-input in front." pane="$p" command="$name"
    fi
  fi
  box=$(input_text "$s")
  if [[ -n $box ]]; then
    own_at="" own_text=""
    { IFS=$'\t' read -r own_at own_text <"$state/guard/typed-${p#%}"; } 2>/dev/null
    if [[ $own_at =~ ^[0-9]+$ ]] && (( now - own_at <= OWN_S )) && [[ -n $own_text ]] &&
      [[ $(squash "$box") == "$(squash "$own_text")" || $box =~ $placeholder ]]; then
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
  glog INFO "orchestrator guard: tmux send checked" pane="$p" command="$name" limit="${lim:+yes}" idle_min="${idle:+$((idle / 60))}" stop_from="${mt:+transcript}" box_chars="${#box}"
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
