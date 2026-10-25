"""The wall in a real browser: its fit, and Auto's density as things change.

Maximised on a 1920x1080 screen the wall's content is about 1920x1000, and
snapped to half the screen about 945x1000 (the taskbar, title bar and frame
take the rest). In Auto, sixteen demo cards fit the first and eight the
second, compact, in four and two columns, with no vertical scrollbar and the
ring key in view. Auto never leaves a comfortable wall scrolling: not when a
card grows, not at an exact fit, not where the comfortable bar is taller than
the compact one. A note on a compact card never covers its exchange. The ledger line and
chip fit the compact foot slot, and the ledger drawer opens, closes and gives
focus back. Ending a session: the card's menu, the confirm dialog and the 5 s
undo window run against a stubbed `window.__TAURI__` that records every invoke,
and no single click or key, nor any run of them short of the full deliberate
path, sends end_session. Wrapping up: the confirm's groups, each card's line
in both densities, the bar's count, Stop wrap-up and Safe to restart, and End
all ready sessions… under the same rule as End.

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

    def open(self, width, height, cards, fixture=None, ledger=None, query=""):
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
        page.goto(f"http://127.0.0.1:{self.port}/src/wall.html?demo={cards}{query}")
        page.wait_for_function(
            f"document.getElementById('wall').children.length === {cards}"
        )
        # In the app the bar shows + New session and Wrap up…; the fit must hold with them.
        page.evaluate(
            "document.getElementById('new-session').hidden = false;"
            " document.getElementById('wrapup-open').hidden = false;"
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


PARTIAL_SENTENCE = "Some telemetry for this session was not received: klepsydra was not running for part of it."
PARTIAL_STATE = """() => {
  const marks = [...document.querySelectorAll('.partial')].filter((m) => !m.hidden);
  return marks.map((m) => {
    const line = m.closest('.ledger-line').getBoundingClientRect();
    const r = m.getBoundingClientRect();
    const card = m.closest('.card');
    return {
      text: m.textContent, title: m.title, label: m.getAttribute('aria-label'), role: m.getAttribute('role'),
      inside: r.width > 0 && r.left >= line.left - 0.5 && r.right <= line.right + 0.5,
      clipped: m.scrollWidth > m.clientWidth,
      oneLine: r.height < 24,
      cardTall: card.getBoundingClientRect().height.toFixed(1),
    };
  });
}"""


def partial_mark(wall):
    """A session whose ledger_partial is set wears a short mark, named in full,
    inside its ledger line in both densities; the rest wear none."""
    page = wall.open(1920, 2000, 16)
    for density in ("compact", "comfortable"):
        page.click(f".density label:has([value={density}])")
        page.wait_for_timeout(SETTLE_MS)
        got = page.evaluate(PARTIAL_STATE)
        one = len(got) == 1
        ok = (
            one
            and got[0]["text"] == "partial"
            and got[0]["title"] == PARTIAL_SENTENCE
            and got[0]["label"] == PARTIAL_SENTENCE
            and got[0]["role"] == "img"
            and got[0]["inside"]
            and not got[0]["clipped"]
            and got[0]["oneLine"]
        )
        wall.check(ok, f"the partial mark is short, named in full and fits ({density})", got)
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
        and "Tokens today by model" in names
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
        and "local list-price estimate" in got["cost"][0]
        and "Console usage page or claude.ai usage settings" in got["cost"][0]
        and not got["scrollsX"]
    )
    wall.check(ok, "the drawer's tables, bars and cost line", {k: got[k] for k in ("heads", "cost", "textOnAccent", "links")} | {"tables": names, "rows": len(got["rows"])})
    # Each row's name as a reader hears it (the visually hidden text, else the
    # cell's), the words on screen, and the tooltip.
    rows = page.evaluate(
        """() => [...document.querySelectorAll('#ledger-characters-table tbody tr')].map((r) => {
      const c = r.cells[0];
      const shown = c.querySelector('[aria-hidden="true"]');
      return [c.querySelector('.visually-hidden')?.textContent ?? c.textContent, shown ? shown.textContent : c.textContent, c.querySelector('[title]')?.title ?? null];
    })"""
    )
    other = "Other sessions: 2 (1 with no voice, 1 with a voice outside the cast)"
    names = [r[0] for r in rows]
    cdp = page.context.new_cdp_session(page)
    tree = [n for n in cdp.send("Accessibility.getFullAXTree")["nodes"] if not n.get("ignored")]
    cdp.detach()
    cells = [n.get("name", {}).get("value", "") for n in tree if n.get("role", {}).get("value") == "cell"]
    # The tooltip sits on hidden words, so it is never read again as a description.
    described = [n.get("description", {}).get("value") for n in tree]
    ok = (
        rows[-1] == [other, "Other sessions", other]
        and names.count(other) == 1
        and cells.count(other) == 1
        and other not in described
        and not any(" :" in c or c.count("Other sessions") > 1 for c in cells)
        and not any("Earlier" in n for n in names)
        and "Techne" in names
        and "Aidos" in names
        and "am_onyx" not in " ".join(names)
    )
    wall.check(ok, "tokens by character: recorded voices only, one Other sessions row last, named once", [rows, [c for c in cells if "Other" in c]])
    models = page.evaluate(
        """() => [...document.querySelectorAll('#ledger-models-table tbody tr')].map((r) => [...r.cells].map((c) => c.textContent))"""
    )
    heads = page.evaluate("[...document.querySelectorAll('#ledger-models-table thead th')].map((h) => h.textContent)")
    ok = (
        heads == ["Model", "Tokens", "Estimate"]
        and [m[0] for m in models] == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5"]
        and all(m[1].replace(",", "").isdigit() and m[2].startswith("$") for m in models)
    )
    wall.check(ok, "tokens by model: a real table, largest first, with an estimate", [heads, models])
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

    # Blocked calls from sessions no longer on the wall: a recorded voice
    # still names its character; with none the row says "Earlier session".
    view = json.loads(ledger_view())
    day = view["day"]
    for id_, voice in (("cleared-0001", "af_heart"), ("gone-0002", None)):
        day["sessions"][id_] = {"tokens": {"input": 5}}
        if voice:
            day["voices"][id_] = voice
    view["guardrails"] = [
        {"at": 1792530000 + i, "session_id": id_, "tool_name": "Bash", "source": "config"}
        for i, id_ in enumerate(("cleared-0001", "gone-0002"))
    ]
    view["guardrails_total"] = 2
    page = wall.open(960, 1000, 8, ledger=json.dumps(view))
    open_drawer(page)
    who = sorted(c.inner_text() for c in page.locator("#ledger-blocked-table tbody tr td:nth-child(2)").all())
    wall.check(who == ["Cupid", "Earlier session"], "a cleared session's blocked calls keep its character", who)
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
        page.wait_for_function("!document.getElementById('portrait').open && !document.getElementById('portrait').contains(document.activeElement)")
        closed = page.evaluate(state)
        wall.check(
            opened["open"] and who == f"View {opened['name']}'s portrait" and not closed["open"] and closed["focus"] == "look",
            f"{opener} opens, {closer} closes, focus returns",
            [opened, closed],
        )
    look.click()
    page.evaluate("document.querySelector('.card').remove()")
    page.keyboard.press("Escape")
    # Focus moves in the close event, a task after .open turns false.
    page.wait_for_function("!document.getElementById('portrait').open && !document.getElementById('portrait').contains(document.activeElement)")
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


# ---- Ending a session -------------------------------------------------------

TIMES = {"status_at", "active_at", "updated_at", "quiet_since", "at", "started_at", "ends_at", "until", "settled_at", "turn_at"}


def shifted(value, by):
    """The demo snapshot with its times moved up to now, as feed.js does in a browser."""
    if isinstance(value, list):
        return [shifted(v, by) for v in value]
    if not isinstance(value, dict):
        return value
    return {
        k: v + by if k in TIMES and isinstance(v, (int, float)) else shifted(v, by)
        for k, v in value.items()
    }


# Stands in for the Tauri runtime. In the app the wall's only feed is
# fleet_subscribe, which hands a Channel the snapshot (ipc.js `follow`); every
# other command is recorded in window.__calls and answers "ok".
TAURI_STUB = """
window.__calls = [];
window.__TAURI__ = { core: {
  Channel: class { },
  invoke: (cmd, args) => {
    if (cmd === 'fleet_subscribe') {
      window.__channel = args.onMessage;
      setTimeout(() => args.onMessage.onmessage(%s), 0);
      return Promise.resolve();
    }
    if (cmd === 'get_wall_density') return Promise.resolve('auto');
    if (cmd === 'end_session' && window.__hold) { window.__calls.push([cmd, args]); return window.__hold; }
    window.__calls.push([cmd, args]);
    if (cmd === 'start_wrapup') return Promise.resolve(window.__asked ?? []);
    return Promise.resolve('ok');
  },
} };
"""
ENDS = "window.__calls.filter(([c]) => c === 'end_session')"
WORKING_CARD = ".card:has(.pill .label:text-is('working')):has(.menu:not([hidden]))"


def open_app(wall, width=1920, height=1000):
    """The demo wall as the app would feed it, with invokes recorded."""
    import time

    fixture = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    at = fixture.pop("at")
    snapshot = shifted(fixture, int(time.time()) - at)
    page = wall.browser.new_page(viewport={"width": width, "height": height})
    page.snapshot = snapshot
    page.add_init_script(TAURI_STUB % json.dumps(snapshot))
    page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html")
    page.wait_for_function("document.getElementById('wall').children.length > 0")
    page.wait_for_timeout(SETTLE_MS)
    return page


def menu_of(card):
    return card.locator(".menu")


def open_menu(page, card):
    menu_of(card).click()
    page.wait_for_selector("#session-menu:not([hidden])")


def confirm_end(page, name):
    """Click the dialog's End once it wakes, as a deliberate second step would."""
    page.wait_for_selector(".end-confirm:not([aria-disabled='true'])")
    page.get_by_role("button", name=f"End {name}").click()


