"""The wall in a real browser: its fit, and Auto's density as things change.

Maximised on a 1920x1080 screen the wall's content is about 1920x1000, and
snapped to half the screen about 945x1000 (the taskbar, title bar and frame
take the rest). In Auto, sixteen demo cards fit the first and eight the
second, compact, in four and two columns, with no vertical scrollbar and the
ring key in view. Auto never leaves a comfortable wall scrolling: not when a
card grows, not at an exact fit, not where the comfortable bar is taller than
the compact one. A note on a compact card never covers its exchange. The ledger line and
chip fit the compact foot slot, and the ledger drawer opens, closes and gives
focus back.

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

    def open(self, width, height, cards, fixture=None, ledger=None):
        page = self.browser.new_page(viewport={"width": width, "height": height})
        self.ledger_requests = 0

        def count(route):
            self.ledger_requests += 1
            if ledger is None:
                route.continue_()
            else:
                route.fulfill(
                    status=200, content_type="application/json", body=ledger
                )

        page.route("**/ledger-demo.json", count)
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


DRAWER_OPEN = "document.getElementById('ledger').open"
# Shut, and its close event has run: focus moves in that event, a task after .open turns false.
DRAWER_SHUT = "!document.getElementById('ledger').open && !document.getElementById('ledger').contains(document.activeElement)"
ACTIVE = """() => {
  const a = document.activeElement;
  const card = a.closest('.card');
  return { id: a.id, cls: a.className, card: card ? card.querySelector('.name').textContent : null };
}"""


def ledger_view(**changes):
    """The ledger sample as a string, with `changes` laid over it."""
    view = json.loads((ROOT / "scripts/fixtures/ledger-demo.json").read_text())
    view.update(changes)
    return json.dumps(view)


def open_drawer(page):
    page.click("#ledger-open")
    page.wait_for_selector("#ledger .ledger-content table, #ledger .empty-state")


def ledger_line_clear_of_text(wall):
    """A compact card's ledger line sits in the foot slot: clear of every
    text, inside the card, and gone while a note shows."""
    page = wall.open(1920, 1000, 16)
    got = page.evaluate(
        """() => {
      const hit = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
      const out = { lines: 0, overlaps: [], tall: new Set(), long: 0, chips: 0 };
      for (const card of document.querySelectorAll('.card')) {
        const line = card.querySelector('.ledger-line');
        out.tall.add(card.getBoundingClientRect().height.toFixed(1));
        if (getComputedStyle(line).display === 'none' || line.hidden) continue;
        out.lines++;
        const l = line.getBoundingClientRect();
        if (l.bottom > card.getBoundingClientRect().bottom) out.overlaps.push('outside');
        for (const el of card.querySelectorAll('.said p, .ask, .meta, .name, .task, .pill, .jump')) {
          const r = el.getBoundingClientRect();
          if (r.height && getComputedStyle(el).display !== 'none' && hit(l, r)) out.overlaps.push(el.className);
        }
        const short = card.querySelector('.r-short').textContent;
        if (short.split(' \u00b7 ').length > 3) out.long++;
        if (!card.querySelector('.chip').hidden) out.chips++;
        // A note takes the slot.
        card.querySelector('.note').textContent = 'Opened';
        if (getComputedStyle(line).display !== 'none') out.overlaps.push('shown with a note');
        card.querySelector('.note').textContent = '';
      }
      out.tall = [...out.tall];
      return out;
    }"""
    )
    ok = (
        got["lines"] >= 8
        and not got["overlaps"]
        and got["long"] == 0
        and got["chips"] >= 3
        and len(got["tall"]) == 1
    )
    wall.check(ok, "compact ledger lines clear of the text, one card height", got)
    page.close()


def receipt_text(wall):
    """Comfortable cards say the whole receipt; compact ones the top three;
    an all-zero session has no line."""
    page = wall.open(1920, 2000, 16)
    page.click(".density label:has([value=comfortable])")
    page.wait_for_timeout(SETTLE_MS)
    got = page.evaluate(
        """() => {
      const find = (name) => [...document.querySelectorAll('.card')].find((c) => c.querySelector('.name').textContent === name);
      const text = (name) => find(name).querySelector('.r-full').textContent;
      const visible = (name) => !find(name).querySelector('.ledger-line').hidden && getComputedStyle(find(name).querySelector('.ledger-line')).display !== 'none';
      return {
        hephaestus: text('Hephaestus'),
        techne: text('Techne'),
        zero: visible('Dokimasia'),
        none: visible('Nightly corpus rebuild'),
        shortHidden: getComputedStyle(find('Techne').querySelector('.r-short')).display,
      };
    }"""
    )
    ok = (
        got["hephaestus"]
        == "+312 \u221240 lines \u00b7 2 commits \u00b7 1 PR \u00b7 1.2M tokens (86% cached)"
        and got["techne"].startswith("+1.5k \u2212310 lines \u00b7 6 commits \u00b7 2 PRs")
        and got["zero"] is False
        and got["none"] is False
        and got["shortHidden"] == "none"
    )
    wall.check(ok, "receipt lines: full when comfortable, absent when all zero", got)
    page.close()


def chip_name(wall):
    """The chip's accessible name says what was blocked; its short text is hidden from readers."""
    page = wall.open(1920, 1000, 16)
    chip = page.get_by_role("button", name="3 blocked: tool calls a hook or config rule turned down")
    one = page.get_by_role("button", name="1 blocked: tool call a hook or config rule turned down")
    got = page.evaluate(
        """() => [...document.querySelectorAll('.chip')].map((c) => [c.querySelector('.c-short').textContent, c.querySelector('.c-short').getAttribute('aria-hidden')])"""
    )
    four = page.get_by_role("button", name="4 blocked: tool calls a hook or config rule turned down")
    ok = chip.count() == 1 and one.count() == 1 and four.count() == 1 and all(h == "true" for _, h in got)
    wall.check(ok, "the guardrail chip is named in full", [chip.count(), one.count(), got[:3]])
    page.close()


