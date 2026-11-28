"""Browser checks for Needs you and Agents (#386), in each layout at 1920 and 390.

The wall runs as the app would feed it: a stand-in for the Tauri runtime hands
it the demo fleet, a Needs you file and the queue file, records every command,
and answers needs_done / needs_undo by editing its copy of the file the way the
app's needs.rs does, then sends the new text back as the file watcher would.

    uv run -q --no-project --with playwright python -I scripts/test_rooms_browser.py
    ... --shots DIR    save one screenshot per layout and width (needs view) to DIR
    ... --needs FILE   show FILE's shape, its words swapped for placeholders (dates kept)

Needs Playwright's Chromium (`uvx playwright install chromium`).
"""

import argparse
import functools
import http.server
import json
import pathlib
import socket
import sys
import threading
import time

from playwright.sync_api import sync_playwright

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from needs_scrub import scrub  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
TIMES = {"status_at", "active_at", "updated_at", "quiet_since", "at", "started_at", "ends_at", "until", "settled_at", "turn_at"}
WIDTHS = [(1920, 1080), (390, 844)]
LAYOUTS = ["B", "D", "E"]

# Lines an agent could write that must stay text: markup, a script link, an image.
HOSTILE = (
    '- 📋 **Hostile <img src=x onerror="window.__pwned=1">:** see [x](javascript:window.__pwned=2) '
    "and <script>window.__pwned=3</script> [ok](https://example.com/safe)\n"
)

STUB = """
window.__calls = [];
window.__panelWidths = %(panel_widths)s;
window.__needsText = %(needs)s;
window.__layout = %(layout)s;
const send = (ch, v) => setTimeout(() => ch && ch.onmessage(v), 0);
const lines = (t) => t.split('\\n');
// As queue.rs's Follower: a view only when the text changed, after 250 ms of quiet.
window.__sent = null;
window.__republish = () => { window.__sent = window.__needsText; send(window.__needs, { path: 'C:/demo/needs-you.md', text: window.__needsText, problem: null }); };
let settle = 0;
const follow = () => { if (window.__noFollow) return; clearTimeout(settle); settle = setTimeout(() => { if (window.__needsText !== window.__sent) window.__republish(); }, 250); };
window.__TAURI__ = { core: {
  Channel: class { },
  invoke: (cmd, args) => {
    if (cmd === 'fleet_subscribe') { window.__channel = args.onMessage; send(args.onMessage, %(snapshot)s); return Promise.resolve(); }
    if (cmd === 'needs_subscribe') { window.__needs = args.onMessage; window.__republish(); return Promise.resolve(); }
    if (cmd === 'queue_subscribe') { send(args.onMessage, { path: 'C:/demo/queue.md', text: %(queue)s, problem: null }); return Promise.resolve(); }
    if (cmd.endsWith('_subscribe')) return Promise.resolve();
    if (cmd === 'plugin:log|log') return Promise.resolve();
    if (cmd === 'get_wall_density') return Promise.resolve('auto');
    if (cmd === 'get_needs_layout') return Promise.resolve(window.__layout);
    if (cmd === 'get_panel_width') return Promise.resolve(window.__panelWidths[args.panel] ?? null);
    if (cmd === 'read_usage') return Promise.resolve([]);
    if (cmd === 'engines_status') return Promise.resolve({ claude: [], agy: false, copilot: false });
    if (cmd === 'new_session_prefs') return Promise.resolve({ default: null, last: null });
    window.__calls.push([cmd, JSON.parse(JSON.stringify(args ?? null))]);
    if (cmd === 'set_panel_width') { window.__panelWidths[args.panel] = args.width; return Promise.resolve(); }
    if (cmd === 'needs_done') {
      // needs.rs remove: only while the file is the text the wall rendered, exactly the lines at `line`.
      if (args.seen !== window.__needsText) return Promise.reject('The Needs you file changed since the wall showed it.');
      const have = lines(window.__needsText), want = lines(args.block);
      if (!want.every((w, j) => have[args.line + j] === w) || !/^\\s*([-*+]|\\d+[.)])(\\s|$)/.test(want[0])) return Promise.reject('That item is not in the Needs you file where the wall showed it.');
      const at = args.line;
      have.splice(at, want.length);
      window.__needsText = have.join('\\n');
      follow();
      return Promise.resolve({ undo: { block: args.block, after: at > 0 ? have[at - 1] : null, at }, text: window.__needsText });
    }
    if (cmd === 'needs_undo') {
      const have = lines(window.__needsText);
      have.splice(args.undo.at, 0, ...lines(args.undo.block));
      window.__needsText = have.join('\\n');
      follow();
      return Promise.resolve(window.__needsText);
    }
    if (cmd === 'jump_to_terminal') return Promise.resolve('Opened its terminal.');
    return Promise.resolve('ok');
  },
} };
"""


