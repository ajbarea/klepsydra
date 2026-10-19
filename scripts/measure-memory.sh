#!/usr/bin/env bash
# klepsydra's memory on Windows: the working set (MiB) of klepsydra.exe and
# every process under it (its WebView2 browser, renderers and GPU process). The
# release checklist in README.md reads it 5 minutes after launch and again at
# 8 hours; a release is blocked if the second is more than 10% above the first.
#
# Usage:
#   bash scripts/measure-memory.sh sample          one line: epoch seconds, working
#                                                  set in MiB, klepsydra's start time
#   bash scripts/measure-memory.sh check LOG       compare the first and last lines
#   bash scripts/measure-memory.sh run LOG         start with klepsydra: sample at
#                                                  5 min and 8 h, then check
set -euo pipefail

FIRST_AT=$((5 * 60))
LAST_AT=$((8 * 3600))
GROWTH_LIMIT_PCT=10

# PowerShell prints "<MiB>\t<start ticks>". A child counts only if it started
# no earlier than its parent: ParentProcessId survives a parent's exit, so a
# reused PID must not pull an unrelated process in. Exit 3: klepsydra.exe is not
# running; exit 4: more than one is.
# shellcheck disable=SC2016  # PowerShell source: its $ variables stay unexpanded.
WORKING_SET='
$all = Get-CimInstance Win32_Process
$roots = @($all | Where-Object { $_.Name -eq "klepsydra.exe" })
if ($roots.Count -eq 0) { exit 3 }
if ($roots.Count -gt 1) { exit 4 }
$started = @{ ([uint32]$roots[0].ProcessId) = $roots[0].CreationDate }
do {
  $added = 0
  foreach ($p in $all) {
    $id = [uint32]$p.ProcessId
    $parent = [uint32]$p.ParentProcessId
    if (-not $started.ContainsKey($id) -and $started.ContainsKey($parent) -and $p.CreationDate -ge $started[$parent]) {
      $started[$id] = $p.CreationDate; $added++
    }
  }
} while ($added -gt 0)
$bytes = ($all | Where-Object { $started.ContainsKey([uint32]$_.ProcessId) } | Measure-Object -Property WorkingSetSize -Sum).Sum
"{0}`t{1}" -f [math]::Round($bytes / 1MB, 1), $roots[0].CreationDate.ToUniversalTime().Ticks
'

# MEASURE_POWERSHELL replaces powershell.exe in tests.
sample() {
  local out rc=0 mb started
  out=$("${MEASURE_POWERSHELL:-powershell.exe}" -NoProfile -Command "$WORKING_SET" | tr -d '\r') || rc=$?
  case $rc in
    0) ;;
    3) echo "klepsydra.exe is not running" >&2; return 3 ;;
    4) echo "more than one klepsydra.exe is running; stop the extra one" >&2; return 4 ;;
    *) echo "could not read process memory (powershell exit $rc)" >&2; return 5 ;;
  esac
  mb=${out%%$'\t'*}
  started=${out#*$'\t'}
  if ! awk -v v="$mb" 'BEGIN { exit !(v ~ /^[0-9]+(\.[0-9]+)?$/ && v + 0 > 0) }' || [[ ! $started =~ ^[0-9]+$ ]]; then
    echo "unusable reading: '$out'" >&2
    return 5
  fi
  printf '%s\t%s\t%s\n' "$(date +%s)" "$mb" "$started"
}

# Exit 0 when the last reading is within the limit of the first, 1 when it
# grew past it, 2 when the log cannot answer (a missing, non-numeric or zero
# reading, too few readings, too short, or klepsydra restarted in between).
check() { # log
  awk -F'\t' -v span="$((LAST_AT - FIRST_AT))" -v limit="$GROWTH_LIMIT_PCT" '
    NF == 0 { next }
    NF != 3 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+(\.[0-9]+)?$/ || $2 + 0 <= 0 || $3 !~ /^[0-9]+$/ {
      print "unusable reading on line " NR ": " $0; bad = 1; exit 2
    }
    { if (n++ == 0) { t0 = $1; m0 = $2; c0 = $3 } t1 = $1; m1 = $2; c1 = $3 }
    END {
      if (bad) exit 2
      if (n < 2) { print "need two readings, found " n; exit 2 }
      if (c0 != c1) { print "klepsydra restarted; measure again"; exit 2 }
      if (t1 - t0 < span) { printf "readings %d s apart; the check needs %d s\n", t1 - t0, span; exit 2 }
      growth = (m1 - m0) / m0 * 100
      printf "%.1f MiB -> %.1f MiB over %.1f h: %+.1f%% (limit %d%%)\n", m0, m1, (t1 - t0) / 3600, growth, limit
      exit growth > limit ? 1 : 0
    }' "$1"
}

usage() { sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "$0" >&2; }

case ${1:-} in
  sample) sample ;;
  check) check "${2:?log file}" ;;
  run)
    log=${2:?log file}
    : >"$log"
    sleep "$FIRST_AT"
    sample >>"$log"
    sleep "$((LAST_AT - FIRST_AT))"
    sample >>"$log"
    check "$log"
    ;;
  *) usage; exit 2 ;;
esac
