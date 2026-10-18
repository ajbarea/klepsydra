#!/usr/bin/env bash
# Claude Code hook for the klepsydra fleet strip. Keeps one JSON file per
# session in <KLEPSYDRA_DIR>/fleet: its state, where it works, and what it was
# last asked and last said. Registered with "async": true on the events listed
# in README.md, so Claude Code never waits for it. It prints nothing and always
# exits 0.

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

# Sets where_repo, where_worktree and where_branch for `path` (empty when
# none), reading .git directly as keryx's source_name does, so no git process
# runs. A worktree is named by its main checkout, a submodule by its own folder,
# and a path outside any repo by its own name.
git_where() { # path
  local here=${1%/} folder dotgit link gitdir common main
  where_repo="" where_worktree="" where_branch=""
  [[ -n $here ]] || here=/
  if [[ $here != /* ]]; then where_repo=${here##*/}; return; fi
  folder=$here
  while :; do
    dotgit=$folder/.git
    if [[ -d $dotgit ]]; then
      where_repo=${folder##*/}
      branch_of "$dotgit"
      return
    elif [[ -f $dotgit ]]; then
      link=""
      { IFS= read -r link <"$dotgit"; } 2>/dev/null
      where_repo=${folder##*/}
      [[ $link == gitdir:* ]] || return
      gitdir=${link#gitdir:}
      gitdir=${gitdir#"${gitdir%%[![:space:]]*}"}
      [[ $gitdir == /* ]] || gitdir=$folder/$gitdir
      if [[ -f $gitdir/commondir ]]; then
        common=""
        { IFS= read -r common <"$gitdir/commondir"; } 2>/dev/null
        [[ $common == /* ]] || common=$gitdir/$common
        if main=$(cd "$common" 2>/dev/null && pwd -P); then
          main=${main%/*}
          where_repo=${main##*/}
          where_worktree=${folder##*/}
        fi
      fi
      branch_of "$gitdir"
      return
    fi
    [[ $folder == / ]] && break
    folder=${folder%/*}
    [[ -n $folder ]] || folder=/
  done
  where_repo=${here##*/}
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

# Fields of /proc/<pid>/stat after the command name, into `stat`: [0] is the
# state, [1] the parent pid, [19] the start time. The name sits in parentheses
# and may itself contain spaces or ")".
proc_stat() { # pid
  local raw=""
  { IFS= read -r raw <"$PROC_ROOT/$1/stat"; } 2>/dev/null
  [[ $raw == *") "* ]] || return 1
  read -r -a stat <<<"${raw##*") "}"
  (( ${#stat[@]} > 19 ))
}

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

# The voice keryx holds for a terminal, or nothing without keryx or a hold.
holder_voice() { # pid start
  [[ -n $VOICES && -r $VOICES ]] || return 0
  jq -r --arg h "$1:$2" '.holders[$h].voice // empty | strings' "$VOICES" 2>/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  exit 0
fi