def shifted(value, by):
    if isinstance(value, list):
        return [shifted(v, by) for v in value]
    if not isinstance(value, dict):
        return value
    return {k: v + by if k in TIMES and isinstance(v, (int, float)) else shifted(v, by) for k, v in value.items()}


class Run:
    def __init__(self):
        self.failed = 0
        self.passed = 0

    def check(self, ok, what, got=None):
        if ok:
            self.passed += 1
            print(f"ok    {what}")
        else:
            self.failed += 1
            print(f"FAIL  {what}: {got!r}")


def serve():
    handler = functools.partial(type("Quiet", (http.server.SimpleHTTPRequestHandler,), {"log_message": lambda *a: None}), directory=str(ROOT))
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, port


STATE = """() => {
  const vis = (sel) => { const e = document.querySelector(sel); return Boolean(e && e.checkVisibility()); };
  const room = document.getElementById('needs-room');
  const rows = [...room.querySelectorAll('.ny-row')].filter((r) => r.checkVisibility());
  return {
    layout: document.body.dataset.layout, view: document.body.dataset.view,
    pill: document.querySelector('#needs-pill .rp-count').textContent,
    tab: document.querySelector('#phone-tabs [data-view=needs] .pt-count').textContent,
    rows: rows.length, items: rows.filter((r) => r.classList.contains('ny-item')).length,
    blocked: rows.filter((r) => r.classList.contains('ny-blocked')).length,
    sub: room.querySelector('.ny-sub').textContent,
    wall: vis('#wall'), room: vis('#needs-room'), queue: vis('#queue-file'),
    lanes: [...document.querySelectorAll('#wall > .lane-head')].map((h) => h.dataset.lane),
    hscroll: document.documentElement.scrollWidth > innerWidth,
    active: document.activeElement?.dataset?.key ?? document.activeElement?.id ?? null,
    toast: document.getElementById('room-toast').hidden ? null : document.getElementById('room-toast').textContent,
    unsafe: room.querySelectorAll('a, script, iframe, [href], [onerror], [onclick], img:not(.ny-face)').length,
    pwned: window.__pwned ?? null,
    calls: window.__calls.filter(([c]) => !['read_usage'].includes(c)),
  };
}"""


def open_wall(browser, port, layout, width, height, needs, scheme="dark", panel_widths=None):
    fixture = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    at = fixture.pop("at")
    snapshot = shifted(fixture, int(time.time()) - at)
    page = browser.new_page(viewport={"width": width, "height": height}, color_scheme=scheme, reduced_motion="reduce")
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.add_init_script(
        STUB
        % {
            "panel_widths": json.dumps(panel_widths or {}),
            "needs": json.dumps(needs),
            "layout": json.dumps(layout),
            "snapshot": json.dumps(snapshot),
            "queue": json.dumps((ROOT / "scripts/fixtures/queue-demo.md").read_text()),
        }
    )
    page.goto(f"http://127.0.0.1:{port}/src/wall.html")
    page.wait_for_function("document.querySelectorAll('#wall > .card').length > 0")
    page.wait_for_function("document.querySelector('#needs-pill .rp-count').textContent !== '0'")
    page.wait_for_timeout(300)
    page.snapshot = snapshot
    page.errors = errors
    return page


def state(page):
    return page.evaluate(STATE)


