"""Shots of the wall for the #247/#248 A/B pass: serve a worktree root, open the dev wall at 1920x1080, one PNG per variant and density."""
import functools, http.server, sys, threading, pathlib
from playwright.sync_api import sync_playwright
root, out, variants = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3].split(",")
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Q, directory=str(root)))
threading.Thread(target=srv.serve_forever, daemon=True).start()
port = srv.server_address[1]
out.mkdir(parents=True, exist_ok=True)
with sync_playwright() as p:
    b = p.chromium.launch()
    for v in variants:
        for dens in ("comfortable", "compact"):
            pg = b.new_page(viewport={"width": 1920, "height": 1080}, device_scale_factor=1)
            msgs = []
            pg.on("console", lambda m: msgs.append(m.text) if m.type in ("error", "warning") else None)
            pg.on("pageerror", lambda e: msgs.append(str(e)))
            q = "" if v == "a" else f"?design={v}"
            pg.goto(f"http://127.0.0.1:{port}/src/wall.html{q}")
            pg.wait_for_selector(".card")
            pg.check(f'.density input[value="{dens}"]', force=True)
            pg.wait_for_timeout(1500)
            f = out / f"{v}-{dens}.png"
            pg.screenshot(path=str(f), clip={"x": 0, "y": 0, "width": 1920, "height": 620 if dens == "comfortable" else 360})
            print(f, msgs[:3])
            pg.close()
    b.close()
srv.shutdown()
