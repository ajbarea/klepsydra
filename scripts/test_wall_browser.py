"""The wall in a real browser: its fit, and Auto's density as things change.

Maximised on a 1920x1080 screen the wall's content is about 1920x1000, and
snapped to half the screen about 945x1000 (the taskbar, title bar and frame
take the rest). In Auto, sixteen demo cards fit the first and eight the
second, compact, in four and two columns, with no vertical scrollbar and the
ring key in view. Auto never leaves a comfortable wall scrolling: not when a
card grows, not at an exact fit, not where the comfortable bar is taller than
the compact one. A note on a compact card never covers its exchange.

    uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py

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

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
SETTLE_MS = 350  # past the wall's resize settle and a frame
FIT = [  # (width, height, cards, columns)
    (1920, 1000, 16, 4),
    (945, 1000, 8, 2),
]

STATE = """() => {
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


class Wall:
    def __init__(self, browser, port):
        self.browser, self.port, self.failed, self.passed = browser, port, 0, 0

    def open(self, width, height, cards, fixture=None):
        page = self.browser.new_page(viewport={"width": width, "height": height})
        if fixture:
            page.route(
                "**/fleet-demo.json",
                lambda r: r.fulfill(
                    status=200, content_type="application/json", body=fixture
                ),
            )
        page.goto(f"http://127.0.0.1:{self.port}/src/wall.html?demo={cards}")
        page.wait_for_function(
            f"document.getElementById('wall').children.length === {cards}"
        )
        # In the app the bar shows + New session; the fit must hold with it.
        page.evaluate(
            "document.getElementById('new-session').hidden = false;"
            " dispatchEvent(new Event('resize'))"
        )
        page.wait_for_timeout(SETTLE_MS)
        return page

    def check(self, ok, what, got):
        self.passed += bool(ok)
        self.failed += not ok
        print(f"{'ok' if ok else 'FAIL'} {what}: {got}")

    def resize(self, page, width, height):
        page.set_viewport_size({"width": width, "height": height})
        page.wait_for_timeout(SETTLE_MS)
        return page.evaluate(STATE)


def comfortable_height(wall, width, cards):
    """The height the comfortable wall needs at `width`, bar included."""
    page = wall.open(width, 2000, cards)
    page.click(".density label:has([value=comfortable])")
    page.wait_for_timeout(SETTLE_MS)
    need = page.evaluate(
        "Math.ceil(document.getElementById('wall').getBoundingClientRect().bottom)"
    )
    page.close()
    return need


def fit(wall):
    for width, height, cards, columns in FIT:
        page = wall.open(width, height, cards)
        got = page.evaluate(STATE)
        want = {
            "cards": cards,
            "density": "compact",
            "columns": columns,
            "scrolls": False,
            "key": True,
        }
        ok = {k: got[k] for k in want} == want and got["bottom"] <= height
        wall.check(ok, f"fit {width}x{height}", got)
        page.close()


def grows(wall):
    """A card that grows past the fold turns the wall compact."""
    width, cards = 945, 4
    need = comfortable_height(wall, width, cards)
    page = wall.open(width, need + 20, cards)
    before = page.evaluate(STATE)
    page.evaluate(
        "() => { const e = document.querySelector('.card .error');"
        " e.hidden = false; e.textContent = 'A long error. '.repeat(40); }"
    )
    page.wait_for_timeout(SETTLE_MS)
    after = page.evaluate(STATE)
    ok = before["density"] == "comfortable" and after["density"] == "compact"
    wall.check(ok and not after["scrolls"], "a growing card re-checks Auto", after)
    page.close()


def never_scrolls_comfortable(wall):
    """Down then up through the boundary a pixel at a time: Auto may show
    comfortable only where it does not scroll, and settles on one density."""
    # 1030 px: the comfortable bar is a line taller than the compact one, and
    # five cards leave room in the last row for the spare card Auto asks for.
    for width, cards in ((945, 4), (1030, 5), (850, 4)):
        need = comfortable_height(wall, width, cards)
        page = wall.open(width, need + 40, cards)
        bad = []
        heights = list(range(need + 30, need - 30, -1))
        for h in heights + heights[::-1]:
            got = wall.resize(page, width, h)
            if got["density"] == "comfortable" and got["scrolls"]:
                bad.append(h)
            page.wait_for_timeout(120)
            if (
                page.evaluate("document.getElementById('wall').dataset.density")
                != got["density"]
            ):
                bad.append(f"{h} flips")
        wall.check(
            not bad, f"comfortable never scrolls at {width} (needs {need})", bad[:8]
        )
        page.close()


def same_cards(n):
    """The demo with `n` copies of its speaking session: every card alike, so
    the spare card Auto asks for adds no height of its own."""
    demo = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    one = next(s for s in demo["sessions"] if s["session_id"] == "demo-9-bm_fable")
    sessions = [{**one, "session_id": f"same-{i}"} for i in range(n)]
    return json.dumps({"at": demo["at"], "sessions": sessions, "speaking": None})


BARS = """() => {
  const bar = document.querySelector('.bar');
  const was = bar.dataset.density;
  const h = {};
  for (const d of ['comfortable', 'compact']) { bar.dataset.density = d; h[d] = bar.getBoundingClientRect().height; }
  bar.dataset.density = was;
  return h;
}"""


def bar_of_comfortable(wall):
    """Auto measures the comfortable wall under the comfortable bar, which can
    be a line taller than the compact one it is looking at."""
    cards, body = 5, same_cards(5)
    page = wall.open(1400, 2000, cards, body)
    width = next(
        (
            w
            for w in range(800, 1500, 5)
            if page.set_viewport_size({"width": w, "height": 2000}) is None
            and (h := page.evaluate(BARS))["comfortable"] > h["compact"] + 10
            and page.evaluate(
                "getComputedStyle(document.getElementById('wall')).gridTemplateColumns.split(' ').length"
            )
            == 2
        ),
        None,
    )
    page.close()
    if width is None:
        wall.check(False, "a width where the comfortable bar is taller", None)
        return
    page = wall.open(width, 2000, cards, body)
    page.click(".density label:has([value=comfortable])")
    page.wait_for_timeout(SETTLE_MS)
    need = page.evaluate(
        "Math.ceil(document.getElementById('wall').getBoundingClientRect().bottom)"
    )
    page.click(".density label:has([value=auto])")
    bad = []
    for h in range(need - 40, need + 10, 2):  # up from compact
        got = wall.resize(page, width, h)
        if got["density"] == "comfortable" and got["scrolls"]:
            bad.append(h)
    wall.check(
        not bad,
        f"the comfortable bar decides, {cards} cards at {width} (needs {need})",
        bad[:8],
    )
    page.close()


def note_clear_of_exchange(wall):
    """A button's note on a compact card covers none of its text."""
    page = wall.open(945, 1000, 8)
    overlaps = page.evaluate(
        """() => {
      const hit = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
      const out = [];
      for (const card of document.querySelectorAll('.card')) {
        const note = card.querySelector('.note');
        note.textContent = 'Error: no tmux window named this session in the fleet session, so nothing was selected';
        const n = note.getBoundingClientRect();
        for (const el of card.querySelectorAll('.said p, .ask, .meta, .name, .task, .pill, .jump')) {
          const r = el.getBoundingClientRect();
          if (r.height && getComputedStyle(el).display !== 'none' && hit(n, r)) out.push(card.querySelector('.name').textContent + ' ' + el.className);
        }
        if (n.bottom > card.getBoundingClientRect().bottom) out.push(card.querySelector('.name').textContent + ' outside');
      }
      return out;
    }"""
    )
    got = page.evaluate(STATE)
    wall.check(
        not overlaps and not got["scrolls"], "compact notes clear of the text", overlaps
    )
    page.close()


def comfortable(wall, width, cards):
    page = wall.open(width, 2400, cards)
    page.set_default_timeout(5000)
    page.click(".density label:has([value=comfortable])")
    page.wait_for_timeout(SETTLE_MS)
    return page


def portrait_dialog(wall):
    """The figure opens the full portrait: Enter, Space and a click open it;
    Escape, Close and the backdrop close it; focus goes back to the figure,
    or to the wall once its card has gone. In Compact the face opens it."""
    page = comfortable(wall, 1920, 8)
    state = """() => ({
      open: document.getElementById('portrait').open,
      focus: document.activeElement.id || document.activeElement.className,
      name: document.getElementById('portrait-name').textContent,
    })"""
    look = page.locator(".card .look:not([hidden])").first
    who = look.get_attribute("aria-label")
    for opener, closer in [("Enter", "Escape"), ("Space", "close"), ("click", "backdrop")]:
        if opener == "click":
            look.click()
        else:
            look.focus()
            page.keyboard.press(opener)
        opened = page.evaluate(state)
        if closer == "Escape":
            page.keyboard.press("Escape")
        elif closer == "close":
            page.click("#portrait .close")
        else:
            page.mouse.click(4, 4)
        closed = page.evaluate(state)
        wall.check(
            opened["open"] and who == f"View {opened['name']}'s portrait" and not closed["open"] and closed["focus"] == "look",
            f"{opener} opens, {closer} closes, focus returns",
            [opened, closed],
        )
    look.click()
    page.evaluate("document.querySelector('.card').remove()")
    page.keyboard.press("Escape")
    gone = page.evaluate(state)
    wall.check(gone["focus"] == "wall", "a card gone while open hands focus to the wall", gone)
    page.close()
    page = wall.open(945, 1000, 8)
    page.locator(".card .look:not([hidden])").first.click()
    compact = page.evaluate(state)
    wall.check(compact["open"], "the compact face opens it", compact)
    page.close()


def arrival_once(wall):
    """A card arrives once: built while Compact shows, it does not replay its
    arrival when the wall turns Comfortable."""
    page = wall.open(945, 1000, 8)
    page.click(".density label:has([value=comfortable])")
    page.wait_for_timeout(SETTLE_MS)
    left = page.evaluate("document.querySelectorAll('.card.arriving').length")
    wall.check(left == 0, "no arrival replays on a density switch", left)
    page.close()


def dialog_backdrop_only(wall):
    """In a short window only the backdrop closes the portrait, never a click
    inside the dialog beside the image."""
    page = wall.open(1280, 360, 4)
    page.click(".density label:has([value=comfortable])")
    page.wait_for_timeout(SETTLE_MS)
    page.locator(".card .look:not([hidden])").first.click()
    box = page.evaluate(
        "(() => { const d = document.getElementById('portrait').getBoundingClientRect(); const i = document.querySelector('#portrait .full').getBoundingClientRect(); return [d.left, d.top, d.right, i.right, i.bottom]; })()"
    )
    inside = [(box[3] + box[2]) / 2, (box[1] + box[4]) / 2] if box[2] - box[3] > 4 else [box[0] + 4, box[1] + 4]
    page.mouse.click(*inside)
    still = page.evaluate("document.getElementById('portrait').open")
    wall.check(still, "a click inside the dialog keeps it open", box)
    page.close()


def band_clear(wall):
    """On the band nothing covers the nameplate or the pill, and nothing but
    the figure (and its clipped aura) leaves the card's top edge."""
    for width in (1920, 945):
        page = comfortable(wall, width, 16)
        bad = page.evaluate(
            """() => {
          const hit = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
          const shown = (el) => el && !el.hidden && getComputedStyle(el).display !== 'none' && el.getBoundingClientRect().height > 0;
          const out = [];
          for (const card of document.querySelectorAll('.card')) {
            const name = card.querySelector('.name').textContent;
            const c = card.getBoundingClientRect();
            const text = [...card.querySelectorAll('header .name, header .epithet, header .task, header .pill')].filter(shown);
            // The portrait's waves reach 12/80 of it past its edge; the aura only clips them.
            const grow = (r, by) => ({ left: r.left - by, right: r.right + by, top: r.top - by, bottom: r.bottom + by });
            for (const el of ['.look', '.marks', '.portrait']) {
              const e = card.querySelector(el);
              if (!shown(e)) continue;
              const box = e.getBoundingClientRect();
              const r = el === '.portrait' ? grow(box, box.width * 12 / 80) : box;
              for (const t of text) if (hit(r, t.getBoundingClientRect())) out.push(`${name}: ${el} covers ${t.className}`);
              const top = el === '.portrait' && card.classList.contains('has-figure') ? card.querySelector('.aura').getBoundingClientRect().top : r.top;
              if (top < c.top - 14.5) out.push(`${name}: ${el} ${(c.top - top).toFixed(1)} px over the top`);
            }
            const [n, pill] = [card.querySelector('.name'), card.querySelector('.pill')].map((e) => e.getBoundingClientRect());
            if (hit(n, pill)) out.push(`${name}: name under the pill`);
          }
          return out;
        }"""
        )
        wall.check(not bad, f"band clear at {width}", bad)
        page.close()
    page = wall.open(945, 1000, 16)
    shown = page.evaluate(
        "[...document.querySelectorAll('.marks, .stage, .epithet')].filter((e) => e.getBoundingClientRect().height > 0).length"
    )
    wall.check(shown == 0, "a compact card shows no band, epithet or plinth", shown)
    page.close()


def main() -> int:
    handler = functools.partial(Quiet, directory=str(ROOT))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)  # a free port
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with sync_playwright() as p:
        browser = p.chromium.launch(
            executable_path=os.environ.get("KLEPSYDRA_CHROME") or None
        )
        wall = Wall(browser, server.server_address[1])
        only = sys.argv[1:]
        cases = (
            fit,
            grows,
            never_scrolls_comfortable,
            bar_of_comfortable,
            note_clear_of_exchange,
            portrait_dialog,
            band_clear,
            arrival_once,
            dialog_backdrop_only,
        )
        for case in cases:
            if not only or case.__name__ in only:
                case(wall)
        browser.close()
    server.shutdown()
    print(f"{wall.passed} passed, {wall.failed} failed")
    return 1 if wall.failed else 0


if __name__ == "__main__":
    sys.exit(main())
