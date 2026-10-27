"""The phone wall in a real browser, served by the real server.

Builds and runs the fleet crate's `phone` example (src-tauri/fleet/src/phone.rs
serving src/ from disk, as the app serves its bundle) on a free loopback port,
with the sixteen-session demo fleet, and opens it as an iPhone would (390x844,
touch, 3x). Checks: one column of compact cards, needs-you cards first, the
tally sticky at the top, no horizontal scroll, every visible control at least
44 px, no desktop action anywhere, a card's Remote Control link (and a tap on
the card) opening claude.ai, a second snapshot arriving over /events, the
service worker and manifest installing, fleet.json cut to the wall's fields, a
write refused, a wrap-up request and the empty state shown with none of their
buttons, /wall.html sent to the root, and a stream refused at the cap opened
again. The usage-limit gauges, from readings in the server's accounts folder:
one per account and window in the gauge's order and words, in the sticky
bar, a new reading over /events, a stale one saying its age, none at all
reading as waiting, and AA contrast with the system in light and in dark.
Saves a screenshot in each scheme.

    uv run -q --no-project --with playwright python -I scripts/test_phone_browser.py [shot.png]

Needs cargo, and Playwright's Chromium (`uvx playwright install chromium`) or a
Chrome at $KLEPSYDRA_CHROME.
"""

import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import tempfile
import time

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
TAURI = ROOT / "src-tauri"
DEMO = ROOT / "scripts/fixtures/fleet-demo.json"
WRAPUP = ROOT / "scripts/fixtures/wrapup-demo.json"
REMOTE = "https://claude.ai/code/session_01PLACEHOLDERphone"
# The one card keryx kept a clip for that the server can serve: a real session id.
CLIP_ID = "3f1c0a52-7b1e-4c0e-9a55-2f6f0d1d7a10"
DESKTOP = ", ".join([
    ".jump", ".clear", ".menu", "#new-session", "#ledger-open", ".chip", ".density", ".undo", ".end-confirm", "[data-act]",
    "#wrapup-open", "#wrapup-stop", "#end-ready", "#start-session", "#clear-ended",
])


class Run:
    def __init__(self):
        self.passed = 0
        self.failed = 0

    def check(self, ok, what, got=None):
        if ok:
            self.passed += 1
            print(f"  ok   {what}")
        else:
            self.failed += 1
            print(f"  FAIL {what}: {got!r}")


def snapshot_file(path, change=None):
    """The demo fleet with a Remote Control link on its second session (a
    working one) and a foreign link on its third, which must not become one."""
    fleet = json.loads(DEMO.read_text())
    fleet["sessions"][1]["remote_url"] = REMOTE
    fleet["sessions"][2]["remote_url"] = "https://evil.example/code/session_01x"
    [*_, last] = [s for s in fleet["sessions"] if "reply_at" in s]
    last["session_id"] = CLIP_ID
    if change:
        change(fleet)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(fleet))
    tmp.replace(path)
    return fleet


def with_wrapup(fleet):
    """The demo wrap-up request and answers on the fleet, as the app's
    snapshot carries them (feed.js withWrapup); both share one `at`."""
    sample = json.loads(WRAPUP.read_text())
    assert sample["at"] == fleet["at"]
    fleet["wrapup"] = sample["request"]
    for s in fleet["sessions"]:
        if s["session_id"] in sample["answers"]:
            s["wrapup"] = sample["answers"][s["session_id"]]


# Demo accounts named as the gauge's own examples are; placeholder ids.
PERSONAL = "00000000-0000-4000-8000-0000000000b2"
TEAM = "00000000-0000-4000-8000-0000000000a1"


