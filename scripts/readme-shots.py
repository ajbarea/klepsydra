"""The README's screenshots, captured from the real pages in a browser.

Serves the repo root and opens the bar and the wall with the demo fixtures in
scripts/fixtures/ (the wall's ?demo sample), so nothing private is on screen.
Writes PNGs to assets/, cut to a 256-colour palette and recompressed, and
prints each one's size. Run it after a change to what a screenshot shows:

    uv run -q --no-project --with playwright --with pillow --with pyoxipng \
      python -I scripts/readme-shots.py

Needs Playwright's Chromium (`uvx playwright install chromium`), or a Chrome
at $KLEPSYDRA_CHROME, and cargo, which builds the phone wall's server.
"""

import functools
import http.server
import io
import json
import os
import pathlib
import re
import sys
import tempfile
import threading
import time

import oxipng
from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import test_phone_browser as phone  # noqa: E402  the phone suite's server and demo data
import test_wall_browser as suite  # noqa: E402  the wall suite's app stub, to feed snapshots as the app does
OUT = ROOT / "assets"
DEMO = ROOT / "scripts/fixtures/fleet-demo.json"
SETTLE_MS = 600  # past the wall's resize settle, arrivals and a frame
# The README shows the dark scheme, klepsydra's own (#247); the light one follows the system.
SCHEME = "dark"
# How long after Hephaestus's snapshot the hero is taken: the figure has sprung
# over the frame and the banner "HEPHAESTUS HAS ARRIVED!" holds (#373).
ARRIVAL_SHOT_MS = 1300


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def accounts():
    """Three accounts as the bar shows them: Antigravity's session and week, a
    personal session and week, and a team session with two and a half hours
    to go."""
    now = int(time.time())

    def w(pct, reset_in):
        return {"used_percentage": pct, "resets_at": now + reset_in}

    def entry(key, label, windows, **extra):
        return {"account": key, "label": label, "written_at": now, "observed_at": now, "windows": windows, **extra}

    return json.dumps({
        "agy": entry("agy-primary", "Google AI Pro", {"five_hour": w(7, 6_700), "seven_day": w(4, 590_000)}, harness="agy"),
        "pers": entry("pers", "Personal", {"five_hour": w(57, 480), "seven_day": w(27, 541_000)}),
        "team": entry("team", "Team", {"five_hour": w(12, 9_000)}),
    })


# The app's order (the fleet crate's view.rs `snapshot`): needs you first, the
# longest wait leading; then error, working, done, new, silent and ended, each
# newest first. The wall shows a snapshot as it comes, and the sample is unsorted.
STATUS_ORDER = ["needs_you", "error", "working", "done", "new", "silent", "ended"]


def app_order(fleet):
    def key(s):
        at = s["status_at"] if s["status"] == "needs_you" else -s["status_at"]
        return (STATUS_ORDER.index(s["status"]), at, s["session_id"])

    fleet["sessions"].sort(key=key)
    return fleet


def json_route(body):
    return lambda r: r.fulfill(status=200, content_type="application/json", body=body)


def wall(browser, port, width, height, query, density=None):
    """The wall at `width` x `height` on ?QUERY, the sample's first ?demo=N
    sessions (the page's slice) in the app's order."""
    page = browser.new_page(viewport={"width": width, "height": height}, color_scheme=SCHEME)
    fleet = json.loads(DEMO.read_text())
    n = int(m.group(1)) if (m := re.search(r"\bdemo=(\d+)", query)) else len(fleet["sessions"])
    fleet["sessions"][:n] = app_order({"sessions": fleet["sessions"][:n]})["sessions"]
    page.route("**/fleet-demo.json", json_route(json.dumps(fleet)))
    page.goto(f"http://127.0.0.1:{port}/src/wall.html?{query}")
    page.wait_for_function("document.getElementById('wall').children.length > 0")
    # The app shows + New session and Wrap up… in the bar; a browser hides them.
    page.evaluate(
        "document.getElementById('new-session').hidden = false;"
        " document.getElementById('wrapup-open').hidden = false;"
        " dispatchEvent(new Event('resize'))"
    )
    if density:
        suite.pick(page, f".density label:has([value={density}])")
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


def arrival(browser, port, width, height, n):
    """The wall as the app feeds it, the first N demo sessions in the app's
    order, caught while Hephaestus arrives: the page first sees the others,
    then a snapshot with him (#373)."""
    fixture = json.loads(DEMO.read_text())
    at = fixture.pop("at")
    snapshot = suite.shifted(app_order(fixture), int(time.time()) - at)
    every = snapshot["sessions"][:n]
    snapshot["speaking"] = None
    before = {**snapshot, "sessions": [s for s in every if s["voice"] != "am_michael"]}
    page = browser.new_page(viewport={"width": width, "height": height}, color_scheme=SCHEME)
    page.add_init_script(suite.TAURI_STUB % json.dumps(before))
    page.goto(f"http://127.0.0.1:{port}/src/wall.html")
    page.wait_for_function("document.getElementById('wall').children.length > 0")
    suite.pick(page, ".density label:has([value=comfortable])")
    page.wait_for_timeout(SETTLE_MS)
    page.evaluate("(s) => window.__channel.onmessage(s)", {**snapshot, "sessions": every})
    page.wait_for_timeout(ARRIVAL_SHOT_MS)
    return page