def calls(page, cmd):
    return page.evaluate(f"window.__calls.filter(([c]) => c === '{cmd}')")


def menu_shown_only_where_it_acts(wall):
    page = open_app(wall)
    got = page.evaluate(
        """() => Object.fromEntries([...document.querySelectorAll('.card')].map((c) => [
          c.dataset.key, !c.querySelector('.menu').hidden]))"""
    )
    shown = {k for k, v in got.items() if v}
    ended = "demo-8-am_puck"  # ended
    other_socket = "demo-6-af_nova"  # a tmux server that is not klepsydra's
    no_claude = "demo-12-af_alloy"  # no Claude process recorded
    new = "demo-7-af_aoede"  # no tmux
    ok = (
        shown
        and not shown & {ended, other_socket, no_claude, new}
        and "demo-2-af_bella" in shown
    )
    wall.check(ok, "the menu shows only for live sessions in klepsydra's tmux with a Claude process", sorted(shown))
    card = page.locator(WORKING_CARD).first
    btn = menu_of(card)
    name = card.locator(".name").inner_text()
    attrs = btn.evaluate(
        "b => [b.getAttribute('aria-haspopup'), b.getAttribute('aria-expanded'), b.getAttribute('aria-label')]"
    )
    wall.check(attrs == ["menu", "false", f"Session actions for {name}"], "the menu button's ARIA", attrs)
    btn.click()
    items = page.evaluate(
        "[...document.querySelectorAll('#session-menu [role=menuitem]')].filter((i) => !i.hidden).map((i) => i.textContent.trim())"
    )
    expanded = btn.get_attribute("aria-expanded")
    focused = page.evaluate("document.activeElement.textContent.trim()")
    wall.check(
        items == ["Interrupt", "End session…"] and expanded == "true" and focused == "Interrupt",
        "a working card's menu holds Interrupt then End session…, with the first item focused",
        [items, expanded, focused],
    )
    page.keyboard.press("ArrowDown")
    down = page.evaluate("document.activeElement.textContent.trim()")
    page.keyboard.press("ArrowDown")
    wrap = page.evaluate("document.activeElement.textContent.trim()")
    page.keyboard.press("End")
    end = page.evaluate("document.activeElement.textContent.trim()")
    page.keyboard.press("Home")
    home = page.evaluate("document.activeElement.textContent.trim()")
    wall.check([down, wrap, end, home] == ["End session…", "Interrupt", "End session…", "Interrupt"], "arrow keys, Home and End move through the items", [down, wrap, end, home])
    page.keyboard.press("Escape")
    back = page.evaluate("[document.activeElement === document.querySelector('.menu[aria-expanded=false]:focus'), document.getElementById('session-menu').hidden]")
    wall.check(back == [True, True], "Esc closes the menu and returns focus to its button", back)
    # Tab closes the menu and lets focus move on from the button (APG), never trapped or lost to the body.
    for key_, want in (("Tab", "after"), ("Shift+Tab", "before")):
        open_menu(page, card)
        page.keyboard.press(key_)
        moved = page.evaluate(
            """() => {
          const b = document.querySelector('.menu[aria-expanded=false]');
          const a = document.activeElement;
          return [document.getElementById('session-menu').hidden, a !== document.body, a.isConnected && !a.closest('#session-menu'), a.className || a.tagName];
        }"""
        )
        button_class = page.evaluate("document.activeElement.className")
        wall.check(moved[0] and moved[1] and moved[2] and button_class != "menu", f"{key_} closes the menu and focus moves on from its button", moved)
    btn.click()
    page.mouse.click(5, 5)
    shut = page.evaluate("document.getElementById('session-menu').hidden")
    wall.check(shut and btn.get_attribute("aria-expanded") == "false", "a click outside closes the menu", shut)
    idle = page.locator(".card:has(.pill .label:text-is('done')):has(.menu:not([hidden]))").first
    open_menu(page, idle)
    items = page.evaluate(
        "[...document.querySelectorAll('#session-menu [role=menuitem]')].filter((i) => !i.hidden).map((i) => i.textContent.trim())"
    )
    wall.check(items == ["End session…"], "Interrupt is offered only while the card reads working", items)
    page.close()


