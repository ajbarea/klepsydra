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
and only the full deliberate path sends end_session, not a single click or key
or any shorter run of them. Wrapping up: the confirm's groups, each card's line
in both densities, the bar's count, Stop wrap-up and Safe to restart, and End
all ready sessions… under the same rule as End. With no sessions, or only
ended ones, the empty state stands in the wall's place, in view and
unscrolled, and its buttons send only launch_session and clear_session for
the ended ids; set $KLEPSYDRA_EMPTY_SHOT to a path for a 1920x1000
screenshot of it.
The Queue panel docks beside the wall at 1920 and is a modal dialog at 945,
resizes from the keyboard, renders the sample file as text only, copies code
and links, and follows the app's queue_subscribe channel.

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


def shared_home_voice(wall):
    """Three sessions launched from one folder share its home voice: three
    cards of one character, and three rows in the drawer, each named for its
    card, in Tokens by character and in Blocked today."""
    fleet = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    ids = [x["session_id"] for x in fleet["sessions"][:3]]
    for x in fleet["sessions"][:3]:
        x["voice"] = "am_michael"
    view = json.loads(ledger_view())
    day = view["day"]
    base = day["sessions"][ids[0]]
    for n, sid in enumerate(ids):
        day["sessions"][sid] = base | {"tokens": {"input": 1000 * (3 - n), "output": 10, "cache_read": 0, "cache_creation": 0}}
        day["voices"][sid] = "am_michael"
    day["home_voices"] = ids
    view["guardrails"] = [{"at": view["guardrails"][0]["at"], "session_id": ids[1], "tool_name": "Bash", "source": "hook"}]
    view["guardrails_total"] = 1
    page = wall.open(960, 1000, 8, fixture=json.dumps(fleet), ledger=json.dumps(view))
    open_drawer(page)
    names = page.evaluate(
        """() => [...document.querySelectorAll('#ledger-characters-table tbody tr')].map((r) =>
          r.cells[0].querySelector('.visually-hidden')?.textContent ?? r.cells[0].textContent)"""
    )
    blocked = page.locator("#ledger-blocked-table tbody tr td:nth-child(2)").all_inner_texts()
    tasks = [x["name"] for x in fleet["sessions"][:3]]
    want = [f"Hephaestus \u00b7 {t}" for t in tasks]
    ok = [n for n in names if n.startswith("Hephaestus")] == want and blocked == [want[1]]
    wall.check(ok, "sessions sharing a home voice keep a row each, named for its card", [names, blocked])
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
# fleet_subscribe, which hands a Channel the snapshot (ipc.js `follow`); the
# Queue panel's queue_subscribe gets nothing; every other command is recorded
# in window.__calls and answers "ok".
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
    if (cmd === 'queue_subscribe') return Promise.resolve();
    if (cmd === 'get_wall_density') return Promise.resolve('auto');
    if (cmd === 'get_launch_dir') { window.__calls.push([cmd, args]); return window.__dirAnswer ? window.__dirAnswer() : Promise.resolve('/home/aj/ajsoftworks'); }
    if (cmd === 'end_session' && window.__hold) { window.__calls.push([cmd, args]); return window.__hold; }
    window.__calls.push([cmd, args]);
    if (cmd === 'start_wrapup') return Promise.resolve(window.__asked ?? []);
    if (cmd === 'reply_clip') return window.__clip ? Promise.resolve(window.__clip()) : Promise.reject('No reply to play.');
    return Promise.resolve('ok');
  },
} };
"""
ENDS = "window.__calls.filter(([c]) => c === 'end_session')"
# The wall's read-only queries on load; any other recorded call is an action.
READS = ["get_launch_dir", "get_split_mode"]
WORKING_CARD = ".card:has(.pill .label:text-is('working')):has(.menu:not([hidden]))"


def open_app(wall, width=1920, height=1000, keep=None, motion="no-preference", launch_dir="/home/aj/ajsoftworks"):
    """The demo wall as the app would feed it, with invokes recorded; `keep`
    picks which demo sessions the snapshot carries."""
    import time

    fixture = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    at = fixture.pop("at")
    snapshot = shifted(fixture, int(time.time()) - at)
    if keep is not None:
        snapshot["sessions"] = [s for s in snapshot["sessions"] if keep(s)]
        snapshot["speaking"] = None
    page = wall.browser.new_page(
        viewport={"width": width, "height": height}, reduced_motion=motion
    )
    page.snapshot = snapshot
    page.snapshot_all = shifted(json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text()), int(time.time()) - at)["sessions"]
    stub = TAURI_STUB.replace("'/home/aj/ajsoftworks'", json.dumps(launch_dir))
    page.add_init_script(stub % json.dumps(snapshot))
    page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html")
    if snapshot["sessions"] and keep is None:
        page.wait_for_function("document.getElementById('wall').children.length > 0")
    else:
        page.wait_for_function("window.__channel !== undefined")
    page.wait_for_timeout(SETTLE_MS)
    return page


EMPTY = """() => {
  const empty = document.getElementById('empty');
  const box = (sel) => {
    const el = document.querySelector(sel);
    if (!el || !el.checkVisibility()) return null;
    const r = el.getBoundingClientRect();
    return [Math.round(r.left), Math.round(r.top), Math.round(r.right), Math.round(r.bottom)];
  };
  return {
    empty: empty.checkVisibility(),
    wall: document.getElementById('wall').checkVisibility(),
    start: box('#start-session') && document.getElementById('start-session').textContent,
    clear: box('#clear-ended') && document.getElementById('clear-ended').textContent,
    keeper: box('.keeper'),
    title: box('#empty-title'),
    button: box('#start-session'),
    scrolls: document.documentElement.scrollHeight > innerHeight,
    wide: document.documentElement.scrollWidth > innerWidth,
    alt: document.querySelector('.keeper').getAttribute('alt'),
    animation: getComputedStyle(empty).animationName,
  };
}"""


def inside(box, width, height):
    return box is not None and box[0] >= 0 and box[1] >= 0 and box[2] <= width and box[3] <= height


def send(page, snapshot):
    page.evaluate("(s) => window.__channel.onmessage(s)", snapshot)
    page.wait_for_timeout(SETTLE_MS)


def empty_state(wall):
    """No sessions: Hesychia, the title and the start button in place of the
    wall, in view and unscrolled at 1920x1000 and 945x1000; the button runs
    the same launch as + New session; the fade is off under reduced motion."""
    for width, height in ((1920, 1000), (945, 1000)):
        page = open_app(wall, width, height, keep=lambda s: False)
        got = page.evaluate(EMPTY)
        laid_out = all(inside(got[k], width, height) for k in ("keeper", "title", "button"))
        wall.check(
            got["empty"] and not got["wall"] and laid_out and not got["scrolls"] and not got["wide"],
            f"the empty state stands in the wall's place, in view at {width}x{height}",
            got,
        )
        if width == 1920:
            wall.check(
                got["start"] == "Start a session in /home/aj/ajsoftworks" and got["clear"] is None and got["alt"] == "",
                "it names the launch folder, offers nothing to clear and its portrait is decoration",
                [got["start"], got["clear"], got["alt"]],
            )
            wall.check(got["animation"] == "empty-fade", "it fades in", got["animation"])
            shot = os.environ.get("KLEPSYDRA_EMPTY_SHOT")
            if shot:
                page.wait_for_timeout(500)
                page.screenshot(path=shot)
            page.locator("#start-session").click()
            page.wait_for_timeout(200)
            page.locator("#new-session").click()
            page.wait_for_timeout(200)
            sent = calls(page, "launch_session")
            note = page.locator("#new-note").inner_text()
            wall.check(
                sent == [["launch_session", None], ["launch_session", None]] and note == "ok",
                "Start a session and + New session send the same launch, and its note shows the answer",
                [sent, note],
            )
        page.close()
    page = open_app(wall, keep=lambda s: False, motion="reduce")
    got = page.evaluate(EMPTY)
    wall.check(got["empty"] and got["animation"] == "none", "no fade under reduced motion", got["animation"])
    page.close()


SHORT_DIR = "/home/ajbar/ajsoftworks/klepsydra/.claude/worktrees/empty-state"  # 63 characters
LONG_DIR = "/home/aj/" + "very-long-folder-name/" * 30  # 669 characters


def long_folder_fits(wall):
    """A long launch folder in a narrow window: the start button and the clear
    link stay in view and the page never scrolls sideways."""
    for width, height in ((420, 320), (945, 1000)):
        for folder in (SHORT_DIR, LONG_DIR):
            page = open_app(wall, width, height, keep=lambda s: s["status"] == "ended", launch_dir=folder)
            got = page.evaluate(EMPTY)
            link = page.evaluate("(() => { const r = document.getElementById('clear-ended').getBoundingClientRect(); return [Math.round(r.left), Math.round(r.right)]; })()")
            row = page.evaluate("Math.round(document.querySelector('.empty-actions').getBoundingClientRect().width)")
            fits = not got["wide"] and got["button"] and got["button"][0] >= 0 and got["button"][2] <= width and link[0] >= 0 and link[1] <= width
            wall.check(
                fits and got["start"] == f"Start a session in {folder}",
                f"a {len(folder)}-character folder at {width}x{height}: Start and Clear in view, no sideways scroll",
                {"button": got["button"], "link": link, "row": row, "wide": got["wide"]},
            )
            page.close()


def reveal_density(wall):
    """Ended cards that arrive behind the empty state are laid out once they
    show: a focus request for the last of sixteen finds the wall compact, the
    card in view and focused, and no card left to arrive."""
    page = open_app(wall, keep=lambda s: False)
    import time

    fixture = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    at = fixture.pop("at")
    one = next(s for s in shifted(fixture, int(time.time()) - at)["sessions"] if s["status"] == "ended")
    rows = [{**one, "session_id": f"demo-ended-{i}"} for i in range(16)]
    send(page, {"sessions": rows, "speaking": None})
    behind = page.evaluate("[document.getElementById('wall').hidden, document.querySelectorAll('#wall .arriving').length]")
    target = rows[-1]["session_id"]
    # Auto measures as the wall shows, before the card is scrolled to, not a frame later.
    at_once = page.evaluate(
        "(id) => { window.__channel.onmessage({focus: id}); return document.getElementById('wall').dataset.density; }", target
    )
    page.wait_for_timeout(SETTLE_MS * 2)
    got = page.evaluate(
        """(id) => { const el = document.querySelector(`.card[data-key="${id}"]`); const r = el.getBoundingClientRect();
        return {density: document.getElementById('wall').dataset.density, scrolls: document.documentElement.scrollHeight > innerHeight,
          inView: r.top >= 0 && r.bottom <= innerHeight, focus: document.activeElement.dataset.key ?? null,
          arriving: document.querySelectorAll('#wall .arriving').length}; }""",
        target,
    )
    wall.check(
        behind == [True, 0] and at_once == "compact" and got == {"density": "compact", "scrolls": False, "inView": True, "focus": target, "arriving": 0},
        "sixteen ended cards shown by a focus request: compact, in view, focused, none arriving",
        [behind, at_once, got],
    )
    page.close()


def separate_notes(wall):
    """Start and the clear link each answer in their own note."""
    page = open_app(wall, keep=lambda s: s["status"] == "ended")
    page.evaluate(
        """() => { const inv = window.__TAURI__.core.invoke; window.__TAURI__.core.invoke = (c, a) => {
          if (c === 'launch_session') return new Promise((r, j) => setTimeout(() => j('no distro'), 300));
          if (c === 'clear_session') return Promise.reject('running again');
          return inv(c, a); }; }"""
    )
    page.locator("#start-session").click()
    page.locator("#clear-ended").click()
    page.wait_for_timeout(500)
    got = page.evaluate("[document.getElementById('new-note').textContent, document.getElementById('clear-note').textContent]")
    wall.check(got == ["no distro", "1 of 1 not cleared: running again"], "Start's note and the clear link's note stay apart", got)
    page.close()


def launch_note_outlives_empty_state(wall):
    """A launch's answer shows where it stays in view once the empty state gives way."""
    page = open_app(wall, keep=lambda s: False)
    page.evaluate(
        """() => { const inv = window.__TAURI__.core.invoke; window.__TAURI__.core.invoke = (c, a) => {
          if (c === 'launch_session') return new Promise((r, j) => { window.__fail = j; });
          return inv(c, a); }; }"""
    )
    page.locator("#start-session").click()
    working = next(s for s in page.snapshot_all if s["status"] == "working")
    send(page, {"sessions": [working], "speaking": None})
    page.evaluate("window.__fail('The terminal tab has not attached yet.')")
    page.wait_for_timeout(200)
    got = page.evaluate(
        "[document.getElementById('empty').checkVisibility(), [...document.querySelectorAll('[role=status]')].filter((n) => n.checkVisibility() && n.textContent).map((n) => n.textContent)]"
    )
    wall.check(got == [False, ["The terminal tab has not attached yet."]], "a late launch error shows after the empty state gives way", got)
    page.close()


