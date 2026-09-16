#!/usr/bin/env bash
# Screenshots the overlay across its states using Windows Chrome headless, so
# layout and the colour ramp get eyeballed against real rendering rather than
# assumed. Serves src/ on a local port; Windows reaches it via WSL localhost
# forwarding.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
port=${PORT:-8731}
chrome="/mnt/c/Program Files/Google/Chrome/Application/chrome.exe"
win_out="/mnt/c/Users/$USER/AppData/Local/Klepsydra/shots"
fixture="$here/src/dev-fixture.json"

mkdir -p "$win_out"
rm -f "$win_out"/*.png

if ! curl -sf -o /dev/null "http://127.0.0.1:$port/index.html"; then
  (cd "$here/src" && python3 -m http.server "$port" >/dev/null 2>&1 &)
  sleep 1
fi

now=$(date +%s)

shot() { # name, query, window-size
  local name=$1 query=${2:-} size=${3:-450,120}
  # Deterministic capture: no transitions, and enough budget to finish the fetch.
  # Pin the panel width; Chrome's --window-size is not the viewport width.
  if [[ "$query" == *"?"* ]]; then query="$query&still=1&w=430"; else query="?still=1&w=430"; fi
  "$chrome" --headless=new --disable-gpu --hide-scrollbars \
    --default-background-color=6E6E6E \
    --window-size="$size" \
    --virtual-time-budget=4000 \
    --screenshot="C:\\Users\\$USER\\AppData\\Local\\Klepsydra\\shots\\$name.png" \
    "http://127.0.0.1:$port/index.html$query" >/dev/null 2>&1 || true
  printf '  %s\n' "$name.png"
}

entry() { # id, label, written_ago_sec, windows-json
  printf '"%s":{"account":"%s","label":"%s","written_at":%s,"windows":%s}' \
    "$1" "$1" "$2" "$((now - $3))" "$4"
}
w() { printf '{"used_percentage":%s,"resets_at":%s}' "$1" "$((now + $2))"; }
fixture_write() { printf '{%s}\n' "$1" >"$fixture"; }

echo "rendering states ->"

# One account, session only -- the shape a team seat reports.
fixture_write "$(entry team RIT-CS-DQL 0 "{\"five_hour\":$(w 32 16000)}")"
shot 01-team-only

# One account reporting both windows.
fixture_write "$(entry pers Personal 0 "{\"five_hour\":$(w 46 9000),\"seven_day\":$(w 12 400000)}")"
shot 02-personal-both

# Both accounts at once: the reason rows are labelled.
fixture_write "$(entry team RIT-CS-DQL 0 "{\"five_hour\":$(w 88 3000)}"),$(entry pers Personal 0 "{\"five_hour\":$(w 21 14000),\"seven_day\":$(w 63 300000)}")"
shot 03-both-accounts "" 450,160

# Critical, and a gateway spend limit past 100.
fixture_write "$(entry team RIT-CS-DQL 0 "{\"five_hour\":$(w 97 600)}")"
shot 04-critical
fixture_write "$(entry gw Gateway 0 "{\"spend_limit\":$(w 118 3600)}")"
shot 05-over-limit

# Degraded readings.
fixture_write "$(entry team RIT-CS-DQL 1800 "{\"five_hour\":$(w 55 7200)}")"
shot 06-stale
fixture_write "$(entry team RIT-CS-DQL 0 "{\"five_hour\":$(w 73 -60)}")"
shot 07-window-reset
fixture_write "$(entry live Personal 0 "{\"five_hour\":$(w 40 7200)}"),$(entry old Abandoned 60000 "{\"five_hour\":$(w 90 7200)}")"
shot 08-abandoned-dropped
rm -f "$fixture"
shot 09-waiting

echo "ramp comparison ->"
for p in 20 45 60 73 90 100; do
  fixture_write "$(entry team RIT-CS-DQL 0 "{\"five_hour\":$(w "$p" 7200)}")"
  shot "ramp-blend-$p" "?mode=blend" 450,90
  shot "ramp-bands-$p" "?mode=bands" 450,90
done
rm -f "$fixture"

echo "-> $win_out"