def one_click_or_key_never_ends(wall):
    """The hard rule: nothing short of confirm, then the full 5 s, sends end_session."""
    page = open_app(wall)
    card = page.locator(WORKING_CARD).first
    key = card.evaluate("c => c.dataset.key")
    log = []

    def step(what):
        log.append(what)

    # A single click on the menu button.
    open_menu(page, card)
    step("click menu button")
    page.keyboard.press("Escape")
    # A single click on End session…
    open_menu(page, card)
    page.get_by_role("menuitem", name="End session…").click()
    page.wait_for_function("document.getElementById('end-dialog').open")
    step("click End session…")
    focus = page.evaluate("document.activeElement.className")
    wall.check(focus == "end-cancel", "Cancel has focus when the confirm opens", focus)
    page.keyboard.press("Escape")
    page.wait_for_function("!document.getElementById('end-dialog').open")
    # Enter and Space on the focused card.
    card.evaluate("c => c.focus()")
    page.keyboard.press("Enter")
    page.keyboard.press("Space")
    step("Enter and Space on the card")
    # Enter on the menu button opens the menu; Enter on its End item opens the dialog.
    menu_of(card).focus()
    page.keyboard.press("Enter")
    page.wait_for_selector("#session-menu:not([hidden])")
    step("Enter on the menu button")
    page.keyboard.press("ArrowDown")
    page.keyboard.press("Enter")  # on End session…
    page.wait_for_function("document.getElementById('end-dialog').open")
    step("Enter on End session…")
    page.keyboard.press("Enter")  # right after the dialog opens: Cancel
    page.wait_for_function("!document.getElementById('end-dialog').open")
    step("Enter right after the dialog opened")
    # Space right after opening, the same way.
    menu_of(card).focus()
    page.keyboard.press("Space")
    page.wait_for_selector("#session-menu:not([hidden])")
    page.keyboard.press("ArrowDown")
    page.keyboard.press("Space")
    page.wait_for_function("document.getElementById('end-dialog').open")
    page.keyboard.press("Space")
    page.wait_for_function("!document.getElementById('end-dialog').open")
    step("Space right after the dialog opened")
    # A click on the backdrop, once the dialog is past a double-click's reach, cancels too.
    open_menu(page, card)
    page.get_by_role("menuitem", name="End session…").click()
    page.wait_for_selector(".end-confirm:not([aria-disabled='true'])")
    page.mouse.click(5, 5)
    page.wait_for_function("!document.getElementById('end-dialog').open")
    step("backdrop click")
    page.wait_for_timeout(6500)
    ended = page.evaluate(ENDS)
    showing = page.evaluate("[...document.querySelectorAll('.ending')].some((e) => !e.hidden)")
    wall.check(not ended and not showing, "no single click or key sends end_session or starts the undo window", [ended, showing, log])
    page.close()
    return key


def deliberate_end_sends_once(wall):
    page = open_app(wall)
    card = page.locator(WORKING_CARD).first
    key = card.evaluate("c => c.dataset.key")
    name = card.locator(".name").inner_text()
    open_menu(page, card)
    page.get_by_role("menuitem", name="End session…").click()
    page.wait_for_function("document.getElementById('end-dialog').open")
    title = page.locator("#end-title").inner_text()
    text = page.locator("#end-text").inner_text()
    wall.check(
        title == f"End {name}'s session?" and "as if you typed /exit" in text and "mid-turn" in text,
        "the confirm names the character and says a working card is mid-turn",
        [title, text],
    )
    confirm_end(page, name)
    page.wait_for_timeout(500)
    shown = card.locator(".ending-text").inner_text()
    focus = page.evaluate("document.activeElement.className")
    sent_early = page.evaluate(ENDS)
    wall.check(
        shown.startswith(f"Ending {name} in ") and focus == "undo" and not sent_early,
        "confirming shows the countdown with focus on Undo and sends nothing yet",
        [shown, focus, sent_early],
    )
    page.wait_for_timeout(4000)
    still = page.evaluate(ENDS)
    page.wait_for_timeout(1500)
    sent = page.evaluate(ENDS)
    wall.check(not still and sent == [["end_session", {"id": key}]], "after 5 s exactly one end_session goes out, with the card's id", [still, sent])
    note = card.locator(".note").inner_text()
    wall.check(note == "ok", "its result shows in the card's note", note)
    page.close()


def menu_off_until_the_call_answers(wall):
    """The card's menu stays disabled from the undo window's end until end_session answers."""
    page = open_app(wall)
    page.evaluate("() => { window.__hold = new Promise((r) => { window.__release = r; }); }")
    card = page.locator(WORKING_CARD).first
    key = card.evaluate("c => c.dataset.key")
    name = card.locator(".name").inner_text()
    card = page.locator(f'.card[data-key="{key}"]')
    open_menu(page, card)
    page.get_by_role("menuitem", name="End session…").click()
    confirm_end(page, name)
    page.wait_for_timeout(5600)
    state = lambda: page.evaluate(
        f"""() => {{
      const c = document.querySelector('.card[data-key="{key}"]');
      return [c.querySelector('.menu').getAttribute('aria-disabled'), c.querySelector('.ending').hidden, c.querySelector('.note').textContent];
    }}"""
    )
    sent = state()
    menu_of(card).click(force=True)
    opened = page.evaluate("!document.getElementById('session-menu').hidden")
    wall.check(
        sent[0] == "true" and sent[1] and sent[2] == f"Ending {name}…" and not opened and len(page.evaluate(ENDS)) == 1,
        "while end_session runs the card's menu stays disabled and will not open",
        [sent, opened],
    )
    page.evaluate("window.__release('Ended')")
    page.wait_for_timeout(400)
    after = state()
    wall.check(after[0] in (None, "false") and after[2] == "Ended", "the menu comes back once end_session answers", after)
    page.close()