def one_launch_at_a_time(wall):
    """While one start button's launch runs, the other is off and sends nothing."""
    page = open_app(wall, keep=lambda s: False)
    page.evaluate(
        """() => { const inv = window.__TAURI__.core.invoke; window.__TAURI__.core.invoke = (c, a) => {
          if (c === 'launch_session') { window.__calls.push([c, a ?? null]); return new Promise((r) => { window.__done = r; }); }
          return inv(c, a); }; }"""
    )
    page.locator("#start-session").click()
    page.wait_for_timeout(100)
    off = page.evaluate("document.getElementById('new-session').getAttribute('aria-disabled')")
    page.locator("#new-session").click(force=True)
    page.wait_for_timeout(100)
    sent = len(calls(page, "launch_session"))
    page.evaluate("window.__done('ok')")
    page.wait_for_timeout(100)
    back = page.evaluate("document.getElementById('new-session').getAttribute('aria-disabled')")
    wall.check([off, sent, back] == ["true", 1, None], "one launch at a time across both start buttons", [off, sent, back])
    page.close()


def cleared_link_waits(wall):
    """After a clear succeeds the link stays away until the snapshot drops the cards."""
    page = open_app(wall, keep=lambda s: s["status"] == "ended")
    page.locator("#clear-ended").click()
    page.wait_for_timeout(200)
    got = page.evaluate("document.getElementById('clear-ended').checkVisibility()")
    send(page, {"sessions": [], "speaking": None})
    after = page.evaluate("[document.getElementById('clear-ended').checkVisibility(), document.getElementById('empty').checkVisibility()]")
    wall.check([got, after] == [False, [False, True]], "a cleared link stays off until its cards leave", [got, after])
    page.close()


def stale_focus_never_reveals(wall):
    """A focus request for a card not drawn waits one snapshot; later it cannot reveal ended cards."""
    page = open_app(wall, keep=lambda s: s["status"] == "working")
    ghost = next(s for s in page.snapshot_all if s["status"] == "ended")
    page.evaluate("(id) => window.__channel.onmessage({focus: id})", ghost["session_id"])
    send(page, page.snapshot)
    send(page, {"sessions": [ghost], "speaking": None})
    got = page.evaluate("[document.getElementById('empty').checkVisibility(), document.getElementById('wall').children.length]")
    wall.check(got == [True, 0], "a stale focus request leaves the quiet wall alone", got)
    page.close()


def reveal_race(wall):
    """A snapshot that slides the cards, then a focus request for an ended card
    in the same task: the ended cards show and that card has focus, whichever
    runs first."""
    for same in (False, True):
        page = open_app(wall, keep=lambda s: s["status"] in ("ended", "working"))
        ss = page.snapshot["sessions"]
        ended = [s for s in ss if s["status"] == "ended"]
        now_ended = ended + [{**s, "status": "ended"} for s in ss if s["status"] == "working"]
        target = ended[0]["session_id"]
        if same:
            page.evaluate("([s, id]) => window.__channel.onmessage({sessions: s, speaking: null, focus: id})", [now_ended, target])
        else:
            page.evaluate("([s, id]) => { window.__channel.onmessage({sessions: s, speaking: null}); window.__channel.onmessage({focus: id}); }", [now_ended, target])
        page.wait_for_timeout(700)
        got = page.evaluate(
            "[document.getElementById('empty').checkVisibility(), document.getElementById('wall').children.length, document.activeElement.dataset.key ?? document.activeElement.id]"
        )
        wall.check(got == [False, len(now_ended), target], f"a reordering snapshot and a focus request {'in one message' if same else 'back to back'}: the ended cards show, that one focused", got)
        page.close()


def reveal_does_not_arrive(wall):
    """Cards shown again are not new: an ended card a focus request shows, or
    one shown again when a live session starts, does not play the arrival; the
    new session's card does."""
    page = open_app(wall, keep=lambda s: s["status"] == "ended")
    ended = page.snapshot["sessions"]
    send(page, {"focus": ended[0]["session_id"]})
    revealed = page.evaluate("[document.getElementById('wall').dataset.density, document.querySelectorAll('#wall .arriving').length]")
    send(page, {"sessions": [], "speaking": None})
    send(page, {"sessions": ended, "speaking": None})
    working = next(s for s in page.snapshot_all if s["status"] == "working")
    send(page, {"sessions": [working] + ended, "speaking": None})
    page.wait_for_timeout(50)
    arriving = page.evaluate("[...document.querySelectorAll('#wall .arriving')].map((c) => c.dataset.key)")
    wall.check(revealed == ["comfortable", 0], "an ended card a focus request shows does not arrive", revealed)
    wall.check(arriving == [working["session_id"]], "with a live session the ended cards show without arriving", arriving)
    page.close()


