#!/usr/bin/env bash
# Claude Code statusLine command. Reads the session JSON on stdin, publishes the
# rate-limit windows to a file the klepsydra overlay polls, writes the session's
# heartbeat for the fleet strip, and echoes a compact readout back to the
# terminal.
#
# Wire it up in ~/.claude/settings.json (README.md has the whole block):
#   "statusLine": { "type": "command", "command": "~/.claude/klepsydra-statusline.sh",
#                   "refreshInterval": 30 }
#
# Each logged-in account publishes to its own file, so terminals signed into
# different accounts never overwrite each other.

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

KLEPSYDRA_DIR="${KLEPSYDRA_DIR:-}"  # unresolvable: publish nothing, still echo
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

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

# Readings the gauge can never draw again: a session's file whose every window
# ended over a day ago, unless it is its account's newest, which goes too once
# the gauge drops the account (DROP_AFTER_MS in src/gauge.js). An account the
# gauge reconciles without trusting its times (an old hook's files) keeps
# every reading until it is dropped. Write litter goes at a day old. Only <account>/<uuid>.json and
# <account>/<uuid>.json.<digits>.tmp inside <dir>/accounts, never through a
# symlink, and only in the overlay's own data dir.
PRUNE_ENDED_FOR=86400
PRUNE_DROP_AFTER=$((30 * 86400))
PRUNE_LITTER_AFTER=86400
# --- lock dir: identical in hooks/klepsydra-fleet.sh, hooks/klepsydra-launch.sh, statusline/klepsydra-statusline.sh and fleet/lib.sh ---
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
lock_dir # no folder: no prune
PRUNE_STAMP=${LOCK_DIR:+$LOCK_DIR/klepsydra-readings-$UID.pruned}
PRUNE_LOCK=${PRUNE_STAMP:+${PRUNE_STAMP%.pruned}.lock}
prune_readings() { # dir now
  local dir=$1 now=$2
  own_data_dir "$dir" || return 1
  while [[ $dir == */ ]]; do dir=${dir%/}; done
  [[ $now =~ ^[0-9]+$ ]] || return 1
  [[ -L $dir/accounts ]] && return 1
  [[ -d $dir/accounts ]] || return 0
  # From inside the folder every name is short, which matters on /mnt/c.
  ( cd -- "$dir/accounts" 2>/dev/null && prune_readings_here "$now" )
}