def double_click_never_confirms(wall):
    """A click on End right after the dialog opens, as a double-click's second, does nothing."""
    page = open_app(wall)
    card = page.locator(WORKING_CARD).first
    name = card.locator(".name").inner_text()
    results = []
    for attempt in ("first open", "reopened"):
        open_menu(page, card)
        page.get_by_role("menuitem", name="End session…").click()
        page.wait_for_function("document.getElementById('end-dialog').open")
        box = page.locator(".end-confirm").bounding_box()
        page.mouse.click(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2)
        page.wait_for_timeout(150)
        results.append(
            page.evaluate(
                """() => [document.getElementById('end-dialog').open,
                document.querySelector('.end-confirm').getAttribute('aria-disabled'),
                [...document.querySelectorAll('.ending')].some((e) => !e.hidden)]"""
            )
        )
        page.keyboard.press("Escape")
        page.wait_for_function("!document.getElementById('end-dialog').open")
    wall.check(
        all(r == [True, "true", False] for r in results) and not page.evaluate(ENDS),
        "End ignores a click in its first second, on every opening",
        results,
    )
    # A double-click on End session…: its second click lands on the dialog or its backdrop, and closes nothing.
    open_menu(page, card)
    page.get_by_role("menuitem", name="End session…").dblclick()
    page.wait_for_timeout(150)
    still = page.evaluate("[document.getElementById('end-dialog').open, document.querySelector('.end-confirm').getAttribute('aria-disabled')]")
    wall.check(still == [True, "true"], "a double-click on End session… leaves the dialog open with End still off", still)
    page.keyboard.press("Escape")
    page.wait_for_function("!document.getElementById('end-dialog').open")
    open_menu(page, card)
    page.get_by_role("menuitem", name="End session…").click()
    page.wait_for_timeout(1200)
    armed = page.evaluate("document.querySelector('.end-confirm').getAttribute('aria-disabled')")
    page.get_by_role("button", name=f"End {name}").click()
    page.wait_for_timeout(300)  # the dialog's close event runs as its own task
    started = page.evaluate("[...document.querySelectorAll('.ending')].some((e) => !e.hidden)")
    page.keyboard.press("Enter")  # Undo has focus
    wall.check(armed in (None, "false") and started and not page.evaluate(ENDS), "after a second End wakes, and its click starts the undo window", [armed, started])
    page.close()


AWAY_PX = 48  # twice the 24 px target


def end_sits_away(wall):
    """AJ's rule: the menu that holds End, shut or open, keeps clear of Open terminal and Clear,
    its own card's and every other card's: the open list stays inside its own card."""
    page = open_app(wall)
    found = {}
    silent = json.loads(json.dumps(page.snapshot))
    fleet_rows = [r for r in silent["sessions"] if (r.get("tmux") or {}).get("socket", "").endswith("/klepsydra") and r["status"] != "ended"]
    for r in fleet_rows[:2]:
        r["status"] = "silent"  # Clear shows beside the menu
    for density in ("compact", "comfortable"):
        page.click(f".density label:has([value={density}])")
        for label, snap in (("demo", page.snapshot), ("two silent", silent)):
            page.evaluate("(s) => window.__channel.onmessage(s)", snap)
            page.wait_for_timeout(SETTLE_MS)
            rows = []
            cards = page.locator(".card:has(.menu:not([hidden]))")
            for i in range(cards.count()):
                card = cards.nth(i)
                card.scroll_into_view_if_needed()
                page.wait_for_timeout(100)  # a scroll closes the menu; let it land first
                open_menu(page, card)
                rows.append(
                    card.evaluate(
                        """(c) => {
              const box = (el) => el.getBoundingClientRect();
              const shown = (el) => el && el.checkVisibility() && box(el).width > 0;
              const gap = (a, b) => Math.hypot(Math.max(0, a.left - b.right, b.left - a.right), Math.max(0, a.top - b.bottom, b.top - a.bottom));
              const list = box(document.getElementById('session-menu'));
              const mine = [box(c.querySelector('.menu')), list];
              const buttons = [...document.querySelectorAll('.card .jump, .card .clear')].filter(shown);
              const own = buttons.filter((b) => c.contains(b)).map(box);
              const cb = box(c);
              const inside = !document.getElementById('session-menu').hidden && list.left >= cb.left && list.right <= cb.right && list.top >= cb.top && list.bottom <= cb.bottom;
              const others = buttons.filter((b) => !c.contains(b)).map(box);
              return [
                Math.min(Infinity, ...mine.flatMap((m) => own.map((o) => gap(m, o)))),
                inside,
                Math.min(Infinity, ...mine.flatMap((m) => others.map((o) => gap(m, o)))),
                own.length,
              ];
            }"""
                    )
                )
                page.keyboard.press("Escape")
            found[f"{density}, {label}"] = {
                "cards": len(rows),
                "own": min(r[0] for r in rows),
                "inside": all(r[1] for r in rows),
                "others": min(r[2] for r in rows),
                "with Clear": sum(r[3] > 1 or False for r in rows),
            }
    wall.check(
        all(f["cards"] > 0 and f["own"] >= AWAY_PX and f["inside"] and f["others"] > 0 for f in found.values())
        and all(found[f"{d}, two silent"]["with Clear"] > 0 for d in ("compact", "comfortable")),
        f"in both densities the actions menu stays {AWAY_PX} px or more from its card's Open terminal and Clear, and the open list stays inside its own card",
        found,
    )
    page.close()

def undo_sends_nothing(wall):
    page = open_app(wall)
    card = page.locator(WORKING_CARD).first
    name = card.locator(".name").inner_text()
    open_menu(page, card)
    page.get_by_role("menuitem", name="End session…").click()
    confirm_end(page, name)
    page.wait_for_timeout(2000)
    card.locator(".undo").click()
    page.wait_for_timeout(6000)
    sent = page.evaluate(ENDS)
    gone = card.locator(".ending").is_hidden()
    note = card.locator(".note").inner_text()
    back = page.evaluate("document.activeElement === document.querySelector('.card .menu:focus')")
    wall.check(not sent and gone and note == f"{name} keeps running" and back, "Undo within 5 s sends nothing and hands focus back to the menu", [sent, gone, note, back])
    page.close()


