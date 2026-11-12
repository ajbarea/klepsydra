#!/usr/bin/env bash
# Tests for the fleet's memory slices and OOM ranks (#353). The first part needs
# nothing; the live part runs only where a systemd user manager answers (not
# CI): it starts two scopes the way launch.sh does, in a private pair of slices
# capped at a few hundred MB, each holding a claude stand-in that starts a
# memory-hungry child through a shell, and checks that the cap's OOM kills the
# children while both stand-ins live and WSL keeps its margin.
# Run: make test-slice (it takes the heavy lock); SLICE_LIVE=0 runs only the first part, bare.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
export FLEET_STATE="$work/state" KLEPSYDRA_DIR="$work/klepsydra" FLEET_LOG="$work/fleet.log" FLEET_SOCK="slice-test-$$"
mkdir -p "$FLEET_STATE" "$KLEPSYDRA_DIR/fleet"
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
# This machine's margin, from its own MemTotal and earlyoom config, for the live part.
live_margin=$(fleet_slice_margin "$(awk '$1 == "MemTotal:" { printf "%d", $2 / 1024 }' /proc/meminfo)")

pass=0 fail=0
check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}
units=""
cleanup() {
  local s
  # Stopping a slice stops every scope in it, so nothing the live part started outlives it.
  if [[ -n $units ]]; then
    for s in $units; do systemctl --user stop "$s" 2>/dev/null; done
    for s in $units; do rm -f -- "${XDG_RUNTIME_DIR:?}/systemd/user/${s:?}"; done
    systemctl --user daemon-reload 2>/dev/null
  fi
  rm -rf -- "${work:?}"
}
trap cleanup EXIT
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

echo "sizes"
check "to_mib reads systemd's sizes" "$(to_mib 4G) $(to_mib 512M) $(to_mib 2048K) $(to_mib 1073741824)" "4096 512 2 1024"
check "to_mib refuses a size it cannot read" "$(to_mib 4g || echo no) $(to_mib '' || echo no) $(to_mib 1.5G || echo no)" "no no no"