def bar_follows_empty_state(wall):
    """Auto measures what is on screen: a compact wall that empties has a comfortable bar."""
    page = open_app(wall, 945, 1000)
    was = page.evaluate("[document.querySelector('.bar').dataset.density, document.getElementById('wall').dataset.density]")
    send(page, {"sessions": [], "speaking": None})
    now = page.evaluate("[document.querySelector('.bar').dataset.density, document.getElementById('empty').checkVisibility()]")
    wall.check(was == ["compact", "compact"] and now == ["comfortable", True], "the bar turns comfortable when the wall empties", [was, now])
    page.close()


def launch_dir_follows_prefs(wall):
    """The window only hides and shows, so the start label reads the folder
    again when the window regains focus, and keeps only the latest answer."""
    page = open_app(wall, keep=lambda s: False)
    page.evaluate("window.__dirAnswer = () => Promise.resolve('/home/aj/new-place')")
    page.evaluate("dispatchEvent(new Event('focus'))")
    page.wait_for_timeout(200)
    label = page.locator("#start-session").inner_text()
    wall.check(label == "Start a session in /home/aj/new-place", "the start label follows a prefs edit when the window regains focus", label)
    page.evaluate(
        """() => { let n = 0; window.__dirAnswer = () => { n++; const mine = n;
          return new Promise((r) => setTimeout(() => r(mine === 1 ? '/old' : '/new'), mine === 1 ? 400 : 20)); }; }"""
    )
    page.evaluate("dispatchEvent(new Event('focus')); document.dispatchEvent(new Event('visibilitychange'))")
    page.wait_for_timeout(700)
    label = page.locator("#start-session").inner_text()
    wall.check(label == "Start a session in /new", "a slower, older answer does not overwrite the latest", label)
    send(page, {"sessions": [next(s for s in page.snapshot_all if s["status"] == "working")], "speaking": None})
    before = len(calls(page, "get_launch_dir"))
    page.evaluate("dispatchEvent(new Event('focus'))")
    page.wait_for_timeout(100)
    wall.check(len(calls(page, "get_launch_dir")) == before, "with cards on the wall, focus reads nothing", before)
    page.close()


def browser_hides_app_actions(wall):
    """Outside the app Start, the clear link and New stay hidden: each needs the app."""
    page = wall.browser.new_page(viewport={"width": 1280, "height": 800})
    page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html?demo&ended")
    page.wait_for_function("document.getElementById('empty').checkVisibility()")
    got = page.evaluate("['start-session', 'clear-ended', 'new-session'].map((id) => document.getElementById(id).checkVisibility())")
    wall.check(got == [False, False, False], "outside the app the empty state offers no button", got)
    page.close()


def landmarks(wall):
    """One main landmark, one level-one heading, the empty state inside main."""
    for keep in (lambda s: False, None):
        page = open_app(wall, keep=keep)
        got = page.evaluate(
            """({main: document.querySelectorAll('main, [role=main]').length, h1: document.querySelectorAll('h1').length,
              wall: !!document.getElementById('wall').closest('main'), empty: !!document.getElementById('empty').closest('main')})"""
        )
        wall.check(got == {"main": 1, "h1": 1, "wall": True, "empty": True}, "one main, one h1, the wall and the empty state inside it", got)
        page.close()


def ended_only(wall):
    """Only ended cards, at 1920x1000 and 945x1000: the empty state with a
    link that clears exactly them; a live session brings the wall back, and a
    focus request for an ended card shows the ended cards."""
    for width, height in ((1920, 1000), (945, 1000)):
        ended_only_at(wall, width, height)


def ended_only_at(wall, width, height):
    at = f" at {width}x{height}"
    page = open_app(wall, width, height, keep=lambda s: s["status"] in ("ended", "working"))
    ended = next(s for s in page.snapshot["sessions"] if s["status"] == "ended")
    working = [s for s in page.snapshot["sessions"] if s["status"] == "working"]
    second = {**ended, "session_id": "demo-ended-2"}
    mixed = page.evaluate(EMPTY)
    wall.check(not mixed["empty"] and mixed["wall"], "ended beside working: the cards show" + at, mixed)
    # The last working session ends while one of its buttons has focus.
    page.locator(f'.card[data-key="{working[0]["session_id"]}"] .jump').focus()
    send(page, {"sessions": [ended, second] + [{**s, "status": "ended"} for s in working[:1]], "speaking": None})
    focus = page.evaluate("document.activeElement.id")
    send(page, {"sessions": [ended, second], "speaking": None})
    got = page.evaluate(EMPTY)
    wall.check(
        got["empty"] and not got["wall"] and got["clear"] == "Clear 2 ended sessions",
        "only ended cards: the empty state offers to clear both" + at,
        got,
    )
    wall.check(focus == "empty-title", "focus in a card that gives way goes to the empty state's title" + at, focus)
    page.locator("#clear-ended").click()
    page.wait_for_timeout(200)
    sent = page.evaluate(f"window.__calls.filter(([c]) => !{json.dumps(READS)}.includes(c))")
    wall.check(
        sent == [["clear_session", {"id": ended["session_id"]}], ["clear_session", {"id": "demo-ended-2"}]],
        "the link clears each ended session and nothing else" + at,
        sent,
    )
    send(page, {"focus": ended["session_id"]})
    shown = page.evaluate(EMPTY)
    focus = page.evaluate("document.activeElement.dataset.key")
    wall.check(
        not shown["empty"] and shown["wall"] and focus == ended["session_id"],
        "a focus request for an ended card shows the ended cards, that one focused" + at,
        [shown["empty"], shown["wall"], focus],
    )
    send(page, {"sessions": [], "speaking": None})
    got = page.evaluate(EMPTY)
    wall.check(got["empty"] and not got["wall"] and got["clear"] is None, "all cleared: the empty state, nothing to clear" + at, got)
    send(page, {"sessions": [working[0]], "speaking": None})
    got = page.evaluate(EMPTY)
    wall.check(not got["empty"] and got["wall"], "a live session takes the empty state's place" + at, got)
    page.close()


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


def ended(snapshot):
    """`snapshot` with every session ended, as after End all ready sessions."""
    snap = json.loads(json.dumps(snapshot))
    for row in snap["sessions"]:
        row.update({"status": "ended", "reason": "exited"})
    return snap


def wrapup_after_every_end(wall):
    """Once every session has ended under a request, the bar says so and keeps
    Safe to restart beside the empty state, never "0 of 0 ready"."""
    want = {"bar": True, "count": "Every session has ended", "safe": True, "stop": True, "endAll": False}
    page = open_app(wall)
    snap = with_wrapup(calm(page.snapshot), all_ready())
    feed(page, snap)
    feed(page, ended(snap))
    bar = page.evaluate(BAR)
    empty = page.evaluate("document.getElementById('empty').checkVisibility()")
    wall.check(bar == want and empty, "End all ready, then every card ends: Safe to restart stays beside the empty state", [bar, empty])
    feed(page, {**snap, "sessions": []})
    wall.check(page.evaluate(BAR) == want, "and stays once the ended cards are cleared", page.evaluate(BAR))
    page.close()
    page = open_app(wall)
    snap = with_wrapup(page.snapshot, WRAPUP_SAMPLE["answers"])
    feed(page, snap)
    feed(page, ended(snap))
    said = page.evaluate("document.getElementById('live').textContent")
    wall.check(page.evaluate(BAR) == want and "Every session has ended. Safe to restart" in said, "sessions that end before they are ready: the live region says Safe to restart", said)
    page.close()


# A third of a second of 24 kHz silence, as keryx keeps a reply clip.
WAV_JS = """() => {
  const n = 8000, b = new DataView(new ArrayBuffer(44 + n * 2));
  const s = (o, t) => [...t].forEach((c, i) => b.setUint8(o + i, c.charCodeAt(0)));
  s(0, 'RIFF'); b.setUint32(4, 36 + n * 2, true); s(8, 'WAVEfmt '); b.setUint32(16, 16, true);
  b.setUint16(20, 1, true); b.setUint16(22, 1, true); b.setUint32(24, 24000, true); b.setUint32(28, 48000, true);
  b.setUint16(32, 2, true); b.setUint16(34, 16, true); s(36, 'data'); b.setUint32(40, n * 2, true);
  return b.buffer;
}"""


