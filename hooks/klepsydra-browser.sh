#!/usr/bin/env bash
# klepsydra-browser.sh: the browsers the Playwright MCP server opens (#379).
# The server (node .../playwright-mcp, started by a Claude Code session) runs
# Chrome as its own child, with the persistent profile
# ~/.cache/ms-playwright-mcp/mcp-chrome-<hash> (~/.cache/ms-playwright/ in
# older releases). Chrome stays open after an agent's last browser step, and a
# server killed with SIGKILL leaves it running with no parent (playwright-mcp
# #1568, playwright #43618). Only a browser's main process with such a profile
# (an exact --user-data-dir= argument, no --type=) is ever matched: AJ's own
# Chrome and Edge never are.
#
#   klepsydra-browser.sh            SessionEnd hook: close the browsers this
#                                   session's MCP server opened (TERM, then
#                                   KILL after KLEPSYDRA_BROWSER_WAIT_S, 1).
#   klepsydra-browser.sh --list     one line per open MCP browser: pid, MCP
#                                   server pid, Claude Code pid (- for none),
#                                   seconds since its profile last changed, profile.
#   klepsydra-browser.sh --reap STATE
#                                   orphans (no live MCP server, reparented to
#                                   init) get TERM, and KILL at a later call
#                                   once KLEPSYDRA_BROWSER_GRACE_S (10) have
#                                   passed; STATE keeps "pid start termed-at".
#                                   One line per action: term|kill|closed, pid,
#                                   profile, seconds since the TERM.
#   klepsydra-browser.sh --sync     each live session's "browser" mark in step
#                                   with the open browsers (see browser holders).
#   klepsydra-browser.sh --pre-tool PreToolUse hook on the Playwright browser
#                                   tools: exits 0 and never blocks; tells a
#                                   session whose window closed under it.
# Tests point KLEPSYDRA_PROC at a fake /proc, KLEPSYDRA_KILL at a fake kill
# and KLEPSYDRA_NOW at a fixed clock; KLEPSYDRA_PPID stands in for the hook's parent.
set -u
PROC_ROOT=${KLEPSYDRA_PROC:-/proc}
KILL=${KLEPSYDRA_KILL:-kill}
WAIT_S=${KLEPSYDRA_BROWSER_WAIT_S:-1}
GRACE_S=${KLEPSYDRA_BROWSER_GRACE_S:-10}
now() { printf '%s' "${KLEPSYDRA_NOW:-$(printf '%(%s)T' -1)}"; }

# --- proc stat: identical in hooks/klepsydra-fleet.sh, hooks/klepsydra-launch.sh, hooks/klepsydra-browser.sh and fleet/lib.sh ---
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

# The kernel's release string ("...microsoft-standard-WSL2" under WSL), into the
# caller's `osrelease`; fails when it cannot be read.
proc_osrelease() {
  osrelease=""
  { IFS= read -r osrelease <"$PROC_ROOT/sys/kernel/osrelease"; } 2>/dev/null
  [[ -n $osrelease ]]
}
# --- end proc stat ---

# Whether `pid` is Claude Code: by name, or an npm install's
# `node .../@anthropic-ai/claude-code/cli.js`, as keryx decides.
is_claude() { # pid
  local comm="" arg part
  local -a argv=() parts=()
  { IFS= read -r comm <"$PROC_ROOT/$1/comm"; } 2>/dev/null
  [[ $comm == claude || $comm == claude-code || $comm == agy || $comm == antigravity || $comm == antigravity-cli ]] && return 0
  { mapfile -d '' -t -n 2 argv <"$PROC_ROOT/$1/cmdline"; } 2>/dev/null || return 1
  for arg in "${argv[@]}"; do
    IFS=/ read -r -a parts <<<"$arg"
    for part in "${parts[@]}"; do
      [[ $part == claude || $part == claude-code || $part == agy || $part == antigravity || $part == antigravity-cli ]] && return 0
    done
  done
  return 1
}