echo "the orchestrator's kept memory"
cgr="$work/cg" scope=/user.slice/user-1.slice/user@1.service/app.slice/fleet-heph-1.scope
mkdir -p "$cgr$scope" "$work/proc/4242"
printf 'anon 524288000\nfile 4294967296\nkernel 52428800\nshmem 10485760\nfile_mapped 1\n' >"$cgr$scope/memory.stat"
export FLEET_CGROUP_ROOT=$cgr FLEET_PROC="$work/proc"
check "anon, kernel and shmem count; page cache does not" "$(cgroup_kept_mib "$scope")" "560"
check "a cgroup with no memory.stat fails" "$(cgroup_kept_mib /nowhere || echo none)" "none"
printf '0::%s\n' "$scope" >"$work/proc/4242/cgroup"
check "a process's cgroup, from its /proc entry" "$(proc_cgroup 4242)" "$scope"
# The orchestrator's pid stands in for heph_pid's lookup (live_session, its fleet file).
heph=4242
heph_pid() { [[ -n $heph ]] && printf '%s' "$heph"; }
check "the live reading, not kept without record" "$(orch_mem_peak) $(cat "$FLEET_STATE/orchestrator.mem" 2>/dev/null || echo unkept)" "560 unkept"
today=$(date +%F)
check "and kept with it, as today's" "$(orch_mem_peak record) $(cat "$FLEET_STATE/orchestrator.mem")" "560 $today 560"
printf 'anon 104857600\nkernel 0\nshmem 0\n' >"$cgr$scope/memory.stat"
check "a lower reading keeps the peak" "$(orch_mem_peak record) $(cat "$FLEET_STATE/orchestrator.mem")" "560 $today 560"
printf 'anon 1073741824\nkernel 0\nshmem 0\n' >"$cgr$scope/memory.stat"
check "a higher one raises it" "$(orch_mem_peak record) $(cat "$FLEET_STATE/orchestrator.mem")" "1024 $today 1024"
heph=""
check "no live orchestrator: the kept peak" "$(orch_mem_peak)" "1024"
heph=4242; printf '0::/user.slice/user-1.slice/user@1.service/app.slice/app-tmux.slice/tmux-1.scope\n' >"$work/proc/4242/cgroup"
mkdir -p "$cgr/user.slice/user-1.slice/user@1.service/app.slice/app-tmux.slice/tmux-1.scope"
printf 'anon 9663676416\n' >"$cgr/user.slice/user-1.slice/user@1.service/app.slice/app-tmux.slice/tmux-1.scope/memory.stat"
check "a claude outside a fleet scope is never read (that cgroup holds the whole tmux server)" "$(orch_mem_peak record) $(cat "$FLEET_STATE/orchestrator.mem")" "1024 $today 1024"
rm -f "$FLEET_STATE/orchestrator.mem"; heph=""
check "neither: fails" "$(orch_mem_peak || echo none)" "none"
# The review's cases: a worker's scope (a stale orchestrator.pane), old days, the first format.
wscope=/user.slice/user-1.slice/user@1.service/fleet.slice/fleet-workers.slice/fleet-w-3.scope
mkdir -p "$cgr$wscope"; printf 'anon 9663676416\n' >"$cgr$wscope/memory.stat"
check "a worker's scope is never read as the orchestrator's" "$(orch_mem_peak record "$wscope" || echo none) $(cat "$FLEET_STATE/orchestrator.mem" 2>/dev/null || echo unkept)" "none unkept"
printf '2026-01-01 9000\n%s 300\n%s 200\n' "$(date -d '-6 days' +%F)" "$(date -d '-7 days' +%F)" >"$FLEET_STATE/orchestrator.mem"
check "days older than the window drop out, at the read and from the file" "$(orch_mem_peak record '') | $(cat "$FLEET_STATE/orchestrator.mem")" "300 | $(date -d '-6 days' +%F) 300"
printf '750\n' >"$FLEET_STATE/orchestrator.mem"
check "a bare number (the first format) counts as today's" "$(orch_mem_peak record '') $(cat "$FLEET_STATE/orchestrator.mem")" "750 $today 750"
rm -f "$FLEET_STATE/orchestrator.mem"
heph=4242; printf '0::%s\n' "$scope" >"$work/proc/4242/cgroup"
check "a cgroup given is read without the lookup" "$(heph=""; orch_mem_peak - "$scope")" "1024"
check "an empty one means no live orchestrator" "$(orch_mem_peak - '' || echo none)" "none"
heph=""

echo "margin"
printf 'EARLYOOM_ARGS="-m 5 -s 100,100 -r 3600"\n' >"$work/earlyoom"
export FLEET_EARLYOOM_CONF="$work/earlyoom"
# 847 + 5% of 9948 (497) = 1344, up to 1536; 847 + 1600 = 2447, up to 2560.
check "WSL's own plus earlyoom's -m line, up to a whole 512 MiB" "$(fleet_slice_margin 9948) $(fleet_slice_margin 32000)" "1536 2560"
check "earlyoom's own default, 10%, with no -m" "$(FLEET_EARLYOOM_CONF=<(echo 'EARLYOOM_ARGS="-r 60"') fleet_slice_margin 9948)" "2048"
check "-m with no space, and a kill percent after it" "$(FLEET_EARLYOOM_CONF=<(echo 'EARLYOOM_ARGS="-s 1 -m3,2"') fleet_slice_margin 9948)" "1536"
check "a commented line is not read" "$(FLEET_EARLYOOM_CONF=<(echo '#EARLYOOM_ARGS="-m 50"') fleet_slice_margin 9948)" "2048"
check "no earlyoom config: WSL's own only" "$(FLEET_EARLYOOM_CONF=$work/none fleet_slice_margin 9948)" "1024"
# earlyoom(1): -M is KiB, and with -m too the lower line is used.
check "-M alone: its KiB" "$(FLEET_EARLYOOM_CONF=<(echo 'EARLYOOM_ARGS="-M 1048576"') fleet_slice_margin 32000)" "2048"
check "-m and -M: the lower (-M here)" "$(FLEET_EARLYOOM_CONF=<(echo 'EARLYOOM_ARGS="-m 50 -M 1048576"') fleet_slice_margin 32000)" "2048"
check "-m and -M: the lower (-m here)" "$(FLEET_EARLYOOM_CONF=<(echo 'EARLYOOM_ARGS="-m 5 -M 2097152"') fleet_slice_margin 9948)" "1536"
check "the last EARLYOOM_ARGS line counts, as the shell reads it" "$(FLEET_EARLYOOM_CONF=<(printf 'EARLYOOM_ARGS="-m 50"\nEARLYOOM_ARGS="-m 2"\n') fleet_slice_margin 9948)" "1536"
check "an indented or exported line counts too" "$(FLEET_EARLYOOM_CONF=<(printf '  export EARLYOOM_ARGS="-m 2"\n') fleet_slice_margin 9948)" "1536"

