#!/usr/bin/env bash
# klepsydra's memory on Windows: the working set of klepsydra.exe and every
# process under it (its WebView2 browser, renderers and GPU process). The
# release checklist in README.md reads it 5 minutes after launch and again at
# 8 hours; a release is blocked if the second is more than 10% above the first.
#
# Usage:
#   bash scripts/measure-memory.sh sample          one line: epoch seconds, MB
#   bash scripts/measure-memory.sh check LOG       compare the first and last lines
#   bash scripts/measure-memory.sh run LOG         start with klepsydra: sample at
#                                                  5 min and 8 h, then check
set -euo pipefail

FIRST_AT=$((5 * 60))
LAST_AT=$((8 * 3600))
GROWTH_LIMIT_PCT=10

# shellcheck disable=SC2016  # PowerShell source: its $ variables stay unexpanded.
WORKING_SET='
$all = Get-CimInstance Win32_Process
$ids = New-Object System.Collections.Generic.HashSet[uint32]
$all | Where-Object { $_.Name -eq "klepsydra.exe" } | ForEach-Object { [void]$ids.Add($_.ProcessId) }
if ($ids.Count -eq 0) { exit 3 }
do {
  $added = 0
  foreach ($p in $all) {
    if (-not $ids.Contains($p.ProcessId) -and $ids.Contains($p.ParentProcessId)) { [void]$ids.Add($p.ProcessId); $added++ }
  }
} while ($added -gt 0)
$bytes = ($all | Where-Object { $ids.Contains($_.ProcessId) } | Measure-Object -Property WorkingSetSize -Sum).Sum
[math]::Round($bytes / 1MB, 1)
'

sample() {
  local mb
  mb=$(powershell.exe -NoProfile -Command "$WORKING_SET" | tr -d '\r') || {
    echo "klepsydra.exe is not running" >&2
    return 3
  }
  printf '%s\t%s\n' "$(date +%s)" "$mb"
}

# Exit 0 when the last reading is within the limit of the first, 1 when it
# grew past it, 2 when the log cannot answer (too few readings, too short).
check() { # log
  awk -F'\t' -v span="$((LAST_AT - FIRST_AT))" -v limit="$GROWTH_LIMIT_PCT" '
    NF == 2 { if (n++ == 0) { t0 = $1; m0 = $2 } t1 = $1; m1 = $2 }
    END {
      if (n < 2) { print "need two readings, found " n; exit 2 }
      if (t1 - t0 < span) { printf "readings %d s apart; the check needs %d s\n", t1 - t0, span; exit 2 }
      growth = (m1 - m0) / m0 * 100
      printf "%.1f MB -> %.1f MB over %.1f h: %+.1f%% (limit %d%%)\n", m0, m1, (t1 - t0) / 3600, growth, limit
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
