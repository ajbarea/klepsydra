"""CPU of the gauge strip (src/index.html) at rest, before and after a change.

Serves each worktree's src/ and opens the gauge with the same readings and
fleet snapshot (dev-fixture.json, dev-fleet.json), its timers running as in
the app (a read every 5 s, a redraw every 15 s). After a settle it reads
Chromium's main-thread task time (CDP Performance.getMetrics TaskDuration)
at the start and end of each window; task time over wall time is the CPU
share of one core. Rounds alternate before/after so load on the machine
falls on both. Headless Chromium, not WebView2: compare the two numbers,
do not quote either as the app's.

usage: measure_gauge.py <before root> <after root> <readings.json> <fleet.json> [seconds] [rounds] [query]
"""

import functools
import http.server
import json
import pathlib
import statistics
import sys
import threading

from playwright.sync_api import sync_playwright

SETTLE_MS = 6000  # the first read, the strip's theme wait and a redraw


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def serve(root):
    handler = functools.partial(Quiet, directory=str(root / "src"))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def task_seconds(cdp):
    metrics = {m["name"]: m["value"] for m in cdp.send("Performance.getMetrics")["metrics"]}
    return metrics["TaskDuration"], metrics["Timestamp"]


def measure(browser, port, readings, fleet, seconds, query):
    page = browser.new_page(viewport={"width": 1100, "height": 120})
    body = lambda text: lambda r: r.fulfill(status=200, content_type="application/json", body=text)  # noqa: E731
    page.route("**/dev-fixture.json", body(readings))
    page.route("**/dev-fleet.json", body(fleet))
    cdp = page.context.new_cdp_session(page)
    cdp.send("Performance.enable", {"timeDomain": "timeTicks"})
    page.goto(f"http://127.0.0.1:{port}/index.html?{query}")
    page.wait_for_timeout(SETTLE_MS)
    t0, w0 = task_seconds(cdp)
    page.wait_for_timeout(seconds * 1000)
    t1, w1 = task_seconds(cdp)
    page.close()
    return 100 * (t1 - t0) / (w1 - w0)


def main():
    before, after = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    readings = pathlib.Path(sys.argv[3]).read_text()
    fleet = pathlib.Path(sys.argv[4]).read_text()
    seconds = int(sys.argv[5]) if len(sys.argv) > 5 else 60
    rounds = int(sys.argv[6]) if len(sys.argv) > 6 else 3
    query = sys.argv[7] if len(sys.argv) > 7 else "layout=compact"
    servers = {"before": serve(before), "after": serve(after)}
    got = {"before": [], "after": []}
    with sync_playwright() as p:
        browser = p.chromium.launch()
        for _ in range(rounds):
            for name, server in servers.items():
                got[name].append(measure(browser, server.server_address[1], readings, fleet, seconds, query))
        browser.close()
    for server in servers.values():
        server.shutdown()
    print(json.dumps({
        name: {"median_cpu_pct": round(statistics.median(v), 3), "rounds": [round(x, 3) for x in v]}
        for name, v in got.items()
    }))


if __name__ == "__main__":
    main()
