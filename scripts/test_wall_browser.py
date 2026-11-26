"""The wall in a real browser: its fit, and Auto's density as things change.

Maximised on a 1920x1080 screen the wall's content is about 1920x1000, and
snapped to half the screen about 945x1000 (the taskbar, title bar and frame
take the rest). In Auto, sixteen demo cards fit the first and eight the
second, compact, in four and two columns, with no vertical scrollbar. An MCP ask cut short loses its middle, never the tool's
own name. Comfortable holds four full cards at half the screen
and eight maximised, and Auto keeps it there. Auto never leaves a comfortable wall scrolling: not when a
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
The Fleet button shows fleet doctor's checks, failing first; set
$KLEPSYDRA_HEALTH_SHOT to a path stem for a screenshot of it.

    uv run -q --no-project --with playwright python -I scripts/test_wall_browser.py

Needs Playwright's Chromium (`uvx playwright install chromium`), or a Chrome
at $KLEPSYDRA_CHROME.
"""

import functools
import http.server
import json
import re
import os
import pathlib
import sys
import threading
import time

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
SETTLE_MS = 350  # past the wall's resize settle and a frame
FIT = [  # (width, height, cards, columns)
    (1920, 1000, 16, 4),
    (945, 1000, 8, 2),
]

STATE = """() => {
  const wall = document.getElementById('wall');
  return {
    cards: wall.querySelectorAll(':scope > .card').length,
    density: wall.dataset.density,
    columns: getComputedStyle(wall).gridTemplateColumns.split(' ').length,
    scrolls: document.documentElement.scrollHeight > innerHeight,
    bottom: Math.max(...[...wall.querySelectorAll(':scope > .card')].map((c) => c.getBoundingClientRect().bottom)),
  };
}"""


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def open_gear(page):
    """The density and theme pickers sit in the bar's gear menu (#248): open it, as a user would."""
    page.evaluate("document.querySelector('.gear').open = true")


def pick(page, selector):
    """Pick a density from the gear menu, then close the menu again."""
    open_gear(page)
    page.click(selector)
    page.evaluate("document.querySelector('.gear').open = false")


def watch(page):
    """Keep what a page asked for and said, so an open that never paints can name why."""
    seen = {"asked": [], "done": set(), "said": []}
    page.on("request", lambda r: seen["asked"].append(r.url))
    page.on("requestfinished", lambda r: seen["done"].add(r.url))
    page.on("requestfailed", lambda r: seen["said"].append(f"failed {r.url}: {r.failure}"))
    page.on("console", lambda m: m.type in ("error", "warning") and seen["said"].append(f"{m.type}: {m.text}"[:300]))
    page.on("pageerror", lambda e: seen["said"].append(f"pageerror: {e}"[:300]))
    page.seen = seen


def painted(page, expression):
    """Wait for `expression`; on a timeout, print what the page still waited on, then fail as before."""
    try:
        page.wait_for_function(expression)
    except Exception:
        seen = getattr(page, "seen", None)
        if seen:
            pending = [u.split("/", 3)[-1] for u in seen["asked"] if u not in seen["done"]]
            print(f"  open never painted: pending {pending[:10]}, said {seen['said'][:8]}", file=sys.stderr)
        raise