# The MCP profile of `pid` into `profile` when it is an MCP browser's main
# process: one argument exactly --user-data-dir=<...>/ms-playwright-mcp/mcp-chrome-<hash>
# (or the older .../ms-playwright/mcp-chrome-<hash>), and no --type= (Chrome's
# renderers, zygote and GPU process carry one).
mcp_browser() { # pid
  local arg dir="" main=1
  local -a argv=()
  profile=""
  { mapfile -d '' -t argv <"$PROC_ROOT/$1/cmdline"; } 2>/dev/null || return 1
  for arg in "${argv[@]}"; do
    case $arg in
      --type=*) main=0 ;;
      --user-data-dir=*) dir=${arg#--user-data-dir=} ;;
    esac
  done
  (( main )) || return 1
  [[ $dir == /*/ms-playwright-mcp/mcp-chrome-* || $dir == /*/ms-playwright/mcp-chrome-* ]] || return 1
  [[ ${dir##*/} == mcp-chrome-* && $dir != *..* ]] || return 1
  profile=$dir
}

# Whether `pid` is a Playwright MCP server: an argument naming playwright-mcp
# or mcp-server-playwright (the old name), a path through @playwright/mcp, or
# playwright's own run-mcp-server.
is_mcp_server() { # pid
  local arg
  local -a argv=()
  { mapfile -d '' -t argv <"$PROC_ROOT/$1/cmdline"; } 2>/dev/null || return 1
  for arg in "${argv[@]}"; do
    case ${arg##*/} in playwright-mcp | mcp-server-playwright | run-mcp-server) return 0 ;; esac
    [[ $arg == @playwright/mcp || $arg == @playwright/mcp@* || $arg == */@playwright/mcp/* ]] && return 0
  done
  return 1
}

# Every MCP browser as "pid start ppid server claude profile" (server and
# claude: the nearest such ancestor, or -). One grep picks the candidates, so
# a pass reads only their files.
browsers() {
  local f pid start ppid server claude p i
  local -a stat=()
  while IFS= read -r f; do
    pid=${f#"$PROC_ROOT"/} pid=${pid%/cmdline}
    [[ $pid =~ ^[0-9]+$ ]] || continue
    mcp_browser "$pid" || continue
    proc_stat "$pid" && [[ ${stat[0]} != Z ]] || continue
    start=${stat[19]} ppid=${stat[1]} server=- claude=- p=$ppid
    for ((i = 0; i < 32 && p > 1; i++)); do
      if [[ $server == - ]] && is_mcp_server "$p"; then server=$p
      elif is_claude "$p"; then claude=$p; break; fi
      proc_stat "$p" || break
      p=${stat[1]}
    done
    printf '%s %s %s %s %s %s\n' "$pid" "$start" "$ppid" "$server" "$claude" "$profile"
  done < <(grep -lsaF -- 'mcp-chrome-' "$PROC_ROOT"/[0-9]*/cmdline 2>/dev/null)
}

# Whether `ppid` is what an orphan is reparented to: pid 1, or a subreaper
# named systemd or init (WSL's).
reparented() { # ppid
  local comm=""
  (( $1 <= 1 )) && return 0
  { IFS= read -r comm <"$PROC_ROOT/$1/comm"; } 2>/dev/null
  [[ $comm == systemd || $comm == init ]]
}

# Send SIG to `pid` only while it is still the MCP browser that started at `start`.
signal() { # SIG pid start
  local profile
  proc_is "$2" "$3" && mcp_browser "$2" || return 1
  "$KILL" "-$1" "$2" 2>/dev/null
}


# --- klepsydra dir: identical in hooks/klepsydra-fleet.sh, hooks/klepsydra-browser.sh and statusline/klepsydra-statusline.sh ---
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

# --- lock dir: identical in hooks/klepsydra-fleet.sh, hooks/klepsydra-launch.sh, hooks/klepsydra-browser.sh, statusline/klepsydra-statusline.sh and fleet/lib.sh ---
# The folder for the locks and stamps every caller must share: one per host and
# boot in ~/.local/state/klepsydra (KLEPSYDRA_STATE), made with mode 0700 and
# used only while it and the folder above it are ours, not symlinks and the
# folder above it is writable by no one else. Sets LOCK_DIR, or empties it,
# says why in LOCK_WHY and fails; never waits, never prints. Not
# XDG_RUNTIME_DIR: a WSL boot sets it before logind makes it, and the overlay's
# shells may lack it, so callers would split between two locks (#517). Making
# this boot's folder removes this host's folders last changed before this boot
# began (btime), which only ended boots can be. Another host's are untouched
# while hostnames differ (same-name hosts on one shared HOME still prune each
# other). An unusable hostname never prunes, so run-_-* accumulates one small
# folder per boot. The host is the kernel's hostname, so renaming a host
# mid-boot moves its lock.
lock_why() { # PATH [w]: fails with LOCK_WHY set when PATH is no folder of ours (w: or not writable)
  local mode
  if [[ -L $1 ]]; then LOCK_WHY="$1 is a symlink"
  elif [[ ! -e $1 ]]; then LOCK_WHY="$1 is missing"
  elif [[ ! -d $1 ]]; then LOCK_WHY="$1 is not a folder"
  elif [[ ! -O $1 ]]; then LOCK_WHY="$1 belongs to another user"
  elif [[ -n ${2:-} && ! -w $1 ]]; then
    mode=$(stat -c %A -- "$1" 2>/dev/null)
    if [[ ${mode:2:1} == w ]]; then LOCK_WHY="$1 cannot be written (a read-only file system, or locked)"
    else LOCK_WHY="$1 is not writable (mode ${mode:-unknown})"; fi
  else return 0; fi
  return 1
}
# shellcheck disable=SC2034 # LOCK_WHY is for the caller
lock_dir() {
  local base=${KLEPSYDRA_STATE:-} given boot="" host="" run old name mode key val btime="" m err prune=1
  LOCK_DIR="" LOCK_WHY=""
  if [[ -z $base ]]; then
    if [[ -n ${HOME:-} ]]; then base=$HOME
    else local HOME; unset HOME; base=~; fi # bash reads the password file's home
    base=$base/.local/state/klepsydra
  fi
  given=$base
  while [[ $base == */ ]]; do base=${base%/}; done
  if [[ $base != /* ]]; then
    if [[ $given == /* ]]; then LOCK_WHY="the state folder cannot be /"
    else LOCK_WHY="the state folder '$given' is not an absolute path"; fi
    return 1
  fi
  # builtin reads: no process
  { read -r boot <"${KLEPSYDRA_BOOT_ID:-/proc/sys/kernel/random/boot_id}"; } 2>/dev/null
  [[ $boot =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || boot=unknown prune=0
  { read -r host <"${KLEPSYDRA_HOSTNAME:-/proc/sys/kernel/hostname}"; } 2>/dev/null
  [[ ${#host} -le 253 && $host =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || host=_ prune=0 # no hostname has a _, so no host's prune reaches it
  run=$base/run-$host-$boot
  if [[ ! -e $run && ! -L $run ]]; then
    if [[ ! -e $base && ! -L $base ]]; then
      if ! err=$({ mkdir -p -- "${base%/*}" && mkdir -m 700 -- "$base"; } 2>&1); then
        if [[ ! -e $base && ! -L $base ]]; then # not another caller's mkdir winning
          LOCK_WHY="cannot make $base${err:+: ${err##*: }}"; return 1
        fi
      fi
    fi
    lock_why "$base" || return 1
    mode=$(stat -c %a -- "$base" 2>/dev/null) # once a boot: others could plant links
    if [[ ! $mode =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 8#022) != 0 )); then
      LOCK_WHY="$base is writable by its group or others (mode ${mode:-unknown})"; return 1
    fi
    if err=$(mkdir -m 700 -- "$run" 2>&1); then
      if (( prune )); then
        while read -r key val; do [[ $key == btime ]] && { btime=$val; break; }; done 2>/dev/null </proc/stat
        for old in "$base/run-$host-"*; do
          name=${old##*/}; name=${name#"run-$host-"}
          [[ $btime =~ ^[0-9]+$ && $name =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ &&
            $old != "$run" && -d $old && ! -L $old ]] || continue
          m=$(stat -c %Y -- "$old" 2>/dev/null) && [[ $m =~ ^[0-9]+$ ]] && (( m < btime )) && rm -rf -- "${old:?}" 2>/dev/null
        done
      fi
    elif [[ ! -e $run && ! -L $run ]]; then # not another caller's mkdir winning
      LOCK_WHY="cannot make $run${err:+: ${err##*: }}"; return 1
    fi
  fi
  lock_why "$base" && lock_why "$run" w || return 1
  LOCK_DIR=$run
}
# --- end lock dir ---

# --- session rows: identical in hooks/klepsydra-fleet.sh, hooks/klepsydra-browser.sh and fleet/lib.sh ---
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
    # The face of an orchestrator file, as the crate reads it: Athena (bf_alice
    # was her key before 11-02), else Hephaestus.
    def orch_face: if (.orchestrator_face | IN("bf_emma", "bf_alice")) then "bf_emma" else "am_michael" end;
    (index("\t")) as $i | .[:$i] as $f
    | (try (.[$i + 1:] | fromjson) catch empty) | select(type == "object" and .v == 1)
    | try ([$f] + ('"$fields"')) catch empty
    | @tsv' 2>/dev/null
}

# session_rows FIELDS over every session file in FOLDER (<uuid>.json, a file,
# never a link), read from inside it, where every name is short.
fleet_rows() { # folder fields
  ( cd -- "$1" 2>/dev/null || exit 0
    local f names=()
    for f in *.json; do
      [[ ${f%.json} =~ $UUID_RE && -f $f && ! -L $f ]] && names+=("$f")
    done
    session_rows "$2" "${names[@]}" )
}
# --- end session rows ---

# --- host facts: identical in hooks/klepsydra-fleet.sh and hooks/klepsydra-browser.sh ---
# Sets host_boot (this kernel boot) and host_distro (this WSL distro), each
# empty when unknown or malformed.
BOOT_ID=${KLEPSYDRA_BOOT_ID:-/proc/sys/kernel/random/boot_id}
host_facts() {
  host_boot="" host_distro=${WSL_DISTRO_NAME:-}
  { IFS= read -r host_boot <"$BOOT_ID"; } 2>/dev/null
  [[ $host_boot =~ ^[0-9a-f-]{36}$ ]] || host_boot=""
  [[ $host_distro =~ ^[A-Za-z0-9._-]{1,64}$ ]] || host_distro=""
}
# Whether a session file's BOOT and DISTRO ("?" for none) are this boot and
# distro (host_facts first): only there are its pids visible in this /proc.
on_this_host() { # boot distro
  local distro=$2
  [[ $distro == "?" ]] && distro=""
  [[ -n $host_boot && $1 == "$host_boot" && $distro == "$host_distro" ]]
}
# --- end host facts ---

# --- browser holders (#533) ---
# A session's card shows "browser" while its file's mark says its claude holds
# the shared Playwright browser. The fleet hook marks "used" once a Playwright
# browser tool succeeds and drops the mark at browser_close and the session's
# end. "used" becomes "open" only once this script sees that claude's own MCP
# Chrome (an mcp-chrome-* profile), so a setup it cannot see (--isolated, a
# custom profile, another browser) is never told its window closed. --sync
# (each resume pass) keeps the marks in step: "open" for a live session whose
# claude holds one, "closed" once it is gone, none for a "used" one it cannot
# confirm or a session whose claude died. --pre-tool confirms a "used" mark,
# and tells a session whose confirmed window closed under it, once. Every
# write takes the lock the fleet hook writes the files under.
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
SESSIONS=${KLEPSYDRA_DIR:+$KLEPSYDRA_DIR/fleet}
MARK_LOCK="" MARK_LOCK_SET=0
# What --sync reads of each session file: ended (0 or 1), boot and distro ("?"
# for none), claude pid and start, mark.
MARK_FIELDS='[(if .ended == null then 0 else 1 end), (.host.boot | or_q), (.host.distro | or_q),
  ((.claude.pid | numbers) // "-"), ((.claude.start | numbers) // "-"), ((.browser | strings) // "")]'
CLOSED_NOTE='The shared Playwright browser window this session was using has closed since its last browser step (closed by hand, or its MCP server restarted), so the page it had open is gone. Tell the user the window was closed while you were using it. If this browser step fails, call browser_close, then retry it in a fresh window.'

# Whether `dir` is the overlay's own data dir (as the fleet hook checks before
# writing there): absolute, without "..", named for the bundle identifier, and
# not a symlink.
own_data_dir() { # dir
  local dir=$1
  while [[ $dir == */ ]]; do dir=${dir%/}; done
  [[ -n $dir && $dir == /* ]] || return 1
  [[ $dir == */../* || $dir == */.. ]] && return 1
  [[ ${dir##*/} == dev.ajsoftworks.klepsydra ]] || return 1
  [[ ! -L $dir ]]
}

# Whether Claude Code `pid` has an open MCP browser of its own (not one under
# a nested claude). A walk down task/*/children (at most 512 processes) finds
# it cheaply. When the walk finds none, or the kernel has no children files,
# the full scan decides, so a racy walk never calls an open window closed;
# `walk` trusts a walk that found none (a recheck after a full scan did).
holds_browser() { # pid [walk]
  local root=$1 p k f profile seen=0 pid start ppid server claude dir
  local -a queue=("$1") kids=() stat=()
  if [[ -e $PROC_ROOT/$root/task/$root/children ]]; then
    while (( ${#queue[@]} && seen < 512 )); do
      p=${queue[0]} queue=("${queue[@]:1}")
      seen=$((seen + 1))
      if [[ $p != "$root" ]]; then
        mcp_browser "$p" && proc_stat "$p" && [[ ${stat[0]} != Z ]] && return 0
        is_claude "$p" && continue
      fi
      for f in "$PROC_ROOT/$p"/task/*/children; do
        kids=()
        { read -r -a kids <"$f"; } 2>/dev/null
        for k in "${kids[@]}"; do [[ $k =~ ^[0-9]+$ ]] && queue+=("$k"); done
      done
    done
    [[ ${2:-} == walk ]] && (( seen < 512 )) && return 1
  fi
  while read -r pid start ppid server claude dir; do
    [[ $claude == "$root" ]] && return 0
  done < <(browsers)
  return 1
}

# Sets FILE's mark to STATE ("open" or "closed", or "" for none) under the
# fleet hook's lock, only while the file is a live session's and its mark is
# still FROM; a change to "closed" or none first checks again (a walk) that
# claude PID holds no browser. Never waits past KLEPSYDRA_LOCK_WAIT_S (5).
set_mark() { # file state from [pid]
  local f=$1 lock new
  if (( !MARK_LOCK_SET )); then
    MARK_LOCK_SET=1
    lock_dir && MARK_LOCK=$LOCK_DIR/klepsydra-fleet-$UID.lock
  fi
  [[ -n $MARK_LOCK && -f $f && ! -L $f ]] || return 0
  { exec {lock}>>"$MARK_LOCK"; } 2>/dev/null || return 0
  if flock -w "${KLEPSYDRA_LOCK_WAIT_S:-5}" "$lock"; then
    if [[ -z ${4:-} ]] || ! holds_browser "$4" walk; then
      new=$(jq -c --arg to "$2" --arg from "$3" 'select(.ended == null and ((.browser | strings) // "") == $from)
        | if $to == "" then del(.browser) else .browser = $to end' "$f") &&
        [[ -n $new ]] && printf '%s\n' "$new" >"$f.$$.tmp" && mv -f -- "$f.$$.tmp" "$f"
      rm -f -- "$f.$$.tmp"
    fi
  fi
  exec {lock}>&-
  return 0
}

# Every live session's mark in step with the open browsers: only for a session
# of this boot and distro, whose pids this /proc shows.
sync_marks() {
  local -A held=()
  local pid start ppid server claude dir name ended boot distro cpid cstart mark
  [[ -n $SESSIONS && -d $SESSIONS ]] && own_data_dir "$KLEPSYDRA_DIR" || return 0
  host_facts
  while read -r pid start ppid server claude dir; do
    [[ $claude == - ]] || held[$claude]=1
  done < <(browsers)
  while IFS=$'\t' read -r name ended boot distro cpid cstart mark; do
    [[ $ended == 0 && $cpid =~ ^[0-9]+$ ]] && on_this_host "$boot" "$distro" || continue
    if ! proc_is "$cpid" "$cstart"; then
      [[ -z $mark ]] || set_mark "$SESSIONS/$name" "" "$mark"
    elif [[ -n ${held[$cpid]:-} ]]; then
      [[ $mark == open ]] || set_mark "$SESSIONS/$name" open "$mark"
    elif [[ $mark == open ]]; then
      set_mark "$SESSIONS/$name" closed open "$cpid"
    elif [[ $mark == used ]]; then
      set_mark "$SESSIONS/$name" "" used "$cpid"
    fi
  done < <(fleet_rows "$SESSIONS" "$MARK_FIELDS")
}

# PreToolUse on a Playwright browser tool: never blocks. browser_close drops
# the mark at once (the fleet hook's own drop is async). A "used" mark whose
# claude holds its MCP browser (the children walk) becomes "open". A confirmed
# mark ("open" or "closed") whose claude now holds none is dropped, and Claude
# gets CLOSED_NOTE. Reads the payload and the session's own file with
# builtins; walks /proc only for a marked session.
pre_tool() {
  local payload="" text="" tool sid file pid start mark
  IFS= read -r -d '' payload
  [[ $payload =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] || return 0
  tool=${BASH_REMATCH[1]}
  [[ $tool =~ ^mcp__.*playwright.*__browser_ ]] || return 0
  [[ -n $SESSIONS ]] && own_data_dir "$KLEPSYDRA_DIR" || return 0
  [[ $payload =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]] || return 0
  sid=${BASH_REMATCH[1]}
  [[ $sid =~ $UUID_RE ]] || return 0
  file=$SESSIONS/$sid.json
  [[ -f $file && ! -L $file ]] || return 0
  { IFS= read -r text <"$file"; } 2>/dev/null
  [[ $text =~ \"browser\":\"(used|open|closed)\" ]] || return 0
  mark=${BASH_REMATCH[1]}
  [[ $tool == *__browser_close ]] && { set_mark "$file" "" "$mark"; return 0; }
  [[ $text =~ \"claude\":\{\"pid\":([0-9]+),\"start\":([0-9]+)\} ]] || return 0
  pid=${BASH_REMATCH[1]} start=${BASH_REMATCH[2]}
  proc_is "$pid" "$start" || return 0
  if [[ $mark == used ]]; then
    holds_browser "$pid" walk && set_mark "$file" open used
    return 0
  fi
  holds_browser "$pid" && return 0
  set_mark "$file" "" "$mark" "$pid"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$CLOSED_NOTE"
}
# --- end browser holders ---

case ${1:-} in
  --list)
    n=$(now)
    while read -r pid start ppid server claude dir; do
      idle=$(find "$dir" -maxdepth 2 -printf '%Ts\n' 2>/dev/null | sort -rn | head -1)
      [[ $idle =~ ^[0-9]+$ ]] && idle=$((n - idle)) || idle=-
      (( ${idle/-/0} < 0 )) && idle=0
      printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$server" "$claude" "$idle" "$dir"
    done < <(browsers)
    ;;
  --reap)
    state=${2:?--reap takes a state file}
    n=$(now)
    declare -A termed=()
    while read -r pid start at; do
      [[ $pid =~ ^[0-9]+$ && $start =~ ^[0-9]+$ && $at =~ ^[0-9]+$ ]] && termed[$pid:$start]=$at
    done 2>/dev/null <"$state"
    declare -A keep=()
    while read -r pid start ppid server claude dir; do
      [[ $server == - ]] || continue
      reparented "$ppid" || continue
      k=$pid:$start
      if [[ -n ${termed[$k]:-} ]]; then
        keep[$k]=${termed[$k]}
        if (( n - termed[$k] >= GRACE_S )) && signal KILL "$pid" "$start"; then
          printf 'kill\t%s\t%s\t%s\n' "$pid" "$dir" "$((n - termed[$k]))"
        fi
      elif signal TERM "$pid" "$start"; then
        keep[$k]=$n
        printf 'term\t%s\t%s\t0\n' "$pid" "$dir"
      fi
    done < <(browsers)
    for k in "${!termed[@]}"; do
      [[ -n ${keep[$k]:-} ]] || printf 'closed\t%s\t-\t%s\n' "${k%%:*}" "$((n - termed[$k]))"
    done
    tmp=$state.$$
    if (( ${#keep[@]} )); then
      for k in "${!keep[@]}"; do printf '%s %s %s\n' "${k%%:*}" "${k#*:}" "${keep[$k]}"; done >"$tmp" && mv -f -- "$tmp" "$state"
    else
      rm -f -- "${state:?}"
    fi
    ;;
  --sync) sync_marks ;;
  --pre-tool)
    pre_tool
    exit 0
    ;;
  "")
    # SessionEnd: the hook runs under this session's Claude Code process.
    cat >/dev/null 2>&1
    me="" p=${KLEPSYDRA_PPID:-$PPID} # tests start from a fake parent
    declare -a stat=()
    for ((i = 0; i < 32 && p > 1; i++)); do
      is_claude "$p" && { me=$p; break; }
      proc_stat "$p" || break
      p=${stat[1]}
    done
    [[ -n $me ]] || exit 0
    left=()
    while read -r pid start ppid server claude dir; do
      [[ $claude == "$me" && $server != - ]] || continue
      signal TERM "$pid" "$start" && left+=("$pid:$start")
    done < <(browsers)
    (( ${#left[@]} )) || exit 0
    # The browsers' exit, within the budget Claude Code gives SessionEnd hooks
    # (1.5 s shared, unless raised); a browser still up then gets KILL.
    deadline=$(( ${EPOCHREALTIME/./} + WAIT_S * 1000000 ))
    while :; do
      up=()
      for k in "${left[@]}"; do proc_is "${k%%:*}" "${k#*:}" && up+=("$k"); done
      (( ${#up[@]} )) || exit 0
      (( ${EPOCHREALTIME/./} < deadline )) || break
      sleep 0.1
    done
    for k in "${up[@]}"; do signal KILL "${k%%:*}" "${k#*:}"; done
    exit 0
    ;;
  *)
    echo "usage: klepsydra-browser.sh [--list | --reap STATE | --sync | --pre-tool]" >&2
    exit 1
    ;;
esac