def stray_enter_on_undo_undoes(wall):
    page = open_app(wall)
    card = page.locator(WORKING_CARD).first
    name = card.locator(".name").inner_text()
    open_menu(page, card)
    page.get_by_role("menuitem", name="End session…").click()
    confirm_end(page, name)
    page.wait_for_timeout(300)
    page.keyboard.press("Enter")
    page.wait_for_timeout(6000)
    sent = page.evaluate(ENDS)
    wall.check(not sent, "a stray Enter after confirming lands on Undo and cancels the end", sent)
    page.close()


def interrupt_sends_once(wall):
    page = open_app(wall)
    card = page.locator(WORKING_CARD).first
    key = card.evaluate("c => c.dataset.key")
    open_menu(page, card)
    page.get_by_role("menuitem", name="Interrupt").click()
    page.wait_for_timeout(600)
    sent = calls(page, "interrupt_session")
    ended = page.evaluate(ENDS)
    note = card.locator(".note").inner_text()
    wall.check(sent == [["interrupt_session", {"id": key}]] and not ended and note == "ok", "Interrupt sends one interrupt_session and shows its line in the note", [sent, ended, note])
    page.close()


def end_cancelled_when_the_session_ends(wall):
    """A snapshot that ends the session while its undo window runs cancels the end."""
    page = open_app(wall)
    card = page.locator(WORKING_CARD).first
    key = card.evaluate("c => c.dataset.key")
    name = card.locator(".name").inner_text()
    card = page.locator(f'.card[data-key="{key}"]')  # by id: the working-card locator moves on once this one ends
    open_menu(page, card)
    page.get_by_role("menuitem", name="End session…").click()
    confirm_end(page, name)
    page.wait_for_timeout(500)
    # Feed the same fleet with this session ended and the card's window still running.
    snapshot = json.loads(json.dumps(page.snapshot))
    for row in snapshot["sessions"]:
        if row["session_id"] == key:
            row["status"] = "ended"
    page.evaluate("(s) => window.__channel.onmessage(s)", snapshot)
    page.wait_for_timeout(300)
    hidden = card.locator(".ending").is_hidden()
    focus = page.evaluate("document.activeElement.dataset.key ?? document.activeElement.className")
    page.wait_for_timeout(5500)
    sent = page.evaluate(ENDS)
    menu_gone = menu_of(card).is_hidden()
    wall.check(hidden and not sent and menu_gone, "a session that ends during its undo window cancels the pending end", [hidden, sent, menu_gone])
    wall.check(focus == key, "focus on Undo moves to the card when its session ends", focus)
    # And a card that leaves the wall does too.
    card = page.locator(WORKING_CARD).first
    key = card.evaluate("c => c.dataset.key")
    name = card.locator(".name").inner_text()
    open_menu(page, card)
    page.get_by_role("menuitem", name="End session…").click()
    confirm_end(page, name)
    page.wait_for_timeout(300)
    snapshot["sessions"] = [r for r in snapshot["sessions"] if r["session_id"] != key]
    page.evaluate("(s) => window.__channel.onmessage(s)", snapshot)
    page.wait_for_timeout(300)
    focus = page.evaluate("document.activeElement.id")
    page.wait_for_timeout(5500)
    sent = page.evaluate(ENDS)
    wall.check(not sent, "a card that leaves the wall during its undo window cancels the pending end", sent)
    wall.check(focus == "wall", "focus on Undo moves to the wall when its card leaves", focus)
    # A session that ends while its confirm is open closes it, and focus goes to the card.
    card = page.locator(WORKING_CARD).first
    key = card.evaluate("c => c.dataset.key")
    open_menu(page, card)
    page.get_by_role("menuitem", name="End session…").click()
    page.wait_for_function("document.getElementById('end-dialog').open")
    for row in snapshot["sessions"]:
        if row["session_id"] == key:
            row["status"] = "ended"
    page.evaluate("(s) => window.__channel.onmessage(s)", snapshot)
    page.wait_for_timeout(300)
    after = page.evaluate("[document.getElementById('end-dialog').open, document.activeElement.dataset.key ?? document.activeElement.className]")
    wall.check(after == [False, key], "a session that ends while its confirm is open closes it and focus goes to the card", after)
    page.close()


# ---- Wrapping up -------------------------------------------------------------

WRAPUP_SAMPLE = json.loads((ROOT / "scripts/fixtures/wrapup-demo.json").read_text())
STARTS = "window.__calls.filter(([c]) => c === 'start_wrapup')"
BY_HAND = "Ask by hand: type /klepsydra-wrapup in its terminal"
# The demo fleet by route (wrapup.rs route() of each session's status, reason and place), in wall order;
# demo-8 has ended. Working with work out after its turn (9, 13, 14) sits idle at its prompt: typed now.
ROUTED = [
    ("Typed now", ["demo-9-bm_fable", "demo-5-bf_isabella", "demo-13-af_nicole", "demo-14-medallion"]),
    ("At the end of its turn", ["demo-2-af_bella", "demo-3-af_sarah", "demo-4-bf_emma", "demo-10-bm_george", "demo-16-af_kore"]),
    ("After you answer", ["demo-1-am_michael", "demo-11-am_fenrir", "demo-15-am_onyx"]),
    (BY_HAND, ["demo-6-af_nova", "demo-7-af_aoede", "demo-12-af_alloy"]),
]
LIVE = [k for _, keys in ROUTED for k in keys]
# Live, in klepsydra's tmux with a Claude process: what End all ready can end.
ENDABLE = sorted(set(LIVE) - {"demo-6-af_nova", "demo-7-af_aoede", "demo-12-af_alloy"})
SHOWN = "() => Object.fromEntries([...document.querySelectorAll('.card')].map((c) => [c.dataset.key, c.querySelector('.wrapup').hidden ? null : c.querySelector('.wrapup').textContent]))"
BAR = """() => {
  const vis = (sel) => { const e = document.querySelector(sel); return !e.closest('[hidden]') && e.getBoundingClientRect().height > 0; };
  return { bar: vis('.wrapup-bar'), count: document.querySelector('.wrapup-count').textContent, safe: vis('.wrapup-safe'), stop: vis('#wrapup-stop'), endAll: vis('#end-ready') };
}"""