echo "caps"
printf 'MemTotal:       10186856 kB\nMemAvailable:    5151140 kB\n' >"$work/meminfo"
export FLEET_MEMINFO="$work/meminfo"
printf '811\n' >"$FLEET_STATE/orchestrator.mem"
# 9948 MiB less the 1536 margin; less the orchestrator's 811 for the workers.
check "the fleet's cap and the workers', from MemTotal, the margin and the orchestrator's peak" "$(fleet_slice_caps)" "8412 7601 1536"
rm -f "$FLEET_STATE/orchestrator.mem"
check "no reading of the orchestrator: its scope's own cap stands in" "$(fleet_slice_caps) | $(MEM_MAX=3G fleet_slice_caps)" "8412 3292 1536 | 8412 5340 1536"
printf 'MemTotal:       1572864 kB\n' >"$work/meminfo"
check "nothing left for the workers: fails" "$(fleet_slice_caps || echo none)" "none"
printf 'MemTotal:       10186856 kB\n' >"$work/meminfo"; printf '0\n' >"$FLEET_STATE/orchestrator.mem"
check "a peak of 0 (all to the workers, no room for the orchestrator): fails" "$(fleet_slice_caps || echo none)" "none"
rm -f "$FLEET_STATE/orchestrator.mem"; printf 'MemTotal:       1572864 kB\n' >"$work/meminfo"
printf 'nothing\n' >"$work/meminfo"
check "no MemTotal: fails" "$(fleet_slice_caps || echo none)" "none"
unset FLEET_MEMINFO
check "a slice's unit holds only the hard cap (memory.high would freeze it, not kill)" "$(fleet_slice_unit 'w' 7601 | grep -E '^Memory')" $'MemoryAccounting=yes\nMemoryMax=7601M'

echo "scope options and OOM ranks"
check "a worker's scope goes in the workers' slice, and outlives an OOM kill in it" "$(fleet_slice_opts worker)" "--slice=fleet-workers.slice -p OOMPolicy=continue"
check "the orchestrator's in the fleet's" "$(fleet_slice_opts orchestrator)" "--slice=fleet.slice -p OOMPolicy=continue"
# shellcheck disable=SC2016 # $1 and the name are the inner shell's
check "the workers' slice nests in the fleet's by name" "$(env -u FLEET_WORKER_SLICE FLEET_SLICE=x.slice bash -c '. "$1"; echo "$FLEET_WORKER_SLICE"' _ "$here/lib.sh")" "x-workers.slice"
check "BASH_ENV names oom-tool.sh" "$(fleet_oom_env)" "BASH_ENV=$here/oom-tool.sh "
check "BASH_ENV even while the file is missing: bash skips it silently and ranks again once it is back" \
  "$(FLEET_OOM_TOOL=$work/none fleet_oom_env)| $(BASH_ENV=$work/none bash -c 'echo ran' 2>&1)" "BASH_ENV=$work/none | ran"