def drawer_opens_and_returns_focus(wall):
    """The header button and a chip open a modal dialog; Esc and Close shut
    it and focus goes back to the opener."""
    page = wall.open(1920, 1000, 16)
    page.focus("#ledger-open")
    page.keyboard.press("Enter")
    page.wait_for_selector("#ledger .ledger-content table")
    first = page.evaluate("document.activeElement.id")
    wall.check(first == "ledger-title", "the drawer opens with focus on its title", first)
    named = page.get_by_role("dialog", name="Ledger").count()
    inert = page.evaluate("document.querySelector('#ledger:modal') !== null")
    page.keyboard.press("Escape")
    page.wait_for_function(DRAWER_SHUT)
    from_button = page.evaluate(ACTIVE)
    wall.check(
        named == 1 and inert and from_button["id"] == "ledger-open",
        "the Ledger button opens a named modal; Esc returns focus to it",
        [named, inert, from_button],
    )

    chip = page.locator(".card:has(.name:text-is('Kallos')) .chip")
    chip.focus()
    page.keyboard.press("Enter")
    page.wait_for_selector("#ledger .scope")
    scope = page.inner_text("#ledger .scope")
    blocked = page.locator("#ledger-blocked-table tbody tr")
    who = {c.inner_text() for c in page.locator("#ledger-blocked-table tbody tr td:nth-child(2)").all()}
    page.click("#ledger .ledger-close")
    page.wait_for_function(DRAWER_SHUT)
    from_chip = page.evaluate(ACTIVE)
    ok = (
        "Showing Kallos only" in scope
        and blocked.count() == 3
        and who == {"Kallos"}
        and from_chip["card"] == "Kallos"
        and "chip" in from_chip["cls"]
    )
    wall.check(ok, "a chip opens the ledger for its session; Close returns focus", [scope, blocked.count(), who, from_chip])

    chip.click()
    page.wait_for_selector("#ledger .scope")
    page.focus("#ledger .scope button")
    page.keyboard.press("Enter")
    page.wait_for_function("document.querySelectorAll('#ledger-blocked-table tbody tr').length === 5")
    inside = page.evaluate("document.getElementById('ledger').contains(document.activeElement) && document.activeElement.id")
    wall.check(inside == "ledger-title", "Show all keeps focus inside the dialog, on its title", inside)
    page.keyboard.press("Escape")
    page.wait_for_function(DRAWER_SHUT)

    # An opener that stops being drawn while the drawer is open (a compact
    # card's note hides its ledger line) hands focus to the Ledger button.
    chip.click()
    page.wait_for_selector("#ledger .scope")
    page.evaluate("[...document.querySelectorAll('.card')].find(c => c.querySelector('.name').textContent === 'Kallos').querySelector('.ledger-line').style.setProperty('display', 'none')")
    page.keyboard.press("Escape")
    page.wait_for_function(DRAWER_SHUT)
    fallback = page.evaluate(ACTIVE)
    wall.check(fallback["id"] == "ledger-open", "a hidden opener gives focus to the Ledger button", fallback)
    page.close()