# The demo sessions name no account; the bar's shots spread them over the
# demo accounts, so each portrait docks beside its account's chip (#421).
DOCK = [{"id": "pers", "label": "Personal"}, {"id": "team", "label": "Team"}, {"id": "agy-primary", "label": "Google AI Pro"}]


def docked(fleet):
    snapshot = json.loads(fleet)
    for i, s in enumerate(snapshot["sessions"]):
        s["account"] = DOCK[i % len(DOCK)]
    return json.dumps(snapshot)


def bar(browser, port, width, height, query, fleet):
    page = browser.new_page(viewport={"width": width, "height": height}, color_scheme=SCHEME)
    page.route("**/dev-fixture.json", json_route(accounts()))
    page.route("**/dev-fleet.json", json_route(docked(fleet)))
    page.goto(f"http://127.0.0.1:{port}/src/index.html?still=1{query}")
    page.wait_for_selector("#chips > .chip")
    if json.loads(fleet)["sessions"]:
        page.wait_for_selector("#chips .faces > .face")
    page.wait_for_timeout(SETTLE_MS)
    # Down to the panel, which holds the chips and every portrait.
    box = page.evaluate("""() => {
      const b = document.getElementById('panel').getBoundingClientRect();
      return {x: 0, y: 0, width: Math.min(innerWidth, Math.ceil(b.right) + 8),
              height: Math.min(innerHeight, Math.ceil(b.bottom) + 8)};
    }""")
    shot = page.screenshot(clip=box)
    page.close()
    return shot


def main():
    handler = functools.partial(Quiet, directory=str(ROOT))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    fleet = json.dumps(app_order(json.loads(DEMO.read_text())))
    chrome = os.environ.get("KLEPSYDRA_CHROME")
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=chrome) if chrome else p.chromium.launch()

        # The bar as it sits on the taskbar: a chip per account, each with its portraits.
        save(bar(browser, port, 1600, 48, "&layout=compact", fleet), "compact-taskbar")
        # The full layout: a line per account with every window, and its portraits.
        save(bar(browser, port, 1600, 200, "", fleet), "fleet-strip")
        # Three accounts and no sessions: the keeper at rest.
        save(bar(browser, port, 1000, 200, "", json.dumps({"sessions": []})), "two-accounts")

        # The wall maximised at 1920: eight cards, Comfortable, as Hephaestus arrives.
        page = arrival(browser, port, 1920, 1000, 8)
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

        # The Ledger, docked beside the wall.
        page = wall(browser, port, 1920, 1000, "demo=8", "comfortable")
        page.click("#ledger-open")
        page.wait_for_selector("#ledger .ledger-content table")
        page.wait_for_timeout(SETTLE_MS)
        save(page.locator("#ledger").screenshot(), "ledger")
        page.close()

        # The Needs you room: blocked sessions, then the to-do file's sections.
        page = wall(browser, port, 1920, 1000, "demo=8", "comfortable")
        page.keyboard.press("n")
        page.wait_for_selector("#needs-room .ny-row")
        page.wait_for_timeout(SETTLE_MS)
        save(page.locator("#needs-room").screenshot(), "needs-you")
        page.close()

        # A wrap-up under way: each card says where its session stands.
        page = wall(browser, port, 1920, 1000, "demo=8&wrapup", "comfortable")
        save(page.screenshot(clip=page.evaluate(CARDS)), "wrap-up")
        page.close()

        # The phone wall, served by the real phone server, at iPhone size:
        # the usage gauges, the tally and the first cards.
        with tempfile.TemporaryDirectory(prefix="klepsydra-shots-") as tmp:
            snapshot = pathlib.Path(tmp) / "fleet.json"
            phone.snapshot_file(snapshot, app_order)
            proc, addr = phone.start_server(snapshot)
            try:
                # After the build, so the countdowns read as written.
                phone.demo_usage(pathlib.Path(tmp) / "klepsydra")
                ctx = browser.new_context(viewport={"width": 390, "height": 844}, device_scale_factor=2, color_scheme=SCHEME,
                                          is_mobile=True, has_touch=True)
                page = ctx.new_page()
                page.goto(f"http://{addr}/")
                for ready in ("document.getElementById('wall').children.length > 0",
                              "document.querySelectorAll('.limits .limit-rows > li').length > 0"):
                    if not phone.wait_until(page, ready, 15):
                        raise SystemExit(f"the phone wall never showed: {ready}")
                page.wait_for_timeout(SETTLE_MS)
                save(page.screenshot(), "phone-wall")
                ctx.close()
            finally:
                proc.kill()
                proc.wait()

        browser.close()
    server.shutdown()


if __name__ == "__main__":
    sys.exit(main())