def checks(run, browser, port, needs, shots):
    blocks = None
    for layout in LAYOUTS:
        for width, height in WIDTHS:
            tag = f"{layout} at {width}"
            page = open_wall(browser, port, layout, width, height, needs)
            s = state(page)
            run.check(s["layout"] == layout and s["view"] == "agents", f"{tag}: the saved layout applies at load, before any key", s["layout"])
            if layout in ("B", "D") and width > 640:
                want = ["blocked", "working", "finished", "idle"] if layout == "B" else ["working", "blocked", "finished", "idle"]
                run.check([x for x in s["lanes"] if x in want] == want, f"{tag}: the wall's status lanes, in the layout's order", s["lanes"])
            if layout == "E":
                run.check(s["lanes"] == [], f"{tag}: Amber Door keeps the wall without lanes", s["lanes"])
            fit = page.evaluate("[document.getElementById('wall').dataset.density, document.documentElement.scrollHeight > innerHeight]")
            run.check(not (fit[0] == "comfortable" and fit[1]), f"{tag}: Auto never leaves comfortable cards scrolling, lanes and queue file counted", fit)
            # Open Needs you: N on a desktop, the tab on a phone.
            if width > 640:
                page.keyboard.press("n")
            else:
                page.click("#phone-tabs [data-view=needs]")
            page.wait_for_timeout(150)
            s = state(page)
            n = int(s["pill"])
            run.check(s["view"] == "needs" and s["room"], f"{tag}: Needs you opens", s["view"])
            run.check(n == s["rows"] == int(s["tab"]) and s["sub"].startswith(f"{n} open"), f"{tag}: pill, tab, list and subtitle show one number", [s["pill"], s["tab"], s["rows"], s["sub"]])
            want_blocked = sum(x["status"] == "needs_you" for x in page.snapshot["sessions"])
            lead = page.evaluate("[...document.querySelectorAll('#needs-room .ny-row')].slice(0, %d).every((r) => r.classList.contains('ny-blocked'))" % want_blocked)
            run.check(s["blocked"] == want_blocked and lead, f"{tag}: the blocked sessions lead the list", [s["blocked"], want_blocked])
            if layout == "E" and width > 640:
                run.check(s["wall"], f"{tag}: the wall stays in view beside the panel", s["wall"])
            else:
                run.check(not s["wall"] and not s["queue"], f"{tag}: the wall and the queue give way to Needs you", [s["wall"], s["queue"]])
            run.check(s["unsafe"] == 0 and s["pwned"] is None, f"{tag}: the file's text is text: no link, image or script runs", [s["unsafe"], s["pwned"]])
            run.check(not s["hscroll"], f"{tag}: no sideways scroll", s["hscroll"])
            # At every width, and in E's side panel too: nothing in the bar covers the room's title.
            head = page.evaluate("document.getElementById('needs-title').getBoundingClientRect().top >= document.querySelector('.bar').getBoundingClientRect().bottom - 1")
            run.check(head, f"{tag}: the room's title sits below the header", head)
            if width <= 640:
                cols = page.evaluate("[...document.querySelectorAll('#needs-room .ny-row')].map((r) => getComputedStyle(r).gridTemplateColumns.split(' ').length)")
                run.check(cols and set(cols) == {1}, f"{tag}: every row is one column on a phone", sorted(set(cols)))
            if shots:
                page.screenshot(path=str(shots / f"klepsydra-386-{layout}-{width}.png"))
            if layout == "B" and width > 640:
                blocks = flow_b(run, page, needs)
            if layout == "E" and width > 640:
                flow_e(run, browser, port, needs)
            run.check(page.errors == [], f"{tag}: no page error", page.errors)
            page.close()
    return blocks


