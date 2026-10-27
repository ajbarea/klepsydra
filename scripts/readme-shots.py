"""The README's screenshots, captured from the real pages in a browser.

Serves the repo root and opens the bar and the wall with the demo fixtures in
scripts/fixtures/ (the wall's ?demo sample), so nothing private is on screen.
Writes PNGs to assets/, cut to a 256-colour palette and recompressed, and
prints each one's size. Run it after a change to what a screenshot shows:

    uv run -q --no-project --with playwright --with pillow --with pyoxipng \
      python -I scripts/readme-shots.py

Needs Playwright's Chromium (`uvx playwright install chromium`), or a Chrome
at $KLEPSYDRA_CHROME.
"""

import functools
import http.server
import json
import os
import pathlib
import sys
import threading
import io
import tempfile
import time

import oxipng
from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import test_phone_browser as phone  # noqa: E402  the phone suite's server and demo data
OUT = ROOT / "assets"
SETTLE_MS = 600  # past the wall's resize settle, arrivals and a frame


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def accounts():
    """Two accounts as the bar shows them: a personal session and week, and a
    team session that reset a while ago."""
    now = int(time.time())

    def w(pct, reset_in):
        return {"used_percentage": pct, "resets_at": now + reset_in}

    def entry(key, label, windows):
        return {"account": key, "label": label, "written_at": now, "observed_at": now, "windows": windows}

    return json.dumps({
        "pers": entry("pers", "Personal", {"five_hour": w(57, 480), "seven_day": w(27, 541_000)}),
        "team": entry("team", "Team", {"five_hour": w(12, 9_000)}),
    })


def json_route(body):
    return lambda r: r.fulfill(status=200, content_type="application/json", body=body)


def wall(browser, port, width, height, query, density=None):
    page = browser.new_page(viewport={"width": width, "height": height})
    page.goto(f"http://127.0.0.1:{port}/src/wall.html?{query}")
    page.wait_for_function("document.getElementById('wall').children.length > 0")
    # The app shows + New session and Wrap up… in the bar; a browser hides them.
    page.evaluate(
        "document.getElementById('new-session').hidden = false;"
        " document.getElementById('wrapup-open').hidden = false;"
        " dispatchEvent(new Event('resize'))"
    )
    if density:
        page.click(f".density label:has([value={density}])")
    page.wait_for_timeout(SETTLE_MS)
    return page


# The page down to its lowest card, and a margin.
CARDS = """() => ({x: 0, y: 0, width: innerWidth, height: Math.min(innerHeight,
  Math.ceil(Math.max(...[...document.getElementById('wall').children]
    .map((c) => c.getBoundingClientRect().bottom))) + 28)})"""


def save(shot, name):
    """Write `shot` (PNG bytes) to assets/NAME.png as a 256-colour palette."""
    im = Image.open(io.BytesIO(shot)).convert("RGB")
    pal = im.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG)
    raw = io.BytesIO()
    pal.save(raw, "PNG", optimize=True)
    path = OUT / f"{name}.png"
    path.write_bytes(oxipng.optimize_from_memory(raw.getvalue(), level=4))
    print(f"{path.relative_to(ROOT)}: {im.width}x{im.height}, {path.stat().st_size // 1024} KiB")


def bar(browser, port, width, height, query, fleet):
    page = browser.new_page(viewport={"width": width, "height": height})
    page.route("**/dev-fixture.json", json_route(accounts()))
    page.route("**/dev-fleet.json", json_route(fleet))
    page.goto(f"http://127.0.0.1:{port}/src/index.html?still=1{query}")
    page.wait_for_selector("#rows > *")
    if json.loads(fleet)["sessions"]:
        page.wait_for_selector("#strip:not([hidden]) > *")
    page.wait_for_timeout(SETTLE_MS)
    # Down to the panel and the strip, whichever reaches further.
    box = page.evaluate("""() => {
      const r = [document.getElementById('panel'), document.getElementById('strip')]
        .filter((e) => !e.hidden).map((e) => e.getBoundingClientRect());
      return {x: 0, y: 0, width: Math.min(innerWidth, Math.ceil(Math.max(...r.map((b) => b.right))) + 8),
              height: Math.min(innerHeight, Math.ceil(Math.max(...r.map((b) => b.bottom))) + 8)};
    }""")
    shot = page.screenshot(clip=box)
    page.close()
    return shot


