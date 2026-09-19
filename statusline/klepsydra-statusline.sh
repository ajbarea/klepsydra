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
: "${KLEPSYDRA_DIR:=/mnt/c/Users/$USER/AppData/Local/dev.ajsoftworks.klepsydra}"

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
[[ -z "$account" ]] && account='{"id":"unknown","label":"Claude"}'

parsed=$(printf '%s' "$input" | jq -r \
  --argjson now "$(date +%s)" --argjson acct "$account" '
  def pct: (.used_percentage // empty) | floor;

  . as $root
  | ( $root.rate_limits // {} ) | with_entries(select(.value.used_percentage != null)) as $w
  |
  ( if ($w | length) == 0 then "SKIP"
    else { account: $acct.id, label: $acct.label, session: ($root.session_id // "unknown"),
           written_at: $now, windows: $w } | tojson
    end ),
  ( [ ( $w.five_hour   | if . then "5h \(pct)%"    else empty end ),
      ( $w.seven_day   | if . then "7d \(pct)%"    else empty end ),
      ( $w.spend_limit | if . then "spend \(pct)%" else empty end ) ] | join(" · ") ),
  ( [ ( $root.model.display_name // empty ),
      ( $root.context_window.used_percentage | if . then "ctx \(floor)%" else empty end ) ] | join(" · ") )
' 2>/dev/null) || parsed=""

# Malformed stdin: say nothing, write nothing, exit clean. A statusLine that
# errors here would spam every render.
[[ -z "$parsed" ]] && exit 0

payload=$(printf '%s' "$parsed" | sed -n 1p)
limits=$(printf '%s' "$parsed" | sed -n 2p)
extra=$(printf '%s' "$parsed" | sed -n 3p)

# No rate-limit windows in this render (pre-first-response, or none active).
# Leave the last good file alone -- another terminal may hold fresher data.
if [[ "$payload" != "SKIP" ]]; then
  id=$(printf '%s' "$account" | jq -r '.id')
  # A file per session: several terminals on one login each hold whatever their
  # own last API response reported, so sharing a file made them overwrite each
  # other with stale numbers. The overlay reconciles them.
  session=$(printf '%s' "$payload" | jq -r '.session')
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
