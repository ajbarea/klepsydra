import { test } from "node:test";
import assert from "node:assert/strict";
import { wireOpacityPick } from "./fleet/opacitypick.js";

const WAIT = 20; // the rest before a save, shortened for the tests
const rest = (ms = WAIT * 3) => new Promise((r) => setTimeout(r, ms));

// A range input and its label, and a fake app whose saves answer when told,
// without pushing anything back (Tauri does not order a push before the reply).
function setup({ fail = false } = {}) {
  const listeners = {};
  const winListeners = {};
  const input = {
    value: "80",
    attrs: {},
    setAttribute(k, v) { this.attrs[k] = v; },
    addEventListener(type, fn) { listeners[type] = fn; },
  };
  const value = { textContent: "" };
  const calls = [];
  const answers = [];
  const warned = [];
  let push;
  const invoke = (command, args) => {
    calls.push([command, args]);
    return new Promise((resolve, reject) => answers.push(() => (fail ? reject(new Error("prefs.json")) : resolve())));
  };
  wireOpacityPick({
    input, value, invoke, wait: WAIT,
    subscribe: (fn) => (push = fn),
    log: { warn: (m) => warned.push(m) },
    win: { addEventListener: (type, fn) => (winListeners[type] = fn) },
  });
  const step = (v) => {
    input.value = String(v);
    listeners.input();
  };
  const answer = async () => {
    answers.shift()();
    await rest(0);
  };
  return { input, value, calls, warned, step, answer, push: (v) => push(v), fire: (t) => listeners[t](), hide: () => winListeners.pagehide() };
}

test("the saved value shows on the slider, its label and its spoken value", () => {
  const s = setup();
  s.push(45);
  assert.deepEqual([s.input.value, s.value.textContent, s.input.attrs["aria-valuetext"]], ["45", "45%", "45%"]);
});

test("a held arrow key or a slow drag saves once, where the slider rests", async () => {
  const s = setup();
  s.push(80);
  for (let v = 75; v >= 0; v -= 5) s.step(v);
  assert.equal(s.value.textContent, "0%", "each step shows at once");
  assert.deepEqual(s.calls, [], "nothing saved mid-drag");
  await rest();
  assert.deepEqual(s.calls, [["set_gauge_opacity", { opacity: 0 }]]);
});

test("a move within one step saves nothing new", async () => {
  const s = setup();
  s.push(80);
  s.step(76); // 75
  s.step(74); // still 75
  await rest();
  assert.deepEqual(s.calls, [["set_gauge_opacity", { opacity: 75 }]]);
});

test("release, blur and page hide save at once", async () => {
  for (const how of ["pointerup", "blur", "pagehide"]) {
    const s = setup();
    s.push(80);
    s.step(50);
    if (how === "pagehide") s.hide();
    else s.fire(how);
    assert.deepEqual(s.calls, [["set_gauge_opacity", { opacity: 50 }]], how);
    await rest();
    assert.equal(s.calls.length, 1, `${how}: the timer saves nothing again`);
  }
});

test("a save answered before the app's push keeps what was asked", async () => {
  const s = setup();
  s.push(80);
  s.step(55);
  s.fire("pointerup");
  await s.answer();
  assert.equal(s.input.value, "55", "no push yet, and the thumb stays");
  s.push(55);
  assert.equal(s.input.value, "55");
});

test("a push of an earlier value never pulls the thumb back while a value waits", async () => {
  const s = setup();
  s.push(80);
  s.step(60);
  s.push(80); // the app's word, older than the slider's
  assert.equal(s.input.value, "60");
  await rest();
  await s.answer();
  assert.equal(s.input.value, "60");
});

test("a refused save says why and puts the slider back to the saved value", async () => {
  const s = setup({ fail: true });
  s.push(80);
  s.step(40);
  s.fire("pointerup");
  s.push(80); // the app republishes what prefs.json still holds
  await s.answer();
  assert.deepEqual([s.input.value, s.value.textContent], ["80", "80%"]);
  assert.match(s.warned[0], /could not be saved at 40%/);
});