# prune_readings' work, in the accounts folder. Types and mtimes come from one
# stat (which does not follow links) and the readings are parsed by one jq.
prune_readings_here() { # now
  local now=$1 line name f acct sess
  local -A type=() mt=() id=() listed=() emptied=()
  local -a readings=() doomed=()
  while IFS= read -r -d '' line; do
    [[ $line =~ ^([^|]+)\|([0-9]+)\|([^|]+)\|(.+)$ ]] || continue
    type[${BASH_REMATCH[4]}]=${BASH_REMATCH[1]}
    mt[${BASH_REMATCH[4]}]=${BASH_REMATCH[2]}
    id[${BASH_REMATCH[4]}]=${BASH_REMATCH[3]}
  done < <(LC_ALL=C stat --printf '%F|%Y|%i %y|%n\0' -- * */*.json */*.tmp 2>/dev/null)
  plain() { [[ ${type[$1]:-} == "regular file" || ${type[$1]:-} == "regular empty file" ]]; } # name
  # An account folder, not a link to one; its name never starts with a dash.
  owned() { [[ $1 =~ ^[0-9A-Za-z][0-9A-Za-z-]*$ && ${type[$1]:-} == directory ]]; } # account

  for name in */*.json; do
    [[ $name =~ ^([^/]+)/([^/]+)\.json$ ]] || continue
    acct=${BASH_REMATCH[1]} sess=${BASH_REMATCH[2]}
    if owned "$acct" && [[ $sess =~ $UUID_RE ]] && plain "$name"; then
      readings+=("$name"); listed[$name]=1
    fi
  done
  if (( ${#readings[@]} )); then
    # A file of more than one line, or one that does not parse, is kept; one
    # without a final newline runs into the next and both fail to parse. The
    # rest follows src/gauge.js: which readings it sees (toRows), how it groups
    # and stamps them, and when it trusts their times (reconcilable). An
    # account is left alone if any reading has an account id that is not a
    # string or a stamp that is not a whole second between 1970 and 2100 (NaN
    # fails the whole-second test), since jq reads those differently from the
    # overlay.
    while IFS= read -r f; do
      # Only a name this function globbed is ever deleted, whatever jq printed.
      [[ -n ${listed[$f]:-} ]] && doomed+=("$f")
    done < <(jq -nRr --argjson now "$now" --argjson ended_for "$PRUNE_ENDED_FOR" \
      --argjson drop "$PRUNE_DROP_AFTER" '
      [inputs | {f: input_filename, r: (try fromjson catch null)}]
      | group_by(.f) | map(select(length == 1) | .[0].r as $r | select($r | type == "object")
        | select($r.windows | type == "object" or type == "array")
        | { f: .[0].f, account: ($r.account // "?" | tostring),
            observed: ($r.observed_at != null),
            odd: (($r.account | . != null and type != "string")
              or ([$r.observed_at, $r.written_at] | any(. != null and (type != "number"
                or . != floor or . < 0 or . > 4102444800)))),
            stamp: (if $r.observed_at != null then $r.observed_at else $r.written_at end),
            ended: ($r.windows | type == "object" and length > 0
              and all(.[]; type == "object" and (.resets_at | type) == "number"
                and .resets_at < $now - $ended_for)) })
      | group_by(.account)[] | select(any(.odd) | not)
      | (map(select(.observed) | .stamp) | max) as $seen
      | ($seen != null and all(.[]; .observed or .stamp == null or .stamp <= $seen)) as $by_time
      | (if $by_time then $seen else map(.stamp | numbers) | max end) as $written
      | .[] | select(.ended and .stamp != null)
      | select($written < $now - $drop or ($by_time and .stamp != $seen))
      | .f' "${readings[@]}" 2>/dev/null)
  fi
  if (( ${#doomed[@]} )); then
    # A writer may have renamed a new reading into place since the stat, and
    # ext4 can hand the new file the old inode, so only a file with the same
    # inode and the same mtime to the nanosecond goes. One renamed in between
    # this check and the rm comes back on its session's next render.
    while IFS= read -r -d '' line; do
      [[ $line =~ ^([^|]+)\|(.+)$ ]] || continue
      f=${BASH_REMATCH[2]}
      [[ -n ${listed[$f]:-} && ${BASH_REMATCH[1]} == "${id[$f]}" ]] || continue
      rm -f -- "$f" && emptied[${f%%/*}]=1
    done < <(LC_ALL=C stat --printf '%i %y|%n\0' -- "${doomed[@]}" 2>/dev/null)
  fi
  # A folder left empty goes; one a writer has just made again stays.
  for acct in "${!emptied[@]}"; do rmdir -- "$acct" 2>/dev/null; done

  for name in */*.tmp; do
    [[ $name =~ ^([^/]+)/([^/]+)\.json\.[0-9]+\.tmp$ ]] || continue
    acct=${BASH_REMATCH[1]} sess=${BASH_REMATCH[2]}
    if owned "$acct" && [[ $sess =~ $UUID_RE ]] && plain "$name" &&
      (( now - mt[$name] > PRUNE_LITTER_AFTER )); then
      rm -f -- "$name"
    fi
  done
  return 0
}

input=$(cat)
now=${KLEPSYDRA_NOW:-}
[[ $now =~ ^[0-9]+$ ]] || printf -v now '%(%s)T' -1

