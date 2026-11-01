#!/usr/bin/env bash
# A tmux suite stopped mid-run must not keep the lock it ran under (#193, #239).
# Each suite runs under flock on a private lock and is stopped after a few
# seconds: by TERM, its trap stops its tmux server; by KILL, no trap runs and
# the server outlives it, but holds no descriptor of the lock.
# Run: bash fleet/test_heavy_lock.sh
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
export TMUX_TMPDIR="$work/tmux" # every -L socket the suites make lands here
mkdir -p "$TMUX_TMPDIR"
sockdir="$TMUX_TMPDIR/tmux-$(id -u)"
lock="$work/heavy.lock"
RUN_S=${RUN_S:-6}
servers() { # the live tmux servers under $sockdir, one socket name per line
  local s
  for s in "$sockdir"/*; do
    [[ -S $s ]] && tmux -S "$s" has-session 2>/dev/null && echo "${s##*/}"
  done
}
cleanup() {
  local s
  for s in "$sockdir"/*; do [[ -S $s ]] && tmux -S "$s" kill-server 2>/dev/null; done
  rm -rf -- "${work:?}"
}
trap cleanup EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

pass=0 fail=0
check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}

for suite in fleet/test_fleet.sh hooks/test_launch.sh; do
  echo "$suite"
  # A server must be up mid-run, or the stop below proves nothing.
  flock "$lock" timeout -s TERM "$RUN_S" bash "$root/$suite" >/dev/null 2>&1 &
  job=$!
  up=no
  for _ in $(seq 1 $((RUN_S * 10 - 10))); do
    [[ -n $(servers) ]] && { up=yes; break; }
    sleep 0.1
  done
  check "a tmux server runs while the suite does" "$up" "yes"
  wait "$job"
  sleep 0.5 # the trap's kill-server
  check "stopped by TERM: its tmux servers are gone" "$(servers | tr '\n' ' ')" ""
  check "and the lock is free" "$(flock -n "$lock" true && echo free || echo held)" "free"

  flock "$lock" timeout -s KILL "$RUN_S" bash "$root/$suite" >/dev/null 2>&1
  left=$(servers | tr '\n' ' ')
  check "stopped by KILL: a server outlives it (no trap can run)" "$([[ -n $left ]] && echo yes || echo no)" "yes"
  check "yet the lock is free" "$(flock -n "$lock" true && echo free || echo held)" "free"
  for s in $left; do tmux -S "$sockdir/$s" kill-server 2>/dev/null; done
done

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