def reply_buttons(wall):
    """A card keryx kept a reply for has a play button by its reply; a press
    reads that session's clip through reply_clip and plays it, Stop while it
    plays, Play again once it ends or is pressed; a card without one has none."""
    page = open_app(wall)
    page.evaluate(f"window.__clip = {WAV_JS}")
    want = sorted(s["session_id"] for s in page.snapshot["sessions"] if "reply_at" in s)
    shown = page.evaluate("[...document.querySelectorAll('.card')].filter((c) => c.querySelector('.play').checkVisibility()).map((c) => c.dataset.key).sort()")
    wall.check(shown == want and len(want) == 10, "a play button on exactly the cards keryx kept a reply for", [len(shown), len(want)])
    key = want[0]
    button = page.locator(f'.card[data-key="{key}"] .play')
    name = page.locator(f'.card[data-key="{key}"] .name').text_content()
    before = button.get_attribute("aria-label")
    button.click()
    page.wait_for_selector(f'.card[data-key="{key}"] .play.playing')
    during = button.get_attribute("aria-label")
    sent = page.evaluate("window.__calls.filter(([c]) => c === 'reply_clip')")
    page.wait_for_selector(f'.card[data-key="{key}"] .play:not(.playing)', timeout=5000)
    wall.check(
        before == f"Play {name}'s last reply" and during == f"Stop {name}'s reply" and sent == [["reply_clip", {"id": key}]],
        "a press reads that session's clip and plays it, Stop while it plays, Play once it ends",
        [before, during, sent],
    )
    page.evaluate("window.__clip = null")
    button.click()
    page.wait_for_function(f"document.querySelector('.card[data-key=\"{key}\"] .note').textContent.startsWith('Could not play')")
    wall.check(not page.locator(f'.card[data-key="{key}"] .play.playing').count(), "a clip that cannot be read says so and plays nothing", page.locator(f'.card[data-key="{key}"] .note').text_content())
    none = next(s["session_id"] for s in page.snapshot["sessions"] if "reply_at" not in s and s.get("reply"))
    line = page.evaluate(f"[document.querySelector('.card[data-key=\"{none}\"] .play').checkVisibility(), document.querySelector('.card[data-key=\"{none}\"] .reply').checkVisibility()]")
    wall.check(line == [False, True], "a card without a clip keeps its reply and has no button", line)
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


# ---- The Queue panel ---------------------------------------------------------

QUEUE_STATE = """() => {
  const q = document.getElementById('queue');
  const r = q.getBoundingClientRect();
  return {
    open: q.open,
    modal: q.matches(':modal'),
    mode: q.dataset.mode ?? null,
    label: document.getElementById('queue-open').textContent,
    expanded: document.getElementById('queue-open').getAttribute('aria-expanded'),
    hscroll: document.documentElement.scrollWidth > innerWidth,
    wallRight: Math.round(document.getElementById('wall').getBoundingClientRect().right),
    barRight: Math.round(document.querySelector('.bar').getBoundingClientRect().right),
    left: Math.round(r.left),
    width: Math.round(r.width),
    active: document.activeElement.id || document.activeElement.className,
  };
}"""
# The close event, and the panel's handling of it, come a task after the dialog shuts.
QUEUE_SHUT = "!document.getElementById('queue').open && document.getElementById('queue-open').getAttribute('aria-expanded') === 'false'"


def queue_docks_wide_and_is_a_dialog_narrow(wall):
    """At 1920 the Queue button docks the panel beside the wall, which gives
    up its room; at 945 it is a modal dialog. Either way it opens with focus
    on its title, closes on Esc with focus back on the button, and the page
    never scrolls sideways. Crossing the breakpoint while open switches mode."""
    for width, modal in ((1920, False), (945, True)):
        page = wall.open(width, 1000, 16 if width == 1920 else 8)
        before = page.evaluate(QUEUE_STATE)
        page.focus("#queue-open")
        page.keyboard.press("Enter")
        page.wait_for_selector("#queue .queue-content details")
        page.wait_for_timeout(SETTLE_MS)
        st = page.evaluate(QUEUE_STATE)
        named = page.get_by_role("dialog", name="Queue").count()
        ok = (
            before["open"] is False
            and before["expanded"] == "false"
            and st["open"]
            and st["modal"] is modal
            and st["mode"] == ("modal" if modal else "docked")
            and st["expanded"] == "true"
            and st["active"] == "queue-title"
            and not st["hscroll"]
            and named == 1
            and st["label"] == "Queue \u00b7 4 for you"
            and (modal or (st["wallRight"] <= st["left"] and st["barRight"] <= st["left"]))
        )
        wall.check(ok, f"at {width} px the Queue panel opens {'as a modal dialog' if modal else 'docked beside the wall'}", st)
        page.keyboard.press("Escape")
        page.wait_for_function(QUEUE_SHUT)
        shut = page.evaluate(QUEUE_STATE)
        wall.check(
            shut["active"] == "queue-open" and shut["expanded"] == "false" and shut["barRight"] == before["barRight"],
            f"at {width} px Esc closes the panel, the wall gets its room back and focus returns to the button",
            shut,
        )
        page.close()

    page = wall.open(1920, 1000, 8)
    page.click("#queue-open")
    page.wait_for_selector("#queue .queue-content details")
    narrow = wall.resize(page, 945, 1000) and page.evaluate(QUEUE_STATE)
    page.wait_for_timeout(SETTLE_MS)  # a late close event from the switch must not shut it
    narrow = page.evaluate(QUEUE_STATE)
    tight = wall.resize(page, 1300, 1000) and page.evaluate(QUEUE_STATE)
    wide = wall.resize(page, 1920, 1000) and page.evaluate(QUEUE_STATE)
    wall.check(
        narrow["modal"] and narrow["open"] and not narrow["hscroll"]
        and tight["mode"] == "docked" and tight["width"] == 480 and not tight["hscroll"]
        and wide["open"] and not wide["modal"] and wide["mode"] == "docked" and wide["width"] == 480,
        "an open panel turns into a dialog below the breakpoint, docks again above it, and a narrow window never shrinks the width asked for",
        [narrow, wide],
    )
    page.close()


def queue_resizes_by_keyboard_and_remembers(wall):
    """The separator is a focusable slider of the docked width: arrows step it,
    Home and End reach its bounds, and the width survives a reload."""
    page = wall.open(1920, 1000, 8)
    page.click("#queue-open")
    page.wait_for_selector("#queue .queue-content details")
    sep = page.locator("#queue [role=separator]")
    start = int(sep.get_attribute("aria-valuenow"))
    sep.focus()
    page.keyboard.press("ArrowLeft")
    page.keyboard.press("ArrowLeft")
    wider = page.evaluate(QUEUE_STATE)
    page.keyboard.press("Home")
    least = int(sep.get_attribute("aria-valuenow"))
    page.keyboard.press("End")
    most = int(sep.get_attribute("aria-valuenow"))
    page.keyboard.press("ArrowRight")
    kept = int(sep.get_attribute("aria-valuenow"))
    page.reload()
    page.wait_for_selector("#queue[open] .queue-content details")
    again = page.evaluate(QUEUE_STATE)
    ok = (
        start == 480
        and wider["width"] == 512
        and least == 320
        and most == int(sep.get_attribute("aria-valuemax")) == 900
        and kept == 884
        and again["open"]
        and again["width"] == 884
        and not again["hscroll"]
        and again["active"] not in ("queue-resize", "queue-close", "queue-title")
    )
    wall.check(ok, "the separator steps, bounds and remembers the docked width", [start, wider["width"], least, most, kept, again])
    page.close()


TEXT_STATE = """() => {
  const c = document.querySelector('#queue .queue-content');
  const body = document.querySelector('#queue .queue-body');
  const q = document.getElementById('queue').getBoundingClientRect();
  const inside = [...document.querySelectorAll('#queue .queue-tools button')].every((b) => {
    const r = b.getBoundingClientRect();
    return r.width > 0 && r.left >= q.left && r.right <= q.right;
  });
  const h = document.getElementById('queue-title').getBoundingClientRect();
  const t = document.querySelector('#queue .queue-tools').getBoundingClientRect();
  const apart = h.right <= t.left || h.bottom <= t.top;
  return {
    zoom: c.style.zoom,
    reset: document.querySelector('#queue .queue-reset').textContent,
    resetName: document.querySelector('#queue .queue-reset').getAttribute('aria-label'),
    smallerOff: document.querySelector('#queue .queue-smaller').getAttribute('aria-disabled'),
    largerOff: document.querySelector('#queue .queue-larger').getAttribute('aria-disabled'),
    stored: localStorage.getItem('klepsydra.queue.text'),
    cards: Math.round(document.querySelector('#wall .card .name').getBoundingClientRect().height * 10),
    title: [Math.round(h.width), document.getElementById('queue-title').scrollWidth <= Math.ceil(h.width)],
    apart,
    share: Math.round(body.scrollTop / Math.max(1, body.scrollHeight - body.clientHeight) * 100),
    hscroll: document.documentElement.scrollWidth > innerWidth || body.scrollWidth > body.clientWidth,
    inside,
  };
}"""


