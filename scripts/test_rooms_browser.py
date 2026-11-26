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
window.__needsText = %(needs)s;
window.__layout = %(layout)s;
const send = (ch, v) => setTimeout(() => ch && ch.onmessage(v), 0);
const lines = (t) => t.split('\\n');
window.__republish = () => send(window.__needs, { path: 'C:/demo/needs-you.md', text: window.__needsText, problem: null });
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
    if (cmd === 'read_usage') return Promise.resolve([]);
    if (cmd === 'engines_status') return Promise.resolve({ claude: [], agy: false, copilot: false });
    if (cmd === 'new_session_prefs') return Promise.resolve({ default: null, last: null });
    window.__calls.push([cmd, JSON.parse(JSON.stringify(args ?? null))]);
    if (cmd === 'needs_done') {
      const have = lines(window.__needsText), want = lines(args.block);
      const at = have.findIndex((_, i) => want.every((w, j) => have[i + j] === w));
      if (at < 0 || !/^\\s*([-*+]|\\d+[.)])\\s/.test(want[0])) return Promise.reject('That item is no longer in the Needs you file as shown.');
      have.splice(at, want.length);
      window.__needsText = have.join('\\n');
      setTimeout(window.__republish, 120);
      return Promise.resolve({ block: args.block, after: at > 0 ? have[at - 1] : null, at });
    }
    if (cmd === 'needs_undo') {
      const have = lines(window.__needsText);
      have.splice(args.undo.at, 0, ...lines(args.undo.block));
      window.__needsText = have.join('\\n');
      setTimeout(window.__republish, 120);
      return Promise.resolve(null);
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


def open_wall(browser, port, layout, width, height, needs, scheme="dark"):
    fixture = json.loads((ROOT / "scripts/fixtures/fleet-demo.json").read_text())
    at = fixture.pop("at")
    snapshot = shifted(fixture, int(time.time()) - at)
    page = browser.new_page(viewport={"width": width, "height": height}, color_scheme=scheme, reduced_motion="reduce")
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.add_init_script(
        STUB
        % {
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
            if width <= 640:
                head = page.evaluate("document.getElementById('needs-title').getBoundingClientRect().top >= document.querySelector('.bar').getBoundingClientRect().bottom - 1")
                run.check(head, f"{tag}: the room's title sits below the header", head)
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
    run.check(done == [{"block": first_item}], f"{tag}: E sends the item's exact lines to the app", done)
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shots", type=pathlib.Path)
    ap.add_argument("--needs", type=pathlib.Path)
    args = ap.parse_args()
    base = scrub(args.needs.read_text()) if args.needs else (ROOT / "scripts/fixtures/needs-demo.md").read_text()
    needs = base.replace("## When convenient\n", "## When convenient\n\n" + HOSTILE, 1) if not args.shots else base
    if args.shots:
        args.shots.mkdir(parents=True, exist_ok=True)
    run = Run()
    httpd, port = serve()
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch()
            checks(run, browser, port, needs, args.shots)
            browser.close()
    finally:
        httpd.shutdown()
    print(f"\n{run.passed} passed, {run.failed} failed")
    sys.exit(1 if run.failed else 0)


if __name__ == "__main__":
    main()
