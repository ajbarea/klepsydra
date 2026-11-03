#!/usr/bin/env bash
# A tmux suite stopped mid-run must not keep the lock it ran under (#193, #239).
# Each suite runs under flock on a private lock and is stopped after a few
# seconds: by TERM, its trap stops its tmux server; by KILL, no trap runs and
# the server outlives it, but holds no descriptor of the lock.
# Run: make test-heavy-lock (it takes the heavy lock)
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
export TMUX_TMPDIR="$work/tmux" # every -L socket the suites make lands here
# A suite killed by KILL never removes its own mktemp folder: it lands here.
export TMPDIR="$work/t"
mkdir -p "$TMUX_TMPDIR" "$TMPDIR"
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

echo "fleet/heavy.sh (#291 reviews 4 and 5)"
hl="$work/heavy-sh.lock"; : >"$hl"
hv() { FLEET_HEAVY_LOCK=$hl "$root/fleet/heavy.sh" "$@"; }
gone() { # pattern: wait up to 5 s for no process with that exact command line
  for _ in $(seq 50); do pgrep -fx "$1" >/dev/null || { echo gone; return; }; sleep 0.1; done
  echo running; pkill -fx "$1" 2>/dev/null
}
held() { flock -n "$hl" true && echo free || echo held; }
check "a free lock: the command runs, quietly" "$(hv echo ran 2>&1)" "ran"
check "the caller's stdin reaches the command" "$(echo hi | hv cat)" "hi"
flock -o "$hl" sleep 1.5 &
holder=$!
for _ in $(seq 50); do [[ $(held) == held ]] && break; sleep 0.05; done
check "a held lock: it names the run holding it, then runs once the lock is free" \
  "$(hv echo ran 2>&1 | sed "s/pid $holder:/pid HOLDER:/")" $'heavy.sh: waiting for '"$hl"$' (open in pid HOLDER: the run holding it, and any others waiting)\nran'
wait "$holder"
# Review 6: heavy.sh as the holder (its lock is taken by a flock(1) that
# exits, so /proc/locks names no live pid): named, and refused when nested.
FLEET_HEAVY_LOCK=$hl "$root/fleet/heavy.sh" sleep 1.5 &
holder=$!
for _ in $(seq 50); do [[ $(held) == held ]] && break; sleep 0.05; done
check "another heavy.sh holding it: named by its pid" "$(hv true 2>&1 | grep -c "open in pid $holder:")" "1"
wait "$holder"
out=$(timeout 10 env FLEET_HEAVY_LOCK="$hl" "$root/fleet/heavy.sh" bash -c "FLEET_HEAVY_LOCK='$hl' '$root/fleet/heavy.sh' echo ran" 2>&1)
check "heavy.sh inside heavy.sh on the same lock: refused at once" "$? $(grep -c 'already holds' <<<"$out") $(grep -c '^ran$' <<<"$out")" "2 1 0"
ln -sf -- "$hl" "$work/heavy-sh.link"
out=$(timeout 10 flock -o "$hl" bash -c "FLEET_HEAVY_LOCK='$work/heavy-sh.link' '$root/fleet/heavy.sh' echo ran" 2>&1)
check "the same lock through a symlinked name: refused at once" "$? $(grep -c 'already holds' <<<"$out")" "2 1"
# shellcheck disable=SC2016 # expanded by the command's shell
check "the command is told the lock is held, so a make target in it takes no second one" "$(hv bash -c 'echo "$FLEET_HEAVY_HELD"')" "1"
out=$(timeout 10 flock -o "$hl" bash -c "FLEET_HEAVY_LOCK='$hl' '$root/fleet/heavy.sh' echo ran" 2>&1)
check "inside an outer flock on the same file: refused at once, not a wait until the timeout" \
  "$? $(grep -c 'already holds' <<<"$out") $(grep -c '^ran$' <<<"$out")" "2 1 0"
check "a lock file it cannot open: refused, not a wait" \
  "$(FLEET_HEAVY_LOCK=$work/no-such-dir/l "$root/fleet/heavy.sh" echo ran 2>&1; echo "rc=$?")" $'heavy.sh: cannot open '"$work"$'/no-such-dir/l\nrc=2'
check "the timeout stops the command" "$(FLEET_HEAVY_TIMEOUT=1 hv sleep 5; echo $?)" "124"
# The limit bounds every process the command started (review 5: under
# --foreground a suite's TERM trap waited on its stuck child, and a
# background grandchild outlived the run with the lock already free).
s0=$SECONDS
FLEET_HEAVY_TIMEOUT=1 hv bash -c 'trap "exit 143" TERM; sleep 30.1'
check "a suite that traps TERM, stuck in a child: ended at the limit" "$(( SECONDS - s0 < 5 )) $(gone 'sleep 30.1')" "1 gone"
FLEET_HEAVY_TIMEOUT=1 hv bash -c 'sleep 30.2 & wait'
check "a background grandchild: ended with it" "$(gone 'sleep 30.2') $(held)" "gone free"
s0=$SECONDS
FLEET_HEAVY_TIMEOUT=1 FLEET_HEAVY_KILL_S=1 hv bash -c 'trap "" TERM; sleep 30.3'
check "a command that ignores TERM: killed after the grace" "$(( SECONDS - s0 < 6 )) $(gone 'sleep 30.3') $(held)" "1 gone free"
# The command never holds the lock: a process it leaves behind keeps none (review 6 m4).
hv bash -c 'setsid sleep 30.4 </dev/null >/dev/null 2>&1 &'
check "a process the command leaves behind keeps no lock" "$(held)" "free"
pkill -fx 'sleep 30.4' 2>/dev/null
# The lock is held until the command's own cleanup ends (review 6 m5).
setsid env --default-signal=INT FLEET_HEAVY_LOCK="$hl" "$root/fleet/heavy.sh" bash -c 'trap "sleep 1.2; exit 0" TERM; sleep 31.8 & wait' &
sj=$!
for _ in $(seq 50); do pgrep -fx 'sleep 31.8' >/dev/null && break; sleep 0.05; done
kill -INT -- "-$sj" 2>/dev/null
sleep 0.5
check "Ctrl-C: the lock stays held while the command's TERM cleanup runs" "$(held)" "held"
wait "$sj" 2>/dev/null
check "and is free once it ends" "$(held) $(gone 'sleep 31.8')" "free gone"
# Ctrl-C, or a tool call stopped, signals heavy.sh's group; the command runs in
# timeout's own group, so heavy.sh passes it on. A script's & job starts with
# SIGINT ignored; a terminal's Ctrl-C finds it at its default.
for sig in INT TERM; do
  setsid env --default-signal=INT FLEET_HEAVY_LOCK="$hl" "$root/fleet/heavy.sh" sleep 31.7 &
  sj=$!
  for _ in $(seq 50); do pgrep -fx 'sleep 31.7' >/dev/null && break; sleep 0.05; done
  check "a run in progress holds the lock" "$(held)" "held"
  kill -"$sig" -- "-$sj" 2>/dev/null
  wait "$sj" 2>/dev/null
  check "$sig to its group: the command is gone and the lock is free" "$(gone 'sleep 31.7') $(held)" "gone free"
done

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
