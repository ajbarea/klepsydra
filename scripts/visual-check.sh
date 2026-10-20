#!/usr/bin/env bash
# Screenshots the overlay across its states using Windows Chrome headless, so
# layout and the colour ramp get eyeballed against real rendering rather than
# assumed. Serves src/ on a local port; Windows reaches it via WSL localhost
# forwarding.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
port=${PORT:-8731}
chrome="/mnt/c/Program Files/Google/Chrome/Application/chrome.exe"
# Windows temp, not the install dir: Chrome needs a native path, and the
# gauge's own directories are for the gauge's data, not harness output.
win_out="/mnt/c/Users/$USER/AppData/Local/Temp/klepsydra-shots"
win_out_native=$(wslpath -w "$win_out")
fixture="$here/src/dev-fixture.json"
fleet_fixture="$here/src/dev-fleet.json"

mkdir -p "$win_out"
rm -f "$win_out"/*.png

# Serve src/ only if nothing already is, and take that server down on the way
# out. Left running it holds the port, and as a child of this script it keeps
# the script from exiting at all when a caller pipes its output.
if ! curl -sf -o /dev/null "http://127.0.0.1:$port/index.html"; then
  (cd "$here/src" && exec python3 -m http.server --bind 127.0.0.1 "$port" >/dev/null 2>&1) &
  server=$!
  # `|| true` because under `set -e` a kill of an already-dead server would
  # become the script's exit status; INT/TERM/HUP because bash runs no EXIT trap
  # when a signal is delivered straight to it.
  trap 'kill "$server" 2>/dev/null || true' EXIT INT TERM HUP
  # Poll rather than sleep: chrome shot against a server that is not up yet
  # writes nothing, and every chrome failure below is deliberately swallowed.
  for _ in $(seq 40); do
    curl -sf -o /dev/null "http://127.0.0.1:$port/index.html" && break
    sleep 0.25
  done
fi

if ! curl -sf -o /dev/null "http://127.0.0.1:$port/index.html"; then
  echo "nothing serving $here/src on port $port" >&2
  exit 1
fi

now=$(date +%s)

wanted=0
shot() { # name, query, window-size, page
  local name=$1 query=${2:-} size=${3:-450,120} page=${4:-index.html}
  wanted=$((wanted + 1))
  # Deterministic capture: no transitions, and enough budget to finish the fetch.
  # Pin the panel width; Chrome's --window-size is not the viewport width.
  if [[ "$query" == *"?"* ]]; then query="$query&still=1&w=430"; else query="?still=1&w=430"; fi
  "$chrome" --headless=new --disable-gpu --hide-scrollbars \
    --default-background-color=6E6E6E \
    --window-size="$size" \
    --virtual-time-budget=4000 \
    --screenshot="$win_out_native\\$name.png" \
    "http://127.0.0.1:$port/$page$query" >/dev/null 2>&1 || true
  printf '  %s\n' "$name.png"
}

entry() { # id, label, observed_ago_sec, windows-json
  printf '"%s":{"account":"%s","label":"%s","written_at":%s,"observed_at":%s,"windows":%s}' \
    "$1" "$1" "$2" "$((now - $3))" "$((now - $3))" "$4"
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

# Old and ended readings.
fixture_write "$(entry team RIT-CS-DQL 1800 "{\"five_hour\":$(w 55 7200)}")"
shot 06-old-reading
fixture_write "$(entry team RIT-CS-DQL 0 "{\"five_hour\":$(w 73 -60)}")"
shot 07-window-reset
# The account you switched away from, its window since emptied.
fixture_write "$(entry pers Personal 0 "{\"five_hour\":$(w 59 14700),\"seven_day\":$(w 31 116000)}"),$(entry team RIT-CS-DQL 30000 "{\"five_hour\":$(w 100 -21600)}")"
shot 08-switched-away-reset "" 450,160
fixture_write "$(entry live Personal 0 "{\"five_hour\":$(w 40 7200)}"),$(entry old Abandoned 2700000 "{\"five_hour\":$(w 90 7200)}")"
shot 09-abandoned-dropped
echo "compact ->"
# The taskbar layout: the same states as rings in one row, 48px tall or less.
fixture_write "$(entry team RIT-CS-DQL 0 "{\"five_hour\":$(w 88 3000)}"),$(entry pers Personal 0 "{\"five_hour\":$(w 21 14000),\"seven_day\":$(w 63 300000)}")"
shot c03-both-accounts "?layout=compact" 900,80
fixture_write "$(entry team RIT-CS-DQL 0 "{\"five_hour\":$(w 97 600)}")"
shot c04-critical "?layout=compact" 450,80
fixture_write "$(entry gw Gateway 0 "{\"spend_limit\":$(w 118 3600)}")"
shot c05-over-limit "?layout=compact" 450,80
fixture_write "$(entry team RIT-CS-DQL 0 "{\"five_hour\":$(w 73 -60)}")"
shot c07-window-reset "?layout=compact" 450,80
# Width holds across the percent's digits: these three come out equally wide.
for pct in 9 10 97; do
  fixture_write "$(entry team RIT-CS-DQL 0 "{\"five_hour\":$(w $pct 3000)}")"
  shot "c-width-$pct" "?layout=compact" 450,80
done
fixture_write "$(entry team RIT-CS-DQL 1800 "{\"five_hour\":$(w 55 7200)}")"
shot c06-old-reading "?layout=compact" 450,80
fixture_write "$(entry pers Personal 0 "{\"five_hour\":$(w 59 14700),\"seven_day\":$(w 31 116000)}"),$(entry team RIT-CS-DQL 30000 "{\"five_hour\":$(w 100 -21600)}")"
shot c08-switched-away-reset "?layout=compact" 900,80
for z in -3 1 2 4; do
  shot "c-zoom-$z" "?layout=compact&zoom=$z" 1400,140
done
rm -f "$fixture"
shot 10-waiting
shot c10-waiting "?layout=compact" 450,80

echo "zoom ->"
fixture_write "$(entry pers Personal 0 "{\"five_hour\":$(w 59 14700),\"seven_day\":$(w 31 116000)}"),$(entry team RIT-CS-DQL 30000 "{\"five_hour\":$(w 100 -21600)}")"
for z in -3 0 4 9; do
  shot "zoom-$z" "?zoom=$z" 1100,420
done
rm -f "$fixture"

echo "ramp comparison ->"
for p in 20 45 60 73 90 100; do
  fixture_write "$(entry team RIT-CS-DQL 0 "{\"five_hour\":$(w "$p" 7200)}")"
  shot "ramp-blend-$p" "?mode=blend" 450,90
  shot "ramp-bands-$p" "?mode=bands" 450,90
done
rm -f "$fixture"

echo "fleet ->"
# A snapshot as the reader hands it over: one session per status, the cast,
# Lorelei and fallback faces among them.
fleet_session() { # id, voice, status, reason, age_sec, name, quiet_age_sec
  jq -nc --arg id "$1" --arg voice "$2" --arg status "$3" --arg reason "$4" --argjson at "$((now - $5))" \
    --arg name "$6" --argjson quiet "${7:-null}" 'def opt: if . == "" then null else . end;
    {session_id: $id, name: ($name | opt), launch_dir: "/home/aj/ajsoftworks",
      voice: ($voice | opt), status: $status, reason: ($reason | opt), status_at: $at,
      where: {repo: "klepsydra", worktree: "fleet", branch: "feat/fleet-visualizer", at: $at},
      touched: [{repo: "ideas", at: ($at - 3600)}, {repo: "keryx", at: ($at - 9000)}],
      prompt: (if $status == "new" then null
               else {text: "i just want to be able to VIZ them, one glance at the screen and I know who needs me", at: ($at - 60)} end),
      reply: (if $status == "new" then null
              else {text: "That works with no model calls: the hook writes one file per session and the overlay reads them.", at: ($at - 30)} end),
      quiet_since: (if $quiet == null then null else $at - $quiet end),
      error: (if $status == "error" then "API Error: Rate limit reached" else null end), updated_at: $at}'
}
jq -s '{sessions: .}' \
  <(fleet_session 11111111-0000-4000-8000-000000000001 am_michael needs_you "approve Bash" 130 "Plan the fleet visualizer") \
  <(fleet_session 11111111-0000-4000-8000-000000000009 bm_george needs_you "question" 1900 "Choose the release date" 0) \
  <(fleet_session 11111111-0000-4000-8000-000000000002 af_bella error "rate limit" 400 "Rebuild the deck") \
  <(fleet_session 11111111-0000-4000-8000-000000000003 bf_emma working "" 45 "Port the hook") \
  <(fleet_session 11111111-0000-4000-8000-000000000008 am_adam working "" 700 "Sweep the logs" 600) \
  <(fleet_session 11111111-0000-4000-8000-000000000004 am_fenrir "done" "" 900 "Fix the CI pins") \
  <(fleet_session 11111111-0000-4000-8000-000000000005 "" new "" 20 "") \
  <(fleet_session 11111111-0000-4000-8000-000000000006 af_heart silent "" 300 "Draft the email") \
  <(fleet_session 11111111-0000-4000-8000-000000000007 am_puck ended "exited" 120 "Tidy worktrees") \
  >"$fleet_fixture"
fixture_write "$(entry pers Personal 0 "{\"five_hour\":$(w 46 9000),\"seven_day\":$(w 12 400000)}")"
shot 11-fleet-strip "" 1100,140
shot 12-fleet-strip-zoom "?zoom=4" 1500,260
shot c11-fleet-strip "?layout=compact" 1100,80
shot 13-fleet-wall-1920 "" 1920,1100 wall.html
shot 14-fleet-wall-1280 "" 1280,1000 wall.html
rm -f "$fixture" "$fleet_fixture"

echo "-> $win_out"

# Every chrome call is swallowed so one bad state cannot abort the run, which
# means a silent total failure otherwise reports as a clean sweep.
got=$(find "$win_out" -name '*.png' | wc -l)
if [ "$got" -ne "$wanted" ]; then
  echo "only $got of $wanted screenshots were written" >&2
  exit 1
fi
