import { test } from "node:test";
import assert from "node:assert/strict";

// A just-enough DOM for chipview: elements, text, classes, dataset, style.
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
    this.classList = { add: (c) => (this.className = `${this.className} ${c}`.trim()) };
  }
  set textContent(t) { this.text = t; }
  get textContent() { return this.text + this.children.map((c) => (typeof c === "string" ? c : c.textContent)).join(""); }
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
  has(cls) { return this.className.split(" ").includes(cls); }
  /** Every element under this one, depth first. */
  all() { return this.children.filter((c) => typeof c !== "string").flatMap((c) => [c, ...c.all()]); }
}
globalThis.document = { createElement: (t) => new El(t) };

const { toRows } = await import("./gauge.js");
const { toChips } = await import("./fleet/chips.js");
const { syncChips } = await import("./fleet/chipview.js");

const NOW = Date.UTC(2026, 10, 18, 18, 23);
const S = NOW / 1000;
const win = (pct, inSec) => ({ used_percentage: pct, resets_at: S + inSec });
const reading = (account, label, windows, extra = {}) => ({ account, label, written_at: S - 60, observed_at: S - 60, windows, ...extra });
const OPTS = { now: NOW, stops: { low: "#0f0", mid: "#ff0", high: "#f00", midAt: 60, highAt: 85 }, mode: "ramp" };
const draw = (payload, layout) => {
  const box = new El("div");
  const chips = toChips(toRows(payload, NOW), NOW);
  syncChips(box, chips, { ...OPTS, layout });
  return { box, chips };
};
const pips = (chipEl) => chipEl.all().filter((e) => e.has("pip"));
const PERSONAL = reading("me", "Personal", { five_hour: win(9, 10_620), seven_day: win(45, 430_000) });

test("the lead window's pip carries data-lead in both layouts (the tray icon reads its colour)", () => {
  for (const layout of ["linear", "stacked"]) {
    const { box, chips } = draw([PERSONAL], layout);
    const me = box.children.find((c) => c.dataset.key === "me");
    const led = pips(me).filter((p) => "lead" in p.dataset);
    assert.equal(led.length, 1, layout);
    assert.equal(chips.find((c) => c.key === "me").lead.window, "seven_day");
    // The stacked cells are in window order; its lead is the week, the second.
    if (layout === "stacked") assert.equal(pips(me).indexOf(led[0]), 1);
    assert.equal(led[0].has("big"), layout === "linear", "only the linear row draws the lead larger");
  }
});

test("a window kept from an older reading: its pip greys, its stacked cell says its age", () => {
  const fresh = reading("agy", "Google AI Pro", { five_hour: win(7, 6720) }, { harness: "agy" });
  const old = reading("agy", "Google AI Pro", { claude_gpt: win(100, 4 * 86_400) }, { harness: "agy", written_at: S - 2 * 86_400, observed_at: S - 2 * 86_400 });
  const linear = draw([fresh, old], "linear").box.children.find((c) => c.dataset.key === "agy");
  assert.deepEqual(pips(linear).map((p) => p.has("old")), [false, true]);
  assert.equal("stale" in linear.dataset, false, "the chip itself is fresh");
  const stacked = draw([fresh, old], "stacked").box.children.find((c) => c.dataset.key === "agy");
  const cells = stacked.all().filter((e) => e.has("cell"));
  assert.match(cells[1].textContent, /· 2d old$/);
  assert.doesNotMatch(cells[0].textContent, /old/);
});

test("a stacked chip names an age from 30 minutes; the linear row does not until stale", () => {
  const halfHour = reading("me", "Personal", { five_hour: win(9, 10_620) }, { written_at: S - 50 * 60, observed_at: S - 50 * 60 });
  const stacked = draw([halfHour], "stacked").box.children.find((c) => c.dataset.key === "me");
  assert.ok(stacked.all().some((e) => e.has("age") && e.textContent === "50m old"));
  const linear = draw([halfHour], "linear").box.children.find((c) => c.dataset.key === "me");
  assert.ok(!linear.all().some((e) => e.has("age")));
});

test("an unchanged chip is not rebuilt on the next redraw", () => {
  const box = new El("div");
  const chips = toChips(toRows([PERSONAL], NOW), NOW);
  syncChips(box, chips, { ...OPTS, layout: "linear" });
  const before = box.children.find((c) => c.dataset.key === "me").firstChild.children[0];
  syncChips(box, toChips(toRows([PERSONAL], NOW), NOW), { ...OPTS, layout: "linear" });
  assert.equal(box.children.find((c) => c.dataset.key === "me").firstChild.children[0], before);
});

test("the stacked grid has a column per window of the widest account", () => {
  const agy = reading("agy", "Google AI Pro", { five_hour: win(7, 6720), seven_day: win(4, 590_000), gemini: win(20, 7000), claude_gpt: win(50, 7740) }, { harness: "agy" });
  const { box } = draw([agy, PERSONAL], "stacked");
  assert.equal(box.style["--cells"], "4");
  assert.equal(draw([PERSONAL], "stacked").box.style["--cells"], "2");
});