def flow_b(run, page, needs):
    """Answer, Done, Undo and the keys, on Two rooms at 1920."""
    tag = "B keys"
    # Answer on the first blocked row reaches the wall's jump with the card's id and session name.
    page.click(".ny-blocked >> nth=0 >> .ny-answer")
    page.wait_for_timeout(100)
    jumps = [a for c, a in state(page)["calls"] if c == "jump_to_terminal"]
    first = next(x for x in page.snapshot["sessions"] if x["status"] == "needs_you")
    run.check(jumps == [{"id": first["session_id"], "name": first["name"]}], f"{tag}: Answer jumps to the session's terminal", jumps)
    # Move to the first ask with j, past the two blocked rows.
    page.click("#needs-title")
    for _ in range(3):
        page.keyboard.press("j")
    s = state(page)
    first_item = page.evaluate("document.querySelector('.ny-item.is-focused')?.dataset.key")
    run.check(first_item is not None and first_item.startswith("- 📋"), f"{tag}: j walks down to the first ask", first_item)
    before = int(s["pill"])
    page.keyboard.press("e")
    page.wait_for_timeout(400)
    s = state(page)
    done = [a for c, a in s["calls"] if c == "needs_done"]
    at = needs.split("\n").index(first_item.split("\n")[0])
    run.check(done == [{"seen": needs, "block": first_item, "line": at}], f"{tag}: E sends the item's exact lines, where they start and the file it read", done)
    run.check(int(s["pill"]) == before - 1 and s["rows"] == before - 1, f"{tag}: the count ticks down and the row leaves", [s["pill"], s["rows"]])
    text = page.evaluate("window.__needsText")
    run.check(first_item not in text, f"{tag}: the file no longer holds the item", None)
    run.check(s["toast"] and s["toast"].startswith("Done:") and "Undo" in s["toast"], f"{tag}: a toast offers Undo", s["toast"])
    # Enter after E opens the focused item; it never undoes.
    page.keyboard.press("Enter")
    page.wait_for_timeout(150)
    s = state(page)
    run.check(not [c for c, _ in s["calls"] if c == "needs_undo"], f"{tag}: Enter after E is not Undo", [c for c, _ in s["calls"]])
    # Ctrl+C belongs to the selection.
    page.keyboard.press("Control+c")
    page.wait_for_timeout(100)
    run.check("Copied" not in (state(page)["toast"] or ""), f"{tag}: Ctrl+C is not the room's C", state(page)["toast"])
    page.keyboard.press("u")
    page.wait_for_timeout(400)
    s = state(page)
    undo = [a for c, a in s["calls"] if c == "needs_undo"]
    run.check(len(undo) == 1 and undo[0]["undo"]["block"] == first_item, f"{tag}: U puts back that block alone", undo)
    run.check(page.evaluate("window.__needsText") == needs and int(s["pill"]) == before, f"{tag}: the file and the count are as before", s["pill"])
    # Holding E removes one row, not several.
    calls = len([c for c, _ in state(page)["calls"] if c == "needs_done"])
    page.keyboard.down("e")
    page.evaluate("for (let i = 0; i < 4; i++) (document.activeElement ?? document.body).dispatchEvent(new KeyboardEvent('keydown', { key: 'e', repeat: true, bubbles: true }))")
    page.keyboard.up("e")
    page.wait_for_timeout(400)
    held = len([c for c, _ in state(page)["calls"] if c == "needs_done"]) - calls
    run.check(held == 1, f"{tag}: holding E marks one item done", held)
    page.keyboard.press("u")
    page.wait_for_timeout(300)
    # E then U at once, inside the file watcher's quiet time: the file never looks changed to it.
    page.keyboard.press("e")
    page.wait_for_timeout(30)
    page.keyboard.press("u")
    page.wait_for_timeout(700)
    s = state(page)
    run.check(page.evaluate("window.__needsText") == needs and int(s["pill"]) == before and s["rows"] == before, f"{tag}: E then U at once shows the item again", [s["pill"], s["rows"]])
    # Twins: Done on the second removes the second, and the first stays in view.
    twin = "- 📋 **Twin:** same words"
    page.evaluate("(t) => { window.__needsText = t; window.__republish(); }", needs.replace("## When convenient\n", f"## When convenient\n\n{twin}\n", 1).replace("## Coming up\n", f"## Coming up\n\n{twin}\n", 1))
    page.wait_for_timeout(200)
    lines_before = page.evaluate("window.__needsText").split("\n")
    page.locator(".ny-item", has_text="same words").nth(1).locator(".ny-done").click()
    page.wait_for_timeout(500)
    after = page.evaluate("window.__needsText").split("\n")
    gone = [i for i, ln in enumerate(lines_before) if ln == twin]
    run.check(after.count(twin) == 1 and after.index(twin) == gone[0], f"{tag}: Done on the second twin removes the second", gone)
    run.check(page.locator(".ny-item", has_text="same words").count() == 1, f"{tag}: the twin left stays in view", page.locator(".ny-item", has_text="same words").count())
    page.evaluate("(t) => { window.__needsText = t; window.__republish(); }", needs)
    page.wait_for_timeout(200)
    # An agent's edit the wall has not shown yet: Done writes nothing and says why.
    edited = "- 📋 **Agent:** added a moment ago\n" + needs
    page.evaluate("(t) => { window.__needsText = t; }", edited)
    page.locator(".ny-item .ny-done").first.click()
    page.wait_for_timeout(300)
    s = state(page)
    run.check(page.evaluate("window.__needsText") == edited and s["toast"] and "changed since" in s["toast"], f"{tag}: Done on a file changed since it was shown writes nothing and says so", s["toast"])
    page.evaluate("(t) => { window.__needsText = t; window.__republish(); }", needs)
    page.wait_for_timeout(200)
    # A problem from the last read clears as soon as Done writes a file the room reads, not at the next read.
    page.evaluate("window.__noFollow = true; window.__needs.onmessage({ path: 'C:/demo/needs-you.md', text: window.__needsText, problem: 'The Needs you file could not be read: test' })")
    shown = page.evaluate("!document.querySelector('#needs-room .ny-problem').hidden")
    page.locator(".ny-item .ny-done").first.click()
    page.wait_for_timeout(150)
    gone = page.evaluate("document.querySelector('#needs-room .ny-problem').hidden")
    run.check(shown and gone, f"{tag}: Done's written file clears the last read's problem line", [shown, gone])
    page.evaluate("(t) => { window.__noFollow = false; window.__needsText = t; window.__republish(); }", needs)
    page.wait_for_timeout(200)
    # N, A and Esc do nothing behind a dialog.
    page.evaluate("document.getElementById('portrait').showModal()")
    page.keyboard.press("a")
    run.check(state(page)["view"] == "needs", f"{tag}: A does nothing behind a dialog", state(page)["view"])
    page.evaluate("document.getElementById('portrait').close()")
    # A session that blocks while Needs you is open: a toast names it; Enter shows its card.
    snap = json.loads(json.dumps(page.snapshot))
    victim = next(x for x in snap["sessions"] if x["status"] == "working")
    victim["status"] = "needs_you"
    victim["reason"] = "approve Bash"
    victim["status_at"] = int(time.time())
    page.click("#needs-title")
    page.evaluate("(s) => window.__channel.onmessage(s)", snap)
    page.wait_for_timeout(300)
    s = state(page)
    run.check(s["toast"] and "needs you" in s["toast"], f"{tag}: a new block shows a toast naming the session", s["toast"])
    run.check(s["view"] == "needs", f"{tag}: the view never switches itself", s["view"])
    page.keyboard.press("Enter")
    page.wait_for_timeout(300)
    s = state(page)
    run.check(s["view"] == "agents" and s["active"] == victim["session_id"], f"{tag}: Enter on the toast focuses that session's card", [s["view"], s["active"]])
    page.keyboard.press("n")
    page.keyboard.press("Escape")
    run.check(state(page)["view"] == "agents", f"{tag}: Esc returns to Agents", state(page)["view"])


