#!/usr/bin/env bash
# Guard against per-session-file forks in fleet scripts (#492 slice 1).
# live_session and fleet_sessions_tsv must read session files with one jq,
# not with a loop running jq or basename per file.
# Run: bash fleet/test_forks_sessions.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1

pass=0 fail=0
check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}

STRACE=${STRACE:-strace}
if ! command -v "$STRACE" >/dev/null 2>&1; then
  if [[ -n ${CI:-} ]]; then
    echo "FAIL: strace missing ($STRACE)"
    exit 1
  else
    echo "SKIP: no strace ($STRACE)"
    exit 0
  fi
fi

forks_of() {
  local log count
  log=$(mktemp)
  "$STRACE" -f -qq -e trace=clone,clone3,fork,vfork -e signal=none -o "$log" "$@" >/dev/null 2>&1 </dev/null
  count=$(grep -cE ' (clone|clone3|fork|vfork)\(' "$log" || true)
  rm -f -- "${log:?}"
  printf '%s' "$count"
}

work=$(mktemp -d)
trap 'rm -rf -- "${work:?}"' EXIT
mkdir -p "$work/k/fleet"

mk() {
  local n=$1 i u
  rm -f -- "$work"/k/fleet/*
  # Many ended files on %7: tmux reuses pane ids over time, so a pane has many ended files.
  for ((i = 1; i <= n; i++)); do
    u=$(printf '%08x-0000-4000-8000-%012x' "$i" "$i")
    printf '{"v":1,"tmux":{"pane":"%%7","socket":"/tmp/tmux-1/klepsydra"},"started_at":%d,"ended":{"at":%d},"claude":{"pid":%d,"start":5}}\n' "$i" "$i" "$((i + 1000))" > "$work/k/fleet/$u.json"
  done
  # Exactly one live file for %7
  printf '{"v":1,"tmux":{"pane":"%%7","socket":"/tmp/tmux-1/klepsydra"},"started_at":1000,"ended":null,"claude":{"pid":2007,"start":5}}\n' > "$work/k/fleet/00000007-0000-4000-8000-000000000007.json"
}

base=$(forks_of env KLEPSYDRA_DIR="$work/k" bash -c ". fleet/lib.sh")
mk 10
a=$(forks_of env KLEPSYDRA_DIR="$work/k" bash -c ". fleet/lib.sh; live_session %7")
rm -f -- "$work"/k/fleet/*
mk 60
b=$(forks_of env KLEPSYDRA_DIR="$work/k" bash -c ". fleet/lib.sh; live_session %7")

check "live_session forks do not grow with session files" "$((b - base))" "$((a - base))"
# Cap at 4 forks: the hook's session_rows / fleet_rows block sets the floor
# (command substitution, subshell cd, jq pipeline, process substitution).
check "live_session forks at most 4" "$(( a - base <= 4 ))" 1

rm -f -- "$work"/k/fleet/*
printf '{"v":1,"tmux":{"pane":"%%7","socket":"/tmp/tmux-1/klepsydra"},"started_at":100,"ended":null,"claude":{"pid":2007,"start":5}}\n' > "$work/k/fleet/00000007-0000-4000-8000-000000000007.json"
printf '{"v":1,"tmux":{"pane":"%%7","socket":"/tmp/tmux-1/klepsydra"},"started_at":50,"ended":{"at":1},"claude":{"pid":2070,"start":5}}\n' > "$work/k/fleet/00000070-0000-4000-8000-000000000070.json"
ln -s 00000007-0000-4000-8000-000000000007.json "$work/k/fleet/00000001-0000-4000-8000-000000000001.json"
printf '{"v":1,"tmux":' > "$work/k/fleet/00000002-0000-4000-8000-000000000002.json"
printf '{"v":1,"tmux":{"pane":"%%10","socket":"/tmp/tmux-1/klepsydra"},"started_at":10,"ended":null,"claude":{"pid":2010,"start":5}}\n' > "$work/k/fleet/notauuid.json"
printf '{"v":1,"tmux":"str","started_at":10,"ended":null,"claude":{"pid":2003,"start":5}}\n' > "$work/k/fleet/00000003-0000-4000-8000-000000000003.json"
printf '{"v":2,"tmux":{"pane":"%%10","socket":"/tmp/tmux-1/klepsydra"},"started_at":10,"ended":null,"claude":{"pid":2004,"start":5}}\n' > "$work/k/fleet/00000004-0000-4000-8000-000000000004.json"
printf '{"v":1,"tmux":{"pane":"%%9","socket":"/tmp/tmux-1/klepsydra"},"started_at":10,"ended":null,"claude":{"pid":2009,"start":5}}\n' > "$work/k/fleet/00000009-0000-4000-8000-000000000009.json"
printf '{"v":1,"tmux":{"pane":"%%9","socket":"/tmp/tmux-1/klepsydra"},"started_at":20,"ended":null,"claude":{"pid":2099,"start":5}}\n' > "$work/k/fleet/00000099-0000-4000-8000-000000000099.json"
printf '{"v":1,"tmux":{"pane":"%%11","socket":""},"started_at":10,"ended":null,"claude":{"pid":2011,"start":5}}\n' > "$work/k/fleet/00000011-0000-4000-8000-000000000011.json"
printf '{"v":1,"tmux":{"pane":"%%12"},"started_at":10,"ended":null,"claude":{"pid":2012,"start":5}}\n' > "$work/k/fleet/00000012-0000-4000-8000-000000000012.json"

out7=$(env KLEPSYDRA_DIR="$work/k" bash -c ". fleet/lib.sh; live_session %7" 2>/dev/null || true)
check "live_session %7 prints live %7 id" "$out7" "00000007-0000-4000-8000-000000000007"

rc9=0
env KLEPSYDRA_DIR="$work/k" bash -c ". fleet/lib.sh; live_session %9" >/dev/null 2>&1 || rc9=$?
check "live_session %9 fails (two live)" "$(( rc9 != 0 ))" 1

rc8=0
env KLEPSYDRA_DIR="$work/k" bash -c ". fleet/lib.sh; live_session %8" >/dev/null 2>&1 || rc8=$?
check "live_session %8 fails (none live)" "$(( rc8 != 0 ))" 1

valid_count=$(env KLEPSYDRA_DIR="$work/k" bash -c ". fleet/lib.sh; fleet_sessions_tsv" 2>/dev/null | wc -l || true)
check "fleet_sessions_tsv rows equal valid parseable files" "$(( valid_count ))" 6

fake_out=$(env KLEPSYDRA_DIR="$work/k" SESSION_ROWS="fake_file.json	%99	-	0	0	-	-" bash -c ". fleet/lib.sh; fleet_sessions_tsv" 2>/dev/null || true)
check "fleet_sessions_tsv honours SESSION_ROWS" "$fake_out" "fake_file.json	%99	-	0	0	-	-"

out11=$(env KLEPSYDRA_DIR="$work/k" FLEET_SOCK="klepsydra" bash -c ". fleet/lib.sh; eval \"\$(sed -n '/^fleet_sessions() {/,/^}/p' fleet/close.sh)\"; fleet_sessions %11" 2>/dev/null || true)
check "fleet_sessions %11 prints nothing" "$out11" ""

out12=$(env KLEPSYDRA_DIR="$work/k" FLEET_SOCK="klepsydra" bash -c ". fleet/lib.sh; eval \"\$(sed -n '/^fleet_sessions() {/,/^}/p' fleet/close.sh)\"; fleet_sessions %12" 2>/dev/null || true)
check "fleet_sessions %12 prints its id" "$out12" "00000012-0000-4000-8000-000000000012"

block_fleet=$(sed -n '/^# --- session rows/,/^# --- end session rows ---$/p' fleet/lib.sh)
block_hooks=$(sed -n '/^# --- session rows/,/^# --- end session rows ---$/p' hooks/klepsydra-fleet.sh)
check "session rows block identical in the fleet hook" "$block_fleet" "$block_hooks"
check "session rows block is non-empty" "$(( ${#block_fleet} > 0 ))" 1

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