class Wall:
    def __init__(self, browser, port):
        self.browser, self.port, self.failed, self.passed = browser, port, 0, 0

    def open(self, width, height, cards, fixture=None, ledger=None, query=""):
        page = self.browser.new_page(viewport={"width": width, "height": height})
        watch(page)
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
        painted(page, f"document.querySelectorAll('#wall > .card').length === {cards}")
        # In the app the bar shows + New session with its caret and an account badge, and
        # Wrap up…; the fit must hold with them.
        page.evaluate(
            "document.getElementById('new-session').hidden = false;"
            " document.getElementById('new-kind').hidden = false;"
            " Object.assign(document.querySelector('#new-session .mono'), { hidden: false, textContent: 'RIT' });"
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
    pick(page, ".density label:has([value=comfortable])")
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
    # A button's note is the one text a comfortable card does not clamp.
    page.evaluate(
        "() => { document.querySelector('.card .note').textContent = 'A long note. '.repeat(40); }"
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
    # Since the view settings went behind the gear (#248) the bar wraps only
    # below the two-column widths, so the case runs on one column there.
    width = next(
        (
            w
            for w in range(800, 1500, 5)
            if page.set_viewport_size({"width": w, "height": 2000}) is None
            and (h := page.evaluate(BARS))["comfortable"] > h["compact"] + 10
        ),
        None,
    )
    page.close()
    if width is None:
        wall.check(False, "a width where the comfortable bar is taller", None)
        return
    page = wall.open(width, 2000, cards, body)
    pick(page, ".density label:has([value=comfortable])")
    page.wait_for_timeout(SETTLE_MS)
    need = page.evaluate(
        "Math.ceil(document.getElementById('wall').getBoundingClientRect().bottom)"
    )
    pick(page, ".density label:has([value=auto])")
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
    """A compact card's ledger line shows only for an exception mark (a
    guardrail chip or missed telemetry, #248), sits in the foot slot clear of
    every text and inside the card, and is gone while a note shows."""
    page = wall.open(1920, 1000, 16)
    got = page.evaluate(
        """() => {
      const hit = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
      const out = { lines: 0, marked: 0, overlaps: [], tall: new Set(), long: 0, chips: 0 };
      for (const card of document.querySelectorAll('.card')) {
        const line = card.querySelector('.ledger-line');
        out.tall.add(card.getBoundingClientRect().height.toFixed(1));
        if (line.querySelector('.chip:not([hidden]), .partial:not([hidden])')) out.marked++;
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
        got["lines"] == got["marked"] >= 4
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
    pick(page, ".density label:has([value=comfortable])")
    page.wait_for_timeout(SETTLE_MS)
    got = page.evaluate(
        """() => {
      // A card by its name, or by its session (a voiceless one is named for the character it was cast).
      const find = (name) => [...document.querySelectorAll('.card')].find((c) => c.querySelector('.name').textContent === name || c.dataset.key === name);
      const text = (name) => find(name).querySelector('.r-full').textContent;
      const visible = (name) => !find(name).querySelector('.ledger-line').hidden && getComputedStyle(find(name).querySelector('.ledger-line')).display !== 'none';
      return {
        hephaestus: text('Hephaestus'),
        techne: text('Techne'),
        zero: visible('Dokimasia'),
        none: visible('demo-14-medallion'),
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
        pick(page, f".density label:has([value={density}])")
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
    """The header button and a chip open the Ledger; Esc and Close shut it
    and focus goes back to the opener."""
    page = wall.open(1920, 1000, 16)
    page.focus("#ledger-open")
    page.keyboard.press("Enter")
    page.wait_for_selector("#ledger .ledger-content table")
    first = page.evaluate("document.activeElement.id")
    wall.check(first == "ledger-title", "the drawer opens with focus on its title", first)
    named = page.get_by_role("dialog", name="Ledger").count()
    docked = page.evaluate("document.querySelector('#ledger:modal') === null && document.getElementById('ledger').dataset.mode === 'docked'")
    page.keyboard.press("Escape")
    page.wait_for_function(DRAWER_SHUT)
    from_button = page.evaluate(ACTIVE)
    wall.check(
        named == 1 and docked and from_button["id"] == "ledger-open",
        "the Ledger button opens a named panel, docked at 1920; Esc returns focus to it",
        [named, docked, from_button],
    )

    chip = page.locator(".card[data-key='demo-2-af_bella'] .chip")
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
    page.evaluate("[...document.querySelectorAll('.card')].find(c => c.dataset.key === 'demo-2-af_bella').querySelector('.ledger-line').style.setProperty('display', 'none')")
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
    # demo-15's voice is outside the cast, but its card wears a picked character (#148), so its
    # tokens count under that row; only the earlier session with no voice and no card is Other.
    other = "Other sessions: 1 (with no voice)"
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


def cast_pick_outlives_its_card(wall):
    """#148: a session the wall cast a character keeps that character's row in
    Tokens by character after its card leaves the wall (the crate records the
    pick in today's file, day.picks)."""
    fleet = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    gone = fleet["sessions"][1]["session_id"]
    view = json.loads(ledger_view())
    view["day"]["voices"].pop(gone, None)
    # af_heart: a character no other session in the demo day wears.
    view["day"]["picks"] = {gone: "af_heart"}
    want = json.loads((ROOT / "src/fleet/themes/kourai.json").read_text())["characters"]["af_heart"]["name"]
    fleet["sessions"] = [x for x in fleet["sessions"] if x["session_id"] != gone]
    page = wall.open(960, 1000, 8, fixture=json.dumps(fleet), ledger=json.dumps(view))
    open_drawer(page)
    rows = page.evaluate(
        """() => [...document.querySelectorAll('#ledger-characters-table tbody tr')].map((r) =>
      r.cells[0].querySelector('.visually-hidden')?.textContent ?? r.cells[0].textContent)"""
    )
    page.close()
    ok = want in rows
    wall.check(ok, "a cast session keeps its character's Ledger row after its card leaves", [rows, want])


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
    page.locator(".card[data-key='demo-2-af_bella'] .chip").click()
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
    page.locator(".card[data-key='demo-2-af_bella'] .chip").click()
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
    pick(page, ".density label:has([value=comfortable])")
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
    """A card arrives once: one that arrived while Compact showed does not
    replay its arrival when the wall turns Comfortable."""
    page = open_app(wall, keep=lambda s: s["status"] == "working" and s["voice"] != "am_michael")
    pick(page, ".density label:has([value=compact])")
    page.wait_for_timeout(SETTLE_MS)
    heph = next(s for s in page.snapshot_all if s["voice"] == "am_michael")
    send(page, {"sessions": [heph] + page.snapshot["sessions"], "speaking": None})
    page.wait_for_timeout(400)
    came = page.evaluate("document.querySelectorAll('.card.arriving').length")
    page.wait_for_timeout(4200)
    pick(page, ".density label:has([value=comfortable])")
    page.wait_for_timeout(SETTLE_MS)
    left = page.evaluate("document.querySelectorAll('.card.arriving').length")
    wall.check(came == 1 and left == 0, "an arrival seen in Compact does not replay on a switch to Comfortable", [came, left])
    page.close()


def slim_portrait_fits(wall):
    """A slim card (done, not started, silent, ended) in a theme with no
    figures keeps its portrait inside the 72 px band, clear of the repo line
    and the task."""
    probe = """() => [...document.querySelectorAll('.card:is(.tone-done,.dim):not(.has-figure)')].map((c) => {
      const R = (s) => c.querySelector(s).getBoundingClientRect();
      const p = R('.portrait'), h = R('header'), repo = R('.where'), task = R('header .task');
      return { name: c.querySelector('.name').textContent, below: Math.round(p.bottom - h.bottom), overRepo: p.bottom > repo.top, intoTask: Math.round(p.right - task.left) };
    })"""
    for theme in ("professions", "dicebear"):
        page = open_app(wall, 1920, 1000, theme=theme)
        pick(page, ".density label:has([value=comfortable])")
        page.wait_for_timeout(SETTLE_MS)
        got = page.evaluate(probe)
        wall.check(got and all(g["below"] <= 0 and not g["overRepo"] and g["intoTask"] <= 0 for g in got),
                   f"{theme}: each slim card's portrait stays in its band, off the repo line and the task", got)
        # An arrival animates the portrait's transform: the slim scale must hold through it.
        page.evaluate("document.querySelector('.card:is(.tone-done,.dim):not(.has-figure)').classList.add('arriving')")
        mid = []
        for wait in (300, 600, 1100):
            page.wait_for_timeout(wait)
            mid.append(page.evaluate(probe)[0])
        wall.check(all(g["below"] <= 0 and not g["overRepo"] for g in mid), f"{theme}: it stays in the band while it arrives", mid)
        page.close()


def dialog_backdrop_only(wall):
    """In a short window only the backdrop closes the portrait, never a click
    inside the dialog beside the image."""
    page = wall.open(1280, 360, 4)
    pick(page, ".density label:has([value=comfortable])")
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


# Each shown needs-you line: its two parts, whether each is cut, and whether it stays in its card.
ASKS = """() => [...document.querySelectorAll('.card .ask')].filter((a) => !a.hidden).map((ask) => {
  const [lead, keep] = ['.ask-lead', '.ask-keep'].map((s) => ask.querySelector(s));
  const [a, c, k, l] = [ask, ask.closest('.card'), keep, lead].map((e) => e.getBoundingClientRect());
  return {
    keep: keep.textContent,
    keepWhole: keep.scrollWidth <= keep.clientWidth,
    leadCut: lead.scrollWidth > lead.clientWidth,
    // An ellipsis draws only on a block box: a flex or inline lead clips mid-letter instead.
    ellipsis: [lead, keep].every((e) => getComputedStyle(e).textOverflow === 'ellipsis' && getComputedStyle(e).display === 'block'),
    leadWidth: Math.round(l.width),
    inside: a.right <= c.right + 0.5 && k.right <= a.right + 0.5 && ask.scrollWidth <= ask.clientWidth + 1,
    whole: ask.querySelector('.text').textContent === ask.title && ask.title.startsWith('Waiting for you to approve mcp__'),
    unfold: [...document.querySelectorAll('.unfold')].some((b) => b.checkVisibility()),
  };
})"""


def ask_keeps_the_tool_name(wall):
    """An MCP ask cut short loses its middle, not the tool's own name: at 1920
    and 945, in either density, each asking card's lead takes the ellipsis and
    browser_run_code_unsafe shows whole after it, inside the card; the title
    and the line's text hold all of it. The desktop wall has no Full text."""
    for width, cards in ((1920, 8), (945, 4)):
        for density in ("comfortable", "compact"):
            page = wall.open(width, 1000, cards, busy(cards))
            pick(page, f".density label:has([value={density}])")
            page.wait_for_timeout(SETTLE_MS)
            asks = page.evaluate(ASKS)
            ok = len(asks) == cards and all(
                a["keep"] == "browser_run_code_unsafe" and a["keepWhole"] and a["leadCut"] and a["ellipsis"] and a["inside"] and a["whole"] and not a["unfold"]
                for a in asks
            )
            wall.check(ok, f"an MCP ask keeps its tool's name, {density} at {width}", asks)
            page.close()


def long_tool_stays_in_card(wall):
    """A needs-you line whose tool name alone is wider than the card stays
    inside it at either density: the name is cut too, and the lead keeps four
    characters before its ellipsis."""
    reason = "approve mcp__claude_ai_Gmail__apply_sensitive_message_label_and_then_some_more_words_without_breaks"
    for density in ("comfortable", "compact"):
        page = wall.open(945, 1000, 4, busy(4, reason=reason))
        pick(page, f".density label:has([value={density}])")
        page.wait_for_timeout(SETTLE_MS)
        asks = page.evaluate(ASKS)
        ok = len(asks) == 4 and all(a["inside"] and not a["keepWhole"] and a["leadCut"] and a["ellipsis"] and a["leadWidth"] >= 20 for a in asks)
        wall.check(ok, f"a long tool name stays in its {density} card", asks)
        page.close()


def dialog_caption_fits(wall):
    """In a short window the dialog's caption is never cut off: it fits or scrolls."""
    page = wall.open(1280, 300, 4)
    pick(page, ".density label:has([value=comfortable])")
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
    the figure (and its clipped aura) leaves the card's top edge, by no more
    than the figure's overshoot."""
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
              // The figure breaks the frame by its overshoot (#247): --fig less the band's height.
              const head = card.querySelector('header');
              const allow = Math.max(14.5, parseFloat(getComputedStyle(head).getPropertyValue('--fig')) - head.getBoundingClientRect().height + 2.5);
              if (top < c.top - allow) out.push(`${name}: ${el} ${(c.top - top).toFixed(1)} px over the top`);
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


# Split mode on a 1920x1080 screen leaves the wall about 945 to 958 px wide;
# maximised, 1920. Either way about 1000 px tall under the taskbar.
COMFORTABLE_FIT = [  # (width, height, cards, columns)
    (945, 1000, 4, 2),
    (958, 1000, 4, 2),
    (1920, 1000, 8, 4),
]


OTHER_REPOS = ["kourai-khryseai", "papers", "ajsoftworks", "talks", "techne", "claude-prefs", "keryx",
               "pharos", "sphragis", "ariadne", "ldqis", "agones", "askesis", "epistole"]
LONG = "Re-running the sweep over five seeds, then redrawing the bars with the median and range before the deck refresh picks them up. " * 2


def busy(n, shape="asking", reason="approve mcp__plugin_playwright_playwright__browser_run_code_unsafe"):
    """The demo's first `n` sessions, each as full as a live card gets outside
    a wrap-up: a long session name, worktree and branch, twelve other repos
    touched, a crew, a long prompt and reply, a ledger line with a blocked
    chip, and quiet ten minutes, so "updated" shows. `shape` "asking" waits
    on AJ to approve a long MCP tool; "error" ends on a long API error."""
    demo = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    at, ledger = demo["at"], demo["sessions"][0]["ledger"]
    states = {
        "asking": {"status": "needs_you", "reason": reason, "error": None},
        "error": {"status": "error", "reason": None, "error": "API Error: 529 overloaded_error, the request was retried three times and failed. " * 3},
    }
    sessions = []
    for s in demo["sessions"][:n]:
        sessions.append({
            **s,
            **states[shape],
            "quiet_since": None,
            "name": "A session name long enough to run past the nameplate",
            "status_at": at - 600,
            "updated_at": at - 600,
            "where": {**s["where"], "worktree": "comfortable-density-four-and-eight", "branch": "feat/comfortable-density-four-and-eight"},
            "touched": [{"repo": r, "at": at - 900} for r in OTHER_REPOS if r != s["where"]["repo"]][:12],
            "background": {"agents": 2, "shells": 1},
            "prompt": {"text": LONG, "at": at - 660},
            "reply": {"text": LONG, "at": at - 600},
            "ledger": {**(s.get("ledger") or ledger), "guardrail_rejects": 3},
        })
    return json.dumps({**demo, "sessions": sessions, "speaking": None})


FITS = """() => {
  const d = document.documentElement;
  const wall = document.getElementById('wall');
  const bar = document.querySelector('.bar').getBoundingClientRect();
  const cards = [...wall.querySelectorAll(':scope > .card')];
  const rows = [...new Set(cards.map((c) => Math.round(c.getBoundingClientRect().top)))].sort((a, b) => a - b);
  // Each figure breaks its card's top edge, and stays clear of the bar and of the row above.
  const breakout = cards.filter((c) => c.classList.contains('has-figure')).map((c) => {
    const [card, fig] = [c, c.querySelector('.figure')].map((e) => e.getBoundingClientRect());
    const above = cards.map((o) => o.getBoundingClientRect()).filter((o) => o.bottom <= card.top && o.left < card.right && card.left < o.right);
    const floor = Math.max(bar.bottom, ...above.map((o) => o.bottom));
    return { over: card.top - fig.top, clear: fig.top - floor };
  });
  return {
    density: wall.dataset.density,
    scrollHeight: d.scrollHeight,
    clientHeight: d.clientHeight,
    columns: getComputedStyle(wall).gridTemplateColumns.split(' ').length,
    rows: rows.length,
    cards: cards.map((c) => Math.round(c.getBoundingClientRect().height)),
    breakout: breakout.length ? [Math.min(...breakout.map((b) => b.over)), Math.min(...breakout.map((b) => b.clear))] : null,
    jump: [...new Set(cards.map((c) => c.querySelector('.jump').getBoundingClientRect().height))],
  };
}"""


def comfortable_fits(wall):
    """Comfortable holds four cards in split mode (2x2) and eight maximised
    (4x2) with no vertical scrollbar, the demo as it is and with every card
    full, all asking or all in error; Auto stays comfortable there. Each figure breaks
    the card's top edge cleanly: above it, yet clear of the bar and the row
    above. Open terminal is 24 to 28 px tall."""
    for width, height, cards, columns in COMFORTABLE_FIT:
        for fleet, body in (("demo", None), ("asking", busy(cards)), ("error", busy(cards, "error"))):
            for density in ("comfortable", "auto"):
                page = wall.open(width, height, cards, body)
                pick(page, f".density label:has([value={density}])")
                page.wait_for_timeout(SETTLE_MS)
                got = page.evaluate(FITS)
                over, clear = got["breakout"] or (0, 0)
                ok = (
                    got["density"] == "comfortable"
                    and got["scrollHeight"] <= got["clientHeight"]
                    and (got["columns"], got["rows"]) == (columns, cards // columns)
                    and over >= 4
                    and clear >= 4
                    and all(24 <= h <= 28 for h in got["jump"])  # the 24 px minimum (WCAG 2.2, 2.5.8), no taller than compact's
                )
                wall.check(ok, f"{cards} {fleet} cards fit {density} at {width}x{height}", got)
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
# queue file's queue_subscribe gets nothing; every other command is recorded
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
    if (cmd === 'queue_subscribe') { window.__queue = args.onMessage; return Promise.resolve(); }
    if (cmd === 'needs_subscribe') { window.__needs = args.onMessage; return Promise.resolve(); }
    if (cmd === 'ci_subscribe') { window.__ci = args.onMessage; return Promise.resolve(); }
    if (cmd === 'health_subscribe') { window.__health = args.onMessage; return Promise.resolve(); }
    if (cmd === 'split_subscribe') { window.__split = args.onMessage; return Promise.resolve(); }
    if (cmd === 'theme_subscribe') {
      window.__theme = args.onMessage;
      setTimeout(() => args.onMessage.onmessage(window.__savedTheme ?? 'kourai'), window.__themeDelay ?? 0);
      return Promise.resolve();
    }
    if (cmd === 'opacity_subscribe') {
      window.__opacity = args.onMessage;
      setTimeout(() => args.onMessage.onmessage(window.__savedOpacity ?? 80), 0);
      return Promise.resolve();
    }
    if (cmd === 'get_wall_density') return Promise.resolve('auto');
    if (cmd === 'get_needs_layout') return Promise.resolve(window.__layout ?? 'E');
    // The front end's log lines, apart from the actions.
    if (cmd === 'plugin:log|log') { (window.__logs ??= []).push(args); return Promise.resolve(); }
    if (cmd === 'agy_models') { window.__calls.push([cmd, args]); return window.__agy ? Promise.resolve(window.__agy) : Promise.reject(window.__agyError ?? 'agy (Antigravity CLI) was not found on PATH.'); }
    if (cmd === 'read_usage') { window.__calls.push([cmd, args]); return Promise.resolve(window.__usage ?? []); }
    if (cmd === 'engines_status') { window.__calls.push([cmd, args]); return new Promise((r) => setTimeout(() => r(window.__engines ?? { claude: [], agy: false, copilot: false }), window.__enginesDelay ?? 0)); }
    if (cmd === 'launch_session' && window.__launchHold) { window.__calls.push([cmd, args]); return window.__launchHold; }
    if (cmd === 'new_session_prefs') { window.__calls.push([cmd, args]); return Promise.resolve(window.__nsprefs ?? { default: null, last: null }); }
    if (cmd === 'get_launch_dir') { window.__calls.push([cmd, args]); return window.__dirAnswer ? window.__dirAnswer() : Promise.resolve('/home/aj/ajsoftworks'); }
    if (cmd === 'set_theme' && window.__setThemeFails) { window.__calls.push([cmd, args]); return Promise.reject(window.__setThemeFails); }
    if (window.__fails && window.__fails[cmd]) { window.__calls.push([cmd, args]); return Promise.reject(window.__fails[cmd]); }
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
READS = ["get_launch_dir", "get_split_mode", "agy_models", "read_usage", "engines_status", "new_session_prefs"]
WORKING_CARD = ".card:has(.pill .label:text-is('working')):has(.menu:not([hidden]))"


def open_app(wall, width=1920, height=1000, keep=None, motion="no-preference", launch_dir="/home/aj/ajsoftworks", theme=None, init=None, before=None):
    """The demo wall as the app would feed it, with invokes recorded; `keep`
    picks which demo sessions the snapshot carries, `theme` the saved theme."""
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
    watch(page)
    page.add_init_script(stub % json.dumps(snapshot))
    if theme is not None:
        page.add_init_script(f"window.__savedTheme = {json.dumps(theme)};")
    if init is not None:
        page.add_init_script(init)
    if before is not None:
        before(page)
    page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html")
    if snapshot["sessions"] and keep is None:
        painted(page, "document.querySelectorAll('#wall > .card').length > 0")
    else:
        painted(page, "window.__channel !== undefined")
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
                sent == [["launch_session", {}], ["launch_session", {}]] and note == "ok",
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
    got = page.evaluate("[document.getElementById('empty').checkVisibility(), document.querySelectorAll('#wall > .card').length]")
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
            "[document.getElementById('empty').checkVisibility(), document.querySelectorAll('#wall > .card').length, document.activeElement.dataset.key ?? document.activeElement.id]"
        )
        wall.check(got == [False, len(now_ended), target], f"a reordering snapshot and a focus request {'in one message' if same else 'back to back'}: the ended cards show, that one focused", got)
        page.close()


def arrival_is_an_event(wall):
    """#373: a session's first appearance is an event, once. Its card wears
    .arriving with a banner naming it, the live region says it arrived, and
    nothing replays on a reload; reduced motion keeps the banner as a
    crossfade, and Compact arrives too."""
    for motion, density in (("no-preference", "comfortable"), ("reduce", "comfortable"), ("no-preference", "compact")):
        page = open_app(wall, keep=lambda s: s["status"] == "working" and s["voice"] != "am_michael", motion=motion)
        pick(page, f".density label:has([value={density}])")
        page.wait_for_timeout(SETTLE_MS)
        quiet = page.evaluate("document.querySelectorAll('#wall .arriving').length")
        heph = next(s for s in page.snapshot_all if s["voice"] == "am_michael")
        send(page, {"sessions": [heph] + page.snapshot["sessions"], "speaking": None})
        page.wait_for_timeout(400)
        got = page.evaluate("""(id) => { const c = document.querySelector(`#wall .card[data-key="${id}"]`); const h = c.querySelector('.herald');
          return { arriving: c.classList.contains('arriving'), shown: h.checkVisibility(), name: h.querySelector('.herald-name').textContent,
            anim: getComputedStyle(h).animationName, live: document.getElementById('live').textContent,
            others: document.querySelectorAll('#wall .arriving').length }; }""", heph["session_id"])
        calm = "herald-calm" if motion == "reduce" else "herald"
        wall.check(
            quiet == 0 and got["arriving"] and got["shown"] and got["name"] == "Hephaestus" and got["anim"] == calm and got["others"] == 1
            and "Hephaestus has arrived, Master of the Forge" in got["live"],
            f"{density}, motion {motion}: the new session arrives once, named and announced",
            [quiet, got],
        )
        page.wait_for_timeout(4200)
        done = page.evaluate("document.querySelectorAll('#wall .arriving').length")
        send(page, {"sessions": [heph] + page.snapshot["sessions"], "speaking": None})
        again = page.evaluate("document.querySelectorAll('#wall .arriving').length")
        wall.check(done == 0 and again == 0, f"{density}, motion {motion}: it settles and a later snapshot does not replay it", [done, again])
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


NARROW = """() => {
  const cw = document.documentElement.clientWidth;
  const r = (e) => e.getBoundingClientRect();
  const cards = [...document.querySelectorAll('#wall > .card')].filter((c) => c.checkVisibility());
  // Every control inside its own card (the portrait's look button breaks the frame by
  // design, #247: inside the window is its bound), and every card inside the window.
  const out = cards.flatMap((c) => [...c.querySelectorAll('button, a')]
      .filter((e) => e.checkVisibility() && (e.classList.contains('look')
        ? r(e).right > cw + 0.5 || r(e).left < -0.5
        : r(e).right > r(c).right + 0.5 || r(e).left < r(c).left - 0.5))
      .map((e) => (e.getAttribute('aria-label') || e.className || e.tagName).toString().slice(0, 30)))
    .concat(cards.filter((c) => r(c).right > cw + 0.5).map(() => 'card'));
  // A label wider than its button spills out though the button's own box fits.
  const cut = cards.flatMap((c) => [...c.querySelectorAll('button')])
    .filter((b) => b.checkVisibility() && b.scrollWidth > b.clientWidth + 1).map((b) => b.textContent.trim().slice(0, 30));
  // No two header controls overlap (a pill running under Open terminal, #505).
  const hit = (a, b) => a.left < b.right - 0.5 && b.left < a.right - 0.5 && a.top < b.bottom - 0.5 && b.top < a.bottom - 0.5;
  const overlap = cards.flatMap((c) => {
    const els = ['.pill', '.jump', '.clear'].map((q) => c.querySelector(q)).filter((e) => e && e.checkVisibility());
    return els.flatMap((a, i) => els.slice(i + 1).filter((b) => hit(r(a), r(b))).map((b) => `${a.className}/${b.className}`));
  });
  // A name keeps its whole width, or 90 px before it ellipsizes: never squeezed to a letter.
  const squeezed = cards.map((c) => c.querySelector('.name')).filter((n) => n && n.checkVisibility()
      && n.clientWidth < Math.min(n.scrollWidth, 90)).map((n) => `${n.textContent} ${n.clientWidth}px`);
  const jumps = cards.map((c) => c.querySelector('.jump')).filter((b) => b && b.checkVisibility())
    .map((b) => b.textContent.trim());
  return { cards: cards.length, wide: document.documentElement.scrollWidth > cw, out, cut, squeezed, overlap,
           density: document.getElementById('wall').dataset.density, jumps: [...new Set(jumps)] };
}"""


def narrow_window_keeps_cards_inside(wall):
    """#505: a desktop wall window narrower than a card's 420 px minimum keeps
    every card inside the window and every button and link inside its card,
    with no sideways scroll, in both densities and with a shut panel tab's padding;
    no name is squeezed (a narrow compact card gives the name its own line) and
    Open terminal reads whole; at full width the columns are as before."""
    for density in ("compact", "comfortable"):
        for width, tabbed in ((360, False), (390, False), (390, True), (420, True), (450, False), (470, False), (520, False), (530, False), (880, False), (1920, False)):
            page = open_app(wall, width=width, height=900 if width < 1000 else 1000)
            pick(page, f".density label:has([value={density}])")
            if tabbed:
                page.evaluate("document.body.classList.add('ledger-tabbed')")
            page.wait_for_timeout(1500)  # past an arrival's spring over the frame
            got = page.evaluate(NARROW)
            tab = " with a panel tab" if tabbed else ""
            # Left for #535: a two-column compact wall, and a comfortable one under 400 px.
            names = "" if (density == "compact" and width == 880) or (density == "comfortable" and width < 400) else ", no name squeezed"
            wall.check(got["density"] == density and got["cards"] > 0 and not got["wide"] and not got["out"]
                       and not got["cut"] and not got["overlap"] and (not names or not got["squeezed"]) and got["jumps"] in ([], ["Open terminal"]),
                       f"{density} at {width} px{tab}: cards in the window, controls in their card and apart{names}, Open terminal whole", got)
            page.close()
    page = open_app(wall, width=1920, height=1000)
    cols = page.evaluate("getComputedStyle(document.getElementById('wall')).gridTemplateColumns.split(' ').length")
    wall.check(cols == 4, "at 1920 px the wall still has four columns", cols)
    page.close()
    # The phone wall (.served) keeps its own one-line compact header: none of the stacking reaches it.
    page = open_app(wall, width=390, height=900)
    pick(page, ".density label:has([value=compact])")
    page.evaluate("document.documentElement.classList.add('served')")
    page.wait_for_timeout(1500)
    phone = page.evaluate("""() => {
      const c = [...document.querySelectorAll('#wall > .card')].find((e) => e.checkVisibility() && e.querySelector('.pill'));
      const p = c.querySelector('.pill'), n = c.querySelector('.name');
      const mid = (e) => { const r = e.getBoundingClientRect(); return r.top + r.height / 2; };
      return { margin: getComputedStyle(p).marginLeft, sameLine: Math.abs(mid(p) - mid(n)) < 12 };
    }""")
    wall.check(phone["margin"] == "8px" and phone["sameLine"], "the phone wall at 390 px keeps the pill beside the name, as before", phone)
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
    def state():
        return page.evaluate(
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
        pick(page, f".density label:has([value={density}])")
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
    ("At the end of its turn", ["demo-2-af_bella", "demo-3-af_sarah", "demo-4-bf_alice", "demo-10-bm_george", "demo-16-af_kore"]),
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


NATIVE_KEYS = ("demo-1-am_michael", "demo-2-af_bella", "demo-5-bf_isabella")  # needs_you, working, done


def native_flag_reaches_the_cards(wall):
    """A native Linux snapshot (native: true) offers its null-distro sessions End, Interrupt, a typed wrap-up and an
    unnamed Jump styled like any other; the same snapshot with native false (what Windows sends) or
    without the flag (an older app) offers none of them."""
    page = open_app(wall, keep=lambda s: s["session_id"] in NATIVE_KEYS)
    names = names_by_key(page)
    base = json.loads(json.dumps(page.snapshot))
    for row in base["sessions"]:
        row["distro"] = None  # the hook records none on native Linux
        if row["session_id"] != "demo-2-af_bella":
            row["name"] = None  # unnamed: Jump finds it by its pane alone
    state = """() => Object.fromEntries([...document.querySelectorAll('.card')].map((c) => [c.dataset.key, {
      menu: !c.querySelector('.menu').hidden,
      jump: !('off' in c.querySelector('.jump').dataset),
      kind: c.querySelector('.jump').dataset.kind,
    }]))"""
    for native in (True, False, None):
        snap = json.loads(json.dumps(base))
        if native is not None:
            snap["native"] = native
        at = " (flag missing)" if native is None else f" (native: {native})"
        send(page, snap)
        got = page.evaluate(state)
        kinds = {k: got[k]["kind"] for k in NATIVE_KEYS}
        menus = {k: got[k]["menu"] for k in NATIVE_KEYS}
        jumps = {k: got[k]["jump"] for k in ("demo-1-am_michael", "demo-5-bf_isabella")}
        if native:
            wall.check(all(menus.values()), "every null-distro session in klepsydra's tmux gets the actions menu" + at, menus)
            wall.check(all(jumps.values()) and kinds["demo-1-am_michael"] == "needs" and kinds["demo-5-bf_isabella"] in ("accent", "plain"),
                       "an unnamed session's Open terminal is on, filled when it needs you, marked otherwise" + at, [jumps, kinds])
            open_menu(page, page.locator(".card[data-key='demo-2-af_bella']"))
            items = page.evaluate(
                "[...document.querySelectorAll('#session-menu [role=menuitem]')].filter((i) => !i.hidden).map((i) => i.textContent.trim())"
            )
            page.keyboard.press("Escape")
            wall.check(items == ["Interrupt", "End session…"], "a working null-distro card offers Interrupt and End" + at, items)
        else:
            wall.check(not any(menus.values()), "through wsl.exe a session with no distro gets no actions menu" + at, menus)
            wall.check(not any(jumps.values()) and kinds["demo-1-am_michael"] == "off" and kinds["demo-5-bf_isabella"] == "off",
                       "through wsl.exe an unnamed session with no distro cannot be jumped to" + at, [jumps, kinds])
        page.click("#wrapup-open")
        page.wait_for_function("document.getElementById('end-dialog').open")
        groups = page.evaluate(DIALOG)["groups"]
        page.get_by_role("button", name="Cancel").click()
        page.wait_for_function("!document.getElementById('end-dialog').open")
        typed = [["Typed now", [names["demo-5-bf_isabella"]]]] if native else []
        by_hand = [] if native else [[BY_HAND, [names["demo-5-bf_isabella"]]]]
        want = typed + [["At the end of its turn", [names["demo-2-af_bella"]]], ["After you answer", [names["demo-1-am_michael"]]]] + by_hand
        wall.check(groups == want, "the Wrap up confirm types into an idle null-distro session only with the flag" + at, groups)
        wall.check(not page.evaluate(STARTS), "looking asks no one" + at, page.evaluate(STARTS))
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
    reason = WRAPUP_SAMPLE["answers"]["demo-4-bf_alice"]["reason"]
    want = {
        "demo-5-bf_isabella": "Ready",
        "demo-2-af_bella": "Finishing its turn",
        "demo-9-bm_fable": "Ready once its background work ends",
        "demo-3-af_sarah": "Wrapping up…",
        "demo-4-bf_alice": f"Not ready: {reason}",
        "demo-1-am_michael": "Answer it first; it wraps up after",
        "demo-10-bm_george": "Wraps up when this turn ends",
        "demo-6-af_nova": "Ask by hand: /klepsydra-wrapup",
        "demo-8-am_puck": None,
    }
    wall.check(all(lines[k] == v for k, v in want.items()), "each card reads its answer, its route or nothing once ended", {k: lines[k] for k in want})
    label = page.evaluate("document.querySelector('.card[data-key=\"demo-4-bf_alice\"]').getAttribute('aria-label')")
    wall.check(label.endswith(f"Not ready: {reason}"), "the line is in the card's accessible name", label)
    bar = page.evaluate(BAR)
    wall.check(bar == {"bar": True, "count": "1 of 15 ready", "safe": False, "stop": True, "endAll": False}, "the bar counts only settled, idle sessions and offers Stop wrap-up only", bar)
    for density in ("compact", "comfortable"):
        pick(page, f".density label:has([value={density}])")
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
    wall.check(bar["count"] == "1 of 15 ready" and not bar["stop"] and lines["demo-4-bf_alice"].startswith("Not ready: ") and lines["demo-5-bf_isabella"] == "Ready", "the demo carries a request and its answers", [bar, lines["demo-4-bf_alice"]])
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


def open_portrait(page):
    page.locator(".card .look:not([hidden])").first.click()
    page.wait_for_function("document.getElementById('portrait').open")


LEDGER_STATE = """() => {
  const d = document.getElementById('ledger');
  const r = d.getBoundingClientRect();
  const box = (el) => {
    if (!el || !el.checkVisibility()) return null;
    const b = el.getBoundingClientRect();
    return [Math.round(b.left), Math.round(b.top), Math.round(b.right), Math.round(b.bottom)];
  };
  const lt = document.getElementById('ledger-tab');
  const cards = [...document.querySelectorAll('#wall .card')].map((c) => c.getBoundingClientRect());
  const covers = (t) => !!t && cards.some((c) => c.left < t[2] && c.right > t[0] && c.top < t[3] && c.bottom > t[1]);
  const hit = (el, t) => {
    if (!t) return false;
    const h = document.elementFromPoint((t[0] + t[2]) / 2, (t[1] + t[3]) / 2);
    return !!h && el.contains(h);
  };
  const tab = box(lt);
  return {
    open: d.open,
    modal: d.matches(':modal'),
    mode: d.dataset.mode ?? null,
    width: Math.round(r.width),
    left: Math.round(r.left),
    view: localStorage.getItem('klepsydra.ledger.view'),
    stored: localStorage.getItem('klepsydra.ledger.width'),
    text: localStorage.getItem('klepsydra.ledger.text'),
    zoom: d.querySelector('.ledger-content').style.zoom,
    reset: d.querySelector('.ledger-reset').textContent,
    smallerOff: d.querySelector('.ledger-smaller').getAttribute('aria-disabled'),
    largerOff: d.querySelector('.ledger-larger').getAttribute('aria-disabled'),
    queueStored: localStorage.getItem('klepsydra.queue.width'),
    queueText: localStorage.getItem('klepsydra.queue.text'),
    tab,
    queueTab: null,
    tabName: lt.getAttribute('aria-label'),
    tabHit: hit(lt, tab),
    tabCovers: covers(tab),
    cardsRight: Math.round(Math.max(...cards.map((c) => c.right))),
    wallRight: Math.round(document.getElementById('wall').getBoundingClientRect().right),
    edge: document.documentElement.clientWidth,
    mid: innerHeight / 2,
    expanded: document.getElementById('ledger-open').getAttribute('aria-expanded'),
    active: document.activeElement.id || document.activeElement.className,
    hscroll: document.documentElement.scrollWidth > innerWidth,
    docked: document.body.classList.contains('ledger-docked'),
    full: d.querySelector('.ledger-full').getAttribute('aria-pressed'),
    textButtons: [...d.querySelectorAll('.ledger-text button')].every((b) => b.checkVisibility()),
    now: Number(d.querySelector('[role=separator]').getAttribute('aria-valuenow')),
    scope: d.querySelector('.scope')?.textContent ?? null,
  };
}"""
LEDGER_SHUT = "!document.getElementById('ledger').open && document.getElementById('ledger-open').getAttribute('aria-expanded') === 'false'"
LEDGER_READ = "#ledger[open] .ledger-content table"


def ledger_grip(page):
    box = page.locator("#ledger .ledger-resize").bounding_box()
    return box["x"] + box["width"] / 2, box["y"] + 300


def tabs_stacked(st):
    """The Ledger's shut tab on the right edge, clear of the cards and clickable."""
    t = st["tab"]
    return (
        t is not None
        and t[2] == st["edge"]
        and min(t[2] - t[0], t[3] - t[1]) >= 24
        and st["tabName"] == "Open Ledger"
        and st["tabHit"]
        and not st["tabCovers"]
        and st["cardsRight"] <= t[0]
        and not st["hscroll"]
    )


def drag(page, grip, to_x, steps=15):
    x, y = grip
    page.mouse.move(x, y)
    page.mouse.down()
    page.mouse.move(to_x, y, steps=steps)
    page.wait_for_timeout(100)


def ledger_docks_wide_and_is_a_dialog_narrow(wall):
    """At 1920 the Ledger button docks the Ledger beside the wall, which gives
    up its room; at 945 it is a 600 px modal dialog. Either way it opens with
    focus on its title and Esc shuts it with focus back on the button."""
    for width, modal in ((1920, False), (945, True)):
        page = wall.open(width, 1000, 16 if width == 1920 else 8)
        page.focus("#ledger-open")
        page.keyboard.press("Enter")
        page.wait_for_selector(LEDGER_READ)
        page.wait_for_timeout(SETTLE_MS)
        st = page.evaluate(LEDGER_STATE)
        ok = (
            st["open"] and st["modal"] is modal and st["mode"] == ("modal" if modal else "docked")
            and st["expanded"] == "true" and st["active"] == "ledger-title" and not st["hscroll"]
            and st["width"] == (600 if modal else 480)
            and (modal or (st["docked"] and st["wallRight"] <= st["left"]))
            and page.get_by_role("dialog", name="Ledger").count() == 1
        )
        wall.check(ok, f"at {width} px the Ledger opens {'as a modal dialog' if modal else 'docked beside the wall'}", st)
        page.keyboard.press("Escape")
        page.wait_for_function(LEDGER_SHUT)
        shut = page.evaluate(LEDGER_STATE)
        wall.check(
            shut["active"] == "ledger-open" and not shut["docked"] and shut["view"] == "shut",
            f"at {width} px Esc shuts the Ledger, the wall gets its room back and focus returns to the button",
            shut,
        )
        page.close()


def ledger_gives_auto_its_room(wall):
    """Docked, the Ledger narrows the wall and Auto measures the narrower wall:
    eight comfortable cards fit 1920 but not 1440, so it turns compact and
    never scrolls. A drag of its separator measures once, on release."""
    page = wall.open(1920, 1000, 8)
    before = page.evaluate(STATE)
    page.click("#ledger-open")
    page.wait_for_selector(LEDGER_READ)
    page.wait_for_timeout(SETTLE_MS)
    docked = page.evaluate(STATE)
    wall.check(
        before["density"] == "comfortable" and docked["density"] == "compact" and not docked["scrolls"],
        "with the Ledger docked Auto measures the narrower wall: compact, no scroll",
        [before, docked],
    )
    page.evaluate("""() => {
      window.__measures = 0;
      new MutationObserver((m) => { window.__measures += m.length; })
        .observe(document.querySelector('.density label:has([value=auto])'), { attributes: true, attributeFilter: ['title'] });
    }""")
    drag(page, ledger_grip(page), 1920 - 680, steps=20)
    page.wait_for_timeout(SETTLE_MS)
    during = page.evaluate("({ measures: window.__measures, stored: localStorage.getItem('klepsydra.ledger.width') })")
    page.mouse.up()
    page.wait_for_timeout(SETTLE_MS)
    after = page.evaluate("({ measures: window.__measures, stored: localStorage.getItem('klepsydra.ledger.width') })")
    wall.check(
        during["measures"] == 0 and during["stored"] is None and abs(int(after["stored"] or 0) - 680) <= 2 and after["measures"] == 1,
        "a drag of the Ledger's separator stores its width and measures Auto once, on release",
        [during, after],
    )
    page.close()


def ledger_snaps_by_drag(wall):
    """Dragged past half its minimum the Ledger snaps shut to its tab, focus on
    the tab and its width untouched; dragged near the left edge it fills the
    window as a modal; a drag back out of full docks it where it drops."""
    page = wall.open(1920, 1000, 16)
    page.click("#ledger-tab")
    page.wait_for_selector(LEDGER_READ)
    opened = page.evaluate(LEDGER_STATE)
    wall.check(
        opened["open"] and opened["mode"] == "docked" and opened["width"] == 480 and opened["tab"] is None
        and opened["queueTab"] is None and opened["active"] == "ledger-title" and opened["view"] == "docked",
        "a click on the Ledger's tab docks it and focuses its title; both tabs go while it holds the edge",
        opened,
    )
    drag(page, ledger_grip(page), 1920 - 170)
    least = page.evaluate(LEDGER_STATE)
    page.mouse.move(1920 - 150, 300, steps=4)
    page.wait_for_timeout(100)
    over = page.evaluate(LEDGER_STATE)
    page.mouse.move(1919, 300, steps=10)
    page.mouse.up()
    page.wait_for_timeout(SETTLE_MS)
    shut = page.evaluate(LEDGER_STATE)
    wall.check(
        least["width"] == 320 and over["width"] <= 1 and over["open"]
        and not shut["open"] and tabs_stacked(shut) and shut["view"] == "shut" and shut["stored"] is None
        and not shut["docked"] and shut["expanded"] == "false" and shut["active"] == "ledger-tab",
        "a drag stops at 320, previews shut past 160, and on release snaps shut, the width untouched and the focus on its tab",
        [least["width"], over["width"], shut],
    )
    page.click("#ledger-tab")
    page.wait_for_selector(LEDGER_READ)
    drag(page, ledger_grip(page), 340, steps=20)
    held = page.evaluate(LEDGER_STATE)
    page.mouse.move(10, 300, steps=5)
    page.mouse.up()
    page.wait_for_timeout(SETTLE_MS)
    full = page.evaluate(LEDGER_STATE)
    wall.check(
        held["width"] == 1920 and full["open"] and full["modal"] and full["mode"] == "full" and full["width"] == 1920
        and full["left"] == 0 and full["full"] == "true" and full["textButtons"] and full["view"] == "full"
        and full["stored"] is None and not full["hscroll"],
        "a drag past 350 px from the left previews full, and on release fills the window as a modal with its text controls",
        [held["width"], full],
    )
    page.keyboard.press("Escape")
    page.wait_for_timeout(SETTLE_MS)
    esc = page.evaluate(LEDGER_STATE)
    page.click("#ledger .ledger-full")
    page.wait_for_timeout(SETTLE_MS)
    drag(page, ledger_grip(page), 1100, steps=20)
    page.mouse.up()
    page.wait_for_timeout(SETTLE_MS)
    dropped = page.evaluate(LEDGER_STATE)
    wall.check(
        esc["mode"] == "docked" and not esc["modal"] and esc["width"] == 480 and esc["active"] == "ledger-title"
        and dropped["mode"] == "docked" and dropped["width"] == 820 and dropped["stored"] == "820"
        and dropped["active"] == "ledger-resize",
        "Esc in full docks it; a drag right out of full docks it where it drops, focus kept on its separator",
        [esc, dropped],
    )
    page.close()


def ledger_separator_snaps_by_keyboard(wall):
    """The Ledger's separator is the APG window splitter: Enter shuts it to its
    tab and Enter there restores it; Home at the narrowest shuts it, End at
    the widest fills the window, and Enter in full docks it."""
    page = wall.open(1920, 1000, 8)
    page.click("#ledger-open")
    page.wait_for_selector(LEDGER_READ)
    sep = page.locator("#ledger [role=separator]")
    sep.focus()
    page.keyboard.press("ArrowLeft")
    page.keyboard.press("ArrowLeft")
    wider = page.evaluate(LEDGER_STATE)
    page.keyboard.press("Enter")
    page.wait_for_timeout(SETTLE_MS)
    entered = page.evaluate(LEDGER_STATE)
    page.keyboard.press("Enter")
    page.wait_for_selector(LEDGER_READ)
    restored = page.evaluate(LEDGER_STATE)
    wall.check(
        wider["width"] == 512 and wider["stored"] == "512" and wider["queueStored"] is None
        and not entered["open"] and entered["active"] == "ledger-tab" and tabs_stacked(entered)
        and restored["open"] and restored["width"] == 512 and restored["active"] == "ledger-title",
        "arrows step the Ledger alone; Enter on its separator shuts it to its tab, Enter on the tab restores it",
        [wider, entered, restored],
    )
    sep.focus()
    page.keyboard.press("Home")
    home = page.evaluate(LEDGER_STATE)
    page.keyboard.press("Home")
    page.wait_for_timeout(SETTLE_MS)
    home2 = page.evaluate(LEDGER_STATE)
    page.keyboard.press(" ")
    page.wait_for_selector(LEDGER_READ)
    spaced = page.evaluate(LEDGER_STATE)
    wall.check(
        home["now"] == 320 and home["open"] and not home2["open"] and home2["active"] == "ledger-tab"
        and home2["stored"] == "320" and spaced["open"] and spaced["width"] == 320,
        "Home reaches 320, a second Home shuts it, and Space on its tab reopens it at 320",
        [home, home2, spaced],
    )
    sep.focus()
    page.keyboard.press("End")
    end = page.evaluate(LEDGER_STATE)
    page.keyboard.press("End")
    page.wait_for_timeout(SETTLE_MS)
    end2 = page.evaluate(LEDGER_STATE)
    page.keyboard.press("Enter")
    page.wait_for_timeout(SETTLE_MS)
    out = page.evaluate(LEDGER_STATE)
    wall.check(
        end["now"] == 900 and not end["modal"]
        and end2["mode"] == "full" and end2["modal"] and end2["width"] == 1920 and end2["active"] == "ledger-resize"
        and out["mode"] == "docked" and out["width"] == 900 and out["active"] == "ledger-resize",
        "End reaches 900, a second End fills the window with focus kept on the separator, and Enter docks it again",
        [end, end2, out],
    )
    page.close()


def ledger_text_size(wall):
    """A-/A+ and the percentage set the Ledger's text size from 75% to 200%;
    Ctrl+= / Ctrl+- / Ctrl+0 act while it is open, Ctrl+wheel over it steps
    it, the cards never change, and the Queue's size is its own."""
    page = wall.open(1920, 1000, 8)
    page.keyboard.press("Control+Equal")
    closed = page.evaluate(LEDGER_STATE)
    wall.check(closed["zoom"] == "1" and closed["text"] is None and closed["queueText"] is None, "with both panels shut Ctrl+= changes nothing", closed)
    page.click("#ledger-open")
    page.wait_for_selector(LEDGER_READ)
    page.wait_for_timeout(SETTLE_MS)
    def name():
        return page.evaluate("Math.round(document.querySelector('#wall .card .name').getBoundingClientRect().height * 10)")

    card_name = name()
    page.keyboard.press("Control+Equal")
    page.keyboard.press("Control+Equal")
    up = page.evaluate(LEDGER_STATE)
    page.keyboard.press("Control+Minus")
    down = page.evaluate(LEDGER_STATE)["zoom"]
    page.keyboard.press("Control+0")
    reset = page.evaluate(LEDGER_STATE)
    wall.check(
        up["zoom"] == "1.25" and up["reset"] == "125%" and up["text"] == "1.25" and up["queueText"] is None
        and name() == card_name and down == "1.1" and reset["zoom"] == "1" and reset["text"] == "1",
        "Ctrl+= steps the Ledger 110% then 125%, Ctrl+- back, Ctrl+0 resets; the cards and the Queue keep their size",
        [up, down, reset],
    )
    for _ in range(6):
        page.click("#ledger .ledger-larger", force=True)
    most = page.evaluate(LEDGER_STATE)
    page.click("#ledger .ledger-reset")
    for _ in range(4):
        page.click("#ledger .ledger-smaller", force=True)
    least = page.evaluate(LEDGER_STATE)
    wall.check(
        most["zoom"] == "2" and most["largerOff"] == "true" and most["smallerOff"] == "false" and not most["hscroll"]
        and least["zoom"] == "0.75" and least["smallerOff"] == "true",
        "A+ stops at 200% and A- at 75%, each turning off there; nothing scrolls sideways",
        [most, least],
    )
    page.click("#ledger .ledger-reset")
    box = page.locator("#ledger .ledger-content").bounding_box()
    page.mouse.move(box["x"] + box["width"] / 2, box["y"] + 40)
    page.keyboard.down("Control")
    page.mouse.wheel(0, -100)
    page.wait_for_timeout(150)
    page.mouse.wheel(0, -100)
    page.keyboard.up("Control")
    page.wait_for_timeout(100)
    wheeled = page.evaluate(LEDGER_STATE)["zoom"]
    wall.check(wheeled == "1.25", "Ctrl+wheel over the Ledger steps a notch at a time", wheeled)
    page.locator("#ledger [role=separator]").focus()
    page.keyboard.press("Home")
    narrow = page.evaluate("""() => {
      const d = document.getElementById('ledger').getBoundingClientRect();
      const h = document.getElementById('ledger-title').getBoundingClientRect();
      const t = document.querySelector('#ledger .ledger-tools').getBoundingClientRect();
      return {
        inside: [...document.querySelectorAll('#ledger .ledger-tools button')].every((b) => { const r = b.getBoundingClientRect(); return r.width > 0 && r.left >= d.left && r.right <= d.right; }),
        apart: h.right <= t.left || h.bottom <= t.top,
        sideways: document.querySelector('#ledger .ledger-body').scrollWidth > document.querySelector('#ledger .ledger-body').clientWidth,
      };
    }""")
    wall.check(narrow["inside"] and narrow["apart"] and not narrow["sideways"], "at 320 px the Ledger's header buttons stay inside it, clear of the title, at 125%", narrow)
    page.close()
    page = wall.open(945, 1000, 8)
    page.click("#ledger-open")
    page.wait_for_selector(LEDGER_READ)
    page.keyboard.press("Control+Equal")
    modal = page.evaluate(LEDGER_STATE)
    wall.check(modal["zoom"] == "1.1" and modal["modal"], "as a dialog at 945 px the keys work", modal)
    page.close()


def ledger_chip_opens_on_a_session(wall):
    """A card's chip opens the docked Ledger on that session; another chip
    while it is open turns it to that one; Close returns focus to the chip;
    the Ledger button shuts the open Ledger; a snapshot reads it again."""
    page = wall.open(1920, 1000, 16)
    kallos = page.locator(".card[data-key='demo-2-af_bella'] .chip")
    kallos.click()
    page.wait_for_selector("#ledger .scope")
    st = page.evaluate(LEDGER_STATE)
    wall.check(
        st["open"] and st["mode"] == "docked" and "Showing Kallos only" in (st["scope"] or "") and st["active"] == "ledger-title",
        "a chip opens the docked Ledger on its session, focus on the title",
        st,
    )
    other = page.locator(".card:not([data-key='demo-2-af_bella']) .chip:not([hidden])").first
    who = other.evaluate("(c) => c.closest('.card').querySelector('.name').textContent")
    other.click()
    page.wait_for_function("(who) => document.querySelector('#ledger .scope')?.textContent.includes(`Showing ${who} only`)", arg=who)
    turned = page.evaluate(LEDGER_STATE)
    # Full and back keep the session and the opener: docked to full is no shut.
    page.click("#ledger .ledger-full")
    page.wait_for_timeout(SETTLE_MS)
    page.keyboard.press("Escape")
    page.wait_for_timeout(SETTLE_MS)
    turned["scope"] = page.evaluate("document.querySelector('#ledger .scope')?.textContent ?? null")
    page.click("#ledger .ledger-close")
    page.wait_for_function(LEDGER_SHUT)
    back = page.evaluate(ACTIVE)
    wall.check(
        turned["open"] and turned["active"] == "ledger-title" and f"Showing {who} only" in (turned["scope"] or "")
        and back["card"] == who and "chip" in back["cls"],
        "another chip turns the open Ledger to its session, which full and back keep; Close returns focus to that chip",
        [turned["scope"], back],
    )
    page.click("#ledger-open")
    page.wait_for_selector(LEDGER_READ)
    unfiltered = page.evaluate(LEDGER_STATE)["scope"]
    seen = wall.ledger_requests
    waited = 0
    while wall.ledger_requests <= seen and waited < 20000:
        page.wait_for_timeout(250)
        waited += 250
    read_again = wall.ledger_requests > seen
    page.click("#ledger-open")
    page.wait_for_function(LEDGER_SHUT)
    toggled = page.evaluate(LEDGER_STATE)
    wall.check(
        unfiltered is None and read_again and not toggled["open"] and toggled["active"] == "ledger-open",
        "the Ledger button opens it on every session (a closed filter is forgotten), a snapshot reads it again, and the button shuts it",
        [unfiltered, read_again, toggled],
    )
    page.close()


def ledger_old_and_narrow_state(wall):
    """Below the dock breakpoint a stored Ledger view starts shut, unforgotten,
    with no tab; docked is the 600 px dialog, full the whole window, and Esc
    steps back through them. A corrupt stored view or width is shut and 480."""
    def at(width, values):
        page = wall.browser.new_page(viewport={"width": width, "height": 1000})
        page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html?demo=8")
        page.evaluate("(v) => { localStorage.clear(); for (const [k, x] of Object.entries(v)) localStorage.setItem(k, x); }", values)
        page.reload()
        page.wait_for_function("document.querySelectorAll('#wall > .card').length === 8")
        page.wait_for_timeout(SETTLE_MS)
        return page

    page = at(1920, {"klepsydra.ledger.view": "banana", "klepsydra.ledger.width": "abc", "klepsydra.ledger.text": "x"})
    bad = page.evaluate(LEDGER_STATE)
    page.click("#ledger-tab")
    page.wait_for_selector(LEDGER_READ)
    bad_open = page.evaluate(LEDGER_STATE)
    wall.check(not bad["open"] and tabs_stacked(bad) and bad_open["width"] == 480 and bad_open["zoom"] == "1", "a corrupt Ledger view is shut with its tab; a corrupt width opens at 480, a corrupt size at 100%", [bad, bad_open])
    page.close()
    page = at(1920, {"klepsydra.ledger.view": "docked", "klepsydra.ledger.width": "5000"})
    big = page.evaluate(LEDGER_STATE)
    wall.check(big["open"] and big["mode"] == "docked" and big["width"] == 900 and not big["hscroll"], "a stored docked Ledger reopens at load; a width past the maximum is held to 900", big)
    page.close()

    page = at(945, {"klepsydra.ledger.view": "full", "klepsydra.ledger.width": "700"})
    start = page.evaluate(LEDGER_STATE)
    wall.check(not start["open"] and start["tab"] is None and start["queueTab"] is None and start["view"] == "full", "at 945 a stored full Ledger starts shut, with no tab, and is not forgotten", start)
    page.click("#ledger-open")
    page.wait_for_selector(LEDGER_READ)
    dialog = page.evaluate(LEDGER_STATE)
    page.click("#ledger .ledger-full")
    page.wait_for_timeout(SETTLE_MS)
    full = page.evaluate(LEDGER_STATE)
    page.keyboard.press("Escape")
    page.wait_for_timeout(SETTLE_MS)
    esc = page.evaluate(LEDGER_STATE)
    page.keyboard.press("Escape")
    page.wait_for_function(LEDGER_SHUT)
    shut = page.evaluate(LEDGER_STATE)
    wall.check(
        dialog["modal"] and dialog["mode"] == "modal" and dialog["width"] == 600 and dialog["textButtons"]
        and full["modal"] and full["mode"] == "full" and full["width"] == 945 and full["textButtons"] and not full["hscroll"]
        and esc["modal"] and esc["width"] == 600
        and not shut["open"] and shut["tab"] is None and shut["active"] == "ledger-open" and shut["stored"] == "700",
        "at 945 the Ledger is the 600 px dialog, Full screen the whole window, Esc steps back to the dialog then shut, its width kept",
        [dialog, full, esc, shut],
    )
    page.click("#ledger-open")
    page.wait_for_selector(LEDGER_READ)
    page.mouse.click(10, 500)  # the backdrop
    page.wait_for_function(LEDGER_SHUT)
    backdrop = page.evaluate(LEDGER_STATE)
    wide = wall.resize(page, 1920, 1000) and page.evaluate(LEDGER_STATE)
    wall.check(backdrop["active"] == "ledger-open" and tabs_stacked(wide), "the backdrop shuts the dialog, focus on the button; widened, both tabs show", [backdrop, wide])
    page.close()


def panels_reduced_motion(wall):
    """Under prefers-reduced-motion no panel or tab animates: not opening, not
    in a held drag's preview, not snapping; a transition either panel gains is
    zeroed by the page's reduced-motion rule."""
    page = wall.browser.new_page(viewport={"width": 1920, "height": 1000}, reduced_motion="reduce")
    page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html?demo=8")
    page.wait_for_function("document.querySelectorAll('#wall > .card').length === 8")
    # Any transition a panel or tab might gain later; the reduced-motion rule must still win.
    page.add_style_tag(content=".ledger, .ledger-tab, .ledger-body { transition: width 400ms, left 400ms, opacity 400ms, translate 400ms; }")
    moving = """() => {
      const parts = ['#ledger', '#ledger-tab'].map((s) => document.querySelector(s));
      const ours = document.getAnimations().filter((a) => parts.some((p) => p.contains(a.effect?.target)));
      return {
        running: ours.length,
        durations: parts.map((p) => getComputedStyle(p).transitionDuration),
      };
    }"""
    page.click("#ledger-tab")
    page.wait_for_selector(LEDGER_READ)
    opened = page.evaluate(moving)
    drag(page, ledger_grip(page), 1920 - 150)
    held = page.evaluate(moving)
    page.mouse.move(1919, 300, steps=5)
    page.mouse.up()
    snapped = page.evaluate(moving)
    still = all(m["running"] == 0 and all(d == "0s" for d in m["durations"]) for m in (opened, held, snapped))
    wall.check(still, "under reduced motion the panel and its tab neither animate nor transition, opening, dragging or snapping", [opened, held, snapped])
    page.close()


def ledger_button_keeps_focus(wall):
    """The Ledger button toggles: shutting a Ledger a chip opened keeps focus
    on the button; Close and Esc give it back to the chip, docked or as the
    narrow dialog."""
    page = wall.open(1920, 1000, 16)
    chip = page.locator(".card[data-key='demo-2-af_bella'] .chip")
    chip.click()
    page.wait_for_selector("#ledger .scope")
    page.click("#ledger-open")
    page.wait_for_function(LEDGER_SHUT)
    toggled = page.evaluate(ACTIVE)
    chip.click()
    page.wait_for_selector("#ledger .scope")
    page.keyboard.press("Escape")
    page.wait_for_function(LEDGER_SHUT)
    escaped = page.evaluate(ACTIVE)
    wall.check(
        toggled["id"] == "ledger-open" and escaped["card"] == "Kallos" and "chip" in escaped["cls"],
        "the Ledger button shuts a chip-opened Ledger with focus on the button; Esc returns it to the chip",
        [toggled, escaped],
    )
    page.close()
    page = wall.open(945, 1000, 8)
    chip = page.locator(".card[data-key='demo-2-af_bella'] .chip")
    chip.click()
    page.wait_for_selector("#ledger .scope")
    modal = page.evaluate("document.getElementById('ledger').matches(':modal')")
    page.keyboard.press("Escape")
    page.wait_for_function(LEDGER_SHUT)
    escaped = page.evaluate(ACTIVE)
    chip.click()
    page.wait_for_selector("#ledger .scope")
    page.click("#ledger .ledger-close")
    page.wait_for_function(LEDGER_SHUT)
    closed = page.evaluate(ACTIVE)
    wall.check(
        modal and escaped["card"] == "Kallos" and "chip" in escaped["cls"] and closed["card"] == "Kallos",
        "as the 945 px dialog, Esc and Close return focus to the chip that opened it",
        [modal, escaped, closed],
    )
    page.close()


REFLOW = """() => {
  const body = document.querySelector('#ledger .ledger-body');
  const edge = body.getBoundingClientRect().right;
  const over = [...document.querySelectorAll('#ledger .ledger-content *')]
    .filter((el) => el.getClientRects().length && el.getBoundingClientRect().right > edge + 0.5)
    .map((el) => el.tagName + '.' + el.className + ':' + Math.round(el.getBoundingClientRect().right - edge));
  return {
    zoom: document.querySelector('#ledger .ledger-content').style.zoom,
    width: Math.round(document.getElementById('ledger').getBoundingClientRect().width),
    sideways: body.scrollWidth - body.clientWidth,
    over: over.slice(0, 4),
  };
}"""


def ledger_reflows_at_every_size(wall):
    """No text size from 75% to 200% scrolls the Ledger sideways, docked at
    320 and 480 px or as the 600 px dialog: figures and tables reflow."""
    bad = []
    seen = 0
    for width, cards, at in ((1920, 8, (320, 480)), (945, 8, (600,))):
        page = wall.open(width, 1000, cards)
        page.click("#ledger-open")
        page.wait_for_selector(LEDGER_READ)
        for want in at:
            if width == 1920:
                sep = page.locator("#ledger [role=separator]")
                sep.focus()
                now = int(sep.get_attribute("aria-valuenow"))
                for _ in range(abs(want - now) // 16):
                    page.keyboard.press("ArrowRight" if want < now else "ArrowLeft")
            for _ in range(4):
                page.keyboard.press("Control+Minus")
            for step in range(9):
                if step:
                    page.keyboard.press("Control+Equal")
                st = page.evaluate(REFLOW)
                seen += 1
                if st["width"] != want or st["sideways"] > 0 or st["over"]:
                    bad.append(st)
        page.close()
    wall.check(seen == 27 and not bad, "no text size from 75% to 200% scrolls the Ledger sideways at 320, 480 or 600 px", bad[:4] or seen)


def github_links_open_through_the_app(wall):
    """On the desktop a card's GitHub mark and branch chip ask the app to open
    the page it has on record (the webview opens no new window); no popup."""
    page = open_app(wall)
    popups = []
    page.on("popup", lambda p: popups.append(p.url))
    card = page.locator(".card:has(.gh[href]):has(.branch[href])").first
    key = card.get_attribute("data-key")
    card.locator(".gh").click()
    card.locator(".branch").click()
    page.wait_for_timeout(300)
    calls = page.evaluate("window.__calls.filter(([c]) => c === 'open_github')")
    wall.check(
        calls == [["open_github", {"id": key, "branch": False}], ["open_github", {"id": key, "branch": True}]] and popups == [],
        "on the desktop the GitHub mark and the branch chip open through the app, with no new window",
        {"calls": calls, "popups": popups},
    )
    page.close()


def ledger_reads_bounded(wall):
    """An open Ledger reads the ledger at most once every 5 s however fast
    snapshots come, and catches up once after a burst."""
    page = open_app(wall, 1920, 1000)
    page.evaluate("""() => {
      const inv = window.__TAURI__.core.invoke;
      window.__reads = 0;
      window.__TAURI__.core.invoke = (cmd, args) => {
        if (cmd !== 'ledger_today') return inv(cmd, args);
        window.__reads++;
        return fetch('/scripts/fixtures/ledger-demo.json').then((r) => r.json()).then(({ at, ...v }) => v);
      };
    }""")
    page.click("#ledger-open")
    page.wait_for_selector(LEDGER_READ)
    opened = page.evaluate("window.__reads")
    for _ in range(20):
        page.evaluate("(s) => window.__channel.onmessage(s)", page.snapshot)
        page.wait_for_timeout(100)
    burst = page.evaluate("window.__reads") - opened
    page.wait_for_timeout(4000)
    caught = page.evaluate("window.__reads") - opened
    page.click("#ledger-open")
    page.wait_for_function(LEDGER_SHUT)
    shut = page.evaluate("window.__reads")
    for _ in range(5):
        page.evaluate("(s) => window.__channel.onmessage(s)", page.snapshot)
    page.wait_for_timeout(5500)
    after = page.evaluate("window.__reads") - shut
    wall.check(
        opened == 1 and burst == 0 and caught == 1 and after == 0,
        "20 snapshots in 2 s read the open Ledger once, 5 s after it opened; a shut one reads nothing",
        {"opened": opened, "during the burst": burst, "after 6 s": caught, "after shutting": after},
    )
    page.close()


def ledger_rolls_over_at_midnight(wall):
    """An open Ledger reads again just past local midnight with no snapshot
    to prompt it, even within 5 s of a snapshot's read, and again the next
    night. After a sleep across midnight (the date moves, no timer fires) the
    wall's next tick reads it once, and the timer armed before the sleep
    never reads again; a page coming back into view after another sleep reads
    at once. A shut Ledger does not read.

    The page loads at 23:59:22 and the clock is paused at 23:59:30, so real
    time spent loading (under 8 s, or pause_at raises) cannot move it. The
    wall's 15 s ticks then fall that load time after :37, :52, :07 and :22,
    never at 00:00:00 to 00:00:02, so only the midnight timer can read there. After a
    fast_forward the ticks restart from where it lands."""
    import datetime
    import time

    fixture = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    at = fixture.pop("at")
    snapshot = shifted(fixture, int(time.time()) - at)
    utc = datetime.UTC
    page = wall.browser.new_page(viewport={"width": 1920, "height": 1000}, timezone_id="UTC")
    page.clock.install(time=datetime.datetime(2026, 10, 27, 23, 59, 22, tzinfo=utc))
    page.add_init_script(TAURI_STUB % json.dumps(snapshot))
    page.add_init_script("""(() => {
      const inv = window.__TAURI__.core.invoke;
      window.__reads = 0;
      window.__TAURI__.core.invoke = (cmd, args) => {
        if (cmd !== 'ledger_today') return inv(cmd, args);
        window.__reads++;
        return fetch('/scripts/fixtures/ledger-demo.json').then((r) => r.json()).then(({ at, ...v }) => v);
      };
    })()""")
    page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html")
    page.wait_for_function("document.querySelectorAll('#wall > .card').length > 0")
    page.click("#ledger-open")
    page.wait_for_selector(LEDGER_READ)
    page.clock.pause_at(datetime.datetime(2026, 10, 27, 23, 59, 30, tzinfo=utc))

    def reads():
        return page.evaluate("window.__reads")

    opened = reads()
    page.clock.run_for(28000)  # 23:59:58, no snapshot: no read
    quiet = reads()
    page.evaluate("(s) => window.__channel.onmessage(s)", snapshot)  # its read is due at once
    page.wait_for_timeout(100)
    snapped = reads()
    page.clock.run_for(4000)  # 00:00:02, 3 s after that read: only the midnight timer reads
    page.wait_for_timeout(100)
    rolled = reads()
    page.clock.fast_forward("23:59:56")  # 23:59:58 the next night
    page.wait_for_timeout(100)
    eve = reads()
    page.clock.run_for(4000)  # 00:00:02
    page.wait_for_timeout(100)
    second = reads()
    page.clock.set_system_time(datetime.datetime(2026, 10, 30, 9, 0, 0, tzinfo=utc))  # slept past a midnight
    page.clock.run_for(16000)  # one tick
    page.wait_for_timeout(100)
    woke = reads()
    page.clock.fast_forward("14:59:40")  # 23:59:56 that night
    page.clock.run_for(10000)  # past 00:00:01
    page.wait_for_timeout(100)
    third = reads()
    page.clock.fast_forward("10:00:00")  # when the timer armed before the sleep was due
    page.wait_for_timeout(100)
    no_stray = reads()
    page.clock.set_system_time(datetime.datetime(2026, 11, 1, 8, 0, 0, tzinfo=utc))  # slept again, the page hidden
    page.evaluate("""() => {
      Object.defineProperty(document, 'hidden', { value: false, configurable: true });
      document.dispatchEvent(new Event('visibilitychange'));
    }""")
    page.wait_for_timeout(100)
    shown = reads()
    page.click("#ledger-open")
    page.wait_for_function(LEDGER_SHUT)
    page.clock.fast_forward("24:00:00")
    page.wait_for_timeout(100)
    shut = reads()
    got = [opened, quiet, snapped, rolled, eve, second, woke, third, no_stray, shown, shut]
    wall.check(
        got == [1, 1, 2, 3, 3, 4, 5, 6, 6, 7, 7],
        "an open Ledger reads again just past each midnight, not held back by the 5 s bound, once after a sleep across one and when shown again; a shut one does not",
        dict(zip(["opened", "23:59:58", "snapshot", "00:00:02", "next 23:59:58", "next 00:00:02", "woke 09:00",
                  "that midnight", "no stray read", "shown after a sleep", "a day shut"], got, strict=True)),
    )
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
    want = {"cards": cards, "density": "compact", "columns": columns, "scrolls": False}
    ok = {k: got.get(k) for k in want} == want and got["bottom"] <= height
    wall.check(ok, f"fit {width}x{height} with the split toggle", got)
    # #248: Split sits in the bar's right group, beside New session.
    grouped = page.evaluate("!!document.querySelector('.bar-right #split')")
    wall.check(grouped, "the split toggle sits in the bar's right group", grouped)
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
    # Shots of the bar for AJ (#159): KLEPSYDRA_SPLIT_SHOT=<dir>/<prefix>, -on.png and -off.png added.
    shot = os.environ.get("KLEPSYDRA_SPLIT_SHOT")
    # The toolbar row, from the left edge to past the toggle's note.
    bar = """() => { const r = (id) => document.getElementById(id).getBoundingClientRect();
      const b = r('split'), n = r('split-note'), top = Math.min(b.top, n.top) - 12;
      return { x: 0, y: Math.max(0, top), width: innerWidth, height: Math.max(b.bottom, n.bottom) - top + 24 }; }"""
    if shot:
        page.screenshot(path=f"{shot}-on.png", clip=page.evaluate(bar))
    said = "Split off: the fleet terminal was maximized, so both windows stay where they are."
    page.evaluate("(n) => window.__split.onmessage({ on: false, note: n })", said)
    page.wait_for_timeout(100)
    left = page.evaluate(state)
    calls = page.evaluate("window.__calls.filter(([c]) => c.endsWith('split_mode'))")
    ok = left[1] == "false" and left[4] == said and len(calls) == 2
    wall.check(ok, "a window leaving the split unchecks the toggle and says why, with nothing put back", [left, calls])
    if shot:
        page.screenshot(path=f"{shot}-off.png", clip=page.evaluate(bar))
    page.click("#split")
    page.wait_for_timeout(100)
    again = page.evaluate(state)
    calls = page.evaluate("window.__calls.filter(([c]) => c.endsWith('split_mode'))")
    wall.check(again[1] == "true" and calls[-1] == ["set_split_mode", {"on": True}], "one click snaps it back", [again, calls])
    page.close()


CI_RED = {
    "observed_at": 1800000000, "stale": False, "repos": 14, "dependabot": 2, "unread": 0,
    "red": [
        {"repo": "pharos", "workflow": "CI", "branch": "main", "pr": None, "conclusion": "failure",
         "at": "2026-10-29T03:00:00Z", "url": "https://github.com/ajbarea/pharos/actions/runs/5",
         "failing": {"job": "lint-and-test (3.12)", "step": "pytest"},
         "triage": {"state": "done", "cause": "test_the_validator_resolves_the_distribution fails: the distribution URL 404s",
                    "location": "tests/test_croissant_validation.py:41"}},
        {"repo": "klepsydra", "workflow": "CI Pipeline", "branch": "fix/split", "pr": 160, "conclusion": "failure",
         "at": "2026-10-29T03:05:00Z", "url": "https://github.com/ajbarea/klepsydra/actions/runs/7",
         "failing": {"job": "Rust (windows-latest)", "step": "cargo test"},
         "triage": {"state": "pending", "cause": None, "location": None}},
    ],
}


def ci_watch(wall):
    """The bar's CI button: hidden with no CI watch, green when all is, red with
    a popover naming each red run's repo, step and cause, and a link to the run."""
    page = open_app(wall, 1920, 1000)
    state = """() => { const b = document.getElementById('ci-open'), p = document.getElementById('ci');
      return { hidden: b.hidden, label: b.textContent, tone: b.dataset.tone ?? null, open: p.matches(':popover-open'),
               rows: [...p.querySelectorAll('.ci-runs li')].map((li) => li.innerText.replace(/\\s+/g, ' ').trim()),
               links: [...p.querySelectorAll('.ci-runs a')].map((a) => [a.href, a.rel]),
               note: p.querySelector('.ci-note').textContent }; }"""
    got = page.evaluate(state)
    wall.check(got["hidden"], "no CI watch, no button", got)
    page.evaluate("(v) => window.__ci.onmessage(v)", {**CI_RED, "red": []})
    got = page.evaluate(state)
    wall.check([got["hidden"], got["label"], got["tone"]] == [False, "CI ok", "ok"], "all green reads CI ok", got)
    page.evaluate("(v) => window.__ci.onmessage(v)", CI_RED)
    page.click("#ci-open")
    page.wait_for_timeout(150)
    got = page.evaluate(state)
    ok = got["label"] == "CI 2 red" and got["tone"] == "red" and got["open"] and len(got["rows"]) == 2
    wall.check(ok, "red runs turn the button red and it opens their list", got)
    wall.check(
        "tests/test_croissant_validation.py:41" in got["rows"][0] and "pytest" in got["rows"][0]
        and "PR #160" in got["rows"][1] and "pending" in got["rows"][1],
        "each row names repo, branch or PR, failing step and the triaged cause",
        got["rows"],
    )
    titles = page.evaluate("[...document.querySelectorAll('#ci .ci-head')].map((h) => h.title)")
    wall.check(
        got["links"] == [] and titles == ["https://github.com/ajbarea/pharos/actions/runs/5", "https://github.com/ajbarea/klepsydra/actions/runs/7"],
        "on the desktop, which cannot open a link yet, each run's address is its tooltip",
        [got["links"], titles],
    )
    shot = os.environ.get("KLEPSYDRA_CI_SHOT")
    if shot:
        page.screenshot(path=f"{shot}-red.png", clip={"x": 0, "y": 0, "width": 1920, "height": 420})
    page.keyboard.press("Escape")
    page.wait_for_timeout(100)
    wall.check(not page.evaluate(state)["open"], "Escape closes it", None)
    page.evaluate("(v) => window.__ci.onmessage(v)", {**CI_RED, "stale": True})
    got = page.evaluate(state)
    wall.check([got["label"], got["tone"]] == ["CI ?", "stale"], "a watch that stopped reporting says so", got)
    page.evaluate("(v) => window.__ci.onmessage(v)", CI_RED)
    page.click("#ci-open")
    page.evaluate("(v) => window.__ci.onmessage(v)", {**CI_RED, "red": [], "dependabot": 0})
    got = page.evaluate(state)
    wall.check(got["hidden"] and not got["open"], "all green while the list is open hides the button and closes the list with it", got)
    page.evaluate("() => window.__ci.onmessage(null)")
    wall.check(page.evaluate(state)["hidden"], "the file gone hides the button again", None)
    calls = page.evaluate("window.__calls.filter(([c]) => c === 'ci_subscribe')")
    wall.check(calls == [], "subscribing is a read, not an action", calls)
    page.close()


HEALTH = {
    "observed_at": 0, "stale": False, "failed": 1, "warned": 1,
    "checks": [
        {"status": "FAIL", "check": "pane watcher", "detail": "none running: the orchestrator is not woken when an agent finishes"},
        {"status": "warn", "check": "briefs", "detail": "stale: task-demo.src (fleet brief --check)"},
        {"status": "ok", "check": "resume service", "detail": "active"},
        {"status": "ok", "check": "remote control %0 (orchestrator)", "detail": "(link)"},
        {"status": "ok", "check": "phone wall", "detail": "fleet.json observed 4 s ago"},
    ],
}


AGY = [
    {"id": "gemini-3.8-flash-high", "label": "Gemini 3.8 Flash (High)", "group": "gemini"},
    {"id": "gemini-3.8-flash-medium", "label": "Gemini 3.8 Flash (Medium)", "group": "gemini"},
    {"id": "gemini-3.8-flash-low", "label": "Gemini 3.8 Flash (Low)", "group": "gemini"},
    {"id": "claude-sonnet-4-6", "label": "Claude Sonnet 4.6 (Thinking)", "group": "3p"},
    {"id": "claude-opus-4-6-thinking", "label": "Claude Opus 4.6 (Thinking)", "group": "3p"},
    {"id": "gpt-oss-120b-medium", "label": "GPT-OSS 120B (Medium)", "group": "3p"},
]
PERSONAL = "6f5fe38b-9f23-4588-b57a-6efd1225cadd"
RIT = "96130a18-106b-49a2-9b8e-a0b4d52aa214"


def readings(claude_gpt=0):
    """read_usage's answer as on AJ's PC (11-19): a file per session, the
    account's uuid and organisation label, agy under agy-primary; times from now."""
    now = int(time.time())

    def r(account, label, session, ago, windows, **extra):
        return {"account": account, "label": label, "session": session, "written_at": now - ago,
                "observed_at": now - ago, "api_ms": 1000, "windows": windows, **extra}

    return [
        r(PERSONAL, "Personal", "537f9cf4", 15, {"five_hour": {"used_percentage": 3, "resets_at": now + 15400},
                                                 "seven_day": {"used_percentage": 57, "resets_at": now + 380200}}),
        r(PERSONAL, "Personal", "1111aaaa", 900, {"five_hour": {"used_percentage": 1, "resets_at": now + 15400},
                                                  "seven_day": {"used_percentage": 55, "resets_at": now + 380200}}),
        r(RIT, "RIT-CS-DQL", "14887126", 13, {"five_hour": {"used_percentage": 7, "resets_at": now + 4600},
                                              "seven_day": {"used_percentage": 28, "resets_at": now + 553000}}),
        r("agy-primary", "Google AI Pro", "0e9aa7fa", 95,
          {"five_hour": {"used_percentage": 25.95, "resets_at": now + 10316},
           "seven_day": {"used_percentage": 31.81, "resets_at": now + 543116},
           "claude_gpt": {"used_percentage": claude_gpt, "resets_at": now + 17905}}, harness="agy"),
    ]


ENGINES = {"claude": [PERSONAL, RIT], "agy": True, "copilot": True}


def ns_open(wall, width=1920, height=1000, agy=AGY, engines=ENGINES, prefs=None, usage=None, scheme="dark"):
    init = (
        f"window.__agy = {json.dumps(agy)}; window.__engines = {json.dumps(engines)};"
        f"window.__usage = {json.dumps(usage if usage is not None else readings())};"
        f"window.__nsprefs = {json.dumps(prefs or {'default': None, 'last': None})};"
    )
    page = open_app(wall, width=width, height=height, init=init)
    page.emulate_media(color_scheme=scheme)
    page.wait_for_timeout(300)
    return page


MENU_ROWS = "[...document.querySelectorAll('#new-menu .eng')].map((e) => e.querySelector('.eng-name').textContent)"
FOCUS_KEY = "document.activeElement === document.body ? 'body' : (document.activeElement.dataset.fk || document.activeElement.id)"


def new_session_menu(wall):
    """+ New session (#440, Variant A) on the desktop snapshot, which carries no
    readings: room comes from read_usage, accounts from the launcher's engine
    list, the default and last used from prefs.json. The main button names the
    default engine; the caret lists the others, Recommended first; focus stays
    on what the keyboard pressed through every redraw, and Escape returns it to
    the caret. Set $KLEPSYDRA_NS_SHOTS=1 for shots under shots/<date>/."""
    # The desktop snapshot has no usage; the menu's room is read_usage's.
    page = ns_open(wall, prefs={"default": None, "last": f"claude:{RIT}"})
    wall.check("usage" not in page.snapshot, "the desktop snapshot carries no readings", list(page.snapshot))
    btn = page.locator("#new-session")
    wall.check(btn.inner_text().split() == ["New", "Claude", "session", "RIT"] and btn.get_attribute("title") == "Claude on RIT: 72% of the week left",
               "the button names the engine last started and its account, its room in the title (the week binds)", [btn.inner_text(), btn.get_attribute("title")])
    btn.click()
    page.wait_for_timeout(200)
    icons = page.evaluate("[...document.querySelectorAll('#new-session .ico svg, #new-menu .ico svg')].map((s) => s.namespaceURI === 'http://www.w3.org/2000/svg' && s.getBoundingClientRect().width > 0)")
    wall.check(len(icons) >= 1 and all(icons), "the engine's logo draws on the button", icons)
    wall.check(calls(page, "launch_session") == [["launch_session", {"engine": "claude", "account": RIT}]],
               "the main button launches the default engine on its account", calls(page, "launch_session"))

    # Keyboard: Enter on the caret opens the menu with focus on its first row.
    page.focus("#new-kind")
    page.keyboard.press("Enter")
    page.wait_for_timeout(300)
    rows = page.evaluate(MENU_ROWS)
    wall.check(rows == ["Antigravity", "Claude on Personal", "Copilot"],
               "the menu lists the other engines, the free-first Recommended one first, never the default", rows)
    wall.check(page.evaluate(FOCUS_KEY) == "h:agy", "opening puts focus on the first row", page.evaluate(FOCUS_KEY))
    personal = page.locator("#new-menu .eng", has_text="Claude on Personal")
    wall.check(personal.locator(".room b").inner_text() == "43%" and personal.locator(".room-detail").inner_text().startswith("week · resets "),
               "an account's room is the reconciled reading's binding window, one row however many sessions", personal.locator(".room").inner_text())
    page.focus(f"#new-menu [data-fk='h:claude:{PERSONAL}']")
    page.keyboard.press("Enter")
    page.wait_for_timeout(200)
    wall.check(page.evaluate(FOCUS_KEY) == f"h:claude:{PERSONAL}" and personal.locator(".eng-h").get_attribute("aria-expanded") == "true",
               "Enter on a row opens it and focus stays on it through the redraw", page.evaluate(FOCUS_KEY))
    send(page, page.snapshot)
    wall.check(page.evaluate(FOCUS_KEY) == f"h:claude:{PERSONAL}", "a snapshot arriving while the menu is open keeps focus", page.evaluate(FOCUS_KEY))
    models = page.evaluate("[...document.querySelectorAll('#new-menu .eng.open .model-name')].map((e) => e.textContent)")
    wall.check(models == ["Opus", "Sonnet", "Fable"], "Claude's row offers its models", models)
    page.focus(f"#new-menu [data-fk='m:claude:{PERSONAL}:sonnet']")
    page.keyboard.press("Space")
    page.wait_for_timeout(150)
    wall.check(page.evaluate(FOCUS_KEY) == f"m:claude:{PERSONAL}:sonnet", "picking a model keeps focus on it", page.evaluate(FOCUS_KEY))
    page.keyboard.press("Escape")
    page.wait_for_timeout(150)
    wall.check(page.locator("#new-menu").is_hidden() and page.evaluate(FOCUS_KEY) == "new-kind", "Escape closes the menu and returns focus to the caret",
               page.evaluate(FOCUS_KEY))
    page.close()

    # agy: models in their quota groups; a spent group's models are off; Start sends the model.
    page = ns_open(wall, usage=readings(claude_gpt=100))
    page.click("#new-kind")
    page.wait_for_timeout(250)
    groups = page.evaluate("[...document.querySelectorAll('#new-menu .eng.open .mgrp')].map((e) => e.textContent)")
    wall.check(len(groups) == 2 and groups[0] == "Gemini · 74% of the session, 68% of the week" and groups[1].startswith("Claude & GPT · spent, back "),
               "agy's models sit under their quota groups, each with its room", groups)
    off = page.evaluate("[...document.querySelectorAll('#new-menu .eng.open .model input')].map((i) => i.disabled)")
    wall.check(off == [False, False, False, True, True, True], "only the spent group's models are off", off)
    wall.check("leaving agy" not in page.locator("#new-menu").inner_text(), "no stale 'leaving agy today' note", None)
    page.click("#new-menu .model:has(input[value='gemini-3.8-flash-low'])")
    page.click("#new-menu .eng.open .eng-start")
    page.wait_for_timeout(200)
    wall.check(calls(page, "launch_session") == [["launch_session", {"engine": "agy", "model": "gemini-3.8-flash-low"}]] and page.locator("#new-menu").is_hidden(),
               "Start sends one launch of agy on the model picked and closes the menu", calls(page, "launch_session"))
    # Set as default: saved through the app, the button follows, focus lands on the caret, not the page.
    page.click("#new-kind")
    page.wait_for_timeout(250)
    page.click("#new-menu .eng:has-text('Copilot') .eng-h")
    page.click("#new-menu .eng.open .eng-default")
    page.wait_for_timeout(200)
    wall.check(calls(page, "set_new_session_default") == [["set_new_session_default", {"id": "copilot"}]] and "New Copilot session" in page.inner_text("#new-session"),
               "Set as default saves it in the app's prefs and the button names it", [calls(page, "set_new_session_default"), page.inner_text("#new-session")])
    wall.check(page.evaluate(FOCUS_KEY) != "body", "focus never drops to the page when the default leaves the menu", page.evaluate(FOCUS_KEY))
    wall.check(page.locator("#new-menu .eng-reset").is_visible(), "a chosen default can be cleared from the menu", None)
    page.close()

    # The saved default is judged before the button acts: a click while the engine list is
    # still on its way starts nothing, then the button names the saved engine.
    page = open_app(wall, init=(f"window.__agy = {json.dumps(AGY)}; window.__engines = {json.dumps(ENGINES)};"
                                f"window.__usage = {json.dumps(readings())}; window.__enginesDelay = 1500;"
                                "window.__nsprefs = { default: 'copilot', last: null };"))
    page.wait_for_timeout(200)
    early = page.get_attribute("#new-session", "aria-disabled")
    page.click("#new-session", force=True)  # Playwright waits on an aria-disabled button
    page.wait_for_timeout(1800)
    wall.check(early == "true" and calls(page, "launch_session") == [] and "New Copilot session" in page.inner_text("#new-session")
               and page.get_attribute("#new-session", "aria-disabled") is None,
               "until the saved default can be judged the button is off and a click starts nothing; then it names it",
               [early, calls(page, "launch_session"), page.inner_text("#new-session")])
    # One launch at a time, through any repaint: a launch still running keeps the button off.
    page.evaluate("() => { window.__launchHold = new Promise(() => {}); }")  # returning the promise would wait on it
    page.click("#new-session")
    page.wait_for_timeout(150)
    page.click("#new-kind", force=True)  # off while the launch runs; the menu still opens, and repaints the button
    page.wait_for_timeout(250)
    page.keyboard.press("Escape")
    page.click("#new-session", force=True)
    page.wait_for_timeout(150)
    wall.check(len(calls(page, "launch_session")) == 1 and page.get_attribute("#new-session", "aria-disabled") == "true",
               "a repaint while a launch runs never turns the button back on", calls(page, "launch_session"))
    page.close()

    # Missing engines stay listed, off, with the step that fixes them; agy failing is an error, not a sign-in.
    page = ns_open(wall, agy=None, engines={"claude": [RIT], "agy": False, "copilot": False})
    page.click("#new-kind")
    page.wait_for_timeout(250)
    copilot = page.locator("#new-menu .eng", has_text="Copilot")
    wall.check(copilot.locator(".eng-acct").inner_text() == "Not installed on this PC" and copilot.locator(".eng-start:visible").count() == 0,
               "no agy or Copilot: each is listed off, nothing to start", copilot.inner_text())
    copilot.locator(".eng-fix").click()
    page.wait_for_timeout(150)
    wall.check(copilot.locator(".eng-step code").inner_text() == "npm install -g @github/copilot" and copilot.locator(".eng-fix").get_attribute("aria-expanded") == "true",
               "How to install shows the one command", copilot.locator(".eng-step").inner_text())
    personal = page.locator("#new-menu .eng", has_text="Claude on Personal")
    wall.check(personal.locator(".eng-acct").inner_text() == "Installed, not signed in" and personal.locator(".eng-fix").inner_text() == "Sign in",
               "an account with readings but no login here offers Sign in", personal.inner_text())
    page.close()
    page = open_app(wall, init=(f"window.__engines = {json.dumps(ENGINES)}; window.__usage = {json.dumps(readings())};"
                                "window.__agyError = 'agy models did not answer.';"))
    page.wait_for_timeout(300)
    page.click("#new-kind")
    page.wait_for_timeout(250)
    agy = page.locator("#new-menu .eng", has_text="Antigravity")
    wall.check(agy.locator(".eng-acct").inner_text() == "agy models did not answer." and agy.locator(".eng-fix").inner_text() == "Try again"
               and agy.locator(".rec").is_hidden(),
               "agy installed but failing says why and offers a retry, never 'not signed in', and is not Recommended", agy.inner_text())
    page.close()

    # Narrow: the button stays one line and clear of the gear, the bar inside the window. The
    # app's window is 420 at its narrowest (fleet.rs); 390 is the mockup's phone width.
    for width, height in ((1920, 1000), (420, 844), (390, 844)):
        for scheme in ("dark", "light"):
            page = ns_open(wall, width=width, height=height, prefs={"default": None, "last": f"claude:{RIT}"}, scheme=scheme)
            box = page.evaluate("""() => {
              const r = (s) => document.querySelector(s).getBoundingClientRect();
              const b = r('#new-session'), k = r('#new-kind'), g = r('.gear summary');
              const hit = (a, c) => a.left < c.right && c.left < a.right && a.top < c.bottom && c.top < a.bottom;
              const out = [...document.querySelectorAll('.bar *')].some((e) => e.checkVisibility() && e.getBoundingClientRect().right > innerWidth + 0.5);
              return { h: Math.round(b.height), gearHitsCaret: hit(k, g), wide: out };
            }""")
            wall.check(box["h"] <= 40 and not box["gearHitsCaret"] and not box["wide"],
                       f"{width} {scheme}: the split button is one line, the gear clear of the caret, the bar inside the window", box)
            if os.environ.get("KLEPSYDRA_NS_SHOTS"):
                out = ROOT / "shots" / time.strftime("%Y-%m-%d")
                out.mkdir(parents=True, exist_ok=True)
                page.screenshot(path=str(out / f"new-session-{width}-{scheme}-closed.png"))
            page.click("#new-kind")
            page.wait_for_timeout(250)
            menu = page.evaluate("""() => { const m = document.getElementById('new-menu').getBoundingClientRect();
              const k = document.getElementById('new-kind').getBoundingClientRect();
              return { top: Math.round(m.top - k.bottom), left: Math.round(m.left), right: Math.round(innerWidth - m.right) }; }""")
            wall.check(0 <= menu["top"] <= 12 and menu["left"] >= 0 and menu["right"] >= 0,
                       f"{width} {scheme}: the menu opens just under the caret, on screen", menu)
            if os.environ.get("KLEPSYDRA_NS_SHOTS"):
                page.screenshot(path=str(out / f"new-session-{width}-{scheme}-open.png"))
            page.close()


def gear_closes(wall):
    """The gear's view menu (#248) closes on Escape, giving focus back to the
    gear, and on a press outside it; a press inside it keeps it open."""
    page = open_app(wall, 1920, 1000)
    is_open = "document.querySelector('.gear').open"
    page.click(".gear summary")
    page.click(".gear label:has(input[value=compact])")
    wall.check(page.evaluate(is_open), "a choice inside the menu leaves it open", None)
    page.keyboard.press("Escape")
    got = page.evaluate("[document.querySelector('.gear').open, document.activeElement === document.querySelector('.gear summary')]")
    wall.check(got == [False, True], "Escape closes the menu and focus goes back to the gear", got)
    page.click(".gear summary")
    page.mouse.click(400, 600)
    wall.check(not page.evaluate(is_open), "a press outside closes the menu", None)
    page.close()


def fleet_health(wall):
    """The bar's Fleet button: hidden with no doctor reading and while every
    check is ok (#248: healthy is quiet), red with a popover listing each check, failing first, and
    "Fleet ?" once the reading is stale. Set $KLEPSYDRA_HEALTH_SHOT to a path
    stem for a screenshot of the open list."""
    page = open_app(wall, 1920, 1000)
    state = """() => { const b = document.getElementById('health-open'), p = document.getElementById('health');
      return { hidden: b.hidden, label: b.textContent, tone: b.dataset.tone ?? null, open: p.matches(':popover-open'),
               rows: [...p.querySelectorAll('.health-checks li')].map((li) => li.innerText.replace(/\\s+/g, ' ').trim()) }; }"""
    wall.check(page.evaluate(state)["hidden"], "no reading, no button", None)
    ok = {**HEALTH, "failed": 0, "warned": 0, "checks": [c for c in HEALTH["checks"] if c["status"] == "ok"]}
    page.evaluate("(v) => window.__health.onmessage(v)", ok)
    got = page.evaluate(state)
    # #248: healthy is quiet, so the bar hides the button while every check is ok.
    wall.check(got["hidden"], "all ok hides the button (healthy is quiet)", got)
    page.evaluate("(v) => window.__health.onmessage(v)", HEALTH)
    page.click("#health-open")
    page.wait_for_timeout(150)
    got = page.evaluate(state)
    wall.check(
        got["label"] == "Fleet 1 failing" and got["tone"] == "red" and got["open"] and len(got["rows"]) == 5,
        "a failing check turns it red and it opens the list",
        got,
    )
    wall.check(got["rows"][0].startswith("Failing pane watcher"), "failing checks first", got["rows"])
    shot = os.environ.get("KLEPSYDRA_HEALTH_SHOT")
    if shot:
        page.screenshot(path=f"{shot}.png", clip={"x": 1920 - 600, "y": 0, "width": 600, "height": 420})
    page.keyboard.press("Escape")
    page.evaluate("(v) => window.__health.onmessage(v)", {**HEALTH, "stale": True})
    got = page.evaluate(state)
    wall.check([got["label"], got["tone"]] == ["Fleet ?", "stale"], "a doctor that stopped running says so", got)
    page.evaluate("(v) => window.__health.onmessage(v)", HEALTH)
    page.click("#health-open")
    page.evaluate("(v) => window.__health.onmessage(v)", ok)
    got = page.evaluate(state)
    wall.check(got["hidden"] and not got["open"], "all ok while the list is open hides the button and closes the list with it", got)
    calls = page.evaluate("window.__calls.filter(([c]) => c === 'health_subscribe')")
    wall.check(calls == [], "subscribing is a read, not an action", calls)
    page.close()


THEMES = {t: json.loads((ROOT / f"src/fleet/themes/{t}.json").read_text()) for t in ("kourai", "professions", "dicebear")}
# Each card's voice key, name, face, epithet and accent; the picker; the keeper.
LOOKS = """() => ({
  cards: [...document.querySelectorAll('#wall .card')].map((c) => ({
    key: c.dataset.key,
    name: c.querySelector('.name').textContent,
    face: c.querySelector('.face').getAttribute('src'),
    epithet: c.querySelector('.epithet').hidden ? null : c.querySelector('.epithet').textContent,
    accent: c.style.getPropertyValue('--accent'),
    figure: c.classList.contains('has-figure'),
  })),
  picker: document.getElementById('theme').value,
  options: [...document.getElementById('theme').options].map((o) => [o.value, o.textContent]),
  keeper: document.querySelector('.keeper').getAttribute('src'),
  focus: document.activeElement.className,
  theme: document.documentElement.dataset.theme,
})"""
SAVE_MS = int(re.search(r"THEME_SAVE_MS = (\d+)", (ROOT / "src/fleet/theme.js").read_text()).group(1))


def worn(wall, page, theme, got, what):
    """Each cast card wears `theme`'s name, face and epithet; the picker and keeper agree."""
    cast = THEMES[theme]["characters"]
    voices = {s["session_id"]: s.get("voice") for s in page.snapshot_all}
    cards = [c for c in got["cards"] if voices.get(c["key"]) in cast]
    def ok(c):
        ch = cast[voices[c["key"]]]
        return (
            c["name"] == ch["name"]
            and c["face"] == f"fleet/faces/{theme}/{ch['face']}-192.webp"
            and c["epithet"] == ch.get("epithet")
            and c["figure"] == ("head" in ch)
            and c["accent"] == ch["accent"]
        )
    wrong = [c for c in cards if not ok(c)]
    keeper = f"fleet/faces/{theme}/{cast[THEMES[theme]['keeper']]['face']}-full.webp"
    wall.check(cards and not wrong and got["picker"] == theme and got["keeper"] == keeper, f"{what}: every cast card wears {theme}", [wrong[:2], got["picker"], got["keeper"]])


def gauge_opacity_slider(wall):
    """Gauge background (#438): the gear's slider shows the saved opacity; arrow
    steps show at once and are saved once, where the slider rests; with no push
    back from the app (Tauri does not order one before the reply) the thumb
    stays where it was asked."""
    page = open_app(wall, 1920, 1000, init="window.__savedOpacity = 35;")
    open_gear(page)
    got = page.evaluate("[document.querySelector('.opacity-pick').hidden, document.getElementById('gauge-opacity').value, document.querySelector('.opacity-value').textContent, document.getElementById('gauge-opacity').getAttribute('aria-valuetext')]")
    wall.check(got == [False, "35", "35%", "35%"], "the slider shows the saved opacity, in words too", got)
    box = page.locator("#gauge-opacity").bounding_box()
    wall.check(box is not None and box["height"] >= 24, "the slider is a real target", box)
    before = len(page.evaluate("window.__calls"))
    page.focus("#gauge-opacity")
    for _ in range(3):
        page.keyboard.press("ArrowRight")
    early = page.evaluate("window.__calls")[before:]
    shown = page.evaluate("document.querySelector('.opacity-value').textContent")
    page.wait_for_timeout(600)
    calls = page.evaluate("window.__calls")[before:]
    value = page.evaluate("document.getElementById('gauge-opacity').value")
    wall.check(early == [] and shown == "50%" and calls == [["set_gauge_opacity", {"opacity": 50}]] and value == "50",
               "arrow steps show at once and save once, where the slider rests; the thumb stays", [early, shown, calls, value])


def themes_switch_live(wall):
    """Characters (#135): the saved theme arrives over theme_subscribe and the
    wall wears it; a switch from the tray (a new message) or the picker
    repaints every card's name, face and epithet at once and never its accent,
    order or focus; the picker asks the app to save it; an unknown theme is
    Kourai."""
    page = open_app(wall, 1920, 1000, theme="professions")
    got = page.evaluate(LOOKS)
    worn(wall, page, "professions", got, "the saved theme on load")
    wall.check(got["options"] == [["kourai", "Kourai"], ["professions", "Professions"], ["dicebear", "DiceBear"]],
               "the picker offers the three themes, Kourai first", got["options"])
    base = got
    page.locator(".card .jump:not([aria-disabled='true'])").first.focus()
    for theme in ("dicebear", "kourai", "professions"):
        page.evaluate("(t) => window.__theme.onmessage(t)", theme)
        page.wait_for_timeout(SETTLE_MS)
        got = page.evaluate(LOOKS)
        worn(wall, page, theme, got, "a tray switch, live")
        keys = [c["key"] for c in got["cards"]]
        wall.check(keys == [c["key"] for c in base["cards"]] and got["focus"] == "jump" and got["theme"] == theme,
                   f"{theme}: the same cards in the same order, focus kept, html[data-theme] set", [keys, got["focus"], got["theme"]])
    before = len(page.evaluate("window.__calls"))
    open_gear(page)
    page.select_option("#theme", "dicebear")
    page.wait_for_timeout(SETTLE_MS)
    worn(wall, page, "dicebear", page.evaluate(LOOKS), "the picker, at once")
    page.wait_for_timeout(SAVE_MS)
    calls = page.evaluate("window.__calls")[before:]
    wall.check(calls == [["set_theme", {"theme": "dicebear"}]], "the picker asks the app to save the theme, once", calls)
    # An arrow key over the closed picker wears each step at once and saves once, where it rests.
    before = len(page.evaluate("window.__calls"))
    page.focus("#theme")
    seen = []
    for _ in range(2):
        page.keyboard.press("ArrowUp")
        page.wait_for_timeout(120)
        seen.append(page.evaluate("[document.documentElement.dataset.theme, document.querySelector('#wall .card .name').textContent]"))
    early = page.evaluate("window.__calls")[before:]
    page.wait_for_timeout(SAVE_MS + 200)
    calls = page.evaluate("window.__calls")[before:]
    wall.check([t for t, _ in seen] == ["professions", "kourai"] and early == [] and calls == [["set_theme", {"theme": "kourai"}]],
               "arrow keys wear each theme at once and save once, where the picker rests", [seen, early, calls])
    page.evaluate("window.__theme.onmessage('dicebear')")
    page.wait_for_timeout(SETTLE_MS)
    page.evaluate("window.__theme.onmessage('dicebear')")
    page.wait_for_timeout(SETTLE_MS)
    wall.check(page.evaluate("window.__calls").count(["set_theme", {"theme": "dicebear"}]) == 1, "the app's echo saves nothing again", page.evaluate("window.__calls")[before:])
    for bad in ("Professions", "", "__proto__", None, 3):
        page.evaluate("(t) => window.__theme.onmessage(t)", bad)
        page.wait_for_timeout(100)
        got = page.evaluate(LOOKS)
        worn(wall, page, "kourai", got, f"an unknown theme {bad!r} is Kourai")
    pick(page, ".density label:has([value=compact])")
    page.wait_for_timeout(SETTLE_MS)
    page.evaluate("window.__theme.onmessage('professions')")
    page.wait_for_timeout(SETTLE_MS)
    worn(wall, page, "professions", page.evaluate(LOOKS), "a switch on the compact wall")
    page.close()


def themes_keeper_and_portrait(wall):
    """In each theme the empty wall's keeper is the theme's own and loads, and
    every cast card's portrait button opens its full picture, loaded (Kourai's
    portrait; the others' face drawn large), comfortable and compact."""
    for theme in THEMES:
        page = open_app(wall, 1920, 1000, keep=lambda s: False, theme=theme)
        page.wait_for_function("document.querySelector('.keeper').complete")
        got = page.evaluate("(() => { const k = document.querySelector('.keeper'); return [k.getAttribute('src'), k.naturalWidth, document.getElementById('empty').checkVisibility()]; })()")
        cast = THEMES[theme]["characters"]
        wall.check(got[0] == f"fleet/faces/{theme}/{cast['af_nicole']['face']}-full.webp" and got[1] >= 512 and got[2],
                   f"{theme}: the empty wall's keeper is the theme's and loads", got)
        page.close()
        page = open_app(wall, 1920, 1000, theme=theme)
        voices = {s["session_id"]: s.get("voice") for s in page.snapshot_all}
        for density in ("comfortable", "compact"):
            pick(page, f".density label:has([value={density}])")
            page.wait_for_timeout(SETTLE_MS)
            bad = []
            keys = [k for k in page.evaluate("[...document.querySelectorAll('#wall .card')].map((c) => c.dataset.key)") if voices.get(k) in cast]
            for key in keys:
                page.locator(f'.card[data-key="{key}"] .look').click()
                page.wait_for_function("document.getElementById('portrait').open && document.querySelector('#portrait .full').complete")
                got = page.evaluate("(() => { const i = document.querySelector('#portrait .full'); return [i.getAttribute('src'), i.naturalWidth, document.getElementById('portrait-name').textContent]; })()")
                ch = cast[voices[key]]
                if got != [f"fleet/faces/{theme}/{ch['face']}-full.webp", got[1], ch["name"]] or got[1] < 512:
                    bad.append(got)
                page.keyboard.press("Escape")
                page.wait_for_function("!document.getElementById('portrait').open")
            wall.check(keys and not bad, f"{theme}, {density}: each cast card opens its full picture", bad[:3])
        page.close()


def themes_fit(wall):
    """Each theme's comfortable wall still fits: four cards at 945x1000 and
    eight at 1920x1000, unscrolled, with the picker in the bar."""
    for theme in THEMES:
        for width, height, cards, columns in COMFORTABLE_FIT:
            page = wall.open(width, height, cards, query=f"&theme={theme}")
            pick(page, ".density label:has([value=comfortable])")
            page.wait_for_timeout(SETTLE_MS)
            got = page.evaluate(STATE)
            faces = page.evaluate("[...document.querySelectorAll('#wall .face')].map((f) => f.getAttribute('src'))")
            ok = got["density"] == "comfortable" and not got["scrolls"] and got["bottom"] <= height and got["columns"] == columns
            wall.check(ok and any(f.startswith(f"fleet/faces/{theme}/") for f in faces), f"{theme}: {cards} comfortable cards fit {width}x{height}", got)
            page.close()


EVERYWHERE = """(voices) => {
  const text = (sel) => document.querySelector(sel)?.textContent ?? '';
  const portrait = document.getElementById('portrait');
  return {
    theme: document.documentElement.dataset.theme,
    density: document.getElementById('wall').dataset.density,
    cards: [...document.querySelectorAll('#wall .card')].map((c) => ({
      key: c.dataset.key, name: c.querySelector('.name').textContent,
      face: c.querySelector('.face').getAttribute('src'), accent: c.style.getPropertyValue('--accent'),
      epithet: c.querySelector('.epithet').hidden ? null : c.querySelector('.epithet').textContent,
    })),
    portrait: portrait.open ? [text('#portrait-name'), portrait.querySelector('.full').getAttribute('src'), text('#portrait .epithet')] : null,
    ledger: document.getElementById('ledger').open ? text('#ledger section[aria-labelledby=ledger-characters]') : null,
    docked: document.getElementById('ledger').dataset.mode,
    keeper: document.querySelector('.keeper').getAttribute('src'),
  };
}"""


def theme_everywhere(wall):
    """One switch, every surface: with the Ledger docked and a portrait open,
    each theme in turn shows only its own names, faces, epithets and accents
    on the cards (Comfortable and Compact), in the portrait, in the Ledger's
    Tokens by character and in the empty wall's keeper, and the Ledger is
    not read again for it."""
    page = wall.open(1920, 1000, 16)
    pick(page, ".density label:has([value=comfortable])")
    page.click("#ledger-open")
    page.wait_for_selector("#ledger section[aria-labelledby=ledger-characters]")
    page.wait_for_timeout(SETTLE_MS)
    reads = wall.ledger_requests
    voices = {s["session_id"]: s.get("voice") for s in json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())["sessions"]}
    ledger_voices = set(json.loads((ROOT / "scripts/fixtures/ledger-demo.json").read_text())["day"]["voices"].values())
    michael = next(k for k, v in voices.items() if v == "am_michael")
    page.locator(f'.card[data-key="{michael}"] .look').click()
    page.wait_for_function("document.getElementById('portrait').open")
    for density in ("comfortable", "compact"):
        if density == "compact":
            page.keyboard.press("Escape")
            page.wait_for_function("!document.getElementById('portrait').open")
            pick(page, ".density label:has([value=compact])")
            page.wait_for_timeout(SETTLE_MS)
        for theme in ("professions", "dicebear", "kourai"):
            # The portrait is modal, so the picker behind it is set as a script would.
            page.evaluate("(t) => { const p = document.getElementById('theme'); p.value = t; p.dispatchEvent(new Event('change')); }", theme)
            page.wait_for_timeout(SETTLE_MS)
            got = page.evaluate(EVERYWHERE)
            cast = THEMES[theme]["characters"]
            others = {c["name"] for t, th in THEMES.items() if t != theme for v, c in th["characters"].items() if c["name"] != cast[v]["name"]}
            bad = []
            for c in got["cards"]:
                ch = cast.get(voices.get(c["key"]))
                if ch and [c["name"], c["face"], c["accent"], c["epithet"]] != [ch["name"], f"fleet/faces/{theme}/{ch['face']}-192.webp", ch["accent"], ch.get("epithet")]:
                    bad.append(c)
            ledger_names = [cast[v]["name"] for v in ledger_voices if v in cast]
            stale = [n for n in others if n in (got["ledger"] or "")]
            portrait_ok = got["portrait"] is None if density == "compact" else got["portrait"] == [cast["am_michael"]["name"], f"fleet/faces/{theme}/{cast['am_michael']['face']}-full.webp", cast["am_michael"].get("epithet", "")]
            ok = (got["theme"] == theme and got["density"] == density and not bad and portrait_ok
                  and got["ledger"] and all(n in got["ledger"] for n in ledger_names) and not stale and got["docked"] == "docked"
                  and got["keeper"] == f"fleet/faces/{theme}/{cast['af_nicole']['face']}-full.webp")
            wall.check(ok, f"{density}, {theme}: cards, portrait, docked Ledger and keeper show only {theme}", {"bad": bad[:2], "portrait": got["portrait"], "stale": stale, "ledger": (got["ledger"] or "")[:160], "theme": got["theme"]})
    wall.check(wall.ledger_requests == reads, "no theme switch reads the Ledger again", [reads, wall.ledger_requests])
    page.close()


def refused_saves_say_so(wall):
    """A density prefs.json refused says so in the bar, as a refused theme
    does, and the next save that takes clears it (#484: a corrupt prefs.json
    reads as the defaults, so silence looked saved)."""
    page = open_app(wall)
    density = "prefs.json could not be saved, so the density is not kept."
    page.evaluate("(m) => { window.__fails = { set_wall_density: m }; }", density)
    open_gear(page)
    pick(page, ".density label:has([value=compact])")
    page.wait_for_timeout(SETTLE_MS)
    got = page.evaluate("[document.getElementById('density-note').textContent, document.getElementById('density-note').checkVisibility()]")
    wall.check(got == [f"Not saved: {density}", True], "a refused density save says why in the bar", got)
    page.evaluate("window.__fails = null")
    pick(page, ".density label:has([value=comfortable])")
    page.wait_for_timeout(SETTLE_MS)
    got = page.evaluate("[document.getElementById('density-note').textContent, document.getElementById('density-note').checkVisibility()]")
    wall.check(got == ["", False], "the next density save that takes clears the note", got)
    page.close()


def theme_save_flushes_and_says_when_refused(wall):
    """A choice still waiting to be saved is saved at once when the picker
    loses focus (a click on the tray's Quit takes it away), and only once; a
    save prefs.json refuses says so beside the picker, and the theme the app
    sends back is worn again."""
    page = open_app(wall, 1920, 1000)
    before = len(page.evaluate("window.__calls"))
    open_gear(page)
    page.focus("#theme")
    page.select_option("#theme", "professions")
    page.evaluate("document.getElementById('theme').blur()")
    page.wait_for_timeout(100)
    early = page.evaluate("window.__calls")[before:]
    page.wait_for_timeout(SAVE_MS + 200)
    late = page.evaluate("window.__calls")[before:]
    wall.check(early == [["set_theme", {"theme": "professions"}]] and late == early, "a blur saves the waiting choice at once, and once", [early, late])
    page.evaluate("window.__setThemeFails = 'prefs.json could not be written: the theme is still kourai, not dicebear.'")
    open_gear(page)
    page.select_option("#theme", "dicebear")
    page.wait_for_timeout(SAVE_MS + 200)
    page.evaluate("window.__theme.onmessage('kourai')")
    page.wait_for_timeout(SETTLE_MS)
    got = page.evaluate("[document.getElementById('theme-note').textContent, document.getElementById('theme-note').checkVisibility(), document.documentElement.dataset.theme, document.getElementById('theme').value]")
    wall.check(got == ["Not saved: prefs.json could not be written: the theme is still kourai, not dicebear.", True, "kourai", "kourai"],
               "a refused save says why, and the wall wears the theme the app kept", got)
    logs = page.evaluate("window.__logs ?? []")
    want = {
        "level": 5,
        "message": "set_theme refused theme dicebear: prefs.json could not be written: the theme is still kourai, not dicebear.",
        "location": "fleet/wall.js",
    }
    wall.check([{k: entry.get(k) for k in want} for entry in logs] == [want],
               "the refusal reaches the app's log once, at error, naming the theme and why", logs)
    page.evaluate("window.__setThemeFails = null")
    open_gear(page)
    page.select_option("#theme", "professions")
    page.wait_for_timeout(SAVE_MS + 200)
    note = page.evaluate("document.getElementById('theme-note').textContent")
    wall.check(note == "", "the next save clears the note", note)
    page.close()


# Keeps the first card the wall ever paints: its name and face as first drawn.
FIRST_CARD = """
new MutationObserver((_, obs) => {
  const card = document.querySelector('#wall .card');
  if (!card || window.__first) return;
  window.__first = { key: card.dataset.key, name: card.querySelector('.name').textContent, face: card.querySelector('.face').getAttribute('src'), theme: document.documentElement.dataset.theme };
  obs.disconnect();
}).observe(document, { childList: true, subtree: true });
"""


def hold_theme_until_fleet(page, theme):
    """Hold theme `theme`'s file (Kourai's comes with the page) and note when the demo fleet has arrived."""
    held = {"routes": [], "fleet": False}
    page.on("requestfinished", lambda r: r.url.endswith("fleet-demo.json") and held.__setitem__("fleet", True))
    if theme != "kourai":
        page.route(f"**/fleet/themes/{theme}.json", lambda r: held["routes"].append(r))
    return held


def release_after_fleet(page, held):
    """Let the held theme file go once the fleet is in and a page that did not
    wait would have painted; a page that waits fetches no fleet before its
    theme, so anyway a second before THEME_WAIT_MS, past the wall's 1.5 s
    wait for the app's word, so a fallback that cut the load short shows."""
    deadline = time.monotonic() + THEME_WAIT_MS / 1000 - 1
    while not held["fleet"] and time.monotonic() < deadline:
        page.wait_for_timeout(50)
    page.wait_for_timeout(400)
    for r in held["routes"]:
        r.continue_()


STRIP_FIRST = """
new MutationObserver((_, obs) => {
  const img = document.querySelector('#strip .face img');
  if (!img || !img.getAttribute('src') || window.__first) return;
  window.__first = { id: img.parentElement.dataset.id, face: img.getAttribute('src'), label: img.parentElement.getAttribute('aria-label') };
  obs.disconnect();
}).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
"""


def strip_first_paint(wall):
    """The gauge's strip first draws in the theme worn: with ?theme= and the
    theme's file arriving after the fleet, its first portrait already wears it."""
    voices = {s["session_id"]: s.get("voice") for s in json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())["sessions"]}
    for theme in ("professions", "dicebear"):
        page = wall.browser.new_page(viewport={"width": 1200, "height": 400})
        page.add_init_script(STRIP_FIRST)
        held = hold_theme_until_fleet(page, theme)
        page.goto(f"http://127.0.0.1:{wall.port}/src/index.html?demo&theme={theme}")
        release_after_fleet(page, held)
        painted(page, "!!window.__first")
        first = page.evaluate("window.__first")
        ch = THEMES[theme]["characters"].get(voices.get(first["id"]))
        ok = ch and first["face"].startswith(f"fleet/faces/{theme}/") and first["label"].startswith(f"{ch['name']},")
        wall.check(ok, f"{theme}: the strip's first portrait already wears it", first)
        page.close()


def theme_first_paint(wall):
    """With a saved theme, the first card the wall paints already wears it:
    no frame of another theme first, from the app's saved choice or a
    browser page's ?theme=."""
    voices = {s["session_id"]: s.get("voice") for s in json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())["sessions"]}
    for theme in THEMES:
        for how in ("app", "page"):
            if how == "app":
                page = open_app(wall, 1920, 1000, theme=theme, init=FIRST_CARD)
            else:
                # The theme's file arrives only after the fleet has: a wall that painted
                # before its theme would show its first card in Kourai.
                page = wall.browser.new_page(viewport={"width": 1920, "height": 1000})
                page.add_init_script(FIRST_CARD)
                held = hold_theme_until_fleet(page, theme)
                page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html?demo=8&theme={theme}")
                release_after_fleet(page, held)
                painted(page, "document.querySelectorAll('#wall > .card').length === 8")
            first = page.evaluate("window.__first")
            ch = THEMES[theme]["characters"].get(voices.get(first["key"])) if first else None
            ok = first and ch and first["name"] == ch["name"] and first["face"].startswith(f"fleet/faces/{theme}/") and first["theme"] == theme
            wall.check(ok, f"{theme} ({how}): the first card painted already wears it", first)
            page.close()


def theme_stale_load_leaves_the_choice(wall):
    """A load the picker has moved past changes nothing when it lands: with
    Professions and then DiceBear asked for and both files held, a page
    hidden meanwhile saves DiceBear the moment it is worn (not 600 ms
    later), and an older word from the app during DiceBear's load does not
    replace it."""
    for older in (False, True):
        page = open_app(wall, 1920, 1000)
        held = {}
        def keep(theme):
            return lambda route: held.__setitem__(theme, route)
        for theme in ("professions", "dicebear"):
            page.route(f"**/fleet/themes/{theme}.json", keep(theme))
        before = len(page.evaluate("window.__calls"))
        open_gear(page)
        page.select_option("#theme", "professions")
        page.select_option("#theme", "dicebear")
        page.wait_for_timeout(200)
        if older:
            page.evaluate("window.__theme.onmessage('kourai')")
        else:
            page.evaluate("dispatchEvent(new Event('pagehide'))")
        held["professions"].continue_()
        page.wait_for_timeout(200)
        held["dicebear"].continue_()
        page.wait_for_timeout(300)
        early = page.evaluate("window.__calls")[before:]
        page.wait_for_timeout(SAVE_MS + 200)
        late = page.evaluate("window.__calls")[before:]
        theme = page.evaluate("document.documentElement.dataset.theme")
        if older:
            wall.check(theme == "dicebear" and late == [["set_theme", {"theme": "dicebear"}]],
                       "an older word from the app during DiceBear's load leaves DiceBear, saved", [theme, late])
        else:
            wall.check(theme == "dicebear" and early == [["set_theme", {"theme": "dicebear"}]] and late == early,
                       "a page hidden while DiceBear loads saves it the moment it is worn, once", [theme, early, late])
        page.close()


THEME_WAIT_MS = int(re.search(r"THEME_WAIT_MS = (\d+)", (ROOT / "src/fleet/theme.js").read_text()).group(1))


def theme_file_that_never_answers(wall):
    """A theme file that never answers holds no surface blank: the wall
    paints within THEME_WAIT_MS (and a little) in Kourai, the note says the
    theme is still loading, and the theme takes over when its file comes,
    from the app's saved choice and from ?theme=; the gauge strip draws in
    Kourai and turns too. A theme picked before the app names one, which
    then fails, still lets the wall paint."""
    slack = 2.5
    for how in ("app", "page"):
        held = []
        t0 = time.monotonic()
        if how == "app":
            page = open_app(wall, 1920, 1000, theme="professions", before=lambda p: p.route("**/fleet/themes/professions.json", lambda r: held.append(r)))
        else:
            page = wall.browser.new_page(viewport={"width": 1920, "height": 1000})
            watch(page)
            page.route("**/fleet/themes/professions.json", lambda r: held.append(r))
            page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html?demo=8&theme=professions")
            painted(page, "document.querySelectorAll('#wall > .card').length === 8")
        took = time.monotonic() - t0
        got = page.evaluate("[document.documentElement.dataset.theme, document.querySelector('#wall .card .face').getAttribute('src'), document.getElementById('theme-note').textContent]")
        wall.check(held and took < THEME_WAIT_MS / 1000 + slack and got[0] == "kourai" and got[1].startswith("fleet/faces/kourai/") and got[2] == "Loading the Professions theme…",
                   f"{how}: a theme file that never answers: the wall paints in {took:.1f} s, in Kourai, and says it is loading", [took, got])
        for r in held:
            r.continue_()
        page.wait_for_timeout(600)
        got = page.evaluate("[document.documentElement.dataset.theme, document.querySelector('#wall .card .face').getAttribute('src'), document.getElementById('theme-note').textContent]")
        wall.check(got[0] == "professions" and got[1].startswith("fleet/faces/professions/") and got[2] == "",
                   f"{how}: when the file comes, the theme takes over and the note goes", got)
        page.close()
    # Picked before the app's word, then failed after it: the wall still paints.
    held = []
    t0 = time.monotonic()
    page = wall.browser.new_page(viewport={"width": 1920, "height": 1000})
    fixture = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    at = fixture.pop("at")
    page.add_init_script(TAURI_STUB % json.dumps(shifted(fixture, int(time.time()) - at)))
    page.add_init_script("window.__themeDelay = 500;")
    watch(page)
    page.route("**/fleet/themes/dicebear.json", lambda r: held.append(r))
    page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html")
    page.wait_for_function("document.getElementById('theme').options.length === 3")
    open_gear(page)
    page.select_option("#theme", "dicebear")
    page.wait_for_timeout(900)
    for r in held:
        r.abort()
    try:
        page.wait_for_function("document.querySelectorAll('#wall > .card').length > 0", timeout=int((THEME_WAIT_MS / 1000 + slack) * 1000))
        cards = page.evaluate("document.querySelectorAll('#wall > .card').length")
    except Exception:
        cards = 0
    note = page.evaluate("document.getElementById('theme-note').textContent")
    wall.check(cards > 0 and note == "Not switched: the DiceBear theme could not be loaded.", "a theme picked before the app's word that fails after it: the wall still paints, and says why", [cards, note, round(time.monotonic() - t0, 1)])
    page.close()
    # Picked before the app's word, its file never answering: the wall paints within THEME_WAIT_MS.
    held = []
    t0 = time.monotonic()
    page = wall.browser.new_page(viewport={"width": 1920, "height": 1000})
    page.add_init_script(TAURI_STUB % json.dumps(shifted(fixture, int(time.time()) - at)))
    page.add_init_script("window.__themeDelay = 500;")
    watch(page)
    page.route("**/fleet/themes/dicebear.json", lambda r: held.append(r))
    page.goto(f"http://127.0.0.1:{wall.port}/src/wall.html")
    page.wait_for_function("document.getElementById('theme').options.length === 3")
    open_gear(page)
    page.select_option("#theme", "dicebear")
    try:
        page.wait_for_function("document.querySelectorAll('#wall > .card').length > 0", timeout=int((THEME_WAIT_MS / 1000 + slack) * 1000))
        cards = page.evaluate("document.querySelectorAll('#wall > .card').length")
    except Exception:
        cards = 0
    took = time.monotonic() - t0
    note = page.evaluate("document.getElementById('theme-note').textContent")
    wall.check(held and cards > 0 and took < THEME_WAIT_MS / 1000 + slack and note == "Loading the DiceBear theme…",
               f"a theme picked before the app's word whose file never answers: the wall paints in {took:.1f} s and says it is loading", [cards, note])
    for r in held:
        r.continue_()
    page.wait_for_timeout(600)
    got = page.evaluate("[document.documentElement.dataset.theme, document.getElementById('theme-note').textContent]")
    wall.check(got == ["dicebear", ""], "and wears it when the file comes", got)
    page.close()
    # The gauge strip.
    held = []
    t0 = time.monotonic()
    page = wall.browser.new_page(viewport={"width": 1200, "height": 400})
    page.route("**/fleet/themes/professions.json", lambda r: held.append(r))
    page.goto(f"http://127.0.0.1:{wall.port}/src/index.html?demo&theme=professions")
    try:
        page.wait_for_function("!!document.querySelector('#strip .face img[src]')", timeout=int((THEME_WAIT_MS / 1000 + slack) * 1000))
        first = page.evaluate("document.querySelector('#strip .face img').getAttribute('src')")
    except Exception:
        first = None
    took = time.monotonic() - t0
    wall.check(held and first and first.startswith("fleet/faces/kourai/"), f"the strip draws in {took:.1f} s, in Kourai, while its theme's file never answers", first)
    for r in held:
        r.continue_()
    page.wait_for_timeout(600)
    now = page.evaluate("document.querySelector('#strip .face img')?.getAttribute('src')")
    wall.check(bool(now) and now.startswith("fleet/faces/professions/"), "and turns when the file comes", now)
    page.close()


STRIP_KEEPER = """
async () => {
  const { mountStrip } = await import('/src/fleet/strip.js');
  const { loadTheme } = await import('/src/fleet/theme.js');
  const old = document.getElementById('strip');
  const el = old.cloneNode(false);
  el.hidden = true;
  old.replaceWith(el);
  let cast = await loadTheme('professions');
  const render = mountStrip(el, { open() {}, cast: () => cast });
  window.__strip = { el, render, set: (c) => { cast = c; render([], Date.now()); }, bare: { ...cast, keeper: null } };
  render([], Date.now());
}
"""
STRIP_BOX = """() => {
  const b = document.querySelector('#strip .face.rest'), i = b.querySelector('img'), g = b.querySelector('.glyph');
  const box = (e) => { const r = e.getBoundingClientRect(), c = getComputedStyle(e); return { w: r.width, h: r.height, display: c.display, cx: r.left + r.width / 2, cy: r.top + r.height / 2 }; };
  return { button: box(b), img: box(i), src: i.getAttribute('src'), glyph: g && box(g) };
}"""


def strip_keeper_states(wall):
    """With no sessions the gauge strip is one button: the keeper's face, and for
    a theme with no keeper a plain wall mark that sits centred with no image
    sliver (badge.css's `.face img { display: block }` once beat [hidden]), also
    after a switch from a keeper, whose face must be gone."""
    page = wall.browser.new_page(viewport={"width": 1200, "height": 400})
    page.goto(f"http://127.0.0.1:{wall.port}/src/index.html?still=1&zoom=3&theme=professions")
    page.wait_for_selector("#strip", state="attached")
    page.evaluate(STRIP_KEEPER)
    page.wait_for_selector("#strip .face.rest img[src]")
    got = page.evaluate(STRIP_BOX)
    wall.check(got["img"]["display"] == "block" and got["img"]["w"] > 20 and not got["glyph"], "the keeper's face fills its button", got)
    shot = pathlib.Path(os.environ["STRIP_SHOTS"]) if os.environ.get("STRIP_SHOTS") else None
    if shot:
        page.locator("#strip").screenshot(path=str(shot / "keeper-strip-browser-keeper.png"))
    page.evaluate("window.__strip.set(window.__strip.bare)")
    got = page.evaluate(STRIP_BOX)
    centred = abs(got["glyph"]["cx"] - got["button"]["cx"]) < 1 and abs(got["glyph"]["cy"] - got["button"]["cy"]) < 1 if got["glyph"] else False
    ok = got["img"]["display"] == "none" and got["src"] is None and got["glyph"] and abs(got["glyph"]["w"] - got["glyph"]["h"]) < 1 and centred
    wall.check(ok, "switching to a theme with no keeper leaves a centred wall mark, no face and no image", got)
    if shot:
        page.locator("#strip").screenshot(path=str(shot / "keeper-strip-browser-switched-plain.png"))
    page.evaluate("window.__strip.el.replaceChildren(); window.__strip.render([], Date.now())")
    got = page.evaluate(STRIP_BOX)
    centred = abs(got["glyph"]["cx"] - got["button"]["cx"]) < 1 and abs(got["glyph"]["cy"] - got["button"]["cy"]) < 1 if got["glyph"] else False
    wall.check(got["img"]["display"] == "none" and got["glyph"] and centred, "a fresh plain button draws the same", got)
    if shot:
        page.locator("#strip").screenshot(path=str(shot / "keeper-strip-browser-fresh-plain.png"))
    page.close()


def theme_switch_commits_only_what_it_wore(wall):
    """A theme whose file fails to load is never worn, saved or sent: the
    wall keeps its theme, the picker goes back and the note says why. The
    last switch asked for wins over a slower load: Kourai to Professions
    (held) to DiceBear ends on DiceBear, and Kourai to Professions (held) and
    back ends on Kourai, each saving only the theme it ended on."""
    page = open_app(wall, 1920, 1000)
    page.route("**/fleet/themes/dicebear.json", lambda r: r.abort())
    before = len(page.evaluate("window.__calls"))
    open_gear(page)
    page.select_option("#theme", "dicebear")
    page.wait_for_timeout(SAVE_MS + 300)
    got = page.evaluate("[document.documentElement.dataset.theme, document.getElementById('theme').value, document.getElementById('theme-note').textContent, document.querySelector('#wall .card .face').getAttribute('src')]")
    calls = page.evaluate("window.__calls")[before:]
    wall.check(got[:3] == ["kourai", "kourai", "Not switched: the DiceBear theme could not be loaded."] and got[3].startswith("fleet/faces/kourai/") and calls == [],
               "a theme that fails to load is not worn, saved or sent, and says why", [got, calls])
    page.close()
    for path, want in ((["professions", "dicebear"], "dicebear"), (["professions", "kourai"], "kourai")):
        page = open_app(wall, 1920, 1000)
        held = []
        page.route("**/fleet/themes/professions.json", lambda r: held.append(r))
        before = len(page.evaluate("window.__calls"))
        open_gear(page)
        for theme in path:
            page.select_option("#theme", theme)
            page.wait_for_timeout(150)
        page.wait_for_function("document.documentElement.dataset.theme === '%s'" % want)
        for r in held:
            r.continue_()
        page.wait_for_timeout(SAVE_MS + 400)
        got = page.evaluate("[document.documentElement.dataset.theme, document.getElementById('theme').value, document.querySelector('#wall .card .face').getAttribute('src')]")
        calls = page.evaluate("window.__calls")[before:]
        wall.check(held and got[:2] == [want, want] and got[2].startswith(f"fleet/faces/{want}/") and calls == [["set_theme", {"theme": want}]],
                   f"kourai to {' to '.join(path)}, Professions held: ends on {want} and saves only it", [len(held), got, calls])
        page.close()


def theme_retry_waits_before_loading(wall):
    """Picked again after its file failed, a theme says "Loading…" only once
    that new pick has waited THEME_WAIT_MS: neither at once (a retry past the
    first pick's deadline) nor when the first pick's own wait ends (a retry
    soon after a quick failure). The failure ends the first pick's wait."""
    # Retried 1.5 s after a quick failure, the first pick's wait ends 1.5 s
    # into the retry's, inside the span sampled below.
    for gap, how in ((THEME_WAIT_MS + 300, "past the first pick's deadline"), (THEME_WAIT_MS // 2, "soon after a quick failure")):
        page = open_app(wall, 1920, 1000)
        tries = []

        def fail_first(tries):
            def route(r):  # one parameter: Playwright passes the request too to a handler that takes two
                tries.append(r)
                if len(tries) == 1:
                    r.abort()
            return route

        page.route("**/fleet/themes/dicebear.json*", fail_first(tries))  # a retry asks with ?retry=N
        open_gear(page)
        page.select_option("#theme", "dicebear")
        page.wait_for_function("document.getElementById('theme-note').textContent.startsWith('Not switched')")
        page.wait_for_timeout(gap)
        t0 = time.monotonic()
        open_gear(page)
        page.select_option("#theme", "dicebear")
        early = []
        while time.monotonic() - t0 < THEME_WAIT_MS / 1000 - 0.5:  # the note, sampled until just before the retry's own wait ends
            early.append(page.evaluate("document.getElementById('theme-note').textContent"))
            page.wait_for_timeout(100)
        page.wait_for_timeout(1000)
        late = page.evaluate("document.getElementById('theme-note').textContent")
        for r in tries[1:]:
            r.continue_()
        page.wait_for_function("document.documentElement.dataset.theme === 'dicebear'")
        after = page.evaluate("document.getElementById('theme-note').textContent")
        loading = [n for n in early if n.startswith("Loading")]
        wall.check(len(tries) == 2 and early and not loading and late == "Loading the DiceBear theme…" and after == "",
                   f"a theme picked again {how} says Loading… only after its own wait", [len(tries), len(early), loading[:1], late, after])
        page.close()


def living_backdrop_and_arrival_motifs(wall):
    """#385: living backdrop reflects the theme worn (motif and ambient glow);
    arriving cards carry their character signature arrival motif."""
    page = open_app(wall, 1920, 1000, keep=lambda s: s["voice"] in ("af_heart", "am_michael", "bf_alice"))
    pick(page, ".density label:has([value=comfortable])")
    bd = page.evaluate("""() => {
        const el = document.getElementById('wall-backdrop');
        return {
            exists: Boolean(el),
            motif: el.dataset.motif,
            glow: el.style.getPropertyValue('--bg-glow'),
            secondary: el.style.getPropertyValue('--bg-secondary')
        };
    }""")
    wall.check(bd["exists"] and bd["motif"] == "forge" and bd["glow"] == "#DA8C20" and bd["secondary"] == "#7A8B3C",
               "Kourai wears the forge living backdrop with forge amber glow", bd)

    open_gear(page)
    page.select_option("#theme", "professions")
    page.wait_for_function("document.documentElement.dataset.theme === 'professions'")
    bd_prof = page.evaluate("""() => {
        const el = document.getElementById('wall-backdrop');
        return {
            motif: el.dataset.motif,
            glow: el.style.getPropertyValue('--bg-glow'),
            secondary: el.style.getPropertyValue('--bg-secondary')
        };
    }""")
    wall.check(bd_prof["motif"] == "studio" and bd_prof["glow"] == "#FF8D70" and bd_prof["secondary"] == "#00A3DC",
               "switching to Professions swaps backdrop to studio motif with coral glow", bd_prof)

    page.select_option("#theme", "dicebear")
    page.wait_for_function("document.documentElement.dataset.theme === 'dicebear'")
    bd_dice = page.evaluate("""() => {
        const el = document.getElementById('wall-backdrop');
        return {
            motif: el.dataset.motif,
            glow: el.style.getPropertyValue('--bg-glow'),
            secondary: el.style.getPropertyValue('--bg-secondary')
        };
    }""")
    wall.check(bd_dice["motif"] == "geometric" and bd_dice["glow"] == "#00D7CE" and bd_dice["secondary"] == "#B073DA",
               "switching to DiceBear swaps backdrop to geometric motif with cyan/violet glow", bd_dice)

    puck = dict(next(s for s in page.snapshot_all if s["voice"] == "am_puck"), status="working")
    hermes = dict(next(s for s in page.snapshot_all if s["voice"] == "bm_fable"), status="working")
    send(page, {"sessions": [puck, hermes] + page.snapshot["sessions"], "speaking": None})
    page.wait_for_timeout(350)
    motifs = page.evaluate("""([puckId, hermesId]) => {
        const pCard = document.querySelector(`.card[data-key="${puckId}"]`);
        const hCard = document.querySelector(`.card[data-key="${hermesId}"]`);
        const pBurst = pCard ? pCard.querySelector('.burst') : null;
        const hBurst = hCard ? hCard.querySelector('.burst') : null;
        return {
            puckMotif: pCard ? pCard.dataset.motif : null,
            puckBurst: pBurst ? getComputedStyle(pBurst).display : null,
            hermesMotif: hCard ? hCard.dataset.motif : null,
            hermesBurst: hBurst ? getComputedStyle(hBurst).display : null,
        };
    }""", [puck["session_id"], hermes["session_id"]])
    wall.check(motifs["puckMotif"] == "sparks" and motifs["puckBurst"] == "block" and
               motifs["hermesMotif"] == "sand" and motifs["hermesBurst"] == "block",
               "arriving cards carry signature motifs (Puck: sparks, Hermes: sand)", motifs)
    page.close()


PICKER = """() => {
  const bar = document.querySelector('.bar');
  const gear = document.querySelector('.gear');
  const box = (e) => e.getBoundingClientRect();
  const was = Math.round(box(bar).height * 100);
  gear.style.display = 'none';
  const without = Math.round(box(bar).height * 100);
  gear.style.display = '';
  gear.open = true;
  const opened = Math.round(box(bar).height * 100);
  const menu = box(document.querySelector('.view'));
  const pick = box(document.getElementById('theme'));
  const labels = [...document.querySelectorAll('.density label')].map((l) => box(l).height);
  const out = {
    with: was / 100, without: without / 100, opened: opened / 100,
    inside: menu.left >= 0 && menu.right <= innerWidth && menu.top >= box(bar).bottom - 8,
    select: pick.height, labels,
  };
  gear.open = false;
  return out;
}"""


def picker_costs_no_height(wall):
    """The view settings sit behind the bar's gear (#248): at each width, with
    the app's buttons shown or not, the gear makes the bar no taller, opening
    it makes the bar no taller either, the menu stays on screen under the bar,
    and its controls meet the 24 px target (WCAG 2.2, 2.5.8)."""
    for width in (420, 945, 958, 1100, 1279, 1280, 1366, 1500, 1920):
        for app in (True, False):
            page = wall.open(width, 1000, 8, query="&theme=professions")
            if not app:
                page.evaluate("document.getElementById('new-session').hidden = true; document.getElementById('new-kind').hidden = true; document.getElementById('wrapup-open').hidden = true; dispatchEvent(new Event('resize'))")
                page.wait_for_timeout(SETTLE_MS)
            got = page.evaluate(PICKER)
            ok = got["with"] == got["without"] == got["opened"] and got["inside"] and got["select"] >= 24 and min(got["labels"]) >= 24
            wall.check(ok, f"{width} px{' with the app buttons' if app else ''}: the gear costs the bar no height and its menu fits", got)
            page.close()


LIST_COLOURS = """() => {
  const rgb = (c) => c.match(/[\\d.]+/g).slice(0, 3).map(Number);
  const lum = (c) => { const [r, g, b] = rgb(c).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
  const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m); return (x + 0.05) / (y + 0.05); };
  const opts = [...document.querySelectorAll('#theme option')];
  return {
    options: opts.map((o) => { const s = getComputedStyle(o); return { chosen: o.selected, bg: s.backgroundColor, fg: s.color, ratio: Math.round(ratio(s.color, s.backgroundColor) * 10) / 10, light: lum(s.backgroundColor) > 0.2 }; }),
  };
}"""


def theme_list_is_dark(wall):
    """The Characters list opens in the page's scheme (#151, #247). Windows
    draws the native list from the select's and the options' own colours, so
    the select is the bar's colour, never transparent, every other option the
    wall's card colour and the chosen one the hover colour, each with its text
    at 4.5:1 or more: a dark list in the dark scheme, a light one in the light."""
    page = wall.open(1920, 1000, 8)
    for scheme in ("dark", "light"):
        page.emulate_media(color_scheme=scheme)
        page.wait_for_timeout(100)
        got = page.evaluate(LIST_COLOURS)
        tokens = page.evaluate("""() => {
          const probe = document.createElement('div');
          document.body.append(probe);
          const of = (v) => { probe.style.background = `var(${v})`; return getComputedStyle(probe).backgroundColor; };
          const out = { card: of('--card-bg'), hover: of('--button-hover'), wall: of('--wall-bg'), select: getComputedStyle(document.getElementById('theme')).backgroundColor };
          probe.remove();
          return out;
        }""")
        fits = all(
            o["bg"] == tokens["hover" if o["chosen"] else "card"] and o["light"] == (scheme == "light") and o["ratio"] >= 4.5
            for o in got["options"]
        )
        chosen = sum(o["chosen"] for o in got["options"])
        wall.check(len(got["options"]) == 3 and chosen == 1 and fits and tokens["select"] == tokens["card"],
                   f"{scheme}: the select wears its menu's colour, the chosen option the hover colour and the rest the card's, text at 4.5:1 or more",
                   [got["options"], tokens])
    page.close()


def main() -> int:
    handler = functools.partial(Quiet, directory=str(ROOT))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)  # a free port
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with sync_playwright() as p:
        browser = p.chromium.launch(
            executable_path=os.environ.get("KLEPSYDRA_CHROME") or None
        )
        # These cases measure the wall itself, so every page wears Amber Door,
        # the layout without status lanes (#386); scripts/test_rooms_browser.py
        # checks the lanes of the other two.
        plain_page = browser.new_page

        def new_page(*args, **kwargs):
            page = plain_page(*args, **kwargs)
            page.add_init_script("window.__layout ??= 'E'; try { localStorage.getItem('klepsydra.needs.layout') ?? localStorage.setItem('klepsydra.needs.layout', 'E'); } catch {}")
            return page

        browser.new_page = new_page
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
            cast_pick_outlives_its_card,
            drawer_follows_snapshots,
            portrait_dialog,
            band_clear,
            comfortable_fits,
            arrival_once,
            slim_portrait_fits,
            dialog_backdrop_only,
            compact_look_on_face,
            ask_keeps_the_tool_name,
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
            native_flag_reaches_the_cards,
            one_click_or_key_never_ends_all,
            empty_state,
            fleet_health,
            gear_closes,
            new_session_menu,
            ended_only,
            narrow_window_keeps_cards_inside,
            long_folder_fits,
            reveal_density,
            separate_notes,
            launch_note_outlives_empty_state,
            one_launch_at_a_time,
            cleared_link_waits,
            stale_focus_never_reveals,
            reveal_race,
            arrival_is_an_event,
            reveal_does_not_arrive,
            bar_follows_empty_state,
            launch_dir_follows_prefs,
            browser_hides_app_actions,
            landmarks,
            ledger_docks_wide_and_is_a_dialog_narrow,
            ledger_gives_auto_its_room,
            ledger_snaps_by_drag,
            ledger_separator_snaps_by_keyboard,
            ledger_text_size,
            ledger_chip_opens_on_a_session,
            ledger_old_and_narrow_state,
            panels_reduced_motion,
            ledger_button_keeps_focus,
            ledger_reflows_at_every_size,
            github_links_open_through_the_app,
            ledger_reads_bounded,
            ledger_rolls_over_at_midnight,
            split_toggle,
            ci_watch,
            themes_switch_live,
            gauge_opacity_slider,
            themes_keeper_and_portrait,
            themes_fit,
            picker_costs_no_height,
            theme_list_is_dark,
            theme_everywhere,
            theme_save_flushes_and_says_when_refused,
            refused_saves_say_so,
            theme_first_paint,
            strip_first_paint,
            strip_keeper_states,
            theme_switch_commits_only_what_it_wore,
            theme_stale_load_leaves_the_choice,
            theme_file_that_never_answers,
            theme_retry_waits_before_loading,
            living_backdrop_and_arrival_motifs,
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
