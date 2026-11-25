import { test } from "node:test";
import assert from "node:assert/strict";

// A just-enough DOM: elements with children, dataset, classList and listeners.
class El {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.parent = null;
    this.dataset = {};
    this.attrs = {};
    this.listeners = {};
    this.classes = new Set();
    this.hidden = false;
    this.innerHTML = "";
    this.classList = {
      add: (c) => this.classes.add(c),
      remove: (c) => this.classes.delete(c),
      has: (c) => this.classes.has(c),
      toggle: (c, on) => (on ? this.classes.add(c) : this.classes.delete(c)),
    };
  }
  removeAttribute(k) { delete this.attrs[k]; delete this.src; }
  get firstChild() { return this.children[0]; }
  get lastChild() { return this.children.at(-1); }
  append(...kids) { kids.forEach((k) => this.insertBefore(k, null)); }
  insertBefore(kid, ref) {
    kid.parent?.children.splice(kid.parent.children.indexOf(kid), 1);
    kid.parent = this;
    const i = ref ? this.children.indexOf(ref) : this.children.length;
    this.children.splice(i < 0 ? this.children.length : i, 0, kid);
  }
  remove() { this.parent?.children.splice(this.parent.children.indexOf(this), 1); this.parent = null; }
  setAttribute(k, v) { this.attrs[k] = v; }
  getAttribute(k) { return this.attrs[k] ?? null; }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  closest(sel) {
    for (let e = this; e; e = e.parent) if (sel === ".face" && e.className === "face") return e;
    return null;
  }
  fire(type, target = this) { (this.listeners[type] ?? []).forEach((fn) => fn({ target })); }
}
globalThis.document = { createElement: (t) => new El(t), documentElement: {} };
globalThis.getComputedStyle = () => ({ getPropertyValue: (n) => (n === "--face-size" ? "28px" : "1") });

const { mountStrip } = await import("./fleet/strip.js");

const session = (id, status, extra = {}) => ({
  session_id: id, status, status_at: 1000, reason: null, voice: null, name: id, launch_dir: "/x", ...extra,
});
const NOW = 1_000_000;
const setup = () => {
  const el = new El("div");
  const opened = [];
  const render = mountStrip(el, { open: (id) => opened.push(id), cast: () => ({ characters: {} }) });
  const pulsing = () => el.children.filter((b) => b.classes.has("pulse")).map((b) => b.dataset.id);
  return { el, opened, render, pulsing };
};

