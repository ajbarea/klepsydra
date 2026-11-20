"""Print the README tables from ab.txt and appab.txt (median of runs, range)."""
import json, re, statistics, sys, os
here = os.path.dirname(os.path.abspath(__file__))
runs = {}
side = None
for ln in open(os.path.join(here, "ab.txt")):
    m = re.match(r"== (before|after) run", ln)
    if m:
        side = m.group(1); continue
    m = re.match(r"(scan|usage|reader step): reads/call=(\d+) other/call=(\d+) bytes/call=(\d+) median_us=(\d+)", ln)
    if m:
        k = (m.group(1), side)
        runs.setdefault(k, []).append(tuple(int(x) for x in m.groups()[1:]))
def ms(v):
    return f"{statistics.median(v)/1000:.2f} ms ({min(v)/1000:.2f} to {max(v)/1000:.2f})"
print("| Reader, per call | Before | After |\n|---|---|---|")
for r in ("scan", "usage", "reader step"):
    cells = []
    for s in ("before", "after"):
        v = runs[(r, s)]
        counts = {x[:3] for x in v}
        assert len(counts) == 1, (r, s, counts)
        rd, ot, by = counts.pop()
        cells.append((f"{rd:,} / {ot:,} / {by:,}", ms([x[3] for x in v])))
    print(f"| {r}: reads / other ops / bytes | {cells[0][0]} | {cells[1][0]} |")
    print(f"| {r}: time | {cells[0][1]} | {cells[1][1]} |")
app = [a for a in map(json.loads, open(os.path.join(here, "appab.txt"))) if "build" in a]
print("\n| Whole app, 60 s idle (median of 3, range) | Before | After |\n|---|---:|---:|")
for key, name in (("reads", "read operations"), ("other", "other operations"), ("bytes", "bytes read"), ("cpu_ms", "CPU, ms")):
    cell = []
    for s in ("before", "after"):
        v = [a[key] for a in app if a["build"] == s]
        md = statistics.median(v)
        cell.append(f"{md:,.0f}" if min(v) == max(v) else f"{md:,.0f} ({min(v):,} to {max(v):,})")
    print(f"| {name} | {cell[0]} | {cell[1]} |")
