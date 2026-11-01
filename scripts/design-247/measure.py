"""Render cost of the #247/#248 prototypes in headless Chromium.

Serves the wall at "/" so it runs in served mode and follows /events (the
phone wall server's stream), then per variant (a: today, b, c) and fleet
size (3 cards, the 16-session demo):
  idle    main-thread task time over a quiet 30 s (CDP Performance metrics, as scripts/perf/cdp.mjs)
  refresh median over 15 snapshots that each change one card's reply: task,
          script, layout and style time from the push until 1 s after the card shows it
and one Chrome trace of a refresh per variant. Relative numbers only: not WebView2.

usage: measure.py <worktree> <out dir>
"""

import functools
import http.server
import json
import pathlib
import queue
import statistics
import sys
import threading
import time

from playwright.sync_api import sync_playwright

ROOT, OUT = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
OUT.mkdir(parents=True, exist_ok=True)
TIMES = {"status_at", "active_at", "updated_at", "quiet_since", "at", "started_at", "ends_at", "until", "settled_at", "turn_at"}
REPS, IDLE_S = 15, 30


def shifted(v, by):
    if isinstance(v, list):
        return [shifted(x, by) for x in v]
    if isinstance(v, dict):
        return {k: (x + by if k in TIMES and isinstance(x, (int, float)) and not isinstance(x, bool) else shifted(x, by)) for k, x in v.items()}
    return v


def snapshot(fixture, mark=None):
    d = json.loads(fixture.read_text())
    at = d.pop("at")
    d = shifted(d, int(time.time()) - at)
    d["speaking"] = None
    if mark:
        s = next(s for s in d["sessions"] if s.get("status") == "working")
        s["reply"] = {"text": f"{mark}: the wall redraws this card.", "at": int(time.time())}
    return d


streams: list[queue.Queue] = []
current = {"fixture": None}


class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/":
            body = (ROOT / "src/wall.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/events":
            q = queue.Queue()
            streams.append(q)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            q.put(snapshot(current["fixture"]))
            try:
                while True:
                    data = q.get()
                    if data is None:
                        return
                    self.wfile.write(f"data: {json.dumps(data)}\n\n".encode())
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            finally:
                streams.remove(q)
        return super().do_GET()


def push(data):
    for q in list(streams):
        q.put(data)


srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(H, directory=str(ROOT / "src")))
srv.daemon_threads = True
threading.Thread(target=srv.serve_forever, daemon=True).start()
port = srv.server_address[1]

KEYS = ("TaskDuration", "ScriptDuration", "LayoutDuration", "RecalcStyleDuration")


def metrics(cdp):
    return {m["name"]: m["value"] for m in cdp.send("Performance.getMetrics")["metrics"]}


def delta(a, b):
    return {k: (b[k] - a[k]) * 1000 for k in KEYS}


results = []
fixtures = {"3 cards": ROOT / "src/dev-fleet.json", "16 cards": ROOT / "scripts/fixtures/fleet-demo.json"}
with sync_playwright() as p:
    browser = p.chromium.launch()
    for size, fixture in fixtures.items():
        current["fixture"] = fixture
        for v in ("a", "b", "c"):
            page = browser.new_page(viewport={"width": 1920, "height": 1080})
            page.goto(f"http://127.0.0.1:{port}/" + ("" if v == "a" else f"?design={v}"))
            page.wait_for_selector("#wall article.card")
            page.check('.density input[value="comfortable"]', force=True)
            page.wait_for_timeout(3000)
            cdp = page.context.new_cdp_session(page)
            cdp.send("Performance.enable", {"timeDomain": "threadTicks"})
            a = metrics(cdp)
            time.sleep(IDLE_S)
            idle = delta(a, metrics(cdp))["TaskDuration"] / IDLE_S
            runs = []
            for i in range(REPS + 1):
                mark = f"Measured {v}{i}x{time.time_ns()}"
                q0 = metrics(cdp)
                if i == REPS and size == "3 cards":
                    browser.start_tracing(page=page, path=str(OUT / f"trace-{v}.json"), screenshots=False)
                push(snapshot(fixture, mark))
                page.wait_for_function(f"document.getElementById('wall').textContent.includes({json.dumps(mark)})", timeout=5000)
                page.wait_for_timeout(1000)
                if i == REPS and size == "3 cards":
                    browser.stop_tracing()
                if i < REPS:
                    runs.append(delta(q0, metrics(cdp)))
            med = {k: round(statistics.median(r[k] for r in runs), 2) for k in KEYS}
            spread = [round(min(r["TaskDuration"] for r in runs), 2), round(max(r["TaskDuration"] for r in runs), 2)]
            row = {"size": size, "variant": v, "idle_ms_per_s": round(idle, 3), **{f"refresh_{k}": med[k] for k in KEYS}, "refresh_task_range": spread,
                   "nodes": metrics(cdp).get("Nodes")}
            print(json.dumps(row), flush=True)
            results.append(row)
            page.close()
    browser.close()
for q in list(streams):
    q.put(None)
(OUT / "measure.json").write_text(json.dumps(results, indent=1) + "\n")
srv.shutdown()
