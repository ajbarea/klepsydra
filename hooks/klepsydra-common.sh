# Shared by klepsydra-fleet.sh, klepsydra-launch.sh, klepsydra-wrapup.sh and
# klepsydra-statusline.sh, which source it from their own folder. Defines
# functions and sets KLEPSYDRA_DIR when unset; runs nothing else.
# shellcheck shell=bash

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

# Fields of $PROC_ROOT/<pid>/stat after the command name, into the caller's
# `stat`: [0] is the state, [1] the parent pid, [19] the start time (field 22).
# The name sits in parentheses and may itself contain spaces or ")".
proc_stat() { # pid
  local raw=""
  { IFS= read -r raw <"${PROC_ROOT:-/proc}/$1/stat"; } 2>/dev/null
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
