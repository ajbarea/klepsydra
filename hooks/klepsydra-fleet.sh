#!/usr/bin/env bash
# Claude Code hook for the klepsydra fleet strip. Keeps one JSON file per
# session in <KLEPSYDRA_DIR>/fleet: its state, where it works, and what it was
# last asked and last said. Registered with "async": true on the events listed
# in README.md, so Claude Code never waits for it. As a hook it prints nothing
# and always exits 0; run as `klepsydra-fleet.sh queue ...` it is a command
# (queue_cmd below).

set -uo pipefail

# --- klepsydra dir: identical in hooks/klepsydra-fleet.sh and statusline/klepsydra-statusline.sh ---
# The overlay's app-local-data dir, named for the bundle identifier in
# src-tauri/tauri.conf.json. Not the install dir: the uninstaller's "delete app
# data" reaches only this one, and a per-machine install cannot be written to.
# Under WSL the overlay is a Windows app, so the hook writes across to it. On
# Linux, Tauri honours XDG_DATA_HOME only when it is absolute, and so must we,
# or the readings land under whatever directory Claude Code is running in.
if [[ -z "${KLEPSYDRA_DIR:-}" ]]; then
  osrelease=""
  { read -r osrelease </proc/sys/kernel/osrelease; } 2>/dev/null  # builtin: no process per run
  if [[ "$osrelease" == *[Mm]icrosoft* ]]; then
    if [[ -n "${USER:-}" ]]; then
      KLEPSYDRA_DIR="/mnt/c/Users/$USER/AppData/Local/dev.ajsoftworks.klepsydra"
    fi
  else
    data_home="${HOME:-}/.local/share"
    [[ "${XDG_DATA_HOME:-}" == /* ]] && data_home="$XDG_DATA_HOME"
    [[ "$data_home" == /* ]] && KLEPSYDRA_DIR="$data_home/dev.ajsoftworks.klepsydra"
  fi
fi
# --- end klepsydra dir ---

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
PROC_ROOT=${KLEPSYDRA_PROC:-/proc} # tests point these at a fake /proc and voices.json
VOICES=${KERYX_VOICES:-}
if [[ -z $VOICES ]]; then
  if [[ -n ${XDG_CACHE_HOME:-} ]]; then VOICES=$XDG_CACHE_HOME/keryx/voices.json
  elif [[ -n ${HOME:-} ]]; then VOICES=$HOME/.cache/keryx/voices.json; fi
fi
# The theme worn, whose accents colour the tmux windows: the overlay writes
# it to its data dir on every switch; ~/.claude's copy serves until it has.
CAST=${KLEPSYDRA_CAST:-}
if [[ -z $CAST && -n ${KLEPSYDRA_DIR:-} && -f $KLEPSYDRA_DIR/cast.json ]]; then CAST=$KLEPSYDRA_DIR/cast.json
elif [[ -z $CAST && -n ${HOME:-} ]]; then CAST=$HOME/.claude/klepsydra-cast.json; fi
# Every session's hooks run as separate processes, so writes take one lock.
LOCK=${XDG_RUNTIME_DIR:-/tmp}/klepsydra-fleet-$UID.lock
PROMPT_CHARS=300
# The events README.md registers this hook on; any other is ignored.
EVENTS="SessionStart UserPromptSubmit PermissionRequest PreToolUse Notification PostToolUse PostToolUseFailure SubagentStart SubagentStop Stop StopFailure SessionEnd"
# Remote Control: the hook reads this much of the transcript's end for the
# lines that turn it on or off, keeps the last REMOTE_LINES of them, and skips
# any longer than REMOTE_LINE_MAX bytes (the real ones are under 1 KB), so
# what it hands jq stays far below Linux's 128 KiB limit on one argument.
REMOTE_TAIL=1048576
REMOTE_LINES=4
REMOTE_LINE_MAX=8192
# At most this many background entries are kept; past it the oldest go.
BACKGROUND_MAX=64
# Async hooks can land out of order: a subagent's stop seen before its start is
# remembered this long, so the late start adds no phantom.
STOPPED_TTL=60

# Sets where_repo, where_worktree and where_branch for `path` (empty when
# none), and where_bare=1 when no repo holds it, reading .git directly as keryx's source_name does, so no git process
# runs. A worktree is named by its main checkout, a submodule by its own folder,
# and a path outside any repo by its own name.
git_where() { # path
  local here=${1%/} folder dotgit link gitdir common main
  where_repo="" where_worktree="" where_branch="" where_git="" where_bare=0 where_dir="" where_remote=""
  [[ -n $here ]] || here=/
  if [[ $here != /* ]]; then where_repo=${here##*/} where_bare=1; return; fi
  folder=$here
  while :; do
    dotgit=$folder/.git
    if [[ -d $dotgit ]]; then
      where_repo=${folder##*/} where_git=$dotgit where_dir=$folder
      branch_of "$dotgit"
      remote_of "$dotgit/config"
      return
    elif [[ -f $dotgit ]]; then
      link=""
      { IFS= read -r link <"$dotgit"; } 2>/dev/null
      where_repo=${folder##*/} common=""
      [[ $link == gitdir:* ]] || return
      gitdir=${link#gitdir:}
      gitdir=${gitdir#"${gitdir%%[![:space:]]*}"}
      gitdir=${gitdir%"${gitdir##*[![:space:]]}"} # a CRLF file, as keryx strips it
      [[ $gitdir == /* ]] || gitdir=$folder/$gitdir
      if [[ -f $gitdir/commondir ]]; then
        common=""
        { IFS= read -r common <"$gitdir/commondir"; } 2>/dev/null
        common=${common#"${common%%[![:space:]]*}"}
        common=${common%"${common##*[![:space:]]}"}
        [[ $common == /* ]] || common=$gitdir/$common
        if main=$(cd "$common" 2>/dev/null && pwd -P); then
          main=${main%/*}
          where_repo=${main##*/}
          where_worktree=${folder##*/}
        fi
      fi
      where_git=$gitdir where_dir=$folder
      branch_of "$gitdir"
      remote_of "${common:-$gitdir}/config"
      return
    fi
    [[ $folder == / ]] && break
    folder=${folder%/*}
    [[ -n $folder ]] || folder=/
  done
  where_repo=${here##*/} where_bare=1
}

# Sets where_remote to the GitHub page of the repo whose git config is
# `config` (its origin, by https or ssh), or nothing for another host or none.
remote_of() { # config
  local line url="" in=0
  # Braced, so a missing config's error goes too: on the loop the redirect opens before 2> applies.
  { while IFS= read -r line; do
    line=${line#"${line%%[![:space:]]*}"}
    case $line in
      '[remote "origin"]'*) in=1 ;;
      '['*) in=0 ;;
      url*=*) (( in )) && { url=${line#*=}; url=${url#"${url%%[![:space:]]*}"}; url=${url%"${url##*[![:space:]]}"}; break; } ;;
    esac
  done <"$1"; } 2>/dev/null
  url=${url%.git}
  case $url in
    https://github.com/* | http://github.com/*) url=${url#*github.com/} ;;
    git@github.com:* | ssh://git@github.com/*) url=${url#*github.com[:/]} ;;
    *) return ;;
  esac
  [[ $url =~ ^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$ ]] && where_remote=https://github.com/$url
}

# Sets where_branch from a git dir's HEAD: the branch, else a detached commit's
# first 7 characters.
branch_of() { # gitdir
  local head=""
  { IFS= read -r head <"$1/HEAD"; } 2>/dev/null
  case $head in
    "ref: refs/heads/"*) where_branch=${head#ref: refs/heads/} ;;
    "ref: "*) where_branch=${head#ref: } ;;
    *) where_branch=${head:0:7} ;;
  esac
}

# --- proc stat: identical in hooks/klepsydra-fleet.sh and hooks/klepsydra-launch.sh ---
# Fields of $PROC_ROOT/<pid>/stat after the command name, into the caller's
# `stat`: [0] is the state, [1] the parent pid, [19] the start time (field 22).
# The name sits in parentheses and may itself contain spaces or ")".
proc_stat() { # pid
  local raw=""
  { IFS= read -r raw <"$PROC_ROOT/$1/stat"; } 2>/dev/null
  [[ $raw == *") "* ]] || return 1
  read -r -a stat <<<"${raw##*") "}"
  (( ${#stat[@]} > 19 ))
}

# Whether `pid` runs with start time `start`: a zombie has exited, and a pid
# with another start time is a later process.
proc_is() { # pid start
  local -a stat=()
  [[ $1 =~ ^[0-9]+$ && $2 =~ ^[0-9]+$ ]] || return 1
  proc_stat "$1" && [[ ${stat[0]} != Z && ${stat[19]} == "$2" ]]
}
# --- end proc stat ---

# Whether `pid` is Claude Code: by name, or an npm install's
# `node .../@anthropic-ai/claude-code/cli.js`, as keryx decides.
is_claude() { # pid
  local comm="" arg part
  local -a argv=() parts=()
  { IFS= read -r comm <"$PROC_ROOT/$1/comm"; } 2>/dev/null
  [[ $comm == claude || $comm == claude-code ]] && return 0
  { mapfile -d '' -t -n 2 argv <"$PROC_ROOT/$1/cmdline"; } 2>/dev/null || return 1
  for arg in "${argv[@]}"; do
    IFS=/ read -r -a parts <<<"$arg"
    for part in "${parts[@]}"; do
      [[ $part == claude || $part == claude-code ]] && return 0
    done
  done
  return 1
}

# Sets found_pid and found_start to the nearest Claude Code process at or
# above `pid`: keryx's key for a terminal (pid:starttime in voices.json).
claude_ancestor() { # pid
  local pid=$1 i
  local -a stat=()
  found_pid="" found_start=""
  for ((i = 0; i < 32; i++)); do
    proc_stat "$pid" || return 1
    if is_claude "$pid"; then
      found_pid=$pid found_start=${stat[19]}
      return 0
    fi
    pid=${stat[1]}
    (( pid >= 1 )) || return 1
  done
  return 1
}

# How many Bash tool calls Claude Code process `pid` runs now: its child
# shells, one per call however many subshells or pipes the call starts, less
# the one running this hook (`me` and its parents). Claude Code's footer counts
# them so; the hook events cannot, since none fires when a background shell
# ends mid-turn. A zombie has ended; sh and dash are hook wrappers (dash keeps
# its process for `sh -c CMD`), never a Bash tool call: Claude Code runs those
# in bash or zsh, or the CLAUDE_CODE_SHELL it names. Where /bin/sh is bash, a
# hook wrapper can briefly count; the card's min with its set bounds that.
# Prints nothing when no children list is readable, 0 for an empty one, and
# nothing under CLAUDE_CODE_SHELL_PREFIX, whose wrapper hides the shell.
live_shells() { # pid me
  local pid=$1 p=$2 f child comm n=0 listed=0 i own=${CLAUDE_CODE_SHELL:-}
  local -a stat=() mine=()
  [[ -n ${CLAUDE_CODE_SHELL_PREFIX:-} ]] && return 0
  own=${own##*/}
  [[ $own == sh || $own == dash ]] && own=""
  for ((i = 0; i < 32; i++)); do
    [[ $p == "$pid" ]] && break
    mine+=("$p")
    proc_stat "$p" || break
    p=${stat[1]}
    (( p >= 1 )) || break
  done
  for f in "$PROC_ROOT/$pid"/task/*/children; do
    [[ -r $f ]] || continue
    listed=1
    for child in $(<"$f"); do
      [[ $child =~ ^[0-9]+$ ]] || continue
      [[ " ${mine[*]} " == *" $child "* ]] && continue
      proc_stat "$child" && [[ ${stat[0]} == Z ]] && continue
      comm=""
      { IFS= read -r comm <"$PROC_ROOT/$child/comm"; } 2>/dev/null
      # bwrap: a call in Claude Code's sandbox.
      [[ $comm == bash || $comm == zsh || $comm == bwrap || (-n $own && $comm == "${own:0:15}") ]] && n=$((n + 1))
    done
  done
  (( listed )) && printf '%s' "$n"
}

# The voice keryx holds for a terminal, or nothing without keryx or a hold.
holder_voice() { # pid start
  [[ -n $VOICES && -r $VOICES ]] || return 0
  jq -r --arg h "$1:$2" '.holders[$h].voice // empty | strings' "$VOICES" 2>/dev/null
}

# The voice keryx remembers for each repo, the one keryx hands a new terminal
# there, as {repo: voice}, leaving out a repo unheard for FORGET_SECONDS
# (keryx's own constant); {} without keryx. A muted keryx holds no new
# terminal, so a session takes a repo's voice from here.
FORGET_SECONDS=$((90 * 24 * 3600))
home_voices() { # now
  local homes=""
  # One object or none: the first value only, since a second would make the
  # file's --argjson refuse it and stop every session's updates.
  [[ -n $VOICES && -r $VOICES ]] && homes=$(jq -nc --argjson now "$1" --argjson within "$FORGET_SECONDS" '
    first(inputs) | .homes | if type == "object" then . else {} end
    | with_entries(select(.value | type == "object" and (.seen | type) == "number" and $now - .seen <= $within
        and (.voice | type) == "string" and .voice != "") | .value = .value.voice)' "$VOICES" 2>/dev/null)
  [[ $homes == \{* ]] || homes='{}'
  printf '%s' "$homes"
}

# Whether the Claude Code process recorded as `pid start` still runs. A zombie
# has exited, and a pid with another start time or another program is someone
# else's.
claude_alive() { # pid start
  proc_is "$1" "$2" && is_claude "$1"
}

# Sets host_boot (this kernel boot) and host_distro (this WSL distro), each
# empty when unknown or malformed.
BOOT_ID=${KLEPSYDRA_BOOT_ID:-/proc/sys/kernel/random/boot_id}
host_facts() {
  host_boot="" host_distro=${WSL_DISTRO_NAME:-}
  { IFS= read -r host_boot <"$BOOT_ID"; } 2>/dev/null
  [[ $host_boot =~ ^[0-9a-f-]{36}$ ]] || host_boot=""
  [[ $host_distro =~ ^[A-Za-z0-9._-]{1,64}$ ]] || host_distro=""
}

# Sets tmux_socket and tmux_pane from the session's tmux, both empty outside
# tmux or when either is malformed.
tmux_facts() {
  tmux_socket=${TMUX:-}
  tmux_socket=${tmux_socket%%,*}
  tmux_pane=${TMUX_PANE:-}
  if ! [[ ${TMUX:-} == *,* && $tmux_socket =~ ^/[A-Za-z0-9._/-]{1,255}$ && $tmux_pane =~ ^%[0-9]{1,9}$ ]]; then
    tmux_socket="" tmux_pane=""
  fi
}

# One tab-separated row per named session file whose first line is a v1
# object: its name, then what the jq array `fields` picks from the object
# (`last_active` is its newest time field, `or_q` a string or "?"). One jq
# reads every file; a file without a final newline cannot run into the next,
# and a line that does not parse yields nothing. Callers pass only names they
# checked, from inside the fleet folder.
session_rows() { # fields file...
  local fields=$1 f line
  shift
  (( $# )) || return 0
  for f in "$@"; do
    line=""
    { IFS= read -r line <"$f"; } 2>/dev/null
    printf '%s\t%s\n' "$f" "$line"
  done | jq -Rr '
    def last_active: [.started_at, .state_at, .where.at, .prompt.at, .reply.at, .ended.at, .written_at]
      | map(numbers) | max // 0 | floor;
    def or_q: if type == "string" and length > 0 then . else "?" end;
    (index("\t")) as $i | .[:$i] as $f
    | (try (.[$i + 1:] | fromjson) catch empty) | select(type == "object" and .v == 1)
    | try ([$f] + ('"$fields"')) catch empty
    | @tsv' 2>/dev/null
}

# Delete the files of sessions whose Claude Code process is gone and whose
# last activity is more than a day old, heartbeats a day old with no session
# file, and write litter a day old. Only <uuid>.json, <uuid>.beat and
# <uuid>.{json,beat}.<digits>.tmp directly inside <dir>/fleet, never a
# symlink, and only when `dir` is the overlay's own absolute data dir. Runs
# under the fleet lock in a few processes however many files there are.
PRUNE_AFTER=86400
PRUNE_STAMP=${LOCK%.lock}.pruned
prune_fleet() { # dir now
  local dir=$1 now=$2
  own_data_dir "$dir" || return 1
  while [[ $dir == */ ]]; do dir=${dir%/}; done
  [[ $now =~ ^[0-9]+$ ]] || return 1
  [[ -L $dir/fleet ]] && return 1
  [[ -d $dir/fleet ]] || return 0
  # From inside the folder every name is short, which matters on /mnt/c.
  ( cd -- "$dir/fleet" 2>/dev/null && prune_here "$now" )
}

# prune_fleet's work, in the fleet folder. Types and mtimes of every candidate
# come from one stat (which does not follow links); the session files are read
# by session_rows.
prune_here() { # now
  local now=$1 f name id pid start last line
  local -A type=() mt=() listed=()
  local -a sessions=()
  while IFS= read -r -d '' line; do
    [[ $line =~ ^([^|]+)\|([0-9]+)\|(.+)$ ]] || continue
    type[${BASH_REMATCH[3]}]=${BASH_REMATCH[1]}
    mt[${BASH_REMATCH[3]}]=${BASH_REMATCH[2]}
  done < <(LC_ALL=C stat --printf '%F|%Y|%n\0' -- *.json *.beat *.tmp 2>/dev/null)
  plain() { [[ ${type[$1]:-} == "regular file" || ${type[$1]:-} == "regular empty file" ]]; } # name
  old() { plain "$1" && (( now - mt[$1] > PRUNE_AFTER )); } # name

  for name in *.json; do
    [[ ${name%.json} =~ $UUID_RE ]] && plain "$name" && { sessions+=("$name"); listed[$name]=1; }
  done
  if (( ${#sessions[@]} )); then
    # A file without a final newline cannot run into the next one this way; a
    # line that does not parse as a v1 object yields nothing.
    while IFS=$'\t' read -r f pid start last; do
      # Only a name this function globbed is ever deleted, whatever jq printed.
      [[ -n ${listed[$f]:-} && $f =~ ^[^/]+\.json$ ]] || continue
      id=${f%.json}
      [[ $pid =~ ^[0-9]+$ && $start =~ ^[0-9]+$ && $last =~ ^[1-9][0-9]*$ ]] || continue
      (( now - last > PRUNE_AFTER )) || continue
      if [[ -n ${type[$id.beat]:-} ]]; then
        old "$id.beat" || continue
      fi
      claude_alive "$pid" "$start" && continue
      rm -f -- "$f"
      [[ ${type[$id.beat]:-} == "symbolic link" ]] || rm -f -- "$id.beat"
    done < <(session_rows '[((.claude.pid | numbers) // 0 | floor), ((.claude.start | numbers) // 0 | floor), last_active]' \
      "${sessions[@]}")
  fi

  for name in *.beat; do
    id=${name%.beat}
    [[ $id =~ $UUID_RE && -z ${type[$id.json]:-} ]] || continue
    old "$name" && rm -f -- "$name"
  done
  for name in *.tmp; do
    [[ $name =~ ^(.{36})\.(json|beat)\.[0-9]+\.tmp$ ]] || continue
    [[ ${BASH_REMATCH[1]} =~ $UUID_RE ]] || continue
    old "$name" && rm -f -- "$name"
  done
  return 0
}

# Mark ended, reason "gone", every session in <dir>/fleet that has not ended
# and whose Claude Code process cannot be running: it started on another boot,
# or on this boot and distro under a pid that is no longer it. Sessions from
# another distro on this boot are left alone (their pids are not visible here);
# with no distro on either side, the pid decides. A session idle past
# PRUNE_AFTER is left to the prune, which would otherwise see a fresh clock.
# A field jq finds empty is printed as "?", which no boot or distro can be, so
# read does not collapse the tabs around it. A session with no known pid is
# gone only from an earlier boot, and `self`'s own file is never touched. One
# jq lists every file (session_rows); only a session it marks costs another.
mark_gone() { # dir now self
  local dir=$1 now=$2 self=$3 f state boot distro pid start last new
  [[ -n $host_boot ]] && own_data_dir "$dir" || return 0
  [[ -d $dir/fleet && ! -L $dir/fleet ]] || return 0
  while IFS=$'\t' read -r f state boot distro pid start last; do
    [[ ${f%.json} =~ $UUID_RE && $state != ended && $boot != "?" && $f != "$self.json" ]] || continue
    if [[ $boot == "$host_boot" ]]; then
      [[ $distro == "?" ]] && distro=""
      [[ $distro == "$host_distro" ]] || continue
      [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
      claude_alive "$pid" "$start" && continue
    fi
    [[ $last =~ ^[0-9]+$ ]] || continue
    (( now - last > PRUNE_AFTER )) && continue
    new=$(jq -c --argjson now "$now" \
      '.state = "ended" | .reason = "gone" | .needs = null | .ended = {reason: "gone", at: $now} | .state_at = $now | .written_at = $now' \
      "$dir/fleet/$f" 2>/dev/null) || continue
    [[ -n $new ]] && write_atomic "$dir/fleet/$f" "$new"
  done < <(cd -- "$dir/fleet" 2>/dev/null || exit 0
    names=()
    for f in *.json; do
      [[ ${f%.json} =~ $UUID_RE && -f $f && ! -L $f ]] && names+=("$f")
    done
    session_rows '[(.state | or_q), (.host.boot | or_q), (.host.distro | or_q),
      ((.claude.pid | numbers) // 0 | floor), ((.claude.start | numbers) // 0 | floor), last_active]' "${names[@]}")
}

# --- prune helpers: identical in hooks/klepsydra-fleet.sh and statusline/klepsydra-statusline.sh ---
# Whether `dir` is the overlay's own data dir, the only place a prune deletes
# from: absolute, without "..", named for the bundle identifier, and not a
# symlink. Trailing slashes do not count.
own_data_dir() { # dir
  local dir=$1
  while [[ $dir == */ ]]; do dir=${dir%/}; done
  [[ -n $dir && $dir == /* ]] || return 1
  [[ $dir == */../* || $dir == */.. ]] && return 1
  [[ ${dir##*/} == dev.ajsoftworks.klepsydra ]] || return 1
  [[ ! -L $dir ]]
}

# A prune runs at most once an hour, refused or not; `stamp` holds the time of
# the last run, and a clock that went back runs it again.
PRUNE_EVERY=3600
prune_due() { # stamp now
  local last=""
  { IFS= read -r last <"$1"; } 2>/dev/null
  [[ $2 =~ ^[0-9]+$ ]] || return 1
  ! [[ $last =~ ^[0-9]+$ ]] || (( 10#$2 - 10#$last >= PRUNE_EVERY || 10#$2 < 10#$last ))
}
prune_hourly() { # stamp prune dir now
  prune_due "$1" "$4" || return 0
  "$2" "$3" "$4"
  { printf '%s\n' "$4" >"$1"; } 2>/dev/null
  return 0
}
# --- end prune helpers ---

# The transcript's last few lines that turn Remote Control on or off, one per
# line: `/remote-control` connecting (system bridge_status, with the session
# URL), Claude Code's remote_session_change attachment, and its "Remote
# Control disconnected" system notice (the phrase in a prompt or reply, its
# quotes escaped there, takes no slot). Then the last bridge-session record,
# which Claude Code re-appends every few lines with the bridge's id: it has no
# timestamp, so it is given the one of the line before it. A tail and one awk,
# never a full read; nothing for a path that is not an absolute, readable .jsonl file.
remote_lines() { # transcript
  [[ $1 == /*.jsonl && -f $1 && -r $1 ]] || return 0
  tail -c "$REMOTE_TAIL" -- "$1" 2>/dev/null | LC_ALL=C awk -v keep="$REMOTE_LINES" -v max="$REMOTE_LINE_MAX" '
    length($0) > max { next }
    index($0, "\"subtype\":\"bridge_status\"") || index($0, "\"type\":\"remote_session_change\"") \
      || (index($0, "\"type\":\"system\"") && index($0, "\"content\":\"Remote Control disconnected")) { seen[n++ % keep] = $0 }
    index($0, "{\"type\":\"bridge-session\"") == 1 { bridge = $0; bridge_at = at; next }
    match($0, /"timestamp":"[0-9T:.Z-]+"/) { at = substr($0, RSTART + 13, RLENGTH - 14) }
    END {
      for (i = (n > keep ? n - keep : 0); i < n; i++) print seen[i % keep]
      if (bridge != "" && bridge_at != "") { sub(/}[[:space:]]*$/, ",\"timestamp\":\"" bridge_at "\"}", bridge); print bridge }
    }'
  return 0
}

# The Remote Control link a /clear leaves: /clear ends the session and starts
# another id in the same Claude process, whose Remote Control stays up, and the
# new transcript never names the link. It is the link, or none, of the latest
# active other session of Claude process `pid` started at `start` on this boot
# and distro; empty for none. Reads as mark_gone does, from inside the folder.
cleared_link() { # fleet pid start self
  local f pid start boot distro last began url best=-1 best_began=-1 link=""
  [[ $2 =~ ^[1-9][0-9]*$ && $3 =~ ^[0-9]+$ && -n $host_boot ]] || return 0
  while IFS=$'\t' read -r f pid start boot distro last began url; do
    [[ $f != "$4.json" && $pid == "$2" && $start == "$3" && $boot == "$host_boot" \
      && $distro == "${host_distro:-?}" && $last =~ ^[0-9]+$ && $began =~ ^[0-9]+$ ]] || continue
    # The later started breaks a tie within one second.
    (( last > best || (last == best && began > best_began) )) && best=$last best_began=$began link=$url
  done < <(cd -- "$1" 2>/dev/null || exit 0
    names=()
    for f in *.json; do
      [[ ${f%.json} =~ $UUID_RE && -f $f && ! -L $f ]] && names+=("$f")
    done
    session_rows '[((.claude.pid | numbers) // 0 | floor), ((.claude.start | numbers) // 0 | floor),
      (.host.boot | or_q), (.host.distro | or_q), last_active, ((.started_at | numbers) // 0 | floor),
      (.remote_url | or_q)]' "${names[@]}")
  [[ $link != "?" ]] && printf '%s' "$link"
  return 0
}

# The session file after one event, as compact JSON, or nothing when no field
# changed. `$old` is the current file's text (empty for none).
read -r -d '' APPLY <<'JQ' || true  # read returns 1 at the end of input
def clip: if type == "string" and length > 0 then .[0:$chars] else null end;
def text: if type == "string" and length > 0 then . else null end;
def need_reason($tool): if $tool == "AskUserQuestion" then "question"
  elif $tool == "ExitPlanMode" then "approve plan" else "approve \($tool // "a tool")" end;
def ended_as: {clear: "cleared", resume: "resumed elsewhere", logout: "logged out",
               prompt_input_exit: "exited", other: "stopped"}[.] // gsub("_"; " ");
# The background set, by id: add keeps an entry's first time, drop takes ids (non-strings ignored).
def bg_add($id; $kind): if ($id | text) == null then . elif any(.[]; .id == $id) then .
  else . + [{id: $id, kind: $kind, at: $now}] end;
# A Stop list's task as an entry: subagents are agents, shells shells, any other type a task.
def bg_kind: {subagent: "agent", shell: "shell"}[.type | strings] // "task";
# A status that means the task is over; any other, or none, still runs.
def finished: IN("completed", "finished", "failed", "killed", "stopped", "cancelled", "canceled");
# The session's turn is over: Stop ran (or the prompt sat idle) with work still out.
def turn_over: .reason == "background" or (.needs.turn_over // false) == true;
# A reply whose last line asks AJ to decide: it ends on a question mark, or
# hands him the call ("Your call: ..."), markdown aside (#246).
def ends_on_question: (text // "") | [split("\n")[] | gsub("^[\\s>*_#-]+|[\\s*_`]+$"; "") | select(length > 0)] | last
  | . != null and (test("\\?[)\"'\u201d\u2019]*$") or test("^(your (call|pick|decision)|over to you|you decide)\\b"; "i"));
# Needs you, asked by a subagent still out: nothing but its answer ends that.
# Who asks AJ and for what; a request made once the turn is over remembers that.
def asked($by; $tool): {by: $by, tool: $tool} + (if turn_over then {turn_over: true} else {} end);
def crew_asks: .state == "needs_you" and (.needs.by // "") != "" and (.needs.by as $by | any(.background[]; .id == $by));
def bg_drop($ids): ($ids | map(text | select(. != null))) as $gone | map(select(.id | IN($gone[]) | not));
# Remote Control. A link is only ever a claude.ai Claude Code session.
def rc_ok: if type == "string" and test("^https://claude\\.ai/code/[A-Za-z0-9_-]{1,128}$") then . else null end;
def rc_time: .timestamp | strings | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null;
# What one transcript line says of Remote Control: {url} for on (null when its
# link is not one to follow) or off, {on} for "the bridge is up" with no link,
# nothing when it says neither; a bridge-session record is {url, weak}: its
# bridge's link, which counts while nothing since the process started has said
# off, or when it follows an {on}. The
# attachment's url is set only when Claude Code attributes the session (null
# when attribution is off), so its sendUserFileHint, true
# while a Remote Control bridge is up, is what says off.
def rc_word:
  if .type == "system" and .subtype == "bridge_status" then {url: (.url | rc_ok)}
  elif .type == "attachment" and (.attachment | objects | .type) == "remote_session_change" then
    (.attachment.url | rc_ok) as $u
    | if $u != null then {url: $u} elif .attachment.sendUserFileHint == false then {url: null}
      elif .attachment.sendUserFileHint == true then {on: true} else empty end
  elif .type == "system" and (.content | strings | startswith("Remote Control disconnected")) then {url: null}
  elif .type == "bridge-session" then
    {url: (.bridgeSessionId | strings | select(test("^cse_[A-Za-z0-9]{1,100}$")) | "https://claude.ai/code/session_" + ltrimstr("cse_") | rc_ok), weak: true}
  else empty end;
# The task and tool-use ids of every <task-notification> block in a prompt.
def notified: if type == "string" then [scan("<task-notification>[\\s\\S]*?</task-notification>")
  | scan("<(?:task-id|tool-use-id)>\\s*([^<\\s]+)\\s*</(?:task-id|tool-use-id)>") | .[0]] else [] end;

. as $ev
| $ev.hook_event_name as $event
| ($ev.agent_id // "") as $agent
| ($old | try fromjson catch null
   | if type == "object" and .v == 1 and .session_id == $ev.session_id then . else null end) as $was
| if $was == null and $event == "SessionEnd" then empty
  elif $was.state == "ended" and $event != "SessionStart" then empty
  else
  ($was // {v: 1, session_id: $ev.session_id, name: null, started_at: $now,
            launch_dir: ($ev.cwd | text), claude: null, tmux: null, host: null, voice: null, voice_from: null,
            state: (if $event | IN("PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "SubagentStop") then "working" else "new" end),
            reason: null, needs: null, state_at: $now,
            where: null, touched: [], prompt: null, reply: null, error: null,
            ended: null, turns: 0, written_at: $now}) as $s
  | $s
  | .name = (($ev.session_title | text) // .name)
  | .fleet_name = (($fleet_agent | text) // .fleet_name)
  | .orchestrator = $orchestrator
  | (if $pid != "" then {pid: ($pid | tonumber), start: ($start | tonumber)} else null end) as $me
  # A new process (any start but a compaction) replaces what the file knew of
  # the old one: its pid, pane and host, unknowns included.
  | ($event == "SessionStart" and $ev.source != "compact") as $fresh
  | (if $tmux_pane != "" then {socket: $tmux_socket, pane: $tmux_pane} else null end) as $pane
  | (if $boot != "" then {boot: $boot, distro: ($distro | text)} else null end) as $host
  | .claude = (if $fresh then $me else (.claude // $me) end)
  | .tmux = (if $fresh then $pane else ($pane // .tmux) end)
  | .host = (if $fresh then $host else ($host // .host) end)
  # Remote Control: the newest word on it since this process started wins; a
  # tail with none keeps what the file knew. A new process starts with none,
  # and its transcript's older lines (a resumed session's) are the last one's.
  | (if $fresh then $now - 30 else (.remote_since | numbers) // 0 end) as $rc_since
  | (if $fresh then .remote_since = $rc_since else . end)
  | [$remote | split("\n")[] | try fromjson catch empty | objects
      | select((rc_time // 0) >= $rc_since) | (rc_time // 0) as $at | rc_word + {at: $at}] as $words
  # Remote Control on from startup and /remote-control answered at its menu
  # write no link of their own; the bridge record then names it, until this
  # process says otherwise (remote_heard). Claude Code re-appends the record
  # after Remote Control goes off too, so it never undoes an off; an
  # attachment saying the bridge is up ({on}) takes a record dated after it.
  | ([$words[] | select(.weak | not)] | last) as $said
  | ([$words[] | select((.weak | not) and .on != true)] | last) as $before
  | ([$words[] | select(.weak)] | last) as $bridge
  | (if $fresh then del(.remote_heard) else . end)
  | (if $said != null then .remote_heard = ($said.on != true) else . end)
  | (if $said.on == true then
       (if $bridge != null and $bridge.at >= $said.at then $bridge
        elif $before.url != null then $before else null end)
     elif $said != null then $said
     elif .remote_url == null and .remote_heard != true then $bridge
     else null end) as $rc
  # /clear keeps the process and its Remote Control: the cleared session's
  # file keeps the link, and the next session takes it ($cleared).
  | .remote_url = (if $event == "SessionEnd" and $ev.reason != "clear" then null
      elif $rc != null then $rc.url
      elif $fresh then $cleared | rc_ok
      else .remote_url | rc_ok end)
  | if .remote_url == null then del(.remote_url) else . end
  | (if $account != null then .account = $account else . end)
  # Where: the last edit's repo, or the cwd's until something is edited, or
  # once the edited checkout is gone (a removed worktree, its branch with it).
  # `git` is the checkout's git dir, kept only to tell that it is gone.
  | (if $repo != "" and ($by == "edit" or .where == null or .where.by == "cwd" or $where_gone)
     then {repo: $repo, worktree: ($worktree | text), branch: ($branch | text)}
     else null end) as $w
  | if $w == null then .
    elif .where != null and (.where | {repo, worktree, branch}) == $w
    then .where.by = (if $by == "edit" then "edit" else .where.by end) | .where.git = ($git | text)
      | .where.dir = ($dir | text) | .where.github = ($gh | text)
    else
      (if .where != null and .where.repo != $w.repo
       then .touched = ([{repo: .where.repo, at: $now}]
                        + (.touched | map(select(.repo != $s.where.repo and .repo != $w.repo))))[0:6]
       else . end)
      | .where = $w + {by: $by, at: $now, git: ($git | text), dir: ($dir | text), github: ($gh | text)}
    end
  | if .where.git == null then del(.where.git) else . end
  | if .where != null and .where.dir == null then del(.where.dir) else . end
  | if .where != null and .where.github == null then del(.where.github) else . end

  # A hold always applies. Without one a session takes a repo's home voice:
  # the repo it works in, else the one it started in, and the home of each
  # repo it then edits in, so agents launched from one folder read apart. A
  # face never follows the cwd alone. Files from before voice_from held.
  | .voice_from = (.voice_from // (if .voice != null then "hold" else null end))
  | ($homes[.where.repo // ""] | text) as $here
  | ($homes[$cwd_repo] | text) as $launch
  | if ($voice | text) != null then .voice = $voice | .voice_from = "hold" | del(.voice_repo)
    elif .voice == null and ($here // $launch) != null
    then .voice = ($here // $launch) | .voice_from = "home"
      | .voice_repo = (if $here != null then .where.repo else $cwd_repo end)
    elif .voice_from == "home" and .where.by == "edit" and $here != null and .voice_repo != .where.repo
    then .voice = $here | .voice_repo = .where.repo
    else . end

  # Background work: one entry per subagent or background shell still running,
  # so a turn that ends with work out stays working. An absent field is none.
  | ($ev.tool_input // {}) as $in
  | ($ev.tool_response // {}) as $out
  | (.background | if type == "array" then map(select(type == "object" and (.id | text) != null
       and (.kind | IN("agent", "shell", "task")) and (.at | type) == "number")) else [] end) as $bg
  # Stopped agents, one entry each, until STOPPED_TTL passes: their late launch
  # or tool event adds no phantom. Only a stop seen before any start (early)
  # blocks a start, so a resumed agent counts at once.
  | ((.background_stopped | if type == "array" then . else [] end)
     | map(select(type == "object" and (.id | text) != null and (.at | type) == "number" and $now - .at < $stopped_ttl))) as $tomb
  | ([$tomb[].id]) as $dead
  # Stops seen before any start: only these block a start, so a resumed agent counts at once.
  | ([$tomb[] | select(.early == true) | .id]) as $unstarted
  | .background_stopped = (if $fresh then []
      elif $event == "SubagentStop" and ($agent | text) != null
      then ([$tomb[] | select(.id != $agent)] + [{id: $agent, at: $now} + (if any($bg[]; .id == $agent) then {} else {early: true} end)])[-$bg_max:]
      else $tomb end)
  # The turn is over: Stop ran, or the prompt went idle with work still out.
  | (.state == "done" or turn_over) as $over
  | .background = (
      if $event == "SessionEnd" or $fresh then []
      elif $event == "SubagentStart" and ($agent | IN($unstarted[]) | not) then $bg | bg_add($agent; "agent")
      elif $event == "SubagentStop" then $bg | bg_drop([$agent])
      # A shell asked to run in the background, or one moved there at its timeout
      # or by hand, which only its task id tells.
      elif $event == "PostToolUse" and $ev.tool_name == "Bash"
           and ($in.run_in_background == true
                or (if ($out | type) == "object" then $out.backgroundTaskId | text else null end) != null) then
        $bg | bg_add(($out | objects | .backgroundTaskId | text) // ($ev.tool_use_id | text); "shell")
      # Only an async launch says an agent outlives the turn; SubagentStart cannot tell.
      elif $event == "PostToolUse" and $ev.tool_name == "Agent" and ($out | objects | .isAsync) == true
           and ($out.agentId | IN($dead[]) | not) then
        $bg | bg_add($out.agentId; "agent") | map(if .id == $out.agentId then .async = true else . end)
      # An idle prompt with no Stop is an interrupted turn: a subagent never seen to
      # launch async was in the foreground and died with it (Esc runs neither Stop
      # nor SubagentStop). A launched agent or a shell runs on.
      # An agent still asking after the turn's Stop, under a background agent
      # (nesting), is waiting, not dead; Esc runs no Stop, so its request ends here.
      elif $event == "Notification" and $ev.notification_type == "idle_prompt" then
        (if .state == "needs_you" and (.needs.turn_over // false) == true then .needs.by // "" else "" end) as $asker
        | (any($bg[]; .kind == "agent" and .async == true and .id != $asker)) as $parent
        | $bg | map(select(.kind != "agent" or .async == true or (.id == $asker and $parent)))
      elif $event == "PostToolUse" and ($ev.tool_name | IN("TaskStop", "KillShell")) then
        $bg | bg_drop([$in.task_id, $in.shell_id, ($out | objects | .task_id)])
      elif $event == "UserPromptSubmit" then $bg | bg_drop($ev.prompt | notified)
      # Stop lists what still runs; it is the truth when a dropped event left the set wrong.
      elif $event == "Stop" and ($ev.background_tasks | type) == "array" then
        [$ev.background_tasks[] | objects | select((.id | text) != null and (.status | finished | not))
         | .id as $id | {id: $id, kind: bg_kind, at: ([$bg[] | select(.id == $id) | .at][0] // $now)}
         | if .kind == "agent" then .async = true else . end]
      # With no list, an agent adopted in the turn and never seen async ended with it;
      # a real background one is adopted again, async, at its next event.
      elif $event == "Stop" then $bg | map(select(.adopted != true or .async == true))
      else $bg end
      # A subagent's own events show it still runs.
      | map(if .id == $agent and $now - .at >= 60 then .at = $now else . end)
      | .[-$bg_max:])
  # A Stop's task list is the truth until the next turn starts.
  | .background_listed = (if $fresh or $event == "UserPromptSubmit" then null
      elif $event == "Stop" then (if ($ev.background_tasks | type) == "array" then true else null end)
      else .background_listed end)
  # An agent the set never saw start (a lost SubagentStart, a hook installed
  # mid-session, one the idle prompt dropped) is adopted from its own events,
  # unless the turn is over and its Stop listed what still runs. Adopted after
  # the turn, it outlives the turn: async.
  | (($agent | text) as $aid
     | $aid != null and ($event | IN("SubagentStart", "SubagentStop", "SessionEnd", "Stop") | not) and ($fresh | not)
       and ($aid | IN($dead[]) | not) and (any(.background[]; .id == $aid) | not)
       and (($over and .background_listed == true) | not)) as $adopt
  | if $adopt then .background |= (bg_add($agent; "agent") | .[-$bg_max:]
      | map(if .id == $agent then .adopted = true | (if $over then .async = true else . end) else . end))
    else . end
  # No event says a background shell ended mid-turn, so the set keeps it until
  # Stop (#167). The shells Claude Code still runs (live_shells) are kept as
  # shells_live, which caps the card's count; a count cannot say which entry
  # ended, so entries go only once no shell runs at all.
  | if ($live | test("^[0-9]+$")) then
      ($live | tonumber) as $n
      # A Stop's own task list is the truth (a job that exec'd into a
      # non-shell program counts as no shell, but the list still names it).
      | if $event == "Stop" and ($ev.background_tasks | type) == "array" then del(.shells_live)
        else .shells_live = $n
          | if $n == 0 then .background |= map(select(.kind != "shell")) else . end end
    else del(.shells_live) end

  # State, with what it needs from AJ and who asked.
  | (if $event == "SessionStart" then
       if $was == null then {state: "new", reason: null}
       elif $ev.source == "compact" then {state: .state, reason: .reason}
       else {state: (if .prompt then "done" else "new" end), reason: null} end
     elif $event == "UserPromptSubmit" then {state: "working", reason: null}
     elif $event == "PermissionRequest" then
       {state: "needs_you", reason: need_reason($ev.tool_name), needs: asked($agent; $ev.tool_name)}
     elif $event == "PreToolUse" and ($ev.tool_name | IN("AskUserQuestion", "ExitPlanMode")) then
       {state: "needs_you", reason: need_reason($ev.tool_name), needs: asked($agent; $ev.tool_name)}
     elif $event == "Notification" and ($ev.notification_type | IN("elicitation_dialog", "elicitation_url_dialog")) then
       {state: "needs_you", reason: "question", needs: asked($agent; null)}
     elif ($event | IN("PostToolUse", "PostToolUseFailure")) and .state == "needs_you" and (.needs.by // "") == $agent
          and (.needs.tool == null or .needs.tool == $ev.tool_name) then
       # Answered after the turn ended: back to working in background, or done.
       if turn_over | not then {state: "working", reason: null}
       elif .background != [] then {state: "working", reason: "background"} else {state: "done", reason: null} end
     # A subagent still waiting on AJ outranks the turn's end, by Stop or by the idle prompt.
     elif ($event == "Stop" or ($event == "Notification" and $ev.notification_type == "idle_prompt")) and crew_asks then
       {state: .state, reason: .reason, needs: (.needs + {turn_over: true})}
     elif $event == "Notification" and $ev.notification_type == "idle_prompt"
          and (.state == "working" or (.state == "needs_you" and (.needs.at_end // false | not))) and $now - .state_at >= 30 then
       # The prompt is free; work still out keeps the session working.
       if .background != [] then {state: "working", reason: "background"} else {state: "done", reason: null} end
     # A turn that ends asking AJ to decide waits on him, whatever still runs.
     elif $event == "Stop" and ($ev.last_assistant_message | ends_on_question) then
       {state: "needs_you", reason: "question", needs: {at_end: true}}
     elif $event == "Stop" then
       if .background != [] then {state: "working", reason: "background"} else {state: "done", reason: null} end
     elif $event == "StopFailure" then {state: "error", reason: (($ev.error // "unknown") | gsub("_"; " "))}
     elif $event == "SessionEnd" then {state: "ended", reason: (($ev.reason // "other") | ended_as)}
     elif $adopt and .state == "done" then {state: "working", reason: "background"}
     else {state: .state, reason: .reason} end) as $t
  | (if $t.state != .state or $t.reason != .reason or $event == "UserPromptSubmit" then .state_at = $now else . end)
  | .needs = (if $t.state != "needs_you" then null else ($t.needs // .needs) end)
  | .state = $t.state
  | .reason = $t.reason

  # Always present, so the reader can tell this hook from one that never counted.
  | .turns = (if (.turns | type) == "number" then .turns else 0 end)

  # What AJ asked and what came back. A background subagent's report arrives
  # as a prompt starting <task-notification>; it is not AJ's.
  | if $event == "UserPromptSubmit" then
      # Every prompt starts a turn, a background task's notification too.
      .error = null | .turn_at = $now
      | if ($ev.prompt // "" | test("^\\s*<task-notification>")) then .
        else .prompt = (($ev.prompt | clip) as $p | if $p then {text: $p, at: $now} else .prompt end) end
    elif $event == "Stop" then
      (($ev.last_assistant_message | clip) as $r | if $r then .reply = {text: $r, at: $now} else . end)
      # Turns ended so far; Stop is the only event that ends one.
      | .turns += 1
    elif $event == "StopFailure" then
      .error = ([$ev.last_assistant_message, $ev.error_details, $ev.error] | map(clip | select(. != null)) | .[0])
    elif $event == "SessionEnd" then .ended = {reason: ($ev.reason // "other"), at: $now}
    elif $event == "SessionStart" and $ev.source != "compact" then .ended = null | .error = null
    else . end

  | if .background == [] then del(.background) else . end
  | if .background_stopped == [] then del(.background_stopped) else . end
  | if .background_listed == null then del(.background_listed) else . end

  # An event that changes nothing still refreshes written_at, once a minute.
  # turns_at stamps the count with the write, so a reader can tell a count an
  # older hook carried along unchanged from one this hook kept.
  | if $was != null and (del(.written_at, .turns_at) == ($was | del(.written_at, .turns_at)))
       and $now - $was.written_at < 60 then empty
    else .written_at = $now | .turns_at = $now end
  end
JQ

# Replace the file with `text` through a temp file in the same directory, so a
# reader never sees half of it.
write_atomic() { # file text
  local tmp="$1.$$.tmp"
  if printf '%s\n' "$2" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$1" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

# `klepsydra-fleet.sh queue set PATH [--by NAME] | clear | show`: name the
# Queue panel's file in <KLEPSYDRA_DIR>/queue.json, and who keeps it, so a
# session can own the queue AJ reads. Under WSL the overlay is a Windows app,
# so the path goes across as a Windows one. Unlike the hook it says what it did
# and exits non-zero on a mistake.
queue_cmd() { # args...
  local keeper path by="" osrelease="" usage="usage: klepsydra-fleet.sh queue set PATH [--by NAME] | clear | show"
  [[ -n ${KLEPSYDRA_DIR:-} ]] || { echo "klepsydra: no data folder (set KLEPSYDRA_DIR)" >&2; return 1; }
  keeper=$KLEPSYDRA_DIR/queue.json
  case ${1:-} in
    set)
      [[ -n ${2:-} ]] || { echo "$usage" >&2; return 2; }
      path=$2
      if [[ ${3:-} == --by ]]; then
        [[ -n ${4:-} && $# -eq 4 ]] || { echo "$usage" >&2; return 2; }
        # The panel's rule (queue.rs `kept`): 1 to 80 characters once trimmed, none a control.
        by=$(jq -rn --arg b "$4" '$b | gsub("^\\s+|\\s+$"; "") | select(length >= 1 and length <= 80 and (test("[\u0000-\u001f\u007f-\u009f]") | not))') || by=""
        [[ -n $by ]] || { echo "klepsydra: --by takes a name of 1 to 80 characters with no control characters" >&2; return 2; }
      elif [[ $# -ne 2 ]]; then
        echo "$usage" >&2; return 2
      fi
      [[ $path != -* ]] || { echo "$usage" >&2; return 2; }
      [[ $path == /* ]] || path=$PWD/$path
      [[ ! -d $path ]] || { echo "klepsydra: $2 is a folder; name the queue file" >&2; return 2; }
      { read -r osrelease <"$PROC_ROOT/sys/kernel/osrelease"; } 2>/dev/null
      if [[ $osrelease == *[Mm]icrosoft* ]] && command -v wslpath >/dev/null; then
        path=$(wslpath -w -- "$path" 2>/dev/null) || { echo "klepsydra: $2 has no Windows path" >&2; return 1; }
      fi
      local tmp=$keeper.$$.tmp voice=""
      # A keeper typed with --by is kept as typed. Without one, the session
      # running this names itself: the voice keryx holds for it, and that
      # character's name in the theme worn, which the panel then follows.
      if [[ -z $by ]] && claude_ancestor "${KLEPSYDRA_PID:-$$}"; then
        voice=$(holder_voice "$found_pid" "$found_start") || voice=""
        if [[ -n $voice ]]; then
          by=$(jq -r --arg v "$voice" '.characters[$v].name // empty | strings' "$CAST" 2>/dev/null) || by=""
          [[ -n $by ]] || by=$voice
        fi
      fi
      # -T: a folder at the name is a failure, not a place to move the file into.
      if ! { mkdir -p -- "$KLEPSYDRA_DIR" 2>/dev/null &&
             jq -nc --arg path "$path" --arg by "$by" --arg voice "$voice" \
               '{path: $path, by: (if $by == "" then null else $by end), voice: (if $voice == "" then null else $voice end)}' 2>/dev/null >"$tmp" &&
             mv -fT -- "$tmp" "$keeper" 2>/dev/null; }; then
        rm -f -- "$tmp" 2>/dev/null
        echo "klepsydra: could not write $keeper" >&2
        return 1
      fi
      echo "The Queue panel now reads $path${by:+, kept by $by}."
      ;;
    clear)
      rm -f -- "$keeper" || return 1
      echo "The Queue panel reads its default file again."
      ;;
    show)
      if [[ -f $keeper ]]; then cat -- "$keeper"; else echo "No queue.json: the Queue panel reads its default file."; fi
      ;;
    *) echo "$usage" >&2; return 2 ;;
  esac
}

# The voice a session file records, or nothing: a text scan, no process.
file_voice() { # text
  [[ $1 =~ \"voice\":\"([^\"]*)\" ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

# The voice whose colour a session file's window wears (#172): Heph's for the
# orchestrator, none for a worker holding Heph's voice, else its own.
HEPH_VOICE=am_michael
window_face() { # text
  local v
  if [[ $1 == *'"orchestrator":true'* ]]; then printf '%s' "$HEPH_VOICE"; return 0; fi
  v=$(file_voice "$1")
  [[ $v == "$HEPH_VOICE" ]] || printf '%s' "$v"
  return 0
}

# Marks the session's tmux window with its character's colour, on the
# launcher's own socket only, and clears it for a voice with no character.
# The accent and its ink come from the cast: the theme worn, which the
# overlay writes to $KLEPSYDRA_DIR/cast.json, else ~/.claude/klepsydra-cast.json
# (see CAST above); the ink is black or white, whichever has more WCAG
# contrast, as contrast.js picks.
WINDOW_STYLES=(window-status-style window-status-current-style)
colour_window() { # voice
  local accent="" ink="" row="" opt
  [[ ${tmux_socket##*/} == klepsydra && -n $tmux_pane && -n $1 && -r $CAST ]] || return 0
  # "unset" for a voice with no character; "accent ink" for one with a valid
  # accent; nothing (no tmux call) for a character whose accent is malformed.
  row=$(jq -r --arg v "$1" '
    def lin: ./255 | if . <= 0.04045 then . / 12.92 else pow((. + 0.055) / 1.055; 2.4) end;
    (.characters | objects | .[$v]) as $ch
    | if ($ch | type) != "object" then "unset"
      else ($ch.accent | strings | select(test("^#[0-9A-Fa-f]{6}\\z"))) as $h
        | ([1, 3, 5] | map(($h | ascii_downcase)[.:.+2] | explode | map(if . > 96 then . - 87 else . - 48 end) | .[0] * 16 + .[1] | lin)) as $c
        | (0.2126 * $c[0] + 0.7152 * $c[1] + 0.0722 * $c[2]) as $l
        | "\($h) \(if ($l + 0.05) / 0.05 >= 1.05 / ($l + 0.05) then "#000000" else "#ffffff" end)"
      end' "$CAST" 2>/dev/null) || return 0
  if [[ $row == unset ]]; then
    for opt in "${WINDOW_STYLES[@]}"; do
      timeout 2 tmux -S "$tmux_socket" set-option -w -u -t "$tmux_pane" "$opt" 2>/dev/null
    done
    return 0
  fi
  read -r accent ink <<<"$row"
  if [[ $accent =~ ^#[0-9A-Fa-f]{6}$ && $ink =~ ^#(000000|ffffff)$ ]]; then
    timeout 2 tmux -S "$tmux_socket" set-option -w -t "$tmux_pane" window-status-style "fg=$accent" 2>/dev/null
    timeout 2 tmux -S "$tmux_socket" set-option -w -t "$tmux_pane" window-status-current-style "bg=$accent,fg=$ink,bold" 2>/dev/null
  fi
  return 0
}

main() {
  local input fields session event cwd edited transcript source now file old new lock voice="" cwd_repo by=cwd remote="" cleared="" homes='{}' old_git where_gone=false account=null
  input=$(cat)
  fields=$(printf '%s' "$input" | jq -r '
    def s: if type == "string" then gsub("[\u001f\n]"; " ") else "" end;
    [ (.session_id | s), (.hook_event_name | s), (.cwd | s),
      (if .hook_event_name == "PostToolUse" and (.tool_name | IN("Edit", "Write", "NotebookEdit"))
       then ((.tool_input.file_path // .tool_input.notebook_path) | s) else "" end),
      (.transcript_path | s), (.source | s)
    ] | join("\u001f")' 2>/dev/null) || return 0
  IFS=$'\x1f' read -r session event cwd edited transcript source <<<"$fields"
  [[ $session =~ $UUID_RE && " $EVENTS " == *" $event "* ]] || return 0

  now=${KLEPSYDRA_NOW:-}
  [[ $now =~ ^[0-9]+$ ]] || printf -v now '%(%s)T' -1
  git_where "$cwd"
  cwd_repo=$where_repo # keryx names a session's repo by its cwd
  if [[ -n $edited ]]; then
    by=edit
    git_where "${edited%/*}"
    # A memory or plan file outside every repo says nothing about where work is.
    (( where_bare )) && where_repo=""
  fi
  local live=""
  if claude_ancestor "${KLEPSYDRA_PID:-$$}"; then
    voice=$(holder_voice "$found_pid" "$found_start") || voice=""
    live=$(live_shells "$found_pid" "${KLEPSYDRA_PID:-$$}")
  fi
  [[ -n $voice ]] || homes=$(home_voices "$now")

  host_facts
  tmux_facts
  # Who the session is in the fleet (#172): the agent name launch.sh starts it
  # with, and whether it is Heph, whom only Heph's face is ever given. Started
  # as "heph" (a move, a recovery) it is; started as any other agent it is
  # not. Otherwise it is the session on record in orchestrator.session, or a
  # /clear in the orchestrator's pane; a tmux restart reuses pane ids, so the
  # pane alone says so only while no session is on record.
  local agent=${KLEPSYDRA_AGENT:-} orchestrator=false orch_pane="" orch_sid=""
  local orch_state=${FLEET_STATE:-${HOME:-}/.local/state/fleet-orchestrator}
  [[ $agent =~ ^[A-Za-z0-9._-]{1,64}$ ]] || agent=""
  if [[ ${tmux_socket##*/} == "${KLEPSYDRA_TMUX_SOCKET:-klepsydra}" && -n $tmux_pane ]]; then
    { read -r orch_sid <"$orch_state/orchestrator.session"; } 2>/dev/null
    { read -r orch_pane <"$orch_state/orchestrator.pane"; } 2>/dev/null
    if [[ $agent == heph ]]; then
      orchestrator=true
    elif [[ -n $agent ]]; then
      orchestrator=false
    elif [[ -n $orch_sid ]]; then
      [[ $orch_sid == "$session" || ($event == SessionStart && $source == clear && $orch_pane == "$tmux_pane") ]] && orchestrator=true
    else
      [[ $orch_pane == "$tmux_pane" ]] && orchestrator=true
    fi
  fi
  [[ -n ${KLEPSYDRA_DIR:-} ]] || return 0
  local fleet=$KLEPSYDRA_DIR/fleet
  mkdir -p "$fleet" 2>/dev/null || return 0
  # Read before the lock: no other session waits on this one's transcript.
  [[ $event == SessionEnd ]] || remote=$(remote_lines "$transcript")
  # The account the session runs on, named as the statusLine names it, from
  # the global config CLAUDE_CONFIG_DIR picks: at its start and each prompt.
  if [[ $event == SessionStart || $event == UserPromptSubmit ]]; then
    account=$(jq -cn 'first(inputs) | (.oauthAccount | objects) // {}
      | select(.accountUuid | strings | test("^[0-9A-Za-z-]{1,64}$"))
      | {id: .accountUuid, label: (if .organizationType == "claude_team"
          then ((.organizationName | strings | gsub("[\u0001-\u001f\u007f-\u009f]"; "") | select(length > 0) | .[0:80]) // "Team") else "Personal" end)}' \
      "${CLAUDE_CONFIG_DIR:-${HOME:-}}/.claude.json" 2>/dev/null) || account=""
    [[ -n $account ]] || account=null
  fi
  { exec {lock}>>"$LOCK"; } 2>/dev/null || return 0
  flock -w 5 "$lock" || return 0

  [[ $event == SessionStart && $source == clear ]] && cleared=$(cleared_link "$fleet" "$found_pid" "$found_start" "$session")
  file=$fleet/$session.json
  old=""
  [[ -f $file ]] && { old=$(<"$file"); } 2>/dev/null
  # Heph by a /clear stays Heph on later events in the orchestrator's pane,
  # before orchestrator.session names the new session.
  [[ $orchestrator == false && -z $agent && -n $orch_sid && $orch_pane == "$tmux_pane" && $old == *'"orchestrator":true'* ]] && orchestrator=true
  # The git dir the file last named (an escaped path is not read): gone means the checkout was removed.
  old_git=""
  [[ $old =~ \"git\":\"(/[^\"\\]*)\" ]] && old_git=${BASH_REMATCH[1]}
  [[ -n $old_git && ! -e $old_git ]] && where_gone=true
  new=$(printf '%s' "$input" | jq -c --arg old "$old" --argjson now "$now" --argjson chars "$PROMPT_CHARS" --argjson bg_max "$BACKGROUND_MAX" --argjson stopped_ttl "$STOPPED_TTL" \
    --arg repo "$where_repo" --arg worktree "$where_worktree" --arg branch "$where_branch" \
    --arg git "$where_git" --argjson where_gone "$where_gone" --arg by "$by" --arg dir "$where_dir" --arg gh "$where_remote" \
    --arg tmux_socket "$tmux_socket" --arg tmux_pane "$tmux_pane" --arg boot "$host_boot" --arg distro "$host_distro" \
    --arg voice "$voice" --argjson homes "$homes" --arg cwd_repo "$cwd_repo" --arg pid "$found_pid" --arg start "$found_start" --arg remote "$remote" --arg cleared "$cleared" --argjson account "$account" --arg live "$live" \
    --arg fleet_agent "$agent" --argjson orchestrator "$orchestrator" \
    "$APPLY" 2>/dev/null) || new=""
  # A cast newer than this session's file: the theme changed under it. The
  # file's time is moved past the cast's, so one switch recolours it once.
  local recolour=0
  if [[ ${tmux_socket##*/} == klepsydra && -n $tmux_pane && -f $file && -n $CAST && $CAST -nt $file ]]; then recolour=1; fi
  [[ -n $new ]] && write_atomic "$file" "$new"
  (( recolour )) && touch -c -- "$file" 2>/dev/null
  # Only a start, a changed face or a new theme touches the window. The face
  # follows the wall's rule: Heph's for the orchestrator, never for a worker.
  local was_voice now_voice
  was_voice=$(window_face "$old") now_voice=$(window_face "${new:-$old}")
  if [[ $event == SessionStart || $was_voice != "$now_voice" ]]; then recolour=1; fi
  [[ $event == SessionStart ]] && mark_gone "$KLEPSYDRA_DIR" "$now" "$session"
  [[ $event == SessionStart ]] && prune_hourly "$PRUNE_STAMP" prune_fleet "$KLEPSYDRA_DIR" "$now"
  # tmux can hang for its timeout; no other hook waits on it, so drop the lock first.
  { exec {lock}>&-; } 2>/dev/null
  (( recolour )) && colour_window "$now_voice"
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ ${1:-} == queue ]]; then
    queue_cmd "${@:2}"
    exit
  fi
  (main) >/dev/null 2>&1 # a subshell, so no failure inside can end this shell non-zero
  exit 0
fi