def queue_text_size(wall):
    """A-/A+ and the percentage set the Queue text size from 75% to 200%;
    Ctrl+= / Ctrl+- / Ctrl+0 act while the panel is open and not under
    another dialog, Ctrl+wheel over the panel steps it, the cards never
    change, and the size survives a reload."""
    page = wall.open(1920, 1000, 8)
    page.keyboard.press("Control+Equal")
    closed = page.evaluate(TEXT_STATE)
    wall.check(closed["zoom"] == "1" and closed["stored"] is None, "with the panel closed Ctrl+= changes nothing", closed)
    page.click("#queue-open")
    page.wait_for_selector("#queue .queue-content details")
    page.wait_for_timeout(SETTLE_MS)
    card_name = page.evaluate(TEXT_STATE)["cards"]  # docked: the wall has made room
    page.keyboard.press("Control+Equal")
    page.keyboard.press("Control+Equal")
    up = page.evaluate(TEXT_STATE)
    page.keyboard.press("Control+Minus")
    down = page.evaluate(TEXT_STATE)["zoom"]
    page.keyboard.press("Control+0")
    reset = page.evaluate(TEXT_STATE)
    wall.check(
        up["zoom"] == "1.25" and up["reset"] == "125%" and up["resetName"] == "Reset text size, now 125%" and up["stored"] == "1.25"
        and up["cards"] == card_name and down == "1.1" and reset["zoom"] == "1" and reset["stored"] == "1",
        "Ctrl+= steps 110% then 125%, Ctrl+- back, Ctrl+0 resets; the cards keep their size",
        [up, down, reset],
    )
    for _ in range(5):
        page.click("#queue .queue-larger")
    page.click("#queue .queue-larger", force=True)  # off at 200%: a press there does nothing
    most = page.evaluate(TEXT_STATE)
    wall.check(most["zoom"] == "2" and most["largerOff"] == "true" and most["smallerOff"] == "false" and not most["hscroll"], "A+ stops at 200% and turns off there; nothing scrolls sideways", most)
    page.click("#queue .queue-reset")
    for _ in range(3):
        page.click("#queue .queue-smaller")
    page.click("#queue .queue-smaller", force=True)
    least = page.evaluate(TEXT_STATE)
    wall.check(least["zoom"] == "0.75" and least["smallerOff"] == "true", "A- stops at 75%", least)
    page.click("#queue .queue-reset")
    box = page.locator("#queue .queue-content").bounding_box()
    page.mouse.move(box["x"] + box["width"] / 2, box["y"] + 40)
    page.keyboard.down("Control")
    page.mouse.wheel(0, -100)
    page.wait_for_timeout(150)
    page.mouse.wheel(0, -100)
    page.keyboard.up("Control")
    page.wait_for_timeout(100)
    wheeled = page.evaluate(TEXT_STATE)["zoom"]
    page.mouse.wheel(0, 300)
    page.wait_for_timeout(100)
    plain = page.evaluate(TEXT_STATE)["zoom"]
    wall.check(wheeled == "1.25" and plain == "1.25", "Ctrl+wheel over the panel steps a notch at a time; a plain wheel only scrolls", [wheeled, plain])
    page.locator("#queue [role=separator]").focus()
    page.keyboard.press("Home")
    narrow = page.evaluate(TEXT_STATE)
    wall.check(narrow["inside"] and narrow["apart"] and narrow["title"][1] and not narrow["hscroll"], "at its narrowest the header's buttons stay inside the panel, clear of the whole title", narrow)
    page.evaluate("document.querySelectorAll('#queue details').forEach((d) => { d.open = true; })")
    page.evaluate("(b => { b.scrollTop = (b.scrollHeight - b.clientHeight) / 2; })(document.querySelector('#queue .queue-body'))")
    before = page.evaluate(TEXT_STATE)["share"]
    page.keyboard.press("Control+Equal")  # a click would scroll the header into view
    after = page.evaluate(TEXT_STATE)["share"]
    wall.check(40 <= before <= 60 and abs(after - before) <= 3, "a size change keeps the reading position", [before, after])
    page.click("#queue .queue-reset")
    page.click("#queue .queue-larger")
    page.click("#queue .queue-larger")
    page.reload()
    page.wait_for_selector("#queue[open] .queue-content details")
    again = page.evaluate(TEXT_STATE)
    wall.check(again["zoom"] == "1.25" and again["reset"] == "125%", "the size survives a reload", again)
    open_drawer(page)
    page.keyboard.press("Control+Equal")
    under = page.evaluate(TEXT_STATE)["zoom"]
    wall.check(under == "1.25", "under the Ledger dialog the keys leave the panel alone", under)
    page.close()
    page = wall.open(945, 1000, 8)
    page.click("#queue-open")
    page.wait_for_selector("#queue .queue-content details")
    page.keyboard.press("Control+Equal")
    modal = page.evaluate(TEXT_STATE)
    wall.check(modal["zoom"] == "1.1" and modal["inside"], "as a dialog at 945 px the keys work and the buttons fit", modal)
    page.close()


def queue_renders_as_text_and_copies(wall):
    """The sample file renders with no link, image or script element; the
    HTML block and the javascript: link show as text; Copy puts a code block's
    text and a link's address on the clipboard."""
    page = wall.browser.new_page(viewport={"width": 1920, "height": 1000}, permissions=["clipboard-read", "clipboard-write"])
    page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html?demo=8")
    page.click("#queue-open")
    page.wait_for_selector("#queue .queue-content details")
    got = page.evaluate("""() => {
      const c = document.querySelector('#queue .queue-content');
      return {
        unsafe: c.querySelectorAll('a, img, script, iframe, [href], [src], [style], [onclick], [onerror]').length,
        html: [...c.querySelectorAll('.q-html')].map((e) => e.textContent),
        open: [...c.querySelectorAll('details')].map((d) => d.open),
        done: c.querySelectorAll('.q-done').length,
        pending: c.querySelectorAll('.q-pending').length,
      };
    }""")
    page.click("#queue summary:has-text('Queued')")
    bad = page.inner_text("#queue details:has(summary:has-text('Queued')) li:nth-child(2)")
    page.click("#queue .q-code .q-copy >> nth=0")
    page.wait_for_function("[...document.querySelectorAll('#queue .q-copy')].some((b) => b.textContent === 'Copied')")
    code = page.evaluate("navigator.clipboard.readText()")
    page.click("#queue button[aria-label='Copy link: https://tracker.example.com/items/42']")
    link = page.evaluate("navigator.clipboard.readText()")
    page.wait_for_function("document.querySelector('#queue .queue-live').textContent === 'Copied'")
    said = page.inner_text("#queue .queue-live")
    ok = (
        got["unsafe"] == 0
        and got["html"] == ['<script>alert("an HTML block shows as text")</script>']
        and got["open"] == [True, False, False, False]
        and got["done"] == 2
        and got["pending"] == 2
        and "[bad link](javascript:alert(1))" in bad
        and code.startswith("cp ~/.claude/settings.json") and "jq " in code
        and link == "https://tracker.example.com/items/42"
        and said == "Copied"
    )
    wall.check(ok, "the queue renders as text only, and Copy copies code and links", [got, bad, code[:30], link, said])
    page.close()


QUEUE_STUB = """
(() => {
  const invoke = window.__TAURI__.core.invoke;
  window.__TAURI__.core.invoke = (cmd, args) => {
    if (cmd === 'queue_subscribe') {
      window.__queue = args.onMessage;
      setTimeout(() => args.onMessage.onmessage(%s), 0);
      return Promise.resolve();
    }
    return invoke(cmd, args);
  };
})();
"""


def queue_follows_the_app(wall):
    """In the app the panel follows queue_subscribe: an edit repaints it and
    its count while the sections the viewer opened stay open, and a missing
    file is one line with the count gone."""
    import time

    fixture = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    at = fixture.pop("at")
    snapshot = shifted(fixture, int(time.time()) - at)
    text = (ROOT / "scripts/fixtures/queue-demo.md").read_text()
    first = {"path": "C:\\Users\\you\\Desktop\\claude-queue.md", "text": text, "problem": None}
    page = wall.browser.new_page(viewport={"width": 1920, "height": 1000})
    page.add_init_script(TAURI_STUB % json.dumps(snapshot))
    page.add_init_script(QUEUE_STUB % json.dumps(first))
    page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html")
    page.wait_for_function("document.getElementById('queue-open').textContent.includes('for you')")
    page.click("#queue-open")
    page.wait_for_selector("#queue .queue-content details")
    page.click("#queue summary:has-text('Running now')")
    edited = text.replace("## Running now", "6. **A new ask.**\n\n## Running now")
    page.evaluate("(v) => window.__queue.onmessage(v)", {**first, "text": edited})
    page.wait_for_function("document.getElementById('queue-open').textContent === 'Queue \u00b7 5 for you'")
    after = page.evaluate("""() => ({
      open: [...document.querySelectorAll('#queue details')].map((d) => d.open),
      asks: document.querySelectorAll('#queue details.q-needs > ol > li').length,
      path: document.querySelector('#queue .queue-path').textContent,
    })""")
    page.evaluate("(v) => window.__queue.onmessage(v)", {"path": first["path"], "text": None, "problem": "No queue file at this path."})
    page.wait_for_function("document.getElementById('queue-open').textContent === 'Queue'")
    gone = page.evaluate("""() => ({
      problem: document.querySelector('#queue .queue-problem').textContent,
      shown: !document.querySelector('#queue .queue-problem').hidden,
      blocks: document.querySelector('#queue .queue-content').children.length,
    })""")
    ok = (
        after["open"] == [True, True, False, False]
        and after["asks"] == 6
        and after["path"].endswith("claude-queue.md")
        and gone == {"problem": "No queue file at this path.", "shown": True, "blocks": 0}
    )
    wall.check(ok, "an edit repaints the panel and its count, keeping open sections; a missing file is one line", [after, gone])
    page.close()


