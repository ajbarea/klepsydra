import { test } from "node:test";
import assert from "node:assert/strict";

// A just-enough DOM for the dock: elements, text, dataset, events, focus.
class El {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.parent = null;
    this.dataset = {};
    this.attrs = {};
    this.style = { setProperty: (k, v) => (this.style[k] = v) };
    this.className = "";
    this.text = "";
    this.title = "";
    this.innerHTML = "";
    this.hidden = false;
    this.checked = false;
    this.listeners = {};
    this.classList = { add: (c) => (this.className = `${this.className} ${c}`.trim()) };
  }
  set textContent(t) { this.text = t; }
  get textContent() { return this.text; }
  get firstChild() { return this.children[0]; }
  append(...kids) { kids.forEach((k) => this.insertBefore(k, null)); }
  replaceChildren(...kids) { this.children = []; this.append(...kids); }
  insertBefore(kid, ref) {
    if (typeof kid !== "string") {
      kid.parent?.children.splice(kid.parent.children.indexOf(kid), 1);
      kid.parent = this;
    }
    const i = ref ? this.children.indexOf(ref) : this.children.length;
    this.children.splice(i < 0 ? this.children.length : i, 0, kid);
  }
  remove() { this.parent?.children.splice(this.parent.children.indexOf(this), 1); this.parent = null; }
  setAttribute(k, v) { this.attrs[k] = v; }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  fire(type) { for (const fn of this.listeners[type] ?? []) fn({ type }); }
  focus() { focused = this; }
}
let focused = null;
globalThis.document = { createElement: (t) => new El(t) };

const { WAITING, toRows } = await import("./gauge.js");
const { DOCK_KEY, dockOn, wireDock } = await import("./fleet/dock.js");

const NOW = Date.UTC(2026, 10, 19, 15, 0);
const S = NOW / 1000;
const ROWS = toRows([{ account: "me", label: "Personal", written_at: S - 60, observed_at: S - 60, windows: { five_hour: { used_percentage: 34, resets_at: S + 3600 } } }], NOW);
const LOOK = () => ({ stops: { low: "#0f0", mid: "#ff0", high: "#f00", midAt: 60, highAt: 85 }, mode: "bands" });

function els() {
  return { dock: new El("div"), chips: new El("div"), wait: new El("p"), hide: new El("button"), pick: new El("input"), gear: new El("summary") };
}
const quiet = () => {
  const warned = [];
  return { warned, warn: (...a) => warned.push(a) };
};
const phone = () => {
  const e = els();
  return { e, dock: wireDock({ els: e, inTauri: false, log: quiet(), look: LOOK }) };
};
/** The app's side: a push channel and a command whose answers the test gives. */
function app() {
  const e = els();
  const log = quiet();
  const calls = [];
  const answers = [];
  const changes = [];
  let push = null;
  const invoke = (command, args) => {
    calls.push([command, args]);
    return new Promise((ok, no) => answers.push({ ok, no }));
  };
  const follow = (command, fn) => {
    assert.equal(command, "toggles_subscribe");
    push = fn;
    return Promise.resolve();
  };
  const dock = wireDock({ els: e, inTauri: true, invoke, follow, log, look: LOOK, onChange: (on) => changes.push(on) });
  return { e, dock, log, calls, answers, changes, push: (m) => push(m) };
}
const settle = () => new Promise((r) => setTimeout(r));

test("no usage source: the dock stays hidden; no reading yet: it waits; a reading: one chip per account", () => {
  const { e, dock } = phone();
  dock.paint(null, NOW);
  assert.equal(e.dock.hidden, true, "an older server sends no usage");
  dock.paint([], NOW);
  assert.equal(e.dock.hidden, false);
  assert.equal(e.wait.hidden, false);
  assert.equal(e.wait.textContent, WAITING);
  assert.equal(e.chips.children.length, 0, "the Copilot placeholder alone is not a reading");
  dock.paint(ROWS, NOW);
  assert.equal(e.wait.hidden, true);
  assert.equal(e.chips.dataset.layout, "linear", "the header draws the strip's linear row");
  assert.deepEqual(e.chips.children.map((c) => c.dataset.harness), ["copilot", "claude"], "route order, the placeholder labelled");
});