test("the strip shows a portrait per session", () => {
  const { el, render } = setup();
  render([session("a", "working"), session("b", "done")], NOW);
  assert.equal(el.hidden, false);
  assert.deepEqual(el.children.map((b) => b.dataset.id), ["a", "b"]);
  assert.match(el.children[0].attrs["aria-label"], /working/);
  assert.match(el.children[0].lastChild.innerHTML, /^<svg class="badge/);
});

test("a quiet working session keeps its quiet badge", () => {
  const { el, render } = setup();
  render([session("a", "working", { quiet_since: 900 })], NOW);
  assert.match(el.children[0].lastChild.innerHTML, /\?<\/text>/);
});

test("a click on a portrait opens the wall at it", () => {
  const { el, opened, render } = setup();
  render([session("a", "working"), session("b", "done")], NOW);
  el.fire("click", el.children[1].firstChild);
  assert.deepEqual(opened, ["b"]);
});

test("a session already needing AJ in the first snapshot does not pulse, even after an empty pre-snapshot render", () => {
  const { render, pulsing } = setup();
  render([], NOW, false);
  render([session("a", "needs_you")], NOW);
  assert.deepEqual(pulsing(), []);
});

test("a later change to needs_you pulses once, and a reorder never replays it", () => {
  const { el, render, pulsing } = setup();
  render([session("a", "working"), session("b", "done")], NOW);
  render([session("b", "needs_you"), session("a", "working")], NOW);
  assert.deepEqual(pulsing(), ["b"]);
  el.fire("animationend", el.children[0].firstChild);
  assert.deepEqual(pulsing(), []);
  render([session("a", "working"), session("b", "needs_you")], NOW); // reorder, same statuses
  assert.deepEqual(pulsing(), []);
  render([session("a", "working"), session("b", "needs_you")], NOW, false); // a tick
  assert.deepEqual(pulsing(), []);
});

test("a portrait is reused across renders and removed with its session", () => {
  const { el, render } = setup();
  render([session("a", "working"), session("b", "done")], NOW);
  const a = el.children[0];
  render([session("a", "done")], NOW);
  assert.equal(el.children.length, 1);
  assert.equal(el.children[0], a);
  assert.match(a.attrs["aria-label"], /done/);
});

test("a session going quiet changes its badge without changing status", () => {
  const { el, render } = setup();
  render([session("a", "working")], NOW);
  const before = el.children[0].lastChild.innerHTML;
  render([session("a", "working", { quiet_since: 900 })], NOW);
  assert.notEqual(el.children[0].lastChild.innerHTML, before);
});

test("leaving needs_you clears the pulse", () => {
  const { render, pulsing } = setup();
  render([session("a", "working")], NOW);
  render([session("a", "needs_you")], NOW);
  assert.deepEqual(pulsing(), ["a"]);
  render([session("a", "done")], NOW);
  assert.deepEqual(pulsing(), []);
});

test("the speaking session's portrait wears the gold ring and says so", () => {
  const { el, render } = setup();
  const speaking = { session_id: "b", started_at: 999, ends_at: 1001, envelope: [0.5] };
  render([session("a", "working"), session("b", "working")], NOW, true, speaking);
  const ring = () => el.children.map((b) => b.classes.has("speaking"));
  assert.deepEqual(ring(), [false, true]);
  assert.match(el.children[1].attrs["aria-label"], /, speaking$/);
  render([session("a", "working"), session("b", "working")], NOW, true, null);
  assert.deepEqual(ring(), [false, false]);
  assert.doesNotMatch(el.children[1].attrs["aria-label"], /speaking/);
  render([session("a", "working"), session("b", "working")], 1_002_000, true, speaking);
  assert.deepEqual(ring(), [false, false], "a line long over marks no one");
});

test("a theme switch redraws each portrait in the theme now worn, on the same button", async () => {
  const { loadTheme } = await import("./fleet/theme.js");
  const THEMES = Object.fromEntries(await Promise.all(["kourai", "professions", "dicebear"].map(async (id) => [id, await loadTheme(id)])));
  const el = new El("div");
  let theme = THEMES.kourai;
  const render = mountStrip(el, { open: () => {}, cast: () => theme });
  const s = [session("a", "working", { voice: "bm_fable" })];
  render(s, NOW);
  const button = el.children[0];
  assert.equal(button.firstChild.src, "fleet/faces/kourai/hermes-192.webp");
  assert.match(button.attrs["aria-label"], /^Hermes,/);
  for (const id of ["professions", "dicebear"]) {
    theme = THEMES[id];
    render(s, NOW, false);
    const c = THEMES[id].characters.bm_fable;
    assert.equal(el.children[0], button, `${id}: the same button`);
    assert.equal(button.firstChild.src, `fleet/faces/${id}/${c.face}-192.webp`, id);
    assert.match(button.attrs["aria-label"], new RegExp(`^${c.name},`), id);
  }
});

const KEEPER = { keeper: "am_michael", faces: "kourai", characters: { am_michael: { name: "Hephaestus", face: "hephaestus" } } };

test("no sessions: the strip is the keeper's resting face as one button that opens the wall with no id", () => {
  const opened = [];
  const el = new El("div");
  el.hidden = true; // index.html's start
  const render = mountStrip(el, { open: (...a) => opened.push(a), cast: () => KEEPER });
  render([], NOW);
  assert.equal(el.hidden, false);
  assert.equal(el.children.length, 1);
  const [b] = el.children;
  assert.equal(b.attrs["aria-label"], "Open the fleet wall");
  assert.equal(b.firstChild.src, "fleet/faces/kourai/hephaestus-192.webp");
  assert.equal(b.firstChild.hidden, false);
  assert.equal(b.lastChild.innerHTML, "", "no badge");
  assert.equal(b.classes.has("pulse") || b.classes.has("speaking"), false);
  el.fire("click", b.firstChild);
  assert.deepEqual(opened, [[undefined]]);
});

test("sessions replace the keeper, and their going brings it back", () => {
  const el = new El("div");
  const render = mountStrip(el, { open() {}, cast: () => KEEPER });
  render([], NOW);
  render([session("a", "working")], NOW);
  assert.deepEqual(el.children.map((b) => b.dataset.id), ["a"]);
  assert.equal(el.children[0].classes.has("rest"), false);
  render([], NOW);
  assert.equal(el.children.length, 1);
  assert.equal(el.children[0].classes.has("rest"), true);
});

test("a theme without a keeper shows a plain button that still opens the wall", () => {
  const opened = [];
  const el = new El("div");
  const render = mountStrip(el, { open: (...a) => opened.push(a), cast: () => ({ characters: {} }) });
  render([], NOW);
  const [b] = el.children;
  assert.equal(b.attrs["aria-label"], "Open the fleet wall");
  assert.equal(b.firstChild.hidden, true);
  assert.match(b.lastChild.innerHTML, /^<svg class="glyph"/);
  el.fire("click", b.lastChild);
  assert.deepEqual(opened, [[undefined]]);
});

test("before the reader's first snapshot an empty draw leaves the strip hidden", () => {
  const el = new El("div");
  el.hidden = true;
  const render = mountStrip(el, { open() {}, cast: () => KEEPER });
  render([], NOW, false);
  assert.equal(el.hidden, true);
  assert.equal(el.children.length, 0);
  render([], NOW, true);
  assert.equal(el.hidden, false);
  assert.equal(el.children.length, 1);
});

test("a theme switch turns the keeper's face and the plain button into each other on the same button", () => {
  let cast = KEEPER;
  const el = new El("div");
  const render = mountStrip(el, { open() {}, cast: () => cast });
  render([], NOW);
  const b = el.children[0];
  cast = { characters: {} };
  render([], NOW);
  assert.equal(el.children[0], b);
  assert.equal(b.firstChild.hidden, true);
  assert.equal(b.firstChild.src, undefined, "the keeper's face is gone, not just hidden");
  assert.match(b.lastChild.innerHTML, /glyph/);
  cast = KEEPER;
  render([], NOW);
  assert.equal(b.firstChild.hidden, false);
  assert.equal(b.lastChild.innerHTML, "");
});

// ── #421: portraits dock beside their account's chip ──
const docked = () => {
  const root = new El("div");
  const el = new El("div");
  const slots = new Map([["acct-p", new El("span")], ["agy-primary", new El("span")]]);
  const dockOf = { "acct-p": "acct-p", "agy-primary": "agy-primary" };
  const opened = [];
  const render = mountStrip(el, {
    open: (id) => opened.push(id),
    cast: () => ({ characters: {} }),
    dock: { slots: () => slots, of: (item) => dockOf[item.account?.id] ?? null },
    root,
  });
  return { root, el, slots, opened, render };
};
const ids = (e) => e.children.map((b) => b.dataset.id);

test("a portrait docks in its account's slot; one with no slot stays in the strip", () => {
  const { el, slots, render } = docked();
  render([
    session("a", "working", { account: { id: "acct-p", label: "Personal" } }),
    session("b", "done", { account: { id: "agy-primary", label: "Google AI Pro" } }),
    session("c", "working", { account: { id: "gone", label: "Old" } }),
    session("d", "working"),
  ], NOW);
  assert.deepEqual(ids(slots.get("acct-p")), ["a"]);
  assert.deepEqual(ids(slots.get("agy-primary")), ["b"]);
  assert.deepEqual(ids(el), ["c", "d"]);
  assert.equal(el.hidden, false);
});

test("a portrait that changes account leaves its old slot; an emptied strip hides", () => {
  const { el, slots, render } = docked();
  render([session("a", "working", { account: { id: "acct-p", label: "Personal" } }), session("d", "working")], NOW);
  render([session("a", "working", { account: { id: "agy-primary", label: "Google AI Pro" } })], NOW);
  assert.deepEqual(ids(slots.get("acct-p")), []);
  assert.deepEqual(ids(slots.get("agy-primary")), ["a"]);
  assert.deepEqual(ids(el), []);
  assert.equal(el.hidden, true, "nothing loose: the strip beside the chips hides");
});

test("the resting keeper never docks, and a click on a docked portrait reaches the root", () => {
  const { root, el, slots, opened, render } = docked();
  render([], NOW);
  assert.equal(el.children.length, 1, "the keeper");
  assert.equal(el.hidden, false);
  render([session("a", "working", { account: { id: "acct-p", label: "Personal" } })], NOW);
  root.fire("click", slots.get("acct-p").children[0].firstChild);
  assert.deepEqual(opened, ["a"]);
});