def queue_copy_labels_and_failures(wall):
    """Two Copy clicks within the label's 2 s leave it reading Copy again; a
    link whose copy fails selects nothing and names the address instead."""
    page = wall.browser.new_page(viewport={"width": 1920, "height": 1000}, permissions=["clipboard-read", "clipboard-write"])
    page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html?demo=4")
    page.click("#queue-open")
    page.wait_for_selector("#queue .queue-content details")
    code = page.locator("#queue .q-code > .q-copy").first
    code.click()
    page.wait_for_timeout(300)
    code.click()
    page.wait_for_timeout(1900)  # past the first click's 2 s, inside the second's
    mid = code.text_content()
    page.wait_for_timeout(700)
    twice = code.text_content()
    page.close()

    # An item with both a link and a code block: the link's failure must not select the code.
    both = "## Needs you\n\n1. Read [the tracker](https://tracker.example.com/items/42), then run:\n   ```bash\n   cp ~/.claude/settings.json /tmp/x\n   ```\n"
    page = wall.browser.new_page(viewport={"width": 1920, "height": 1000})
    page.add_init_script("navigator.clipboard.writeText = () => Promise.reject(new DOMException('denied', 'NotAllowedError'));")
    page.route("**/queue-demo.md", lambda r: r.fulfill(status=200, content_type="text/markdown", body=both))
    page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html?demo=4")
    page.click("#queue-open")
    page.wait_for_selector("#queue .queue-content details")
    link = page.locator("#queue button[aria-label='Copy link: https://tracker.example.com/items/42']")
    link.click()
    page.wait_for_function("document.querySelector('#queue .queue-live').textContent !== ''")
    failed = page.evaluate("""() => ({
      selected: getSelection().toString(),
      said: document.querySelector('#queue .queue-live').textContent,
    })""")
    label = link.text_content()
    page.wait_for_timeout(2600)
    after = link.text_content()
    code = page.locator("#queue .q-code > .q-copy").first
    code.click()
    page.wait_for_function("getSelection().toString() !== ''")
    selected = page.evaluate("getSelection().toString()")
    ok = (
        mid == "Copied"
        and twice == "Copy"
        and failed == {"selected": "", "said": "Could not copy. The link is https://tracker.example.com/items/42"}
        and label == "Not copied"
        and after == "Copy link"
        and selected.startswith("cp ~/.claude/settings.json")
    )
    wall.check(ok, "Copy twice keeps its label; a failed link copy selects nothing, a failed code copy selects the code", [mid, twice, failed, label, after, selected[:30]])
    page.close()


QUEUE_FAIL = """
(() => {
  const invoke = window.__TAURI__.core.invoke;
  window.__TAURI__.core.invoke = (cmd, args) =>
    cmd === 'queue_subscribe' ? Promise.reject('no such command') : invoke(cmd, args);
})();
"""


def queue_says_when_it_cannot_follow(wall):
    """A queue_subscribe the app refuses is the panel's problem line, not a blank panel."""
    import time

    fixture = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    at = fixture.pop("at")
    page = wall.browser.new_page(viewport={"width": 1920, "height": 1000})
    page.add_init_script(TAURI_STUB % json.dumps(shifted(fixture, int(time.time()) - at)))
    page.add_init_script(QUEUE_FAIL)
    page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html")
    page.click("#queue-open")
    page.wait_for_timeout(SETTLE_MS)
    shown = page.evaluate("!document.querySelector('#queue .queue-problem').hidden")
    said = page.inner_text("#queue .queue-problem") if shown else None
    wall.check(said == "The queue file could not be followed: no such command", "a failed queue_subscribe shows on the problem line", said)
    page.close()


def queue_drag_settles_once(wall):
    """Dragging the separator moves the panel every frame, stores the width
    once on release, and runs Auto's measure once then, not on every frame."""
    page = wall.open(1920, 1000, 8)
    page.click("#queue-open")
    page.wait_for_selector("#queue .queue-content details")
    page.wait_for_timeout(SETTLE_MS)
    page.evaluate("""() => {
      window.__measures = 0;
      new MutationObserver((m) => { window.__measures += m.length; })
        .observe(document.querySelector('.density label:has([value=auto])'), { attributes: true, attributeFilter: ['title'] });
    }""")
    box = page.locator("#queue .queue-resize").bounding_box()
    x, y = box["x"] + box["width"] / 2, box["y"] + 300
    page.mouse.move(x, y)
    page.mouse.down()
    page.mouse.move(x - 200, y, steps=20)
    page.wait_for_timeout(SETTLE_MS)
    during = page.evaluate("""() => ({
      measures: window.__measures,
      stored: localStorage.getItem('klepsydra.queue.width'),
      width: Math.round(document.getElementById('queue').getBoundingClientRect().width),
    })""")
    page.mouse.up()
    page.wait_for_timeout(SETTLE_MS)
    after = page.evaluate("""() => ({
      measures: window.__measures,
      stored: localStorage.getItem('klepsydra.queue.width'),
      width: Math.round(document.getElementById('queue').getBoundingClientRect().width),
    })""")
    ok = (
        during["measures"] == 0
        and during["stored"] is None
        and abs(during["width"] - 680) <= 2
        and after["stored"] == str(during["width"])
        and after["width"] == during["width"]
        and after["measures"] == 1
    )
    wall.check(ok, "a drag resizes live, then stores the width and measures Auto once on release", [during, after])


SNAP_STATE = """() => {
  const q = document.getElementById('queue');
  const tab = document.getElementById('queue-tab');
  const r = q.getBoundingClientRect();
  const t = tab && tab.checkVisibility() ? tab.getBoundingClientRect() : null;
  const cards = [...document.querySelectorAll('#wall .card')].map((c) => c.getBoundingClientRect());
  const hit = t && document.elementFromPoint(t.left + t.width / 2, t.top + t.height / 2);
  return {
    open: q.open,
    modal: q.matches(':modal'),
    mode: q.dataset.mode ?? null,
    width: Math.round(r.width),
    left: Math.round(r.left),
    view: localStorage.getItem('klepsydra.queue.view'),
    stored: localStorage.getItem('klepsydra.queue.width'),
    tab: t && [Math.round(t.left), Math.round(t.top), Math.round(t.right), Math.round(t.bottom)],
    tabName: tab?.getAttribute('aria-label') ?? null,
    tabKeys: tab?.getAttribute('aria-keyshortcuts') ?? null,
    tabHit: !!hit && tab.contains(hit),
    tabCovers: !!t && cards.some((c) => c.left < t.right && c.right > t.left && c.top < t.bottom && c.bottom > t.top),
    cardsRight: Math.round(Math.max(...cards.map((c) => c.right))),
    edge: document.documentElement.clientWidth,
    mid: innerHeight / 2,
    expanded: document.getElementById('queue-open').getAttribute('aria-expanded'),
    active: document.activeElement.id || document.activeElement.className,
    hscroll: document.documentElement.scrollWidth > innerWidth,
    docked: document.body.classList.contains('queue-docked'),
    full: q.querySelector('.queue-full')?.getAttribute('aria-pressed') ?? null,
    text: [...q.querySelectorAll('.queue-text button')].every((b) => b.checkVisibility()),
    now: Number(q.querySelector('[role=separator]').getAttribute('aria-valuenow')),
  };
}"""


def grip_point(page):
    box = page.locator("#queue .queue-resize").bounding_box()
    return box["x"] + box["width"] / 2, box["y"] + 300


def tab_in_place(st, name="Open Queue"):
    """The tab: shown, at the window's right edge, centred on its height, at least 24 px each way, clear of the cards."""
    t = st["tab"]
    return (
        t is not None
        and t[2] == st["edge"]
        and abs((t[1] + t[3]) / 2 - st["mid"]) <= 1
        and t[2] - t[0] >= 24
        and t[3] - t[1] >= 24
        and st["tabName"] == name
        and st["tabKeys"] == "Control+Alt+B"
        and st["tabHit"]
        and not st["tabCovers"]
        and st["cardsRight"] <= t[0]
        and not st["hscroll"]
    )