# The statusLine payload carries no account identity, so take it from the global
# config -- which CLAUDE_CONFIG_DIR relocates, giving each simultaneous login
# its own file.
config="${CLAUDE_CONFIG_DIR:-${HOME:-}}/.claude.json"
account=$(jq -c '
  (.oauthAccount | objects) // {}
  | { id:    (.accountUuid // "unknown"),
      label: (if .organizationType == "claude_team"
              then ((.organizationName | strings | select(length > 0)) // "Team")
              else "Personal" end) }
' "$config" 2>/dev/null) || account=""
# A config that reads but does not parse is one Claude Code is rewriting; a
# reading published now would be filed under "unknown".
torn=false
if [[ -z "$account" ]]; then
  [[ -r "$config" ]] && torn=true
  account='{"id":"unknown","label":"Claude"}'
fi

# Lines out: the file to publish (or SKIP), the windows readout, the model and
# context readout, the account id, the session id, the session name.
parsed=$(printf '%s' "$input" | jq -r \
  --argjson now "$now" --argjson acct "$account" '
  def pct: (.used_percentage // empty) | floor;
  def parse_reset:
    if .reset_time != null then
      (try (.reset_time | fromdateiso8601) catch ($now + (.reset_in_seconds // 0)))
    else
      ($now + (.reset_in_seconds // 0))
    end;

  . as $root
  | ( $root.session_id // $root.conversation_id // "unknown" ) as $session
  | ( if ($root.quota != null) then {
        id: "agy-primary",
        label: ($root.plan_tier // "Google AI Pro"),
        harness: "agy"
      } else $acct end ) as $effective_acct
  | ( if ($root.rate_limits != null) then
        ($root.rate_limits | with_entries(select(.value.used_percentage != null)))
      elif ($root.quota != null) then
        ( {}
          | if $root.quota["gemini-5h"] and ($root.quota["gemini-5h"].disabled | not) then
              .five_hour = {
                used_percentage: (((1 - $root.quota["gemini-5h"].remaining_fraction) * 10000 | round) / 100),
                resets_at: ($root.quota["gemini-5h"] | parse_reset)
              }
            else . end
          | if $root.quota["gemini-weekly"] and ($root.quota["gemini-weekly"].disabled | not) then
              .seven_day = {
                used_percentage: (((1 - $root.quota["gemini-weekly"].remaining_fraction) * 10000 | round) / 100),
                resets_at: ($root.quota["gemini-weekly"] | parse_reset)
              }
            else . end
          | if $root.quota["3p-5h"] and ($root.quota["3p-5h"].disabled | not) then
              .claude_gpt = {
                used_percentage: (((1 - $root.quota["3p-5h"].remaining_fraction) * 10000 | round) / 100),
                resets_at: ($root.quota["3p-5h"] | parse_reset)
              }
            else . end
        )
      else {} end ) as $w
  |
  # A reading with no live window says nothing about now; a real response
  # always reports the window it counts against. Skipping it also keeps a
  # session whose file was pruned from republishing its last response as new.
  ( if ($w | length) == 0 then "SKIP"
    elif ($w | all(.[]; (.resets_at | type) == "number" and .resets_at <= $now)) then "SKIP"
    else { account: $effective_acct.id, label: $effective_acct.label,
           harness: ($effective_acct.harness // null),
           session: $session, written_at: $now, observed_at: $now,
           api_ms: ($root.cost.total_api_duration_ms // null), windows: $w }
         | if .harness == null then del(.harness) else . end
         | tojson
    end ),
  ( [ ( $w.five_hour   | if . then "5h \(pct)%"    else empty end ),
      ( $w.seven_day   | if . then "7d \(pct)%"    else empty end ),
      ( $w.spend_limit | if . then "spend \(pct)%" else empty end ) ] | join(" · ") ),
  ( [ ( $root.model.display_name // $root.model.id // empty ),
      ( $root.context_window.used_percentage | if . then "ctx \(floor)%" else empty end ) ] | join(" · ") ),
  $effective_acct.id,
  $session,
  ( ($root.session_name // $root.title // "") | tostring | gsub("[\t\r\n]"; " ") )
' 2>/dev/null) || parsed=""

# Malformed stdin: say nothing, write nothing, exit clean. A statusLine that
# errors here would spam every render.
[[ -z "$parsed" ]] && exit 0

{
  IFS= read -r payload
  IFS= read -r limits
  IFS= read -r extra
  IFS= read -r id
  IFS= read -r session
  IFS= read -r name
} <<<"$parsed"
[[ $id == agy-* ]] && torn=false

if [[ -z "$name" ]]; then
  if [[ -n "$KLEPSYDRA_DIR" && -f "$KLEPSYDRA_DIR/fleet/$session.json" ]]; then
    name=$(jq -r '.name // empty' "$KLEPSYDRA_DIR/fleet/$session.json" 2>/dev/null || true)
  fi
fi

# The fleet strip's heartbeat: the session's name (its terminal tab title) and
# the 10 s bucket it was written in. Rewritten only when either changes, so a
# render costs a read and at most one write per 10 s.
if [[ -n "$KLEPSYDRA_DIR" ]] &&
  [[ $session =~ $UUID_RE ]]; then
  beat="$KLEPSYDRA_DIR/fleet/$session.beat"
  beat_line="$name"$'\t'"$((now / 10))"
  was=""
  { IFS= read -r was <"$beat"; } 2>/dev/null
  if [[ "$was" != "$beat_line" ]] && mkdir -p "${beat%/*}" 2>/dev/null; then
    tmp="$beat.$$.tmp"
    if printf '%s\n' "$beat_line" >"$tmp" 2>/dev/null; then
      mv -f "$tmp" "$beat" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi
fi

# Claude Code also re-runs this on refreshInterval, at a window's reset time
# and on mode toggles, passing the session's last API response again. Only a
# new response is news: republishing an old one would stamp it as fresh and
# file it under whichever login is current, which after a switch is not the
# account that served it. A new response changes the session's API time (which
# can restart lower on resume); without that, only changed windows count, and
# a window dropped at its reset is no change.
repeats_last_reading() {
  local earlier=("$KLEPSYDRA_DIR"/accounts/*/"$session".json)
  [[ -e "${earlier[0]}" ]] || return 1
  jq -en --argjson now "$payload" '
    [inputs] | max_by(.written_at) as $was
    | ( ($now.api_ms | type) == "number" and ($was.api_ms | type) == "number"
        and $now.api_ms != $was.api_ms ) as $responded
    | ($responded | not)
      and ($now.windows | all(to_entries[]; $was.windows[.key] == .value))
  ' "${earlier[@]}" >/dev/null 2>&1
}

# SKIP: no rate-limit windows in this render (pre-first-response, or none
# active). Leave the last good file alone -- another terminal may hold fresher
# data. A file per session: several terminals on one login each hold whatever
# their own last API response reported, so sharing a file made them overwrite
# each other with stale numbers. The overlay reconciles them.
if [[ "$payload" != "SKIP" && -n "$KLEPSYDRA_DIR" ]] && ! $torn && ! repeats_last_reading; then
  out_dir="$KLEPSYDRA_DIR/accounts/$id"
  if mkdir -p "$out_dir" 2>/dev/null; then
    out="$out_dir/$session.json"
    # tmp-then-rename so a concurrent reader never sees a half-written file.
    tmp="$out.$$.tmp"
    if printf '%s\n' "$payload" >"$tmp" 2>/dev/null; then
      mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi
fi

# A due prune runs detached, holding a lock taken here, so a render never waits
# on it and two terminals never prune at once.
if [[ -n "$KLEPSYDRA_DIR" && -n $PRUNE_STAMP ]] && own_data_dir "$KLEPSYDRA_DIR" && prune_due "$PRUNE_STAMP" "$now" &&
  { exec {plock}>>"$PRUNE_LOCK"; } 2>/dev/null; then
  if flock -n "$plock" 2>/dev/null; then
    prune_hourly "$PRUNE_STAMP" prune_readings "$KLEPSYDRA_DIR" "$now" </dev/null >/dev/null 2>&1 &
  fi
  exec {plock}>&-
fi

line="$extra"
if [[ -n "$limits" ]]; then
  if [[ -n "$line" ]]; then line+=" · $limits"; else line="$limits"; fi
fi
printf '%s' "$line"