test("on the phone the gauges always show: it is read-only, with no gear and no chevron", async () => {
  const { e, dock } = phone();
  dock.paint(ROWS, NOW);
  assert.equal(dock.isOn(), true);
  assert.equal(e.dock.hidden, false);
  const { readFileSync } = await import("node:fs");
  const css = readFileSync(new URL("./fleet/wall.css", import.meta.url), "utf8");
  assert.match(css, /\.served button:not\(\[data-phone\]\),\s*\.served \.gear,/, "the chevron and the gear are hidden there");
  const html = readFileSync(new URL("./wall.html", import.meta.url), "utf8");
  assert.doesNotMatch(html.match(/<button type="button" class="clear dock-hide"[^>]*>/)[0], /data-phone/);
});

test("the chevron hides and saves, focus lands on the gear, and the gear brings them back", async () => {
  const a = app();
  a.push({ [DOCK_KEY]: true });
  a.dock.paint(ROWS, NOW);
  assert.equal(a.e.pick.checked, true, "on before anyone chooses");
  a.e.hide.fire("click");
  assert.equal(a.e.dock.hidden, true);
  assert.equal(a.e.pick.checked, false, "the gear shows the choice");
  assert.equal(focused, a.e.gear, "the chevron leaves with the dock, so focus goes where it comes back");
  a.answers.shift().ok();
  await settle();
  a.e.pick.checked = true;
  a.e.pick.fire("change");
  assert.equal(a.e.dock.hidden, false);
  assert.deepEqual(a.calls, [["set_gauge_toggle", { key: DOCK_KEY, on: false }], ["set_gauge_toggle", { key: DOCK_KEY, on: true }]]);
  assert.deepEqual(a.changes, [false, true], "the wall hears each change, once");
});

test("in the app the saved choice comes from toggles_subscribe; a save is held, and a refused one goes back", async () => {
  const a = app();
  a.dock.paint(ROWS, NOW);
  a.push({ [DOCK_KEY]: false, other: true });
  assert.equal(a.e.dock.hidden, true, "the saved off");
  a.e.pick.checked = true;
  a.e.pick.fire("change");
  assert.deepEqual(a.calls, [["set_gauge_toggle", { key: DOCK_KEY, on: true }]]);
  assert.equal(a.e.dock.hidden, false, "shown at once");
  a.push({ [DOCK_KEY]: false });
  assert.equal(a.e.dock.hidden, false, "a push from before the save does not undo it");
  a.answers.shift().no("prefs.json could not be saved");
  await settle();
  assert.equal(a.e.dock.hidden, true, "refused: back to the saved choice");
  assert.equal(a.log.warned.length, 1);
});

test("a message without the key, or not an object, means on", () => {
  for (const m of [{}, null, undefined, { [DOCK_KEY]: true }, { [DOCK_KEY]: "false" }]) assert.equal(dockOn(m), true, JSON.stringify(m));
  assert.equal(dockOn({ [DOCK_KEY]: false }), false);
});

test("the key is the app's (klepsydra_fleet::toggles::GAUGES_IN_HEADER) and the dock reads at the strip's pace", async () => {
  const { readFileSync } = await import("node:fs");
  const rust = readFileSync(new URL("../src-tauri/fleet/src/toggles.rs", import.meta.url), "utf8");
  assert.match(rust, new RegExp(`pub const GAUGES_IN_HEADER: Toggle = Toggle \\{\\s*key: "${DOCK_KEY}",\\s*default: true,`));
  const { DOCK_USAGE_MS } = await import("./fleet/dock.js");
  const main = readFileSync(new URL("./main.js", import.meta.url), "utf8");
  assert.equal(DOCK_USAGE_MS, Number(main.match(/const POLL_MS = ([\d_]+);/)[1].replace(/_/g, "")));
});