def flow_e(run, browser, port, needs):
    page = open_wall(browser, port, "E", 1920, 1080, needs)
    # 1. Right-edge tabs stacked when shut, clear of cards.
    shut_e = page.evaluate("""() => {
      const nt = document.getElementById('needs-tab').getBoundingClientRect();
      const lt = document.getElementById('ledger-tab').getBoundingClientRect();
      const cards = [...document.querySelectorAll('#wall .card')].map((c) => c.getBoundingClientRect());
      return {
        nt: [Math.round(nt.left), Math.round(nt.top), Math.round(nt.right), Math.round(nt.bottom)],
        lt: [Math.round(lt.left), Math.round(lt.top), Math.round(lt.right), Math.round(lt.bottom)],
        tabbed: document.body.classList.contains('needs-tabbed'),
        cardsRight: Math.round(Math.max(...cards.map((c) => c.right))),
        wallWidthBefore: Math.round(document.getElementById('wall').getBoundingClientRect().width),
      };
    }""")
    run.check(
        shut_e["tabbed"]
        and shut_e["nt"][2] == 1920
        and shut_e["nt"][2] - shut_e["nt"][0] >= 24
        and shut_e["lt"][3] < shut_e["nt"][1]
        and shut_e["cardsRight"] <= shut_e["nt"][0],
        "E: shut edge tabs stack cleanly clear of the cards",
        shut_e,
    )
    # 2. Clicking the edge tab opens docked (push), complementary landmark, no dimming, wall reflows.
    page.click("#needs-tab")
    page.wait_for_timeout(150)
    docked_e = page.evaluate("""() => {
      const r = document.getElementById('needs-room');
      const rb = r.getBoundingClientRect();
      const wb = document.getElementById('wall').getBoundingClientRect();
      const grip = r.querySelector('.needs-resize').getBoundingClientRect();
      return {
        mode: r.dataset.mode,
        role: r.getAttribute('role'),
        docked: document.body.classList.contains('needs-docked'),
        width: Math.round(rb.width),
        wallWidth: Math.round(wb.width),
        wallRight: Math.round(wb.right),
        panelLeft: Math.round(rb.left),
        filter: getComputedStyle(document.getElementById('wall')).filter,
        gripWidth: Math.round(grip.width),
        gripVis: r.querySelector('.needs-resize').checkVisibility(),
        ledgerTabVis: document.getElementById('ledger-tab').checkVisibility(),
        hscroll: document.documentElement.scrollWidth > innerWidth,
      };
    }""")
    run.check(
        docked_e["mode"] == "docked"
        and docked_e["role"] == "complementary"
        and page.get_by_role("complementary", name="Needs you").count() == 1
        and docked_e["docked"]
        and docked_e["width"] == 480
        and docked_e["wallWidth"] < shut_e["wallWidthBefore"]
        and docked_e["wallRight"] <= docked_e["panelLeft"]
        and docked_e["filter"] == "none"
        and docked_e["gripWidth"] >= 10
        and docked_e["gripVis"]
        and not docked_e["ledgerTabVis"]
        and not docked_e["hscroll"],
        "E: docked panel pushes and reflows wall without dimming, wide grab zone, complementary role",
        docked_e,
    )
    # 3. Drag resize + limits + double-click reset + prefs persistence.
    grip = page.locator("#needs-room .needs-resize").bounding_box()
    gx, gy = grip["x"] + grip["width"] / 2, grip["y"] + 250
    page.mouse.move(gx, gy)
    page.mouse.down()
    page.mouse.move(1920 - 650, gy, steps=12)
    page.mouse.up()
    page.wait_for_timeout(150)
    dragged = page.evaluate("""() => ({
      width: Math.round(document.getElementById('needs-room').getBoundingClientRect().width),
      saved: window.__panelWidths.needs,
      wallRight: Math.round(document.getElementById('wall').getBoundingClientRect().right),
      panelLeft: Math.round(document.getElementById('needs-room').getBoundingClientRect().left),
    })""")
    run.check(
        abs(dragged["width"] - 650) <= 2 and abs(dragged["saved"] - 650) <= 2 and dragged["wallRight"] <= dragged["panelLeft"],
        "E: drag resize updates width, pushes wall, and persists via set_panel_width",
        dragged,
    )
    # Double-click resets width to 480.
    grip = page.locator("#needs-room .needs-resize").bounding_box()
    page.mouse.dblclick(grip["x"] + grip["width"] / 2, grip["y"] + 250)
    page.wait_for_timeout(150)
    dbl = page.evaluate("({ w: Math.round(document.getElementById('needs-room').getBoundingClientRect().width), saved: window.__panelWidths.needs })")
    run.check(dbl["w"] == 480 and dbl["saved"] == 480, "E: double-click on handle resets width to 480", dbl)
    # Keyboard resize on focused handle (ArrowLeft, Home to min, End to max).
    page.locator("#needs-room .needs-resize").focus()
    page.keyboard.press("ArrowLeft")
    page.keyboard.press("ArrowLeft")
    kbd_up = page.evaluate("Math.round(document.getElementById('needs-room').getBoundingClientRect().width)")
    page.keyboard.press("Home")
    kbd_min = page.evaluate("({ w: Math.round(document.getElementById('needs-room').getBoundingClientRect().width), sw: document.querySelector('#needs-room .needs-body').scrollWidth - document.querySelector('#needs-room .needs-body').clientWidth })")
    page.keyboard.press("End")
    kbd_max = page.evaluate("({ w: Math.round(document.getElementById('needs-room').getBoundingClientRect().width), mode: document.getElementById('needs-room').dataset.mode })")
    run.check(
        kbd_up == 512 and kbd_min["w"] == 320 and kbd_min["sw"] <= 0 and kbd_max["w"] == 900 and kbd_max["mode"] == "docked",
        "E: keyboard resize steps, hits min (320, no overflow) and max (900, stays docked)",
        [kbd_up, kbd_min, kbd_max],
    )
    # 4. Escape closes and returns focus to #needs-pill; pill toggles open/shut.
    page.keyboard.press("Escape")
    page.wait_for_timeout(100)
    esc = page.evaluate("({ view: document.body.dataset.view, active: document.activeElement?.id, docked: document.body.classList.contains('needs-docked') })")
    run.check(esc["view"] == "agents" and esc["active"] == "needs-pill" and not esc["docked"], "E: Escape closes panel and returns focus to toggle", esc)
    page.click("#needs-pill")
    page.wait_for_timeout(100)
    toggled_on = page.evaluate("document.body.dataset.view")
    page.click("#needs-pill")
    page.wait_for_timeout(100)
    toggled_off = page.evaluate("({ view: document.body.dataset.view, active: document.activeElement?.id })")
    run.check(toggled_on == "needs" and toggled_off["view"] == "agents" and toggled_off["active"] == "needs-pill", "E: header pill toggles panel open and shut", [toggled_on, toggled_off])
    # 5. Edge exclusivity with Ledger.
    page.click("#needs-pill")
    page.wait_for_timeout(100)
    page.click("#ledger-open")
    page.wait_for_timeout(150)
    ledger_took = page.evaluate("({ ledgerOpen: document.getElementById('ledger').open, view: document.body.dataset.view, needsTab: document.getElementById('needs-tab').checkVisibility() })")
    run.check(ledger_took["ledgerOpen"] and ledger_took["view"] == "agents" and not ledger_took["needsTab"], "E: opening Ledger shuts Needs you and hides its tab", ledger_took)
    page.click("#ledger-open")
    page.wait_for_timeout(100)
    # 6. Auto-open on newly blocked session, and never while typing.
    snap = json.loads(json.dumps(page.snapshot))
    victim = next(x for x in snap["sessions"] if x["status"] == "working")
    victim["status"] = "needs_you"
    victim["status_at"] = int(time.time())
    page.evaluate("(s) => window.__channel.onmessage(s)", snap)
    page.wait_for_timeout(300)
    s = state(page)
    run.check(s["view"] == "needs" and s["active"] == f"s:{victim['session_id']}", "E: a block opens the panel on that session's row", [s["view"], s["active"]])
    # Never while typing.
    page.keyboard.press("Escape")
    page.evaluate("document.body.append(Object.assign(document.createElement('input'), {id: 'typing'}))")
    page.focus("#typing")
    snap2 = json.loads(json.dumps(snap))
    other = next(x for x in snap2["sessions"] if x["status"] == "working")
    other["status"] = "needs_you"
    other["status_at"] = int(time.time())
    page.evaluate("(s) => window.__channel.onmessage(s)", snap2)
    page.wait_for_timeout(300)
    s = state(page)
    run.check(s["view"] == "agents" and s["active"] == "typing", "E: never while typing (a toast says it instead)", [s["view"], s["active"], s["toast"]])
    page.close()

    # 7. Saved width from prefs.json loads on startup + 1280 push limit (580 max leaving 700 for wall).
    page1280 = open_wall(browser, port, "E", 1280, 800, needs, panel_widths={"needs": 540})
    page1280.click("#needs-pill")
    page1280.wait_for_timeout(150)
    at1280 = page1280.evaluate("({ w: Math.round(document.getElementById('needs-room').getBoundingClientRect().width), mode: document.getElementById('needs-room').dataset.mode, wallRight: Math.round(document.getElementById('wall').getBoundingClientRect().right), panelLeft: Math.round(document.getElementById('needs-room').getBoundingClientRect().left), hscroll: document.documentElement.scrollWidth > innerWidth })")
    page1280.locator("#needs-room .needs-resize").focus()
    page1280.keyboard.press("End")
    max1280 = page1280.evaluate("Math.round(document.getElementById('needs-room').getBoundingClientRect().width)")
    run.check(at1280["w"] == 540 and at1280["mode"] == "docked" and at1280["wallRight"] <= at1280["panelLeft"] and not at1280["hscroll"] and max1280 == 580, "E at 1280: loads saved width from prefs, pushes wall, max leaves 700 px for cards", [at1280, max1280])
    page1280.close()

    # 8. Narrow desktop (< 1200, > 640): overlay mode, handle hidden, wall dimmed, Escape returns focus.
    page945 = open_wall(browser, port, "E", 945, 1000, needs)
    page945.click("#needs-pill")
    page945.wait_for_timeout(200)
    ov = page945.evaluate("""() => {
      const r = document.getElementById('needs-room');
      const rb = r.getBoundingClientRect();
      const wb = document.getElementById('wall').getBoundingClientRect();
      return {
        mode: r.dataset.mode,
        docked: document.body.classList.contains('needs-docked'),
        gripVis: r.querySelector('.needs-resize').checkVisibility(),
        wallWidth: Math.round(wb.width),
        wallRight: Math.round(wb.right),
        panelLeft: Math.round(rb.left),
        filter: getComputedStyle(document.getElementById('wall')).filter,
      };
    }""")
    page945.keyboard.press("Escape")
    page945.wait_for_timeout(100)
    ov_esc = page945.evaluate("({ view: document.body.dataset.view, active: document.activeElement?.id })")
    run.check(
        ov["mode"] == "overlay" and not ov["docked"] and not ov["gripVis"] and ov["wallRight"] > ov["panelLeft"] and ov["filter"] != "none" and ov_esc["view"] == "agents" and ov_esc["active"] == "needs-pill",
        "E at 945: overlays dimmed wall without pushing, hides resize handle, Escape returns focus",
        [ov, ov_esc],
    )
    page945.close()


