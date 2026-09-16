#!/usr/bin/env bash
# Claude Code statusLine command. Reads the session JSON on stdin, publishes the
# rate-limit windows to a file the klepsydra overlay polls, and echoes a compact
# readout back to the terminal.
#
# Wire it up in ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "~/.claude/klepsydra-statusline.sh" }

set -uo pipefail

# Where the overlay looks. Override to test, or to target a different Windows user.
: "${KLEPSYDRA_OUT:=/mnt/c/Users/$USER/AppData/Local/Klepsydra/usage.json}"

input=$(cat)

# One jq pass emits both payloads: line 1 is the file, line 2 is the terminal line.
# `windows` is a map so a future limit type needs no change here.
parsed=$(printf '%s' "$input" | jq -r --argjson now "$(date +%s)" '
  def pct: (.used_percentage // empty) | floor;

  ( .rate_limits // {} )
  | with_entries(select(.value.used_percentage != null))
  as $w
  |
  ( if ($w | length) == 0 then "SKIP"
    else { written_at: $now, windows: $w } | tojson
    end ),
  ( [ ( $w.five_hour   | if . then "5h \(pct)%"  else empty end ),
      ( $w.seven_day   | if . then "7d \(pct)%"  else empty end ),
      ( $w.spend_limit | if . then "spend \(pct)%" else empty end ) ]
    | join(" · ") )
' 2>/dev/null) || parsed=""

# Malformed stdin: say nothing, write nothing, exit clean. A statusLine that
# errors here would spam every render.
if [[ -z "$parsed" ]]; then
  exit 0
fi

payload=$(printf '%s' "$parsed" | sed -n 1p)
display=$(printf '%s' "$parsed" | sed -n 2p)

# No rate-limit windows in this render (pre-first-response, or none active).
# Leave the last good file alone -- another terminal may hold fresher data.
if [[ "$payload" != "SKIP" ]]; then
  out_dir=$(dirname "$KLEPSYDRA_OUT")
  if mkdir -p "$out_dir" 2>/dev/null; then
    # tmp-then-rename so a concurrent reader never sees a half-written file.
    tmp="${KLEPSYDRA_OUT}.$$.tmp"
    if printf '%s\n' "$payload" >"$tmp" 2>/dev/null; then
      mv -f "$tmp" "$KLEPSYDRA_OUT" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi
fi

# Context percentage and model round out the terminal line.
extra=$(printf '%s' "$input" | jq -r '
  [ ( .model.display_name // empty ),
    ( .context_window.used_percentage | if . then "ctx \(floor)%" else empty end ) ]
  | join(" · ")
' 2>/dev/null)

line="$extra"
if [[ -n "$display" ]]; then
  if [[ -n "$line" ]]; then line+=" · $display"; else line="$display"; fi
fi
printf '%s' "$line"