def queue_snaps_shut_to_a_tab(wall):
    """Dragged past half its minimum width the panel snaps shut, keeping the
    width it had; a tab at the middle of the right edge, clear of the cards,
    reopens it by click and Ctrl+Alt+B, and the shut panel survives a reload.
    A drag back over the line before release opens it again at the minimum."""
    for density in ("compact", "comfortable"):
        page = wall.open(1920, 1000, 16 if density == "compact" else 4)
        first = page.evaluate(SNAP_STATE)
        wall.check(
            first["open"] is False and first["view"] is None and tab_in_place(first),
            f"first run ({density}): the panel is shut and its tab sits mid right edge, 24 px or more, clear of the cards",
            first,
        )
        page.close()
    page = wall.open(1920, 1000, 16)
    page.click("#queue-tab")
    page.wait_for_selector("#queue[open] .queue-content details")
    opened = page.evaluate(SNAP_STATE)
    wall.check(
        opened["open"] and opened["mode"] == "docked" and opened["width"] == 480 and opened["tab"] is None
        and opened["active"] == "queue-title" and opened["view"] == "docked",
        "a click on the tab docks the panel and focuses its title; the tab goes",
        opened,
    )
    x, y = grip_point(page)
    page.mouse.move(x, y)
    page.mouse.down()
    page.mouse.move(1920 - 170, y, steps=15)
    page.wait_for_timeout(100)
    least = page.evaluate(SNAP_STATE)
    page.mouse.move(1920 - 150, y, steps=4)
    page.wait_for_timeout(100)
    over = page.evaluate(SNAP_STATE)
    page.mouse.move(1920 - 170, y, steps=4)
    page.wait_for_timeout(100)
    back = page.evaluate(SNAP_STATE)
    page.mouse.move(1919, y, steps=10)
    page.wait_for_timeout(100)
    page.mouse.up()
    page.wait_for_timeout(SETTLE_MS)
    shut = page.evaluate(SNAP_STATE)
    wall.check(
        least["width"] == 320 and over["width"] <= 1 and over["open"] and back["width"] == 320
        and not shut["open"] and tab_in_place(shut) and shut["view"] == "shut" and shut["stored"] is None
        and not shut["docked"] and shut["expanded"] == "false",
        "a drag stops at 320, shows it shut past 160 and open again back over the line, and on release snaps shut, the width untouched",
        [least["width"], over["width"], back["width"], shut],
    )
    page.keyboard.press("Control+Alt+b")
    page.wait_for_selector("#queue[open] .queue-content details")
    keyed = page.evaluate(SNAP_STATE)
    page.keyboard.press("Control+Alt+b")
    page.wait_for_function(QUEUE_SHUT)
    keyed_shut = page.evaluate(SNAP_STATE)
    wall.check(
        keyed["open"] and keyed["width"] == 480 and keyed["active"] == "queue-title"
        and not keyed_shut["open"] and tab_in_place(keyed_shut) and keyed_shut["active"] == "queue-open",
        "Ctrl+Alt+B reopens the shut panel at its width and shuts it again, focus going back to the Queue button",
        [keyed, keyed_shut],
    )
    page.reload()
    page.wait_for_function("document.getElementById('wall').children.length === 16")
    page.wait_for_timeout(SETTLE_MS)
    again = page.evaluate(SNAP_STATE)
    wall.check(not again["open"] and tab_in_place(again), "shut survives a reload, with its tab", again)
    # Dropped just inside the line, it opens at the minimum.
    page.click("#queue-tab")
    page.wait_for_selector("#queue[open] .queue-content details")
    x, y = grip_point(page)
    page.mouse.move(x, y)
    page.mouse.down()
    page.mouse.move(1920 - 159, y, steps=10)
    page.mouse.move(1920 - 161, y, steps=2)
    page.mouse.up()
    page.wait_for_timeout(SETTLE_MS)
    inside = page.evaluate(SNAP_STATE)
    wall.check(inside["open"] and inside["width"] == 320 and inside["stored"] == "320", "released on the docked side of the line, it docks at the minimum", inside)
    page.close()


def queue_snaps_full(wall):
    """Dragged to within half the cards' minimum of the left edge the panel
    fills the window as a modal, text size controls and all; Esc, the Full
    screen button or a drag back right return it to docked, and full survives
    a reload. Close from full shuts it."""
    page = wall.open(1920, 1000, 8)
    page.click("#queue-open")
    page.wait_for_selector("#queue .queue-content details")
    x, y = grip_point(page)
    page.mouse.move(x, y)
    page.mouse.down()
    page.mouse.move(400, y, steps=20)
    page.wait_for_timeout(100)
    most = page.evaluate(SNAP_STATE)
    page.mouse.move(340, y, steps=4)
    page.wait_for_timeout(100)
    over = page.evaluate(SNAP_STATE)
    page.mouse.move(10, y, steps=10)
    page.mouse.up()
    page.wait_for_timeout(SETTLE_MS)
    full = page.evaluate(SNAP_STATE)
    wall.check(
        most["width"] == 900 and over["width"] == 1920
        and full["open"] and full["modal"] and full["mode"] == "full" and full["width"] == 1920 and full["left"] == 0
        and full["full"] == "true" and full["text"] and full["view"] == "full" and full["stored"] is None
        and not full["hscroll"] and full["tab"] is None and page.get_by_role("dialog", name="Queue").count() == 1,
        "a drag stops at 900, shows full past 350 px from the left, and on release fills the window as a modal with its text controls",
        [most["width"], over["width"], full],
    )
    page.keyboard.press("Control+Equal")
    zoom = page.evaluate("document.querySelector('#queue .queue-content').style.zoom")
    page.keyboard.press("Escape")
    page.wait_for_timeout(SETTLE_MS)
    esc = page.evaluate(SNAP_STATE)
    wall.check(
        zoom == "1.1" and esc["open"] and not esc["modal"] and esc["mode"] == "docked" and esc["width"] == 480
        and esc["docked"] and esc["full"] == "false" and esc["view"] == "docked" and esc["active"] == "queue-title",
        "in full the text keys work, and Esc goes back to docked at its width",
        [zoom, esc],
    )
    page.click("#queue .queue-full")
    page.wait_for_timeout(SETTLE_MS)
    button = page.evaluate(SNAP_STATE)
    page.reload()
    page.wait_for_selector("#queue[open] .queue-content details")
    page.wait_for_timeout(SETTLE_MS)
    reloaded = page.evaluate(SNAP_STATE)
    wall.check(
        button["mode"] == "full" and button["width"] == 1920 and button["active"] == "queue-full"
        and reloaded["mode"] == "full" and reloaded["modal"] and reloaded["width"] == 1920,
        "the Full screen button fills the window, and full survives a reload",
        [button, reloaded],
    )
    x, y = grip_point(page)
    page.mouse.move(x, y)
    page.mouse.down()
    page.mouse.move(340, y, steps=10)
    page.wait_for_timeout(100)
    held = page.evaluate(SNAP_STATE)
    page.mouse.move(1100, y, steps=20)
    page.wait_for_timeout(100)
    out = page.evaluate(SNAP_STATE)
    page.mouse.up()
    page.wait_for_timeout(SETTLE_MS)
    dropped = page.evaluate(SNAP_STATE)
    wall.check(
        x < 10 and held["width"] == 1920 and out["width"] == 820
        and dropped["mode"] == "docked" and not dropped["modal"] and dropped["width"] == 820 and dropped["stored"] == "820",
        "a drag right out of full docks the panel where it is dropped",
        [x, held["width"], out["width"], dropped],
    )
    page.click("#queue .queue-full")
    page.wait_for_timeout(SETTLE_MS)
    page.click("#queue .queue-full")
    page.wait_for_timeout(SETTLE_MS)
    toggled = page.evaluate(SNAP_STATE)
    page.click("#queue .queue-full")
    page.wait_for_timeout(SETTLE_MS)
    page.click("#queue .queue-close")
    page.wait_for_function(QUEUE_SHUT)
    closed = page.evaluate(SNAP_STATE)
    wall.check(
        toggled["mode"] == "docked" and toggled["width"] == 820 and toggled["active"] == "queue-full"
        and not closed["open"] and tab_in_place(closed) and closed["view"] == "shut" and closed["active"] == "queue-open",
        "a second press of Full screen docks it again; Close from full shuts it to its tab",
        [toggled, closed],
    )
    page.close()


