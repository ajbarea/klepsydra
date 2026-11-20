#!/usr/bin/env bash
# Sample the heavy lock's contention and the room a second run would have,
# every STEP s for SECS s, with bash builtins only (one sleep per sample).
# CSV: epoch,holders,waiters,slice_cur_mb,slice_max_mb,avail_mb,mem_some10,cpu_some10
# usage: sample.sh [SECS] [STEP]
set -u
secs=${1:-3600} step=${2:-10}
lock=${FLEET_HEAVY_LOCK:-/tmp/fleet-heavy.lock}
slice=${FLEET_SLICE_DIR:-/sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/fleet.slice}
read -r ino < <(stat -c %i -- "$lock")
key=":$ino "
psi() { local k a; while read -r k a _; do [[ $k == some ]] && { a=${a#avg10=}; printf '%s' "$a"; return; }; done <"$1"; }
echo "epoch,holders,waiters,slice_cur_mb,slice_max_mb,avail_mb,mem_some10,cpu_some10"
end=$((SECONDS + secs))
while ((SECONDS < end)); do
  h=0 w=0
  while read -r line; do
    [[ $line == *"$key"* ]] || continue
    [[ $line == *"->"* ]] && w=$((w + 1)) || h=$((h + 1))
  done </proc/locks
  read -r cur <"$slice/memory.current"; read -r max <"$slice/memory.max"
  [[ $max == max ]] && max=0
  avail=0
  while read -r k v _; do [[ $k == MemAvailable: ]] && { avail=$((v / 1024)); break; }; done </proc/meminfo
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$EPOCHSECONDS" "$h" "$w" $((cur / 1048576)) $((max / 1048576)) "$avail" \
    "$(psi /proc/pressure/memory)" "$(psi /proc/pressure/cpu)"
  sleep "$step"
done
