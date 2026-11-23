#!/usr/bin/env bash
# scripts/shellcheck.sh [OPTION...] FILE...: `make shellcheck`'s runner (#503).
# ShellCheck's dataflow analysis of fleet/test_fleet.sh alone peaks at 3.4 GB, past
# the room a worker has on WSL, where the kernel kills it (exit 137). Without that
# analysis the same file takes about 240 MB and a few seconds, so a file over
# FLEET_SHELLCHECK_BIG_LINES is checked without it (--extended-analysis=false)
# when the least room over this process's cgroups, and MemAvailable, is under
# FLEET_SHELLCHECK_NEED_MIB, with a note: every check but the dataflow ones
# (SC2030, SC2031 and the like) still runs, and CI runs them all. Full analysis
# always on CI (CI or GITHUB_ACTIONS set) or with FLEET_SHELLCHECK_ALL=1.
# Exits with shellcheck's status: a file checked is never reported as skipped.
set -uo pipefail

read -r -a sc <<<"${SHELLCHECK_BIN:-uvx --from shellcheck-py shellcheck}"
need_mib=${FLEET_SHELLCHECK_NEED_MIB:-4000}
big_lines=${FLEET_SHELLCHECK_BIG_LINES:-3000}

opts=() small=() big=()
for f in "$@"; do
  if [[ $f == -* ]]; then
    opts+=("$f")
  elif (( $(wc -l <"$f" 2>/dev/null || echo 0) > big_lines )); then
    big+=("$f")
  else
    small+=("$f")
  fi
done

# The least memory this process may still take, in MiB: each cgroup from its own
# up to the root caps it (memory.max less memory.current), and so does the machine.
room_mib() {
  local root=${FLEET_CGROUP_ROOT:-/sys/fs/cgroup} cg d max cur least=""
  cg=$(awk -F: '$1 == "0" { print $3; exit }' "${FLEET_PROC:-/proc}/self/cgroup" 2>/dev/null)
  if [[ -n $cg ]]; then
    d=$root${cg%/}
    while [[ $d == "$root"* ]]; do
      max=$(cat -- "$d/memory.max" 2>/dev/null) cur=$(cat -- "$d/memory.current" 2>/dev/null)
      if [[ $max =~ ^[0-9]+$ ]]; then
        [[ $cur =~ ^[0-9]+$ ]] || cur=0
        (( max - cur < 0 )) && cur=$max
        (( ${#least} == 0 || (max - cur) / 1048576 < least )) && least=$(( (max - cur) / 1048576 ))
      fi
      [[ $d == "$root" ]] && break
      d=${d%/*}
    done
  fi
  local avail
  avail=$(awk '/^MemAvailable:/ { print int($2 / 1024); exit }' "${FLEET_MEMINFO:-/proc/meminfo}" 2>/dev/null)
  [[ $avail =~ ^[0-9]+$ ]] && (( ${#least} == 0 || avail < least )) && least=$avail
  printf '%s' "${least:-unknown}"
}

rc=0
(( ${#small[@]} )) && { "${sc[@]}" "${opts[@]}" "${small[@]}" || rc=$?; }
if (( ${#big[@]} )); then
  full=0 room=""
  if [[ ${FLEET_SHELLCHECK_ALL:-} == 1 || -n ${CI:-} || -n ${GITHUB_ACTIONS:-} ]]; then
    full=1
  else
    room=$(room_mib)
    [[ $room =~ ^[0-9]+$ ]] && (( room >= need_mib )) && full=1
  fi
  if (( full )); then
    "${sc[@]}" "${opts[@]}" "${big[@]}" || rc=$?
  else
    printf 'note: %s checked without dataflow analysis: %s MiB of room, under the %s MiB it needs; CI runs the full check (FLEET_SHELLCHECK_ALL=1 runs it here)\n' \
      "${big[*]}" "$room" "$need_mib" >&2
    "${sc[@]}" "${opts[@]}" --extended-analysis=false "${big[@]}" || rc=$?
  fi
fi
exit "$rc"