rank() { # the OOM rank of a shell started under BASH_ENV, from a caller at rank $1
  bash -c "echo $1 >/proc/self/oom_score_adj; $(fleet_oom_env)bash -c 'cat /proc/self/oom_score_adj'"
}
check "a shell under BASH_ENV ranks itself 1000" "$(rank 0)" "1000"
check "and so does a set -eu one" "$(BASH_ENV=$FLEET_OOM_TOOL bash -euc 'cat /proc/self/oom_score_adj')" "1000"
check "bash -x shows nothing of it" "$(BASH_ENV=$FLEET_OOM_TOOL bash -xc ':' 2>&1)" "+ :"
check "a script under it keeps its own arguments" "$(BASH_ENV=$FLEET_OOM_TOOL bash -c 'echo "$0 $*"' name a b)" "name a b"
check "run as a wrapper, it ranks the command it execs" "$(bash "$FLEET_OOM_TOOL" bash -c 'cat /proc/self/oom_score_adj')" "1000"
# The floor's shell drops a rank it inherited back to 0 (a tmux server started from a ranked shell).
floor_cmd="$(fleet_oom_floor)bash -c 'cat /proc/self/oom_score_adj'"
check "the floor takes claude back to 0 from an inherited 1000" "$(bash -c "echo 1000 >/proc/self/oom_score_adj; $floor_cmd")" "0"

