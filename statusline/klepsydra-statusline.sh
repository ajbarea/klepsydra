#!/usr/bin/env bash
# Claude Code statusLine command. Reads the session JSON on stdin, publishes the
# rate-limit windows to a file the klepsydra overlay polls, and echoes a compact
# readout back to the terminal.
#
# Wire it up in ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "~/.claude/klepsydra-statusline.sh" }
#
# Each logged-in account publishes to its own file, so terminals signed into
# different accounts never overwrite each other.

set -uo pipefail

# The overlay's app-local-data dir, named for the bundle identifier in
# src-tauri/tauri.conf.json. Not the install dir: the uninstaller's "delete app
# data" reaches only this one, and a per-machine install cannot be written to.
# Under WSL the overlay is a Windows app, so the hook writes across to it. On
# Linux, Tauri honours XDG_DATA_HOME only when it is absolute, and so must we,
# or the readings land under whatever directory Claude Code is running in.
if [[ -z "${KLEPSYDRA_DIR:-}" ]]; then
  osrelease=""
  { read -r osrelease </proc/sys/kernel/osrelease; } 2>/dev/null  # builtin: runs every render
  if [[ "$osrelease" == *[Mm]icrosoft* ]]; then
    KLEPSYDRA_DIR="/mnt/c/Users/$USER/AppData/Local/dev.ajsoftworks.klepsydra"
  else
    data_home="$HOME/.local/share"
    [[ "${XDG_DATA_HOME:-}" == /* ]] && data_home="$XDG_DATA_HOME"
    KLEPSYDRA_DIR="$data_home/dev.ajsoftworks.klepsydra"
  fi
fi

input=$(cat)

# The statusLine payload carries no account identity, so take it from the global
# config -- which CLAUDE_CONFIG_DIR relocates, giving each simultaneous login
# its own file.
config="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
account=$(jq -c '
  .oauthAccount // {}
  | { id:    (.accountUuid // "unknown"),
      label: (if .organizationType == "claude_team"
              then (.organizationName // "Team")
              else "Personal" end) }
' "$config" 2>/dev/null) || account=""
# A config that exists but does not parse is one Claude Code is rewriting; a
# reading published now would be filed under "unknown".
torn=false
if [[ -z "$account" ]]; then
  [[ -e "$config" ]] && torn=true
  account='{"id":"unknown","label":"Claude"}'
fi

# Lines out: the file to publish (or SKIP), the windows readout, the model and
# context readout, the account id, the session id.
parsed=$(printf '%s' "$input" | jq -r \
  --argjson now "$(date +%s)" --argjson acct "$account" '
  def pct: (.used_percentage // empty) | floor;

  . as $root
  | ( $root.session_id // "unknown" ) as $session
  | ( $root.rate_limits // {} ) | with_entries(select(.value.used_percentage != null)) as $w
  |
  ( if ($w | length) == 0 then "SKIP"
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
  $session
' 2>/dev/null) || parsed=""

# Malformed stdin: say nothing, write nothing, exit clean. A statusLine that
# errors here would spam every render.
[[ -z "$parsed" ]] && exit 0

payload=$(printf '%s' "$parsed" | sed -n 1p)
limits=$(printf '%s' "$parsed" | sed -n 2p)
extra=$(printf '%s' "$parsed" | sed -n 3p)
id=$(printf '%s' "$parsed" | sed -n 4p)
session=$(printf '%s' "$parsed" | sed -n 5p)

# Claude Code also re-runs this on refreshInterval, at a window's reset time
# and on mode toggles, passing the session's last API response again. Only a
# new response is news: republishing an old one would stamp it as fresh and
# file it under whichever login is current, which after a switch is not the
# account that served it. A new response adds API time; without that, only
# changed windows count, and a window dropped at its reset is no change.
repeats_last_reading() {
  local earlier=("$KLEPSYDRA_DIR"/accounts/*/"$session".json)
  [[ -e "${earlier[0]}" ]] || return 1
  jq -en --argjson now "$payload" '
    [inputs] | max_by(.written_at) as $was
    | ( ($now.api_ms | type) == "number" and ($was.api_ms | type) == "number"
        and $now.api_ms > $was.api_ms ) as $responded
    | ($responded | not)
      and ($now.windows | all(to_entries[]; $was.windows[.key] == .value))
  ' "${earlier[@]}" >/dev/null 2>&1
}

# SKIP: no rate-limit windows in this render (pre-first-response, or none
# active). Leave the last good file alone -- another terminal may hold fresher
# data. A file per session: several terminals on one login each hold whatever
# their own last API response reported, so sharing a file made them overwrite
# each other with stale numbers. The overlay reconciles them.
if [[ "$payload" != "SKIP" ]] && ! $torn && ! repeats_last_reading; then
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

line="$extra"
if [[ -n "$limits" ]]; then
  if [[ -n "$line" ]]; then line+=" · $limits"; else line="$limits"; fi
fi
printf '%s' "$line"
