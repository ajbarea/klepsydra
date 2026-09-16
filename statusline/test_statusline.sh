#!/usr/bin/env bash
# Fixture-driven tests for the statusLine producer. Run: bash statusline/test_statusline.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/klepsydra-statusline.sh"
fixtures="$here/fixtures"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0 fail=0

check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}

run() { KLEPSYDRA_OUT="$work/usage.json" bash "$script" <"$fixtures/$1"; }

echo "statusLine producer"

# --- both windows present -------------------------------------------------
rm -f "$work/usage.json"
display=$(run full.json)
check "full: terminal line" "$display" "Opus 5 · ctx 21% · 5h 73% · 7d 12%"
check "full: five_hour pct"  "$(jq -r '.windows.five_hour.used_percentage' "$work/usage.json")" "73.2"
check "full: five_hour reset" "$(jq -r '.windows.five_hour.resets_at' "$work/usage.json")" "1789000000"
check "full: seven_day pct"  "$(jq -r '.windows.seven_day.used_percentage' "$work/usage.json")" "12.9"
check "full: written_at set" "$(jq -r '.written_at | if . > 1700000000 then "yes" else "no" end' "$work/usage.json")" "yes"

# --- only one window ------------------------------------------------------
rm -f "$work/usage.json"
display=$(run five-hour-only.json)
check "one window: terminal line" "$display" "Opus 5 · ctx 5% · 5h 1%"
check "one window: no seven_day" "$(jq -r '.windows | has("seven_day")' "$work/usage.json")" "false"

# --- 0% must publish, not vanish -----------------------------------------
rm -f "$work/usage.json"
display=$(run zero-pct.json)
check "zero pct: terminal line" "$display" "Opus 5 · ctx 0% · 5h 0%"
check "zero pct: published"     "$(jq -r '.windows.five_hour.used_percentage' "$work/usage.json")" "0"

# --- gateway spend limit --------------------------------------------------
rm -f "$work/usage.json"
display=$(run spend-limit.json)
check "spend limit: terminal line" "$display" "Opus 5 · ctx 50% · spend 100%"
check "spend limit: published"     "$(jq -r '.windows.spend_limit.used_percentage' "$work/usage.json")" "100"

# --- absent rate_limits must NOT clobber a good file ----------------------
printf '{"written_at":1,"windows":{"five_hour":{"used_percentage":99,"resets_at":2}}}\n' >"$work/usage.json"
display=$(run no-rate-limits.json)
check "no limits: terminal line"  "$display" "Opus 5"
check "no limits: file preserved" "$(jq -r '.windows.five_hour.used_percentage' "$work/usage.json")" "99"

# --- malformed stdin must not clobber, must not error ---------------------
printf '{"written_at":1,"windows":{"five_hour":{"used_percentage":99,"resets_at":2}}}\n' >"$work/usage.json"
display=$(run malformed.json); rc=$?
check "malformed: exit 0"         "$rc" "0"
check "malformed: silent"         "$display" ""
check "malformed: file preserved" "$(jq -r '.windows.five_hour.used_percentage' "$work/usage.json")" "99"

# --- no stray temp files left behind --------------------------------------
check "no tmp litter" "$(find "$work" -name '*.tmp' | wc -l)" "0"

# --- unwritable destination must not kill the status line -----------------
display=$(KLEPSYDRA_OUT="/proc/nonexistent/usage.json" bash "$script" <"$fixtures/full.json"); rc=$?
check "unwritable dest: exit 0"    "$rc" "0"
check "unwritable dest: still echoes" "$display" "Opus 5 · ctx 21% · 5h 73% · 7d 12%"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
