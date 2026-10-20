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
    };
  }
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
  const render = mountStrip(el, { open: (id) => opened.push(id) });
  const pulsing = () => el.children.filter((b) => b.classes.has("pulse")).map((b) => b.dataset.id);
  return { el, opened, render, pulsing };
};

test("the strip is hidden with no sessions and shows a portrait per session", () => {
  const { el, render } = setup();
  render([], NOW);
  assert.equal(el.hidden, true);
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