def capture_amber_shots(browser, port, needs, out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    for width, height in [(1920, 1080), (1280, 800), (450, 900)]:
        for theme in ("dark", "light"):
            page = open_wall(browser, port, "E", width, height, needs, scheme=theme)
            if width > 640:
                page.click("#needs-pill")
            else:
                page.click("#phone-tabs [data-view=needs]")
            page.wait_for_timeout(250)
            page.screenshot(path=str(out_dir / f"klepsydra-600-amber-door-{width}-{theme}.png"))
            page.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", type=pathlib.Path)
    ap.add_argument("--amber-shots", type=pathlib.Path)
    ap.add_argument("--needs", type=pathlib.Path)
    args = ap.parse_args()
    base = scrub(args.needs.read_text()) if args.needs else (ROOT / "scripts/fixtures/needs-demo.md").read_text()
    needs = base.replace("## When convenient\n", "## When convenient\n\n" + HOSTILE, 1) if not (args.shots or args.amber_shots) else base
    if args.shots:
        args.shots.mkdir(parents=True, exist_ok=True)
    run = Run()
    httpd, port = serve()
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch()
            if args.amber_shots:
                capture_amber_shots(browser, port, needs, args.amber_shots)
            else:
                checks(run, browser, port, needs, args.shots)
            browser.close()
    finally:
        httpd.shutdown()
    print(f"\n{run.passed} passed, {run.failed} failed")
    sys.exit(1 if run.failed else 0)


if __name__ == "__main__":
    main()