def drawer_tables(wall):
    """Every chart has its table: tokens by character is one table whose bar
    is decoration; attribution, the guardrail log and the figures are text."""
    page = wall.open(960, 1000, 16)
    open_drawer(page)
    got = page.evaluate(
        """() => {
      const d = document.getElementById('ledger');
      const t = document.getElementById('ledger-characters-table');
      const heads = [...t.tHead.rows[0].cells].map((c) => [c.textContent, c.getAttribute('aria-hidden')]);
      const rows = [...t.tBodies[0].rows].map((r) => [r.cells[0].textContent, r.cells[1].getAttribute('aria-hidden'), r.cells[1].querySelectorAll('.fill').length, r.cells[2].textContent]);
      const tables = [...d.querySelectorAll('table')].map((x) => [x.querySelector('caption').textContent, [...x.querySelectorAll('thead th')].map((h) => h.textContent)]);
      const colour = getComputedStyle(d.querySelector('.fill')).backgroundColor;
      const textOnAccent = [...d.querySelectorAll('td, th, dd, dt, p, h3')].some((e) => getComputedStyle(e).color === colour && colour !== getComputedStyle(d).color);
      const fills = [...d.querySelectorAll('.fill')].map((f) => f.getBoundingClientRect().height);
      return { heads, rows, tables, textOnAccent, fills, links: d.querySelectorAll('a, [href]').length,
               cost: [...d.querySelectorAll('.cost')].map((c) => c.textContent),
               scrollsX: d.scrollWidth > d.clientWidth };
    }"""
    )
    names = [t[0] for t in got["tables"]]
    ok = (
        got["heads"][0] == ["Character", None]
        and got["heads"][1][1] == "true"
        and got["heads"][2][0] == "Tokens"
        and len(got["rows"]) >= 10
        and all(r[1] == "true" and r[2] == 1 and r[3].replace(",", "").isdigit() for r in got["rows"])
        and "Tokens today by character" in names
        and "Tokens today by skill" in names
        and "Tokens today by plugin" in names
        and "Tokens today by MCP server" in names
        and "Tool calls blocked today" in names
        and all(h for t in got["tables"] for h in t[1][:1])
        and not got["textOnAccent"]
        and set(got["fills"]) == {8}
        and got["links"] == 0
        and len(got["cost"]) == 1
        and got["cost"][0].startswith("\u2248 $")
        and "not your bill" in got["cost"][0]
        and not got["scrollsX"]
    )
    wall.check(ok, "the drawer's tables, bars and cost line", {k: got[k] for k in ("heads", "cost", "textOnAccent", "links")} | {"tables": names, "rows": len(got["rows"])})
    text = page.inner_text("#ledger")
    labels = (
        "third-party (names redacted by Claude Code)" in text
        and "custom (names redacted by Claude Code)" in text
        and "\u2014" not in text
    )
    wall.check(labels, "redacted attribution names are labelled, no em-dash", labels)
    page.close()


