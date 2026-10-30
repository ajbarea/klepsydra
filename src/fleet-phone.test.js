// The phone wall: the page served by the phone wall server (src-tauri/fleet/src/phone.rs).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { card, needsFirst, remoteLink } from "./fleet/model.js";

const ROOT = join(import.meta.dirname, "..");
const read = (f) => readFileSync(join(ROOT, f), "utf8");
globalThis.window ??= {};
const feed = await import("./fleet/feed.js");

test("the page is served when it is the phone server's root, and never inside the app", () => {
  assert.equal(feed.feedKind(false, "", "/"), "served");
  assert.equal(feed.feedKind(false, "?source=pwa", "/"), "served");
  assert.equal(feed.feedKind(true, "", "/"), "app");
  assert.equal(feed.feedKind(false, "?demo", "/"), "demo");
  assert.equal(feed.feedKind(false, "?demo=8", "/src/wall.html"), "demo");
  assert.equal(feed.feedKind(false, "", "/wall.html"), "dev");
  assert.equal(feed.feedKind(false, "", "/src/wall.html"), "dev");
  assert.equal(feed.served, false, "node has no location: not served");
});

class FakeSource {
  static made = [];
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    FakeSource.made.push(this);
  }
  close() {
    this.closed = true;
    this.readyState = 2;
  }
}

test("on the phone the wall follows /events, a snapshot per event", () => {
  const got = [];
  const link = [];
  const source = feed.followServed((m) => got.push(m), (up) => link.push(up), FakeSource);
  assert.equal(source.url, "/events");
  source.onopen();
  const first = { sessions: [{ session_id: "a", status: "working" }], speaking: null };
  source.onmessage({ data: JSON.stringify(first) });
  source.onmessage({ data: "{not json" });
  source.onmessage({ data: JSON.stringify({ focus: "a" }) });
  source.onmessage({ data: JSON.stringify(null) });
  const second = { sessions: [], speaking: null };
  source.onerror();
  source.onmessage({ data: JSON.stringify(second) });
  assert.deepEqual(got, [first, second], "only snapshots reach the wall");
  assert.deepEqual(link, [true, true, false, true], "a lost stream says so until the next snapshot");
});

test("a stream the browser closed for good (a 503 at the stream cap, a 502 while klepsydra restarts) is opened again, backing off", () => {
  FakeSource.made = [];
  const waits = [];
  let due = null;
  const later = (fn, ms) => {
    waits.push(ms);
    due = fn;
  };
  const link = [];
  feed.followServed(() => {}, (up) => link.push(up), FakeSource, later);
  const fail = (state) => {
    const s = FakeSource.made.at(-1);
    s.readyState = state;
    s.onerror();
    return s;
  };
  const retry = () => {
    const fn = due;
    due = null;
    fn();
  };
  fail(0);
  assert.deepEqual(waits, [], "a stream the browser reconnects itself is left to it");
  assert.equal(FakeSource.made.length, 1);
  for (let i = 0; i < 7; i++) {
    const old = fail(2);
    assert.equal(old.closed, true, "the dead source is closed");
    retry();
  }
  assert.deepEqual(waits, [1000, 2000, 4000, 8000, 16000, 30000, 30000], "1 s doubling, at most 30 s");
  assert.equal(FakeSource.made.length, 8, "a new source after each wait");
  assert.ok(FakeSource.made.every((s) => s.url === "/events"));
  FakeSource.made.at(-1).onopen();
  fail(2);
  assert.equal(waits.at(-1), 1000, "an open stream resets the wait");
  assert.equal(link.at(-1), false);
  retry();
  FakeSource.made.at(-1).onmessage({ data: JSON.stringify({ sessions: [], speaking: null }) });
  assert.equal(link.at(-1), true, "the wall hears the stream is back");
});

