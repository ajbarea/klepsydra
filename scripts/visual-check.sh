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
  local name=$1 query=${2:-} size=${3:-420,90}
  # Deterministic capture: no transitions, and enough budget to finish the fetch.
  if [[ "$query" == *"?"* ]]; then query="$query&still=1"; else query="?still=1"; fi
  "$chrome" --headless=new --disable-gpu --hide-scrollbars \
    --default-background-color=6E6E6E \
    --window-size="$size" \
    --virtual-time-budget=4000 \
    --screenshot="C:\\Users\\$USER\\AppData\\Local\\Klepsydra\\shots\\$name.png" \
    "http://127.0.0.1:$port/index.html$query" >/dev/null 2>&1 || true
  printf '  %s\n' "$name.png"
}

write_fixture() { # used_percentage, resets_in_sec, written_ago_sec
  cat >"$fixture" <<EOF
{"written_at": $((now - $3)),
 "windows": {"five_hour": {"used_percentage": $1, "resets_at": $((now + $2))},
             "seven_day": {"used_percentage": 12.4, "resets_at": $((now + 400000))}}}
EOF
}

echo "rendering states ->"
write_fixture 1    17880 0 ; shot 01-fresh
write_fixture 45   9000  0 ; shot 02-mid
write_fixture 73.2 8040  0 ; shot 03-high
write_fixture 95   600   0 ; shot 04-critical
write_fixture 100  120   0 ; shot 05-full
write_fixture 60   7200  0 ; shot 06-two-windows "?secondary=seven_day" 420,130
write_fixture 50   7200  1800 ; shot 07-stale
write_fixture 73   -60   0 ; shot 08-window-reset
rm -f "$fixture"           ; shot 09-waiting

echo "-> $win_out"

# Ramp comparison: same percentages, blend vs bands.
echo "ramp comparison ->"
for p in 20 45 60 73 90 100; do
  write_fixture $p 7200 0
  shot "ramp-blend-$p" "?mode=blend"
  shot "ramp-bands-$p" "?mode=bands"
done