def write_reading(klepsydra, account, label, windows, ago=0, session="00000000-0000-4000-8000-000000000001"):
    """A reading as the statusLine hook publishes it, observed `ago` seconds
    ago; each window is (percent, seconds to its reset, negative once past)."""
    now = int(time.time())
    folder = klepsydra / "accounts" / account
    folder.mkdir(parents=True, exist_ok=True)
    reading = {
        "account": account, "label": label, "session": session, "api_ms": 1234,
        "written_at": now - ago, "observed_at": now - ago,
        "windows": {k: {"used_percentage": pct, "resets_at": now + reset} for k, (pct, reset) in windows.items()},
    }
    tmp = folder / f"{session}.json.1.tmp"
    tmp.write_text(json.dumps(reading))
    tmp.replace(folder / f"{session}.json")


def demo_usage(klepsydra):
    """The strip's examples: two windows on the account in use, a reset
    window on the one signed out of an hour ago."""
    write_reading(klepsydra, PERSONAL, "Personal", {"five_hour": (57, 8 * 60 + 50), "seven_day": (27, (6 * 24 + 6) * 3600 + 1800)})
    write_reading(klepsydra, TEAM, "Team", {"five_hour": (64, -7 * 3600 - 600)}, ago=3600, session="00000000-0000-4000-8000-000000000002")