def with_wrapup(snapshot, answers, until_in=300):
    """`snapshot` with a request made five minutes ago, `until_in` s left to answer, and `answers` (id -> answer) on its sessions."""
    import time

    now = int(time.time())
    snap = json.loads(json.dumps(snapshot))
    live = [r["session_id"] for r in snap["sessions"] if r["status"] != "ended"]
    snap["wrapup"] = {"id": str(now * 1000), "at": now - 300, "until": now + until_in, "ids": live}
    for row in snap["sessions"]:
        row.pop("wrapup", None)
        if row["session_id"] in answers:
            answer = answers[row["session_id"]]
            # A settled answer's turn ended just now, after its prompt.
            row["wrapup"] = {**answer, "at": now, **({"settled_at": now} if "settled_at" in answer else {})}
    return snap


def calm(snapshot):
    """`snapshot` with every live session idle at its prompt: only those can count ready."""
    snap = json.loads(json.dumps(snapshot))
    for row in snap["sessions"]:
        if row["status"] != "ended":
            row.update({"status": "done", "reason": None})
    return snap


def arrived(snapshot, key="demo-99-new"):
    """`snapshot` with one more live session, unasked and unready."""
    snap = json.loads(json.dumps(snapshot))
    row = json.loads(json.dumps(next(r for r in snap["sessions"] if r["session_id"] == "demo-2-af_bella")))
    row.update({"session_id": key, "name": "late arrival"})
    row.pop("wrapup", None)
    snap["sessions"].append(row)
    return snap


def feed(page, snapshot):
    page.evaluate("(s) => window.__channel.onmessage(s)", snapshot)
    page.wait_for_timeout(200)


def all_ready():
    return {k: {"state": "ready", "settled_at": 0} for k in LIVE}


def names_by_key(page):
    """Each card as the confirms list it: its name, and its repo."""
    repos = {r["session_id"]: (r.get("where") or {}).get("repo") for r in page.snapshot["sessions"]}
    names = page.evaluate("() => Object.fromEntries([...document.querySelectorAll('.card')].map((c) => [c.dataset.key, c.querySelector('.name').textContent]))")
    return {k: f"{n} in {repos[k]}" if repos.get(k) else n for k, n in names.items()}


DIALOG = """() => {
  const d = document.getElementById('end-dialog');
  return {
    open: d.open, kind: d.dataset.kind, role: d.getAttribute('role'),
    title: document.getElementById('end-title').textContent,
    text: d.querySelector('.end-what').textContent,
    groups: [...d.querySelectorAll('.end-list ul')].map((ul) => [ul.previousElementSibling?.tagName === 'H3' ? ul.previousElementSibling.textContent : null, [...ul.children].map((li) => li.textContent)]),
    confirm: d.querySelector('.end-confirm').textContent,
    armed: d.querySelector('.end-confirm').getAttribute('aria-disabled') !== 'true',
    focus: document.activeElement.className,
  };
}"""


def wrapup_confirm_lists_routes(wall):
    """Wrap up… asks first, naming who gets the prompt and how; only its armed button asks."""
    page = open_app(wall)
    names = names_by_key(page)
    error = "The prompt did not read /klepsydra-wrapup, so Enter was not pressed."
    asked = [
        {"id": k, "route": r, "error": error if k == "demo-5-bf_isabella" else None, "typed": r == "type" and k != "demo-5-bf_isabella"}
        for r, (_, keys) in zip(["type", "turn_end", "after_answer", "by_hand"], ROUTED)
        for k in keys
    ]
    page.evaluate("(a) => { window.__asked = a; }", asked)
    page.click("#wrapup-open")
    page.wait_for_function("document.getElementById('end-dialog').open")
    got = page.evaluate(DIALOG)
    want = [[heading, [names[k] for k in keys]] for heading, keys in ROUTED]
    wall.check(
        got["groups"] == want and got["kind"] == "wrapup" and got["role"] == "alertdialog" and got["focus"] == "end-cancel" and not got["armed"] and got["confirm"] == "Ask 12 sessions",
        "Wrap up… lists who is asked in four groups, the ended left out, Cancel focused and its button not yet armed",
        got,
    )
    page.keyboard.press("Enter")
    page.wait_for_function("!document.getElementById('end-dialog').open")
    back = page.evaluate("document.activeElement.id")
    wall.check(not page.evaluate(STARTS) and back == "wrapup-open", "Enter right after it opens cancels, asks no one, and focus goes back", back)
    page.click("#wrapup-open")
    page.wait_for_timeout(200)
    page.locator(".end-confirm").click(force=True)
    early = page.evaluate("[document.getElementById('end-dialog').open, " + STARTS + ".length]")
    wall.check(early == [True, 0], "a click inside its first second does nothing", early)
    page.wait_for_selector(".end-confirm:not([aria-disabled='true'])")
    page.mouse.move(5, 5)  # off the button: its hover fill differs from Cancel's resting one
    fills = page.evaluate("() => [getComputedStyle(document.querySelector('.end-confirm')).backgroundColor, getComputedStyle(document.querySelector('.end-cancel')).backgroundColor]")
    wall.check(fills[0] == fills[1], "its armed button is the plain fill, as Cancel's, not the danger one", fills)
    page.get_by_role("button", name="Ask 12 sessions").click()
    page.wait_for_function("document.getElementById('wrapup-note').textContent.startsWith('Typed into')")
    note = page.evaluate("document.getElementById('wrapup-note').textContent")
    card_note = page.evaluate("document.querySelector('.card[data-key=\"demo-5-bf_isabella\"] .note').textContent")
    who = page.evaluate("document.querySelector('.card[data-key=\"demo-5-bf_isabella\"] .name').textContent")
    starts = page.evaluate(STARTS)
    wall.check(
        len(starts) == 1 and note == f"Typed into 3 sessions; 8 asked when their turn ends; 3 to ask by hand; not typed into {who}, see its card" and card_note == error and not page.evaluate(ENDS),
        "confirming calls start_wrapup once, counts who was typed into and who is asked later, names the failed typing, and shows it in that card's note",
        [note, card_note],
    )
    wall.check(sorted((starts[0][1] or {}).get("ids") or []) == sorted(LIVE), "start_wrapup gets exactly the sessions the confirm listed", starts[0][1])
    page.close()


