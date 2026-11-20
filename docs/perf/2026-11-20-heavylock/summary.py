"""Summarise sample.sh CSV: contention and the room a second run would have had."""

import csv
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1] if len(sys.argv) > 1 else "before.csv")))
n = len(rows)
held = [r for r in rows if int(r["holders"]) > 0]
waiting = [r for r in rows if int(r["waiters"]) > 0]


def room(r):
    return min(int(r["slice_max_mb"]) - int(r["slice_cur_mb"]), int(r["avail_mb"]))


print(f"samples: {n} (every 10 s)")
print(f"lock held: {len(held)} ({100 * len(held) / n:.0f}%)")
print(
    f"waiters present: {len(waiting)} ({100 * len(waiting) / n:.0f}%), most waiters: {max(int(r['waiters']) for r in rows)}"
)
for name, sel in (("all samples", rows), ("with waiters", waiting)):
    if not sel:
        continue
    rm = [room(r) for r in sel]
    print(
        f"{name}: room MiB median {statistics.median(rm):.0f} (min {min(rm)}, max {max(rm)}); "
        f"mem PSI some10 max {max(float(r['mem_some10']) for r in sel):.2f}; "
        f"cpu PSI some10 median {statistics.median(float(r['cpu_some10']) for r in sel):.2f} max {max(float(r['cpu_some10']) for r in sel):.2f}"
    )
for need in (1024, 2048, 3584):
    ok = sum(1 for r in waiting if room(r) >= need)
    print(f"waiting samples with room >= {need} MiB: {ok} of {len(waiting)}")