def drawer_states(wall):
    """No tokens today: the empty state names the README section and links
    nowhere. A taken port: the notice shows the receiver's error."""
    empty = ledger_view(
        day={"version": 1, "day": "2026-10-21", "sessions": {}, "guardrails": [], "attribution": {}, "no_session": 0},
        guardrails=[],
        guardrails_total=0,
    )
    # No receipts on the cards either: nothing has ever been exported.
    fleet = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    for session in fleet["sessions"]:
        session.pop("ledger", None)
    page = wall.open(960, 1000, 8, fixture=json.dumps(fleet), ledger=empty)
    open_drawer(page)
    text = page.inner_text("#ledger .ledger-content")
    links = page.locator("#ledger a, #ledger [href]").count()
    tables = page.locator("#ledger-characters-table").count()
    ok = "\u201cThe ledger\u201d" in text and "README" in text and links == 0 and tables == 0
    wall.check(ok, "empty state names the README section, no link", [text[:120], links, tables])
    page.close()

    # An empty day, but the cards' receipts show telemetry worked before (the next morning).
    page = wall.open(960, 1000, 8, ledger=empty)
    open_drawer(page)
    text = page.inner_text("#ledger .ledger-content")
    ok = "No token counts yet today." in text and "README" not in text
    wall.check(ok, "an empty morning with earlier receipts gives no setup advice", text[:120])
    page.close()

    error = "Only one usage of each socket address is normally permitted. (os error 10048)"
    taken = ledger_view(receiver={"addr": "127.0.0.1:4318", "listening": False, "error": error})
    page = wall.open(960, 1000, 8, ledger=taken)
    open_drawer(page)
    notice = page.inner_text("#ledger .notice")
    ok = "127.0.0.1:4318" in notice and error in notice and "not receiving" in notice
    wall.check(ok, "a taken port shows the receiver's error", notice)
    page.close()

    no_tokens = ledger_view(
        day={"version": 1, "day": "2026-10-21", "sessions": {}, "guardrails": [], "attribution": {}, "no_session": 0},
    )
    page = wall.open(960, 1000, 8, ledger=no_tokens)
    open_drawer(page)
    text = page.inner_text("#ledger .ledger-content")
    ok = "No token counts yet today." in text and "README" not in text and page.locator("#ledger-blocked-table").count() == 1
    wall.check(ok, "blocked calls but no tokens: no telemetry-off advice", text[:160])
    page.close()

    # A read that fails after Show all keeps focus in the dialog too.
    page = wall.open(1920, 1000, 16)
    page.locator(".card:has(.name:text-is('Kallos')) .chip").click()
    page.wait_for_selector("#ledger-show-all")
    page.unroute("**/ledger-demo.json")
    page.route("**/ledger-demo.json", lambda r: r.abort())
    page.focus("#ledger-show-all")
    page.keyboard.press("Enter")
    page.wait_for_selector("#ledger .ledger-content .notice")
    kept = page.evaluate("document.activeElement.id")
    wall.check(kept == "ledger-title", "a failed read keeps focus in the dialog", kept)
    page.close()

    page = wall.open(960, 1000, 8)
    open_drawer(page)
    quiet = page.locator("#ledger .notice").count() == 0
    wall.check(quiet, "no notice while the receiver is listening", quiet)
    page.close()