def wrapup_dialogs_close_on_change(wall):
    """A confirm that no longer describes the wall closes: a session arrives, or one stops being ready."""
    page = open_app(wall)
    closed = "!document.getElementById('end-dialog').open"
    page.click("#wrapup-open")
    page.wait_for_function("document.getElementById('end-dialog').open")
    feed(page, arrived(page.snapshot))
    wrap_closed = page.evaluate(closed)
    wall.check(wrap_closed and not page.evaluate(STARTS), "the Wrap up confirm closes, asking no one, when a session arrives", wrap_closed)
    snap = with_wrapup(calm(page.snapshot), all_ready())
    feed(page, snap)
    page.click("#end-ready")
    page.wait_for_function("document.getElementById('end-dialog').open")
    late = arrived(snap)
    feed(page, late)
    gone = [page.evaluate(closed), page.evaluate(BAR)["endAll"]]
    lines = page.evaluate(SHOWN)
    wall.check(gone == [True, False] and lines["demo-99-new"] == "Not asked", "End all ready closes when an unasked, unready session arrives, and is no longer offered", [gone, lines["demo-99-new"]])
    feed(page, snap)
    page.click("#end-ready")
    page.wait_for_function("document.getElementById('end-dialog').open")
    again = json.loads(json.dumps(snap))
    for row in again["sessions"]:
        if row["session_id"] == "demo-5-bf_isabella":
            row["prompt"] = {"text": "one more thing", "at": row["wrapup"]["at"] + 5}
    feed(page, again)
    stale = [page.evaluate(closed), page.evaluate(SHOWN)["demo-5-bf_isabella"], page.evaluate(BAR)["safe"]]
    wall.check(stale == [True, "Worked since it answered; once idle, ask again: /klepsydra-wrapup", False], "a ready session prompted again says to ask again, closes End all ready and withdraws Safe to restart", stale)
    page.wait_for_timeout(5600)
    wall.check(not page.evaluate(ENDS), "none of it sent end_session", page.evaluate(ENDS))
    page.close()


def wrapup_cards_and_bar(wall):
    """Each card's line, in both densities and clear of its text; the bar's count, Stop wrap-up and Safe to restart."""
    page = open_app(wall)
    feed(page, with_wrapup(page.snapshot, WRAPUP_SAMPLE["answers"]))
    lines = page.evaluate(SHOWN)
    reason = WRAPUP_SAMPLE["answers"]["demo-4-bf_emma"]["reason"]
    want = {
        "demo-5-bf_isabella": "Ready",
        "demo-2-af_bella": "Finishing its turn",
        "demo-9-bm_fable": "Ready once its background work ends",
        "demo-3-af_sarah": "Wrapping up…",
        "demo-4-bf_emma": f"Not ready: {reason}",
        "demo-1-am_michael": "Answer it first; it wraps up after",
        "demo-10-bm_george": "Wraps up when this turn ends",
        "demo-6-af_nova": "Ask by hand: /klepsydra-wrapup",
        "demo-8-am_puck": None,
    }
    wall.check(all(lines[k] == v for k, v in want.items()), "each card reads its answer, its route or nothing once ended", {k: lines[k] for k in want})
    label = page.evaluate("document.querySelector('.card[data-key=\"demo-4-bf_emma\"]').getAttribute('aria-label')")
    wall.check(label.endswith(f"Not ready: {reason}"), "the line is in the card's accessible name", label)
    bar = page.evaluate(BAR)
    wall.check(bar == {"bar": True, "count": "1 of 15 ready", "safe": False, "stop": True, "endAll": False}, "the bar counts only settled, idle sessions and offers Stop wrap-up only", bar)
    for density in ("compact", "comfortable"):
        page.check(f".density input[value='{density}']", force=True)
        page.wait_for_timeout(SETTLE_MS)
        got = page.evaluate(
            """() => {
          const hit = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
          const out = { shown: 0, bad: [] };
          for (const card of document.querySelectorAll('.card')) {
            const line = card.querySelector('.wrapup');
            if (line.hidden) continue;
            const l = line.getBoundingClientRect();
            if (!l.height || getComputedStyle(line).display === 'none') { out.bad.push(card.dataset.key + ' unseen'); continue; }
            out.shown++;
            if (l.bottom > card.getBoundingClientRect().bottom + 0.5) out.bad.push(card.dataset.key + ' outside');
            for (const el of card.querySelectorAll('.said p, .ask, .meta, .name, .task, .pill, .jump, .ledger-line, .why, .note')) {
              const r = el.getBoundingClientRect();
              if (r.width && r.height && getComputedStyle(el).display !== 'none' && hit(l, r)) out.bad.push(card.dataset.key + ' ' + el.className);
            }
          }
          return out;
        }"""
        )
        wall.check(got["shown"] == 15 and not got["bad"], f"every live card's line shows {density}, clear of its text", got)
    page.click("#wrapup-stop")
    page.wait_for_timeout(200)
    wall.check(len(calls(page, "cancel_wrapup")) == 1, "Stop wrap-up calls cancel_wrapup once", calls(page, "cancel_wrapup"))
    feed(page, with_wrapup(calm(page.snapshot), all_ready()))
    bar = page.evaluate(BAR)
    said = page.evaluate("document.getElementById('live').textContent")
    wall.check(bar == {"bar": True, "count": "15 of 15 ready", "safe": True, "stop": True, "endAll": True} and "Safe to restart" in said, "every live card ready: Safe to restart, announced, and End all ready sessions…", [bar, said])
    one = dict(all_ready())
    one["demo-3-af_sarah"] = {"state": "blocked", "reason": "a build", "settled_at": 0}
    feed(page, with_wrapup(calm(page.snapshot), one))
    bar = page.evaluate(BAR)
    wall.check(not bar["safe"] and not bar["endAll"] and bar["count"] == "14 of 15 ready", "one not ready takes both away", bar)
    feed(page, with_wrapup(page.snapshot, WRAPUP_SAMPLE["answers"], until_in=-10))
    lines = page.evaluate(SHOWN)
    bar = page.evaluate(BAR)
    wall.check(
        not bar["stop"] and lines["demo-3-af_sarah"] == "No answer" and lines["demo-1-am_michael"] == "No answer" and lines["demo-5-bf_isabella"] == "Ready",
        "past its window no Stop wrap-up, and silence reads No answer, never ready",
        [bar, lines["demo-3-af_sarah"], lines["demo-5-bf_isabella"]],
    )
    snap = json.loads(json.dumps(page.snapshot))
    feed(page, snap)
    wall.check(page.evaluate(BAR)["bar"] is False and not any(page.evaluate(SHOWN).values()), "with no request the bar and the cards say nothing of it", page.evaluate(BAR))
    page.close()


def wrapup_demo_in_browser(wall):
    """?demo&wrapup shows the sample request outside the app; its buttons stay with the app."""
    page = wall.open(1920, 1000, 16, query="&wrapup")
    bar = page.evaluate(BAR)
    lines = page.evaluate(SHOWN)
    wall.check(bar["count"] == "1 of 15 ready" and not bar["stop"] and lines["demo-4-bf_emma"].startswith("Not ready: ") and lines["demo-5-bf_isabella"] == "Ready", "the demo carries a request and its answers", [bar, lines["demo-4-bf_emma"]])
    page.close()