def main():
    handler = functools.partial(Quiet, directory=str(ROOT))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    fleet = (ROOT / "scripts/fixtures/fleet-demo.json").read_text()
    chrome = os.environ.get("KLEPSYDRA_CHROME")
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=chrome) if chrome else p.chromium.launch()

        # The bar as it sits on the taskbar: three rings, then the portraits.
        save(bar(browser, port, 1100, 48, "&layout=compact", fleet), "compact-taskbar")
        # The full layout: a row per window, then the portraits.
        save(bar(browser, port, 1100, 160, "", fleet), "fleet-strip")
        # Two accounts and no sessions.
        save(bar(browser, port, 450, 160, "", json.dumps({"sessions": []})), "two-accounts")

        # The wall maximised at 1920: eight cards, Comfortable.
        page = wall(browser, port, 1920, 1000, "demo=8", "comfortable")
        save(page.screenshot(clip=page.evaluate(CARDS)), "wall-comfortable")
        page.close()

        # Sixteen sessions, Compact.
        page = wall(browser, port, 1920, 1000, "demo=16", "compact")
        save(page.screenshot(clip=page.evaluate(CARDS)), "wall-compact")
        page.close()

        # Split mode: the wall in the left half beside the terminal.
        page = wall(browser, port, 958, 1000, "demo=4", "comfortable")
        save(page.screenshot(clip=page.evaluate(CARDS)), "wall-split")
        page.close()

        # The Ledger drawer.
        page = wall(browser, port, 1920, 1000, "demo=8", "comfortable")
        page.click("#ledger-open")
        drawer = page.get_by_role("dialog", name="Ledger")
        drawer.wait_for()
        page.wait_for_timeout(SETTLE_MS)
        save(drawer.screenshot(), "ledger")
        page.close()

        # The Queue panel, docked beside the wall.
        page = wall(browser, port, 1920, 1000, "demo=8", "comfortable")
        page.click("#queue-open")
        page.wait_for_selector("#queue .queue-content details")
        page.wait_for_timeout(SETTLE_MS)
        save(page.locator("#queue").screenshot(), "queue-panel")
        page.close()

        # A wrap-up under way: each card says where its session stands.
        page = wall(browser, port, 1920, 1000, "demo=8&wrapup", "comfortable")
        save(page.screenshot(clip=page.evaluate(CARDS)), "wrap-up")
        page.close()

        # The phone wall, served by the real phone server, at iPhone size:
        # the usage gauges, the tally and the first cards.
        with tempfile.TemporaryDirectory(prefix="klepsydra-shots-") as tmp:
            snapshot = pathlib.Path(tmp) / "fleet.json"
            phone.snapshot_file(snapshot)
            proc, addr = phone.start_server(snapshot)
            # After the build, so the countdowns read as written.
            phone.demo_usage(pathlib.Path(tmp) / "klepsydra")
            try:
                ctx = browser.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2,
                                          is_mobile=True, has_touch=True)
                page = ctx.new_page()
                page.goto(f"http://{addr}/")
                phone.wait_until(page, "document.getElementById('wall').children.length > 0", 15)
                phone.wait_until(page, "document.querySelectorAll('.limits .limit-rows > li').length > 0", 15)
                page.wait_for_timeout(SETTLE_MS)
                save(page.screenshot(), "phone-wall")
                ctx.close()
            finally:
                proc.kill()

        browser.close()
    server.shutdown()


if __name__ == "__main__":
    sys.exit(main())
