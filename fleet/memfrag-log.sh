#!/usr/bin/env bash
# memfrag-log.sh : one line per run in memfrag.log: time, compaction_proactiveness, free blocks of
# order 7 and up (512 KiB+, what a new Windows<->WSL VMBus channel needs) per zone, MemAvailable,
# and the running count of kernel "page allocation failure" lines. Read-only; tracks whether
# vm.compaction_proactiveness=50 (set 2026-10-27) keeps large blocks available.
L=$(dirname "$0")/memfrag.log
o7=$(awk '{s=0; for(i=12;i<=15;i++) s+=$i; printf "%s=%d ", $4, s}' /proc/buddyinfo)
avail=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
fails=$(dmesg 2>/dev/null | grep -c 'page allocation failure')
echo "$(date '+%F %T') proactiveness=$(cat /proc/sys/vm/compaction_proactiveness) ${o7}avail_mb=$avail alloc_failures_total=$fails" >> "$L"
