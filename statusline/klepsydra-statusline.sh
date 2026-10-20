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
PRUNE_STAMP=${XDG_RUNTIME_DIR:-/tmp}/klepsydra-readings-$UID.pruned
PRUNE_LOCK=${PRUNE_STAMP%.pruned}.lock
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
  local -A type=() mt=() ino=() listed=() emptied=()
  local -a readings=() doomed=()
  while IFS= read -r -d '' line; do
    [[ $line =~ ^([^|]+)\|([0-9]+)\|([0-9]+)\|(.+)$ ]] || continue
    type[${BASH_REMATCH[4]}]=${BASH_REMATCH[1]}
    mt[${BASH_REMATCH[4]}]=${BASH_REMATCH[2]}
    ino[${BASH_REMATCH[4]}]=${BASH_REMATCH[3]}
  done < <(LC_ALL=C stat --printf '%F|%Y|%i|%n\0' -- * */*.json */*.tmp 2>/dev/null)
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
    # account with a stamp that is not a number is left alone.
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
            odd: ([$r.observed_at, $r.written_at] | any(. != null and type != "number")),
            stamp: (if $r.observed_at != null then $r.observed_at else $r.written_at end),
            ended: ($r.windows | type == "object" and length > 0
              and all(.[]; type == "object" and (.resets_at | type) == "number"
                and .resets_at < $now - $ended_for)) })
      | group_by(.account)[] | select(any(.odd) | not)
      | (map(select(.observed) | .stamp) | max) as $seen
      | ($seen != null and all(.[]; .observed or .stamp == null or .stamp <= $seen)) as $by_time
      | (if $by_time then $seen else map(.stamp | numbers) | max end) as $written
      | .[] | select(.ended and .stamp != null)
      | select(($written | not) or $written < $now - $drop or ($by_time and .stamp != $seen))
      | .f' "${readings[@]}" 2>/dev/null)
  fi
  if (( ${#doomed[@]} )); then
    # A writer may have renamed a new reading into place since the stat; a
    # rename brings a new inode, so only a file still on its old one goes.
    while IFS= read -r -d '' line; do
      [[ $line =~ ^([0-9]+)\|(.+)$ ]] || continue
      f=${BASH_REMATCH[2]}
      [[ -n ${listed[$f]:-} && ${BASH_REMATCH[1]} == "${ino[$f]}" ]] || continue
      rm -f -- "$f" && emptied[${f%%/*}]=1
    done < <(LC_ALL=C stat --printf '%i|%n\0' -- "${doomed[@]}" 2>/dev/null)
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
              then (.organizationName // "Team")
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

  . as $root
  | ( $root.session_id // "unknown" ) as $session
  | ( $root.rate_limits // {} ) | with_entries(select(.value.used_percentage != null)) as $w
  |
  # A reading with no live window says nothing about now; a real response
  # always reports the window it counts against. Skipping it also keeps a
  # session whose file was pruned from republishing its last response as new.
  ( if ($w | length) == 0 then "SKIP"
    elif ($w | all(.[]; (.resets_at | type) == "number" and .resets_at <= $now)) then "SKIP"
    else { account: $acct.id, label: $acct.label, session: $session,
           written_at: $now, observed_at: $now,
           api_ms: ($root.cost.total_api_duration_ms // null), windows: $w } | tojson
    end ),
  ( [ ( $w.five_hour   | if . then "5h \(pct)%"    else empty end ),
      ( $w.seven_day   | if . then "7d \(pct)%"    else empty end ),
      ( $w.spend_limit | if . then "spend \(pct)%" else empty end ) ] | join(" · ") ),
  ( [ ( $root.model.display_name // empty ),
      ( $root.context_window.used_percentage | if . then "ctx \(floor)%" else empty end ) ] | join(" · ") ),
  $acct.id,
  $session,
  ( $root.session_name // "" | tostring | gsub("[\t\r\n]"; " ") )
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
if [[ -n "$KLEPSYDRA_DIR" ]] && own_data_dir "$KLEPSYDRA_DIR" && prune_due "$PRUNE_STAMP" "$now" &&
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