def drawer_follows_snapshots(wall):
    """Each snapshot reads the ledger again while the drawer is open, and not once it is shut."""
    page = wall.open(960, 1000, 8)
    open_drawer(page)
    seen = wall.ledger_requests
    deadline = 20000
    waited = 0
    while wall.ledger_requests <= seen and waited < deadline:
        page.wait_for_timeout(250)
        waited += 250
    again = wall.ledger_requests > seen
    page.keyboard.press("Escape")
    page.wait_for_function(DRAWER_SHUT)

    # A repaint keeps focus where it was inside the drawer.
    page.locator(".card:has(.name:text-is('Kallos')) .chip").click()
    page.wait_for_selector("#ledger-show-all")
    page.focus("#ledger-show-all")
    seen = wall.ledger_requests
    waited = 0
    while wall.ledger_requests <= seen and waited < deadline:
        page.wait_for_timeout(250)
        waited += 250
    page.wait_for_timeout(300)
    kept = page.evaluate("document.activeElement?.id")
    wall.check(wall.ledger_requests > seen and kept == "ledger-show-all", "a snapshot keeps focus inside the open drawer", [seen, wall.ledger_requests, kept])
    page.keyboard.press("Escape")
    page.wait_for_function(DRAWER_SHUT)
    shut = wall.ledger_requests
    page.wait_for_timeout(6000)
    wall.check(again and wall.ledger_requests == shut, "an open drawer refetches on a snapshot, a shut one does not", [seen, shut, wall.ledger_requests])
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


def compact_look_on_face(wall):
    """In Compact the portrait button covers the round face exactly."""
    page = wall.open(945, 1000, 8)
    off = page.evaluate(
        """() => [...document.querySelectorAll('.card')].filter((c) => !c.querySelector('.look').hidden).map((c) => {
          const [l, f] = [c.querySelector('.look'), c.querySelector('.portrait')].map((e) => e.getBoundingClientRect());
          return Math.max(...['left', 'top', 'width', 'height'].map((k) => Math.abs(l[k] - f[k])));
        }).filter((d) => d > 0.5)"""
    )
    wall.check(not off, "the compact look button sits on the face", off)
    page.close()


def long_tool_stays_in_card(wall):
    """A needs-you line naming a long tool wraps inside its card at either density."""
    for density in ("comfortable", "compact"):
        page = wall.open(945, 1000, 8)
        page.click(f".density label:has([value={density}])")
        page.wait_for_timeout(SETTLE_MS)
        spill = page.evaluate(
            """() => {
          const ask = [...document.querySelectorAll('.card .ask')].find((a) => !a.hidden);
          ask.querySelector('.text').textContent = 'Waiting for you to approve mcp__claude_ai_Gmail__apply_sensitive_message_label_and_then_some_more_words_without_breaks';
          const [a, c] = [ask.getBoundingClientRect(), ask.closest('.card').getBoundingClientRect()];
          return a.right > c.right + 0.5 || ask.scrollWidth > ask.clientWidth + 1 ? [a.right, c.right, ask.scrollWidth, ask.clientWidth] : null;
        }"""
        )
        wall.check(spill is None, f"a long tool name stays in its {density} card", spill)
        page.close()


def dialog_caption_fits(wall):
    """In a short window the dialog's caption is never cut off: it fits or scrolls."""
    page = wall.open(1280, 300, 4)
    page.click(".density label:has([value=comfortable])")
    page.wait_for_timeout(SETTLE_MS)
    cut = []
    for i in range(page.locator(".card .look:not([hidden])").count()):
        page.locator(".card .look:not([hidden])").nth(i).click()
        cut += page.evaluate(
            """() => {
          const d = document.getElementById('portrait');
          const r = d.getBoundingClientRect();
          const out = [];
          for (const el of d.querySelectorAll('.caption h2, .caption .epithet, .caption .voice, .caption .close')) {
            const e = el.getBoundingClientRect();
            if (e.right > r.right + 0.5 || el.scrollWidth > el.clientWidth + 1) out.push(el.textContent + ' wide');
          }
          if (getComputedStyle(d).overflowY !== 'auto' && d.scrollHeight > d.clientHeight) out.push('clipped below');
          return out;
        }"""
        )
        page.keyboard.press("Escape")
    wall.check(not cut, "the dialog caption fits or scrolls at 1280x300", cut)
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
            ledger_line_clear_of_text,
            receipt_text,
            chip_name,
            drawer_opens_and_returns_focus,
            drawer_tables,
            drawer_states,
            drawer_follows_snapshots,
            portrait_dialog,
            band_clear,
            arrival_once,
            dialog_backdrop_only,
            compact_look_on_face,
            long_tool_stays_in_card,
            dialog_caption_fits,
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
