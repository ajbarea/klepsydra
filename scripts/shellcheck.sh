#!/usr/bin/env bash
# scripts/shellcheck.sh: Run shellcheck with a memory guard for large suites (#503).
# fleet/test_fleet.sh alone requires ~3.4 to 4.0 GB of RAM in ShellCheck's dataflow analysis,
# which exceeds the 3.6 GB worker slice cap and causes an OOM kill (exit 137).
#
# Core files are always checked. The heavy test suite is checked when:
# 1. FLEET_SHELLCHECK_ALL is set (e.g. FLEET_SHELLCHECK_ALL=1)
# 2. Running in CI (CI=true or GITHUB_ACTIONS=true)
# 3. Running with sufficient memory headroom (>= 4500 MiB cgroup cap and available memory).
set -euo pipefail

read -r -a sc <<< "${SHELLCHECK:-uvx --from shellcheck-py shellcheck}"

core_files=()
suite_file=""
for f in "$@"; do
  if [[ $f == *fleet/test_fleet.sh ]]; then
    suite_file=$f
  else
    core_files+=("$f")
  fi
done

if (( ${#core_files[@]} > 0 )); then
  "${sc[@]}" -x "${core_files[@]}"
fi

if [[ -n $suite_file ]]; then
  can_run=1
  why=""
  if [[ ${FLEET_SHELLCHECK_ALL:-} == 1 || ${FLEET_SHELLCHECK_ALL:-} == true || \
        ${CI:-} == true || ${GITHUB_ACTIONS:-} == true ]]; then
    can_run=1
  else
    # Check cgroup v2 memory limit for this process
    proc_root=${FLEET_PROC:-/proc}
    cg=$(awk -F: '$1 == "0" { print $3 }' "$proc_root/self/cgroup" 2>/dev/null || true)
    cgroup_root=${FLEET_CGROUP_ROOT:-/sys/fs/cgroup}
    if [[ -n $cg && -r "$cgroup_root$cg/memory.max" ]]; then
      max=$(cat "$cgroup_root$cg/memory.max" 2>/dev/null || true)
      if [[ $max =~ ^[0-9]+$ ]] && (( max < 4500 * 1048576 )); then
        can_run=0
        why="cgroup memory.max is $((max / 1048576)) MiB (below 4500 MiB needed for $suite_file)"
      fi
    fi
    if (( can_run )); then
      meminfo=${FLEET_MEMINFO:-/proc/meminfo}
      avail=$(awk '/MemAvailable:/ { print $2 }' "$meminfo" 2>/dev/null || true)
      if [[ $avail =~ ^[0-9]+$ ]] && (( avail < 4500 * 1024 )); then
        can_run=0
        why="available memory is $((avail / 1024)) MiB (below 4500 MiB needed for $suite_file)"
      fi
    fi
  fi

  if (( can_run )); then
    "${sc[@]}" -x "$suite_file"
  else
    printf 'skip %s: %s (run with FLEET_SHELLCHECK_ALL=1, make shellcheck-suite, or leave to CI)\n' \
      "$suite_file" "$why"
  fi
fi