def queue_separator_snaps_by_keyboard(wall):
    """On the separator Enter shuts the panel to its tab, which takes focus,
    and Enter there restores it (APG window splitter); Home at the narrowest
    shuts it, End at the widest fills the window, and Enter in full docks it."""
    page = wall.open(1920, 1000, 8)
    page.click("#queue-open")
    page.wait_for_selector("#queue .queue-content details")
    sep = page.locator("#queue [role=separator]")
    sep.focus()
    page.keyboard.press("Enter")
    page.wait_for_timeout(SETTLE_MS)
    entered = page.evaluate(SNAP_STATE)
    page.keyboard.press("Enter")
    page.wait_for_selector("#queue[open] .queue-content details")
    restored = page.evaluate(SNAP_STATE)
    wall.check(
        not entered["open"] and entered["active"] == "queue-tab" and tab_in_place(entered)
        and restored["open"] and restored["width"] == 480 and restored["active"] == "queue-title",
        "Enter on the separator shuts the panel and focuses its tab; Enter on the tab restores it",
        [entered, restored],
    )
    sep.focus()
    page.keyboard.press("Home")
    home = page.evaluate(SNAP_STATE)
    page.keyboard.press("Home")
    page.wait_for_timeout(SETTLE_MS)
    home2 = page.evaluate(SNAP_STATE)
    page.keyboard.press(" ")
    page.wait_for_selector("#queue[open] .queue-content details")
    spaced = page.evaluate(SNAP_STATE)
    wall.check(
        home["now"] == 320 and home["open"] and not home2["open"] and home2["active"] == "queue-tab"
        and home2["stored"] == "320" and spaced["open"] and spaced["width"] == 320,
        "Home reaches the narrowest, a second Home shuts it, and Space on the tab reopens it at 320",
        [home, home2, spaced],
    )
    sep.focus()
    page.keyboard.press("End")
    end = page.evaluate(SNAP_STATE)
    page.keyboard.press("End")
    page.wait_for_timeout(SETTLE_MS)
    end2 = page.evaluate(SNAP_STATE)
    page.keyboard.press("Enter")
    page.wait_for_timeout(SETTLE_MS)
    out = page.evaluate(SNAP_STATE)
    wall.check(
        end["now"] == 900 and not end["modal"]
        and end2["mode"] == "full" and end2["modal"] and end2["width"] == 1920 and end2["active"] == "queue-resize"
        and out["mode"] == "docked" and out["width"] == 900 and out["active"] == "queue-resize",
        "End reaches the widest, a second End fills the window with focus kept on the separator, and Enter docks it again",
        [end, end2, out],
    )
    page.close()


def queue_old_and_narrow_state(wall):
    """An older build's open flag reopens it docked; a stored width past the
    maximum is held to it; a corrupt view is shut. Below the dock breakpoint
    a stored view starts shut, unforgotten, with no tab; docked is the
    600 px dialog, full the whole window, and Esc steps back through them."""
    def at(width, values):
        page = wall.browser.new_page(viewport={"width": width, "height": 1000})
        page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html?demo=8")
        page.evaluate("(v) => { localStorage.clear(); for (const [k, x] of Object.entries(v)) localStorage.setItem(k, x); }", values)
        page.reload()
        page.wait_for_function("document.getElementById('wall').children.length === 8")
        page.wait_for_timeout(SETTLE_MS)
        return page

    page = at(1920, {"klepsydra.queue.open": "1", "klepsydra.queue.width": "5000"})
    old = page.evaluate(SNAP_STATE)
    wall.check(old["open"] and old["mode"] == "docked" and old["width"] == 900 and not old["hscroll"], "an older build's open flag docks the panel; a width past the maximum is held to 900", old)
    page.close()
    page = at(1920, {"klepsydra.queue.view": "banana", "klepsydra.queue.width": "abc"})
    bad = page.evaluate(SNAP_STATE)
    page.click("#queue-tab")
    page.wait_for_selector("#queue[open] .queue-content details")
    bad_open = page.evaluate(SNAP_STATE)
    wall.check(not bad["open"] and tab_in_place(bad) and bad_open["width"] == 480, "a corrupt view is shut with its tab; a corrupt width opens at 480", [bad, bad_open])
    page.close()

    page = at(945, {"klepsydra.queue.view": "full", "klepsydra.queue.width": "700"})
    start = page.evaluate(SNAP_STATE)
    wall.check(not start["open"] and start["tab"] is None and start["view"] == "full", "at 945 a stored full starts shut, with no tab, and is not forgotten", start)
    page.click("#queue-open")
    page.wait_for_selector("#queue .queue-content details")
    dialog = page.evaluate(SNAP_STATE)
    page.click("#queue .queue-full")
    page.wait_for_timeout(SETTLE_MS)
    full = page.evaluate(SNAP_STATE)
    page.keyboard.press("Escape")
    page.wait_for_timeout(SETTLE_MS)
    esc = page.evaluate(SNAP_STATE)
    page.keyboard.press("Escape")
    page.wait_for_function(QUEUE_SHUT)
    shut = page.evaluate(SNAP_STATE)
    wall.check(
        dialog["modal"] and dialog["mode"] == "modal" and dialog["width"] == 600 and dialog["text"]
        and full["modal"] and full["mode"] == "full" and full["width"] == 945 and full["text"] and not full["hscroll"]
        and esc["modal"] and esc["width"] == 600
        and not shut["open"] and shut["tab"] is None and shut["active"] == "queue-open" and shut["stored"] == "700",
        "at 945 the panel is the 600 px dialog, Full screen the whole window, Esc steps back to the dialog then shut, the docked width kept",
        [dialog, full, esc, shut],
    )
    page.keyboard.press("Control+Alt+b")
    page.wait_for_selector("#queue[open] .queue-content details")
    keyed = page.evaluate(SNAP_STATE)
    page.keyboard.press("Escape")
    page.wait_for_function(QUEUE_SHUT)
    wide = wall.resize(page, 1920, 1000) and page.evaluate(SNAP_STATE)
    wall.check(keyed["modal"] and keyed["width"] == 600 and tab_in_place(wide), "Ctrl+Alt+B opens the dialog at 945; widened, the shut panel shows its tab", [keyed, wide])
    page.close()


def split_toggle(wall):
    """Split with terminal: hidden in a browser; in the app a labelled toggle,
    off until the saved choice loads, that calls set_split_mode; and the wall
    at half a screen still fits eight compact cards with it in the bar."""
    width, height, cards, columns = FIT[1]
    page = wall.open(width, height, cards)
    hidden = page.evaluate("document.getElementById('split').hidden")
    wall.check(hidden, "a browser shows no split toggle", hidden)
    page.evaluate(
        "document.getElementById('split').hidden = false;"
        " dispatchEvent(new Event('resize'))"
    )
    page.wait_for_timeout(SETTLE_MS)
    got = page.evaluate(STATE)
    want = {"cards": cards, "density": "compact", "columns": columns, "scrolls": False, "key": True}
    ok = {k: got[k] for k in want} == want and got["bottom"] <= height
    wall.check(ok, f"fit {width}x{height} with the split toggle", got)
    page.close()

    page = open_app(wall, width, height)
    # The hit area reaches 3 px past the border each way, as Ledger's: 24 px (WCAG 2.2, 2.5.8).
    state = """() => { const b = document.getElementById('split'); const r = b.getBoundingClientRect();
      const x = r.left + r.width / 2, at = (y) => b.contains(document.elementFromPoint(x, y));
      return [b.hidden, b.getAttribute('aria-pressed'), b.textContent.trim(),
              at(r.top - 3) && at(r.bottom + 2.5) && r.height + 6 >= 24,
              document.getElementById('split-note').textContent]; }"""
    before = page.evaluate(state)
    wall.check(before[:4] == [False, "false", "Split with terminal", True], "the app shows the toggle, off, named, with a 24 px target", before)
    page.click("#split")
    page.wait_for_timeout(100)
    after = page.evaluate(state)
    calls = page.evaluate("window.__calls.filter(([c]) => c.endsWith('split_mode'))")
    ok = calls == [["get_split_mode", None], ["set_split_mode", {"on": True}]] and after[1] == "true" and after[4] == "ok"
    wall.check(ok, "a click calls set_split_mode and the toggle turns on once it answers", [calls, after])
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
            shared_home_voice,
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
            wrapup_after_every_end,
            reply_buttons,
            bulk_end_waits_on_ready,
            wrapup_dialogs_close_on_change,
            one_click_or_key_never_ends_all,
            empty_state,
            ended_only,
            long_folder_fits,
            reveal_density,
            separate_notes,
            launch_note_outlives_empty_state,
            one_launch_at_a_time,
            cleared_link_waits,
            stale_focus_never_reveals,
            reveal_race,
            reveal_does_not_arrive,
            bar_follows_empty_state,
            launch_dir_follows_prefs,
            browser_hides_app_actions,
            landmarks,
            queue_docks_wide_and_is_a_dialog_narrow,
            queue_resizes_by_keyboard_and_remembers,
            queue_text_size,
            queue_renders_as_text_and_copies,
            queue_follows_the_app,
            queue_copy_labels_and_failures,
            queue_says_when_it_cannot_follow,
            queue_drag_settles_once,
            queue_snaps_shut_to_a_tab,
            queue_snaps_full,
            queue_separator_snaps_by_keyboard,
            queue_old_and_narrow_state,
            split_toggle,
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
