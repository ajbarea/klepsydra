"""The wall's fit at AJ's two window sizes, in a real browser.

Maximised on a 1920x1080 screen the wall's content is about 1920x1000, and
snapped to half the screen about 945x1000 (the taskbar, title bar and frame
take the rest). In Auto, sixteen demo cards fit the first and eight the
second, compact, in four and two columns, with no vertical scrollbar and the
ring key in view.

    uv run -q --no-project --with playwright python -I scripts/test_wall_fit.py

Needs Playwright's Chromium (`uvx playwright install chromium`), or a Chrome
at $KLEPSYDRA_CHROME.
"""

import functools
import http.server
import os
import pathlib
import sys
import threading

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
CASES = [  # (width, height, cards, columns)
    (1920, 1000, 16, 4),
    (945, 1000, 8, 2),
]

MEASURE = """() => {
  const wall = document.getElementById('wall');
  const key = document.querySelector('.ring-key');
  const k = key.getBoundingClientRect();
  return {
    cards: wall.children.length,
    density: wall.dataset.density,
    columns: getComputedStyle(wall).gridTemplateColumns.split(' ').length,
    scrolls: document.documentElement.scrollHeight > innerHeight,
    bottom: Math.max(...[...wall.children].map((c) => c.getBoundingClientRect().bottom)),
    key: !key.hidden && k.height > 0 && k.bottom <= wall.getBoundingClientRect().top,
  };
}"""


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main() -> int:
    handler = functools.partial(Quiet, directory=str(ROOT))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)  # a free port
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    failed = 0
    with sync_playwright() as p:
        browser = p.chromium.launch(
            executable_path=os.environ.get("KLEPSYDRA_CHROME") or None
        )
        for width, height, cards, columns in CASES:
            page = browser.new_page(viewport={"width": width, "height": height})
            page.goto(f"http://127.0.0.1:{port}/src/wall.html?demo={cards}")
            page.wait_for_function(
                f"document.getElementById('wall').children.length === {cards}"
            )
            # In the app the bar shows + New session; the fit must hold with it.
            page.evaluate(
                "document.getElementById('new-session').hidden = false; dispatchEvent(new Event('resize'))"
            )
            page.wait_for_timeout(400)
            got = page.evaluate(MEASURE)
            want = {
                "cards": cards,
                "density": "compact",
                "columns": columns,
                "scrolls": False,
                "key": True,
            }
            ok = {k: got[k] for k in want} == want and got["bottom"] <= height
            failed += not ok
            print(f"{'ok' if ok else 'FAIL'} {width}x{height}: {got}")
            page.close()
        browser.close()
    server.shutdown()
    print(f"{len(CASES) - failed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