echo "live: two scopes in a capped slice"
live() {
  local why
  if [[ ${SLICE_LIVE:-1} == 0 ]]; then
    why="SLICE_LIVE=0"
  elif ! command -v systemd-run >/dev/null || ! systemctl --user show-environment >/dev/null 2>&1; then
    why="no systemd user manager"
  elif [[ -z ${XDG_RUNTIME_DIR:-} || ! -d $XDG_RUNTIME_DIR ]]; then
    why="no XDG_RUNTIME_DIR for a runtime unit"
  elif ! command -v python3 >/dev/null; then
    why="no python3"
  elif (( $(awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' /proc/meminfo) < live_margin + 1024 )); then
    why="under $((live_margin + 1024)) MiB available"
  fi
  if [[ -n ${why:-} ]]; then
    echo "  skip the live part: $why"
    return
  fi
  # Slice names without a dash of their own, so the pair nests only in each other.
  local top=k353test$$.slice
  local sub=${top%.slice}-workers.slice dir=$XDG_RUNTIME_DIR/systemd/user
  units="$sub $top"
  mkdir -p -- "$dir"
  # The workers' cap is tight on purpose: 2 stand-ins of 110M fill most of it.
  fleet_slice_unit "fleet test #353" 360 >"$dir/$top"
  fleet_slice_unit "fleet test #353 workers" 300 >"$dir/$sub"
  systemctl --user daemon-reload
  check "the slices load with the caps their units hold" \
    "$(systemctl --user show -p MemoryMax --value "$sub" "$top" | grep . | paste -sd' ')" "314572800 377487360"
  # The stand-in: holds 110M (more than the child will at the cap), then starts the
  # hungry child through a shell, as claude's Bash tool does, and waits on it.
  cat >"$work/standin.py" <<'EOF'
import os, subprocess, sys, time
held = bytearray(110 << 20)
for i in range(0, len(held), 4096):
    held[i] = 1
cg = open("/proc/self/cgroup").read().strip().split("::", 1)[-1]
open(sys.argv[1], "w").write(f"ready {cg}\n")
rc = subprocess.call(["/bin/bash", "-c", "exec python3 " + sys.argv[2]])
open(sys.argv[1], "a").write(f"child {rc}\n")
# A claude outlives its tool call: stay until the test says stop (at most a minute).
for _ in range(600):
    if os.path.exists(sys.argv[3]):
        break
    time.sleep(0.1)
EOF
  # The child grows by 10M up to 250M, then stops on its own: with no cap at all
  # (the slice flag removed) the test still never holds more than about 720M.
  cat >"$work/hungry.py" <<'EOF'
import time
blocks = []
for _ in range(25):
    b = bytearray(10 << 20)
    for i in range(0, len(b), 4096):
        b[i] = 1
    blocks.append(b)
    time.sleep(0.05)
EOF
  # Each scope's own cap (400M) is above what one scope can hold (110M + 250M),
  # so only the slice's cap can kill: with it removed, both children finish.
  # Started from a shell at rank 1000, as a tmux server started from a ranked shell would start them.
  local i pids=() cmd
  for i in 1 2; do
    cmd="systemd-run --user --scope --quiet --collect --unit=k353test$$-$i $(FLEET_SLICE=$top FLEET_WORKER_SLICE=$sub fleet_slice_opts worker) -p MemoryMax=400M -p MemorySwapMax=0 $(fleet_oom_floor)env $(fleet_oom_env)python3 $work/standin.py $work/standin$i.log $work/hungry.py $work/stop"
    bash -c "echo 1000 >/proc/self/oom_score_adj; exec $cmd" >"$work/scope$i.out" 2>&1 &
    pids+=($!)
  done
  # WSL's available memory, sampled while they run.
  local low=999999 a end=$((SECONDS + 60)) alive=1
  while (( SECONDS < end )); do
    a=$(awk '/^MemAvailable:/ { printf "%d", $2 / 1024 }' /proc/meminfo)
    (( a < low )) && low=$a
    alive=0
    for i in 1 2; do grep -q '^child' "$work/standin$i.log" 2>/dev/null || alive=1; done
    (( alive )) || break
    sleep 0.2
  done
  # Both stand-ins are asked to end; a scope still running then (a throttled one
  # stalls rather than dies) is stopped, so the wait ends.
  check "both children ended before the deadline (none stalled)" "$alive" "0"
  : >"$work/stop"
  sleep 1
  for i in 1 2; do systemctl --user stop "k353test$$-$i.scope" 2>/dev/null; done
  for i in 0 1; do wait "${pids[$i]}" 2>/dev/null; done
  local cg events
  cg=$(systemctl --user show -p ControlGroup --value "$sub")
  for i in 1 2; do
    check "stand-in $i ran in the workers' slice, inside the fleet's" "$(sed -n 's/^ready //p' "$work/standin$i.log" 2>/dev/null)" "${cg:-(no cgroup for $sub)}/k353test$$-$i.scope"
  done
  # Never the root's memory.events, which an empty ControlGroup would name.
  # memory.events.local counts only the slice's own limit and OOM, not a scope's
  # below it; memory.events counts kills anywhere in the slice.
  local own=""
  events=""
  [[ $cg == */${top}/${sub} ]] && events=$(cat "/sys/fs/cgroup$cg/memory.events" 2>/dev/null) own=$(cat "/sys/fs/cgroup$cg/memory.events.local" 2>/dev/null)
  check "the workers' slice hit its own cap (memory.events.local max)" "$(awk '$1 == "max" { print ($2 > 0) ? "yes" : "no" }' <<<"$own")" "yes"
  check "and went OOM itself (memory.events.local oom)" "$(awk '$1 == "oom" { print ($2 > 0) ? "yes" : "no" }' <<<"$own")" "yes"
  check "which killed in the slice (memory.events oom_kill)" "$(awk '$1 == "oom_kill" { print ($2 > 0) ? "yes" : "no" }' <<<"$events")" "yes"
  for i in 1 2; do
    check "stand-in $i outlived its child, which the cap killed (SIGKILL: -9)" "$(sed 's/^ready .*/ready/' "$work/standin$i.log" 2>/dev/null | paste -sd' ')" "ready child -9"
  done
  check "WSL's MemAvailable stayed above the margin (lowest ${low} MiB)" "$(( low > live_margin ))" "1"
}
live

echo
echo "pass=$pass fail=$fail"
(( fail == 0 ))