def write_clip(klepsydra):
    """A third of a second of silence as keryx writes a reply clip."""
    import wave

    (klepsydra / "replies").mkdir(parents=True, exist_ok=True)
    with wave.open(str(klepsydra / "replies" / f"{CLIP_ID}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(24000)
        w.writeframes(b"\x00\x00" * 8000)


def start_server(snapshot):
    subprocess.run(
        ["cargo", "build", "-q", "-p", "klepsydra-fleet", "--example", "phone"],
        cwd=TAURI,
        check=True,
    )
    exe = TAURI / "target/debug/examples/phone"
    proc = subprocess.Popen(
        [str(exe), str(ROOT / "src"), str(snapshot), "0"],
        stdout=subprocess.PIPE,
        text=True,
        env={**os.environ, "KLEPSYDRA_DIR": str(snapshot.parent / "klepsydra")},
    )
    line = proc.stdout.readline().strip()
    if not line.startswith("listening on "):
        proc.kill()
        raise SystemExit(f"the phone example did not start: {line!r}")
    return proc, line.removeprefix("listening on ")


def wait_until(page, expr, timeout_s):
    """Poll `expr` in the page until it is truthy or `timeout_s` passes; its
    last value. (A string predicate in wait_for_function can need eval, which
    the server's CSP refuses.)"""
    end = time.monotonic() + timeout_s
    while True:
        got = page.evaluate(expr)
        if got or time.monotonic() > end:
            return got
        time.sleep(0.1)


def hold_stream(addr):
    """Open /events and keep it, holding one of the server's stream slots."""
    host, port = addr.rsplit(":", 1)
    sock = socket.create_connection((host, int(port)))
    sock.sendall(f"GET /events HTTP/1.1\r\nHost: {addr}\r\nAccept: text/event-stream\r\n\r\n".encode())
    assert sock.recv(64).startswith(b"HTTP/1.1 200"), "a stream slot"
    return sock


LAYOUT = """() => {
  const wall = document.getElementById('wall');
  const cards = [...wall.children];
  const r = (el) => el.getBoundingClientRect();
  const shown = (el) => el.checkVisibility() && r(el).width > 0 && r(el).height > 0;
  const controls = [...document.querySelectorAll('a[href], button, input, [role=menuitem]')].filter(shown);
  return {
    served: document.documentElement.classList.contains('served'),
    density: wall.dataset.density,
    cards: cards.length,
    lefts: [...new Set(cards.map((c) => Math.round(r(c).left)))],
    widths: [...new Set(cards.map((c) => Math.round(r(c).width)))],
    tones: cards.map((c) => [...c.classList].find((k) => k.startsWith('tone-'))),
    hscroll: document.documentElement.scrollWidth - document.documentElement.clientWidth,
    small: controls.filter((c) => r(c).width < 44 || r(c).height < 44).map((c) => `${c.className || c.tagName} ${Math.round(r(c).width)}x${Math.round(r(c).height)}`),
    desktop: [...document.querySelectorAll(%s)].filter(shown).map((c) => c.className || c.id),
    remotes: [...document.querySelectorAll('a.remote')].filter(shown).map((a) => a.href),
    needs: document.querySelector('.tally .t-needs b')?.textContent,
  };
}""" % json.dumps(DESKTOP)

# What the gauges show: each row's words, its ring, and the colours to judge.
GAUGES = """() => {
  const limits = document.querySelector('.limits');
  const css = (el, p) => el && getComputedStyle(el)[p];
  const rows = [...limits.querySelectorAll('.limit-rows > li')].map((li) => {
    const fill = li.querySelector('.ring-fill');
    const r = li.getBoundingClientRect();
    return {
      text: ['pct', 'sub', 'label'].map((k) => li.querySelector('.' + k).textContent).join(' '),
      said: li.querySelector('.said').textContent,
      hidden: li.querySelector('.row').getAttribute('aria-hidden'),
      ring: fill.style.visibility !== 'hidden' && li.querySelector('.ring').checkVisibility(),
      dash: fill.style.strokeDasharray,
      stroke: css(fill, 'stroke'),
      track: css(li.querySelector('.ring-track'), 'stroke'),
      pct: css(li.querySelector('.pct'), 'color'),
      sub: css(li.querySelector('.sub'), 'color'),
      label: css(li.querySelector('.label'), 'color'),
      box: [r.left, r.right, r.top, r.bottom].map(Math.round),
    };
  });
  const bar = document.querySelector('.bar');
  return {
    shown: limits.checkVisibility(),
    inBar: bar.contains(limits),
    region: [limits.tagName, limits.getAttribute('aria-label')],
    wait: limits.querySelector('.limit-wait').checkVisibility() ? limits.querySelector('.limit-wait').textContent : null,
    rows,
    ground: css(bar, 'backgroundColor'),
    scheme: css(document.documentElement, 'colorScheme'),
    width: innerWidth,
  };
}"""


def rgb(c):
    return [int(x) for x in c[c.index("(") + 1:c.index(")")].split(",")[:3]]


def contrast(a, b):
    def lum(c):
        ch = [v / 255 for v in rgb(c)]
        ch = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in ch]
        return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2]
    hi, lo = sorted([lum(a), lum(b)], reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def check_gauges(run, page, scheme):
    """The demo gauges in `scheme`: shown in the bar, words at 4.5:1, the ring's fill at 3:1 on the bar and its track."""
    page.emulate_media(color_scheme=scheme)
    page.wait_for_timeout(100)
    g = page.evaluate(GAUGES)
    run.check(g["scheme"] == "dark", f"{scheme}: the wall stays dark, and says so to the browser", g["scheme"])
    low = []
    for row in g["rows"]:
        for k in ("pct", "sub", "label"):
            if contrast(row[k], g["ground"]) < 4.5:
                low.append((row["text"], k, round(contrast(row[k], g["ground"]), 2)))
        for k in ("ground", "track"):
            against = g["ground"] if k == "ground" else row["track"]
            if row["ring"] and contrast(row["stroke"], against) < 3:
                low.append((row["text"], f"ring on {k}", round(contrast(row["stroke"], against), 2)))
    run.check(g["rows"] and low == [], f"{scheme}: every gauge reads at AA", low or g)
    return g


def main() -> int:
    shot = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(tempfile.gettempdir()) / "klepsydra-phone-390x844.png"
    run = Run()
    with tempfile.TemporaryDirectory(prefix="klepsydra-phone-") as tmp:
        snapshot = pathlib.Path(tmp) / "fleet.json"
        fleet = snapshot_file(snapshot)
        write_clip(pathlib.Path(tmp) / "klepsydra")
        needs = sum(s["status"] == "needs_you" for s in fleet["sessions"])
        proc, addr = start_server(snapshot)
        # After the build, so the countdowns read as written.
        demo_usage(pathlib.Path(tmp) / "klepsydra")
        try:
            with sync_playwright() as p:
                browser = p.chromium.launch(executable_path=os.environ.get("KLEPSYDRA_CHROME") or None)
                ctx = browser.new_context(
                    viewport={"width": 390, "height": 844},
                    device_scale_factor=3,
                    is_mobile=True,
                    has_touch=True,
                )
                opened = []
                ctx.route("https://claude.ai/**", lambda route: (opened.append(route.request.url), route.fulfill(status=200, body="claude"))[1])
                page = ctx.new_page()
                page.goto(f"http://{addr}/")
                shown = wait_until(page, "document.getElementById('wall').children.length === 16", 15)
                run.check(shown, "sixteen cards arrive over the stream", shown)
                page.wait_for_timeout(400)
                s = page.evaluate(LAYOUT)
                run.check(s["served"], "the page knows it is served", s["served"])
                run.check(s["density"] == "compact", "compact cards", s["density"])
                run.check(len(s["lefts"]) == 1 and len(s["widths"]) == 1, "one column", (s["lefts"], s["widths"]))
                run.check(s["widths"][0] >= 340, "a card spans the screen", s["widths"])
                run.check(s["tones"][:needs] == ["tone-needs"] * needs and "tone-needs" not in s["tones"][needs:], "needs-you cards first", s["tones"])
                run.check(s["hscroll"] <= 0, "no horizontal scroll", s["hscroll"])
                run.check(s["small"] == [], "every visible control is at least 44 px", s["small"])
                run.check(s["desktop"] == [], "no desktop action shows", s["desktop"])
                tools = page.evaluate("getComputedStyle(document.querySelector('.tools')).display")
                run.check(tools == "none", "the desktop tool group takes no room on the phone", tools)
                run.check(s["remotes"] == [REMOTE], "only the claude.ai link is a link", s["remotes"])

                # The usage-limit gauges: every account and window, in the gauge's words and order.
                wait_until(page, "document.querySelectorAll('.limit-rows > li').length === 3", 10)
                g = page.evaluate(GAUGES)
                run.check(g["shown"] and g["inBar"] and g["region"] == ["SECTION", "Usage limits"], "the gauges show in the bar, a named region", g)
                texts = [r["text"] for r in g["rows"]]
                want = [r"57% [78]m Personal \u00b7 session", r"27% 6d 6h Personal \u00b7 week", r"0% reset 7h ago Team \u00b7 session"]
                run.check(len(texts) == 3 and all(re.fullmatch(w, t) for w, t in zip(want, texts)),
                          "one gauge per account and window, as the strip reads them", texts)
                said = [r["said"] for r in g["rows"]]
                run.check(re.fullmatch(r"Personal \u00b7 session: 57% used\. Resets in [78] min", said[0]) and all(r["hidden"] == "true" for r in g["rows"]),
                          "a screen reader hears one sentence per gauge, not its short forms", said)
                run.check([r["ring"] for r in g["rows"]] == [True, True, False], "a ring per window, none drawn on a reset one", [r["ring"] for r in g["rows"]])
                # The drawn arc is the percent: the dash plus its round caps (3 wide on r 9.5).
                cap = 3 / (2 * 3.141592653589793 * 9.5) * 100
                arcs = [round(float(r["dash"].replace(",", " ").split()[0]) + cap) if r["dash"] else None for r in g["rows"][:2]]
                run.check(arcs == [57, 27], "each ring's arc is its percent, on a gauge drawn fresh", [r["dash"] for r in g["rows"]])
                run.check(all(0 <= r["box"][0] and r["box"][1] <= g["width"] for r in g["rows"]), "every gauge inside the screen", [r["box"] for r in g["rows"]])
                run.check(g["rows"][0]["stroke"] == "rgb(59, 130, 246)", "the ramp's low stop under 60%", g["rows"][0]["stroke"])
                for scheme in ("light", "dark"):
                    check_gauges(run, page, scheme)
                    page.screenshot(path=str(shot.with_name(f"{shot.stem}-{scheme}{shot.suffix}")))
                    print(f"  shot {shot.with_name(f'{shot.stem}-{scheme}{shot.suffix}')}")
                page.emulate_media(color_scheme=None)
                page.screenshot(path=str(shot))
                print(f"  shot {shot}")

                # A card's reply button plays keryx's clip from the server, on the phone.
                plays = page.evaluate("[...document.querySelectorAll('.card .play')].filter((b) => b.checkVisibility()).length")
                with_clip = sum("reply_at" in s for s in fleet["sessions"])
                run.check(plays == with_clip, "a play button on each card keryx kept a reply for", [plays, with_clip])
                got = page.evaluate("""async (id) => {
                  const a = await fetch(`/audio/${id}`);
                  const demo = await fetch('/audio/demo-1-am_michael');
                  return [a.status, a.headers.get('content-type'), (await a.arrayBuffer()).byteLength, demo.status];
                }""", CLIP_ID)
                run.check(got[:2] == [200, "audio/wav"] and got[2] > 44 and got[3] == 404, "the server sends that card's clip, and only for a real session", got)
                button = page.locator(f'.card[data-key="{CLIP_ID}"] .play')
                button.click()
                playing = wait_until(page, f"!!document.querySelector('.card[data-key=\"{CLIP_ID}\"] .play.playing')", 3)
                src = page.evaluate("document.getElementById('reply-audio').getAttribute('src')")
                run.check(playing and src.startswith(f"/audio/{CLIP_ID}?at="), "a tap plays it from the server", [playing, src])
                stopped = wait_until(page, f"!document.querySelector('.card[data-key=\"{CLIP_ID}\"] .play.playing')", 5)
                label = button.get_attribute("aria-label")
                run.check(stopped and label.startswith("Play "), "it ends by itself and the button reads Play again", [stopped, label])

                # The tally stays at the top while the wall scrolls under it.
                page.evaluate("window.scrollTo(0, document.documentElement.scrollHeight)")
                page.wait_for_timeout(200)
                bar = page.evaluate("(() => { const b = document.querySelector('.bar').getBoundingClientRect(); return [Math.round(b.top), scrollY > 0]; })()")
                run.check(bar == [0, True], "the tally is sticky", bar)
                held = page.evaluate("(() => { const l = document.querySelector('.limits').getBoundingClientRect(); const w = document.getElementById('wall').getBoundingClientRect(); return [l.top >= 0 && l.bottom <= innerHeight, Math.round(l.bottom) <= Math.round(document.querySelector('.bar').getBoundingClientRect().bottom), Math.round(w.height) > innerHeight]; })()")
                run.check(held == [True, True, True], "the gauges stay in view with the tally", held)
                page.evaluate("window.scrollTo(0, 0)")

                # A tap on the card, off its controls, opens its Remote Control link.
                card = page.locator(".card.has-remote")
                run.check(card.count() == 1, "one card has a link", card.count())
                clash = card.evaluate("""(c) => {
                  const r = (el) => el.getBoundingClientRect();
                  const link = r(c.querySelector('a.remote'));
                  const hit = (b) => b.width > 0 && b.height > 0 && b.left < link.right && link.left < b.right && b.top < link.bottom && link.top < b.bottom;
                  const texts = [...c.querySelectorAll('.name, .task, .pill, .where, .ledger-line, .prompt, .reply, .ask')].filter((e) => e.checkVisibility());
                  const name = c.querySelector('.name');
                  return {covers: texts.filter((e) => hit(r(e))).map((e) => e.className), nameCut: name.scrollWidth > name.clientWidth};
                }""")
                run.check(clash == {"covers": [], "nameCut": False}, "the link covers no text and leaves the name whole", clash)
                with ctx.expect_page() as popup:
                    card.locator(".task").tap()
                tab = popup.value
                tab.wait_for_load_state()
                run.check(tab.url == REMOTE, "a tap on the card opens its session", tab.url)
                tab.close()
                page.bring_to_front()
                plain = page.locator(".card:not(.has-remote)").first
                before = len(ctx.pages)
                plain.locator(".task").tap()
                page.wait_for_timeout(300)
                run.check(len(ctx.pages) == before, "a card without a link is no link", len(ctx.pages))

                # A second snapshot arrives over /events.
                def one_more_needs(f):
                    working = next(s for s in f["sessions"] if s["status"] == "working")
                    working["status"] = "needs_you"
                    working["reason"] = "question"
                snapshot_file(snapshot, one_more_needs)
                # Polled, not on animation frames: the closed tab may leave this one in the background.
                wait_until(page, f"document.querySelector('.tally .t-needs b').textContent === '{needs + 1}'", 5)
                got = page.evaluate(LAYOUT)["needs"]
                run.check(got == str(needs + 1), "a new snapshot arrives over the stream", got)

                # A new reading arrives over the stream; one three hours old says so.
                klepsydra = pathlib.Path(tmp) / "klepsydra"
                write_reading(klepsydra, PERSONAL, "Personal", {"five_hour": (91, 8 * 60 + 50), "seven_day": (27, (6 * 24 + 6) * 3600 + 1800)})
                write_reading(klepsydra, TEAM, "Team", {"five_hour": (12, 2 * 3600 + 600)}, ago=3 * 3600, session="00000000-0000-4000-8000-000000000002")
                wait_until(page, "document.querySelector('.limit-rows > li .pct').textContent === '91%' && document.querySelectorAll('.limit-rows > li .ring-fill')[2].style.visibility !== 'hidden'", 15)
                g = page.evaluate(GAUGES)
                texts = [r["text"] for r in g["rows"]]
                run.check(re.fullmatch(r"91% [78]m Personal \u00b7 session", texts[0]) and g["rows"][0]["stroke"] == "rgb(239, 68, 68)", "a new reading arrives over the stream, red past 85%", [texts[0], g["rows"][0]["stroke"]])
                run.check(re.fullmatch(r"12% 2h (10|9)m \u00b7 3h old Team \u00b7 session", texts[2]), "a reading hours old says how old", texts[2])
                s = page.evaluate(LAYOUT)
                run.check(s["hscroll"] <= 0 and s["small"] == [], "no horizontal scroll, every control 44 px, with the gauges", [s["hscroll"], s["small"]])

                # No reading left: the gauges wait, as the strip does.
                for f in (klepsydra / "accounts").glob("*/*.json"):
                    f.unlink()
                wait_until(page, "document.querySelectorAll('.limit-rows > li').length === 0", 15)
                g = page.evaluate(GAUGES)
                run.check(g["shown"] and g["rows"] == [] and g["wait"] == "waiting for Claude Code", "with no reading the gauges wait", g)
                demo_usage(klepsydra)
                wait_until(page, "document.querySelectorAll('.limit-rows > li').length === 3", 15)

                # Install: the service worker controls the page's scope, the manifest loads.
                scope = page.evaluate("navigator.serviceWorker.ready.then((r) => r.scope)")
                run.check(scope == f"http://{addr}/", "the service worker is ready", scope)
                manifest = page.evaluate("fetch('/manifest.webmanifest').then(async (r) => [r.status, r.headers.get('content-type'), (await r.json()).display])")
                run.check(manifest == [200, "application/manifest+json", "standalone"], "the manifest is served", manifest)
                icon = page.evaluate("fetch('/phone/apple-touch-icon.png').then((r) => [r.status, r.headers.get('content-type')])")
                run.check(icon == [200, "image/png"], "the Home Screen icon is served", icon)
                cut = page.evaluate("fetch('/fleet.json').then((r) => r.json()).then((v) => [v.sessions.length, 'tmux' in v.sessions[0], 'receiver' in v])")
                run.check(cut == [16, False, False], "fleet.json carries only the wall's fields", cut)
                post = page.evaluate("fetch('/fleet.json', {method: 'POST', body: '{}'}).then((r) => r.status)")
                run.check(post in (403, 405), "a write from the page is refused", post)

                # A wrap-up request: the readiness count and each card's answer
                # show; Wrap up, Stop and End all ready do not.
                snapshot_file(snapshot, with_wrapup)
                # The bar paints at once; the cards may repaint inside a view transition.
                wait_until(page, "!document.querySelector('.wrapup-bar').hidden && !!document.querySelector('.card .wrapup:not([hidden])')", 5)
                wrap = page.evaluate("""() => {
                  const shown = (el) => el && el.checkVisibility();
                  return {
                    bar: shown(document.querySelector('.wrapup-bar')),
                    count: document.querySelector('.wrapup-count').textContent,
                    lines: [...document.querySelectorAll('.card .wrapup')].filter(shown).map((e) => e.textContent),
                  };
                }""")
                live = sum(s["status"] != "ended" for s in fleet["sessions"])
                run.check(wrap["bar"], "a wrap-up request shows its bar", wrap)
                run.check(wrap["count"].endswith(f" of {live} ready"), "the bar counts the ready sessions", wrap["count"])
                run.check(any(t.startswith("Not ready: a review agent") for t in wrap["lines"]), "a card shows its session's answer", wrap["lines"])
                run.check(any(t == "Ready" for t in wrap["lines"]), "a ready session reads Ready", wrap["lines"])
                s = page.evaluate(LAYOUT)
                run.check(s["desktop"] == [], "no wrap-up action shows", s["desktop"])
                run.check(s["hscroll"] <= 0, "no horizontal scroll with the wrap-up bar", s["hscroll"])

                # The empty state, with ended cards to clear: no Start or Clear.
                for what, keep in (("only ended sessions", lambda x: x["status"] == "ended"), ("no sessions", lambda x: False)):
                    snapshot_file(snapshot, lambda f: f.update(sessions=[x for x in f["sessions"] if keep(x)]) or f.pop("wrapup", None))
                    wait_until(page, "!document.getElementById('empty').hidden", 5)
                    shown = page.evaluate("document.getElementById('empty').checkVisibility()")
                    run.check(shown, f"the empty state shows with {what}", shown)
                    s = page.evaluate(LAYOUT)
                    run.check(s["desktop"] == [], f"no empty-state action shows with {what}", s["desktop"])

                # The page by its file name is sent to the root, where it knows it is served.
                page.goto(f"http://{addr}/wall.html")
                at = [page.url, page.evaluate("document.documentElement.classList.contains('served')")]
                run.check(at == [f"http://{addr}/", True], "/wall.html is the served wall at the root", at)
                browser.close()

            # Every stream slot taken: the page's stream is refused with a 503,
            # which an EventSource never retries; the page opens it again.
            snapshot_file(snapshot)
            held = [hold_stream(addr) for _ in range(8)]
            with sync_playwright() as p:
                browser = p.chromium.launch(executable_path=os.environ.get("KLEPSYDRA_CHROME") or None)
                page = browser.new_page(viewport={"width": 390, "height": 844})
                page.goto(f"http://{addr}/")
                wait_until(page, "!document.getElementById('link').hidden", 10)
                refused = page.evaluate("document.getElementById('wall').children.length")
                run.check(refused == 0, "a refused stream shows no wall", refused)
                for h in held:
                    h.close()
                wait_until(page, "document.getElementById('wall').children.length === 16", 60)
                back = page.evaluate("[document.getElementById('wall').children.length, document.getElementById('link').hidden]")
                run.check(back == [16, True], "the stream is opened again once a slot frees", back)
                browser.close()
        finally:
            proc.kill()
            proc.wait()
    print(f"{run.passed} passed, {run.failed} failed")
    return 1 if run.failed else 0


if __name__ == "__main__":
    sys.exit(main())