test("the served feed is wired: subscribe takes the event stream when served", () => {
  const src = read("src/fleet/feed.js");
  const sub = src.slice(src.indexOf("export function subscribe("), src.indexOf("\n}\n", src.indexOf("export function subscribe(")));
  assert.match(sub, /if \(inTauri\) \{[\s\S]*?return;\s*\}\s*if \(served\) \{\s*followServed\(onMessage, onLink\);\s*return;/);
  assert.match(src, /new Source\("\/events"\)/);
  assert.match(read("src/fleet/wall.js"), /subscribe\(receive, showLink\)/);
});

test("needs-you cards come first, each group in the reader's order", () => {
  const s = (id, status) => ({ session_id: id, status });
  const order = needsFirst([s("a", "working"), s("b", "needs_you"), s("c", "done"), s("d", "needs_you"), s("e", "error")]);
  assert.deepEqual(order.map((x) => x.session_id), ["b", "d", "a", "c", "e"]);
  assert.deepEqual(needsFirst([]), []);
  assert.match(read("src/fleet/wall.js"), /const fresh = castPicks\(message\.sessions, cast\);/);
  assert.match(read("src/fleet/wall.js"), /sessions = served \? needsFirst\(fresh\) : fresh;/);
});

test("only a claude.ai Claude Code session link becomes the card's link", () => {
  assert.equal(remoteLink("https://claude.ai/code/session_01AbC-x_9"), "https://claude.ai/code/session_01AbC-x_9");
  for (const bad of [
    null,
    undefined,
    1,
    "",
    "https://claude.ai/code/",
    "http://claude.ai/code/session_01",
    "https://claude.ai.evil.example/code/session_01",
    "https://claude.ai/code/session_01?next=x",
    "https://claude.ai/code/session_01/../x",
    "javascript:alert(1)//https://claude.ai/code/x",
    `https://claude.ai/code/${"a".repeat(129)}`,
  ]) assert.equal(remoteLink(bad), null, String(bad));
  const base = { session_id: "11111111-2222-4333-8444-555555555555", status: "working", status_at: 1, updated_at: 1 };
  assert.equal(card({ ...base, remote_url: "https://claude.ai/code/session_01x" }, { characters: {} }, 2000).remote, "https://claude.ai/code/session_01x");
  assert.equal(card({ ...base, remote_url: "https://evil.example/x" }, { characters: {} }, 2000).remote, null);
  assert.equal(card(base, { characters: {} }, 2000).remote, null);
});

test("on the phone every desktop action is hidden: only buttons marked data-phone show", () => {
  const html = read("src/wall.html");
  const css = read("src/fleet/wall.css");
  const wall = read("src/fleet/wall.js");
  assert.match(css, /\.served button:not\(\[data-phone\]\),\s*\.served \.density,\s*\.served \.theme-pick,\s*\.served \.tools \{ display: none !important; \}/);
  const buttons = [...html.matchAll(/<button\b[^>]*>/g)].map((m) => m[0]);
  const phone = buttons.filter((b) => /\bdata-phone\b/.test(b));
  assert.deepEqual(
    phone.map((b) => (b.match(/class="([^"]+)"/) ?? b.match(/id="([^"]+)"/))[1]).sort(),
    ["agora-open", "ci-open", "close", "look", "play", "unfold"],
    "only the portrait's look, its Close, a card's reply button, its Full text, the CI list and the Agora feed act on the phone",
  );
  for (const action of ['id="new-session"', 'class="jump"', 'class="clear"', 'class="menu"', 'data-act="interrupt"', 'data-act="end"', 'class="undo"', 'class="end-confirm"', 'id="ledger-open"', 'class="chip"', 'class="agora-react"']) {
    const b = buttons.find((x) => x.includes(action));
    assert.ok(b, `${action} found`);
    assert.doesNotMatch(b, /data-phone/, `${action} is desktop-only`);
  }
  assert.doesNotMatch(wall, /createElement\("button"\)|<button/, "no button is made outside wall.html, where the rule could miss it");
  assert.match(wall, /document\.documentElement\.classList\.toggle\("served", served\)/);
});

test("a card's Remote Control link is a plain new-tab link, set only on the phone", () => {
  const html = read("src/wall.html");
  assert.match(html, /<a class="remote" target="_blank" rel="noopener noreferrer" hidden>Open in Claude<\/a>/);
  const wall = read("src/fleet/wall.js");
  assert.match(wall, /remote\.hidden = !\(served && c\.remote\);/);
  assert.match(wall, /if \(served && c\.remote\) \{\s*remote\.href = c\.remote;/);
  assert.match(wall, /if \(served && !e\.target\.closest\("a, button"\)\)/, "a tap on the card, not on its controls, opens the link");
});

test("the phone wall installs: manifest, Home Screen icon, and a shell-only service worker", () => {
  const manifest = JSON.parse(read("src/manifest.webmanifest"));
  assert.equal(manifest.display, "standalone");
  assert.equal(manifest.start_url, "/");
  assert.ok(manifest.name && manifest.short_name);
  assert.equal(manifest.theme_color, "#11151b");
  assert.deepEqual(manifest.icons.map((i) => i.sizes), ["192x192", "512x512"]);
  for (const icon of manifest.icons) {
    const png = readFileSync(join(ROOT, "src", icon.src));
    const [w, h] = [png.readUInt32BE(16), png.readUInt32BE(20)];
    assert.equal(`${w}x${h}`, icon.sizes, icon.src);
  }
  const html = read("src/wall.html");
  assert.match(html, /<link rel="manifest" href="manifest\.webmanifest" \/>/);
  assert.match(html, /<link rel="apple-touch-icon" href="phone\/apple-touch-icon\.png" \/>/);
  assert.match(html, /<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" \/>/);
  const touch = readFileSync(join(ROOT, "src/phone/apple-touch-icon.png"));
  assert.equal(`${touch.readUInt32BE(16)}x${touch.readUInt32BE(20)}`, "180x180");
  assert.equal(touch[25], 2, "opaque RGB: iOS fills a transparent icon with black");
  const sw = read("src/sw.js");
  assert.match(sw, /const LIVE = new Set\(\["\/fleet\.json", "\/events"\]\);/);
  assert.match(sw, /LIVE\.has\(url\.pathname\) \|\| url\.pathname\.startsWith\("\/audio\/"\)\) return;/, "the fleet and its clips are never answered from the cache");
  assert.match(read("src/fleet/wall.js"), /if \(served\) navigator\.serviceWorker\?\.register\("\/sw\.js"\)/);
});

test("every module the wall imports is a file the phone server serves", () => {
  const rs = read("src-tauri/fleet/src/phone.rs");
  const fn = rs.slice(rs.indexOf("pub fn asset_type"), rs.indexOf("_ => return None", rs.indexOf("pub fn asset_type")));
  const roots = [...fn.slice(0, fn.indexOf(");")).matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  const folders = [...fn.matchAll(/starts_with\("([^"]+)"\)/g)].map((m) => m[1]);
  const exts = [...fn.matchAll(/^\s*((?:"\w+"\s*\|\s*)*"\w+") =>/gm)].flatMap((m) => [...m[1].matchAll(/"(\w+)"/g)].map((x) => x[1]));
  const served = (p) => (roots.includes(p) || folders.some((f) => p.startsWith(f))) && exts.includes(p.split(".").pop());
  const seen = new Set();
  const walk = (file) => {
    if (seen.has(file)) return;
    seen.add(file);
    for (const [, spec] of read(`src/${file}`).matchAll(/^import\s[^;]*?from\s+"(\.{1,2}\/[^"]+)"/gm)) {
      walk(join(file, "..", spec).replaceAll("\\", "/"));
    }
  };
  walk("fleet/wall.js");
  assert.ok(seen.size > 10, `the walk found the wall's modules: ${[...seen]}`);
  assert.deepEqual([...seen].filter((p) => !served(p)), []);
});

// ── the usage-limit gauges ──────────────────────────────────────────────────
const { contrast } = await import("./fleet/contrast.js");
const token = (css, name) => css.match(new RegExp(`${name}:\\s*([^;]+);`))?.[1].trim();
const RAMP = ["--ramp-low", "--ramp-mid", "--ramp-high", "--ramp-mid-at", "--ramp-high-at", "--ramp-mode"];

test("the phone draws the gauge's rows with the gauge's own code: one model, no second formatter", () => {
  const wall = read("src/fleet/wall.js");
  const main = read("src/main.js");
  assert.match(wall, /import \{ WAITING, usageRows \} from "\.\.\/gauge\.js";/);
  assert.match(wall, /import \{ readMode, readStops, syncEntries \} from "\.\.\/gaugeview\.js";/);
  assert.match(main, /import \{ readMode, readStops, syncEntries \} from "\.\/gaugeview\.js";/);
  assert.match(wall, /syncEntries\(limitRows, rows, \{ compact: true, stops: readStops\(\), mode: readMode\(\) \}, true\);/);
  assert.match(main, /syncEntries\(rowsEl, rows, \{/);
  // The words and the ring's arithmetic live in gauge.js alone.
  const others = ["src/main.js", "src/gaugeview.js", ...["wall.js", "model.js", "strip.js", "drawer.js"].map((f) => `src/fleet/${f}`)];
  for (const f of others) {
    const src = read(f);
    assert.doesNotMatch(src, /function format|% used|Resets in|resets_at|used_percentage|2 \* Math\.PI|strokeDasharray = `/, f);
  }
  assert.doesNotMatch(read("src/index.html"), /<template id="row-tpl">/, "the row's markup is gaugeview.js's");
});

test("the wall's ramp is the gauge's", () => {
  const style = read("src/style.css");
  const wall = read("src/fleet/wall.css");
  for (const t of RAMP) {
    assert.ok(token(style, t), `${t} in style.css`);
    assert.equal(token(wall, t), token(style, t), t);
  }
});

test("the gauges read at AA on the phone's page: words 4.5:1, the ring's fill 3:1 on the page and its track", () => {
  const wall = read("src/fleet/wall.css");
  const bar = token(wall, "--wall-bg"); // the page the gauges sit on
  const track = token(wall, "--ring-track");
  for (const t of ["--ramp-low", "--ramp-mid", "--ramp-high"]) {
    const c = token(wall, t);
    assert.ok(contrast(c, bar) >= 3, `${t} on the page: ${contrast(c, bar).toFixed(2)}`);
    assert.ok(contrast(c, track) >= 3, `${t} on the track: ${contrast(c, track).toFixed(2)}`);
  }
  for (const t of ["--text", "--text-dim"]) {
    assert.ok(contrast(token(wall, t), bar) >= 4.5, t);
  }
  const rule = (sel) => wall.match(new RegExp(`${sel.replace(/[.*]/g, "\\$&")} \\{([^}]*)\\}`))?.[1] ?? "";
  assert.match(rule(".limits .pct"), /color: var\(--text\)/);
  for (const sel of [".limits .sub", ".limits .label", ".limit-wait"]) assert.match(rule(sel), /color: var\(--text-dim\)/, sel);
  assert.match(rule(".limits .ring-track"), /stroke: var\(--ring-track\)/);
  assert.match(wall, /html, body \{ background: var\(--wall-bg\);/, "the page the gauges sit on is --wall-bg");
  assert.doesNotMatch(rule(".limits"), /background/, "the gauges draw no ground of their own");
});

test("the gauges open the page, outside the sticky bar, shown only for a snapshot with readings", () => {
  const html = read("src/wall.html");
  const bar = html.slice(html.indexOf('<header class="bar">'), html.indexOf("</header>"));
  assert.doesNotMatch(bar, /limits/, "the sticky bar stays one tally high");
  assert.match(html, /<main id="main">\s*<section class="limits" aria-label="Usage limits" hidden>\s*<ul class="limit-rows"><\/ul>\s*<p class="limit-wait" hidden><\/p>\s*<\/section>\s*<h1 id="wall-title"[^>]*>[^<]*<\/h1>\s*<section id="wall"/, "the sessions heading sits right before the wall it names");
  const wall = read("src/fleet/wall.js");
  assert.match(wall, /const rows = usageRows\(latestSnapshot, now\);\s*limits\.hidden = rows === null;/);
  assert.match(wall, /paintTally\(\);\s*paintLimits\(now\);/, "drawn on every snapshot and every tick");
});