def end_all_ready(wall):
    """One confirm names every session it ends; each card then runs its own undo window."""
    page = open_app(wall)
    feed(page, with_wrapup(calm(page.snapshot), all_ready()))
    names = names_by_key(page)
    page.click("#end-ready")
    page.wait_for_function("document.getElementById('end-dialog').open")
    got = page.evaluate(DIALOG)
    order = [k for k in LIVE if k in ENDABLE]
    wall_order = page.evaluate("[...document.querySelectorAll('.card')].map((c) => c.dataset.key)")
    want = [names[k] for k in wall_order if k in ENDABLE]
    wall.check(
        got["kind"] == "end" and got["title"] == "End 12 sessions?" and got["confirm"] == "End 12 sessions" and got["groups"] == [[None, want]]
        and "Not listed: 3 sessions outside klepsydra's tmux" in got["text"] and got["focus"] == "end-cancel" and not got["armed"] and len(order) == 12,
        "End all ready names each session it ends and the rest it cannot, Cancel focused",
        got,
    )
    page.wait_for_selector(".end-confirm:not([aria-disabled='true'])")
    page.get_by_role("button", name="End 12 sessions").click()
    page.wait_for_timeout(300)
    state = page.evaluate("() => [...document.querySelectorAll('.card')].filter((c) => !c.querySelector('.ending').hidden).map((c) => c.dataset.key).sort()")
    focus = page.evaluate("document.activeElement.className")
    wall.check(state == ENDABLE and not page.evaluate(ENDS) and focus == "undo" and not page.evaluate(BAR)["endAll"], "confirming opens every card's own undo window, sends nothing yet, and puts focus on an Undo", [len(state), focus])
    page.locator('.card[data-key="demo-2-af_bella"] .undo').click()
    page.wait_for_timeout(5300)
    sent = sorted(a["id"] for _, a in page.evaluate(ENDS))
    wall.check(sent == [k for k in ENDABLE if k != "demo-2-af_bella"], "after 5 s each end goes out once; the one undone stays", sent)
    page.close()


def bulk_end_waits_on_ready(wall):
    """A session that goes back to work inside End all ready's undo window is not ended; the rest are."""
    page = open_app(wall)
    snap = with_wrapup(calm(page.snapshot), all_ready())
    feed(page, snap)
    page.click("#end-ready")
    page.wait_for_selector(".end-confirm:not([aria-disabled='true'])")
    page.get_by_role("button", name="End 12 sessions").click()
    page.wait_for_timeout(1000)
    again = json.loads(json.dumps(snap))
    for row in again["sessions"]:
        if row["session_id"] == "demo-5-bf_isabella":
            row["status"] = "working"
            row["status_at"] = row["wrapup"]["at"] + 5
            row["prompt"] = {"text": "one more thing", "at": row["wrapup"]["at"] + 5}
    feed(page, again)
    card = '.card[data-key="demo-5-bf_isabella"]'
    name = page.evaluate(f"document.querySelector('{card} .name').textContent")
    state = page.evaluate(f"[document.querySelector('{card} .ending').hidden, document.querySelector('{card} .note').textContent]")
    wall.check(state == [True, f"{name} is no longer ready; not ended"], "its undo window closes at once, and its card says why", state)
    page.wait_for_timeout(4600)
    sent = sorted(a["id"] for _, a in page.evaluate(ENDS))
    wall.check(sent == [k for k in ENDABLE if k != "demo-5-bf_isabella"], "the others still end; the one working again never gets end_session", sent)
    page.close()


def one_click_or_key_never_ends_all(wall):
    """The hard rule on the bulk path: no click or key short of the armed confirm sends end_session."""
    page = open_app(wall)
    feed(page, with_wrapup(calm(page.snapshot), all_ready()))
    log = []
    dialog_open = "document.getElementById('end-dialog').open"
    page.click("#end-ready")
    page.wait_for_function(dialog_open)
    log.append(("click End all ready…", page.evaluate("document.activeElement.className")))
    page.keyboard.press("Escape")
    page.wait_for_function("!" + dialog_open)
    page.locator('.card[data-key="demo-5-bf_isabella"]').evaluate("c => c.focus()")
    page.keyboard.press("Enter")
    page.keyboard.press("Space")
    log.append(("Enter and Space on a card", page.evaluate(dialog_open)))
    for key_ in ("Enter", "Space"):
        page.locator("#end-ready").focus()
        page.keyboard.press(key_)
        page.wait_for_function(dialog_open)
        page.keyboard.press(key_)  # right after it opens: Cancel
        page.wait_for_function("!" + dialog_open)
        log.append((f"{key_} twice on End all ready…", page.evaluate("document.activeElement.id")))
    page.click("#end-ready")
    page.wait_for_timeout(200)
    page.locator(".end-confirm").click(force=True)
    log.append(("a click on its button inside ARM_MS", page.evaluate(dialog_open)))
    page.keyboard.press("Escape")
    page.wait_for_function("!" + dialog_open)
    page.click("#end-ready")
    page.wait_for_selector(".end-confirm:not([aria-disabled='true'])")  # past a double-click's reach
    page.mouse.click(5, 5)
    page.wait_for_function("!" + dialog_open)
    log.append(("backdrop click", False))
    page.locator("#end-ready").dblclick()
    page.wait_for_timeout(200)
    log.append(("double-click on End all ready…", page.evaluate(dialog_open)))
    page.keyboard.press("Escape")
    page.wait_for_timeout(6500)
    ended = page.evaluate(ENDS)
    showing = page.evaluate("[...document.querySelectorAll('.ending')].some((e) => !e.hidden)")
    focus_ok = log[0][1] == "end-cancel" and log[2][1] == "end-ready" and log[3][1] == "end-ready" and log[4][1] is True
    wall.check(not ended and not showing and focus_ok, "no single click or key on the bulk path sends end_session or starts an undo window", [ended, showing, log])
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
            partial_mark,
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
            menu_shown_only_where_it_acts,
            one_click_or_key_never_ends,
            deliberate_end_sends_once,
            double_click_never_confirms,
            end_sits_away,
            menu_off_until_the_call_answers,
            undo_sends_nothing,
            stray_enter_on_undo_undoes,
            interrupt_sends_once,
            end_cancelled_when_the_session_ends,
            wrapup_confirm_lists_routes,
            wrapup_cards_and_bar,
            wrapup_demo_in_browser,
            end_all_ready,
            bulk_end_waits_on_ready,
            wrapup_dialogs_close_on_change,
            one_click_or_key_never_ends_all,
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
