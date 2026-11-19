import { test } from "node:test";
import assert from "node:assert/strict";
import { wireOpacityPick } from "./fleet/opacitypick.js";

// A range input and its label, a fake app whose saves answer when told.
function setup({ fail = false } = {}) {
  const listeners = {};
  const input = {
    value: "80",
    attrs: {},
    setAttribute(k, v) { this.attrs[k] = v; },
    addEventListener(type, fn) { listeners[type] = fn; },
  };
  const value = { textContent: "" };
  const calls = [];
  const answers = [];
  let push;
  const warned = [];
  const invoke = (command, args) => {
    calls.push([command, args]);
    return new Promise((resolve, reject) => answers.push(() => (fail ? reject(new Error("prefs.json")) : resolve())));
  };
  wireOpacityPick({ input, value, invoke, subscribe: (fn) => (push = fn), log: { warn: (m) => warned.push(m) } });
  const drag = (v) => {
    input.value = String(v);
    listeners.input();
  };
  const settle = async () => {
    answers.shift()();
    await new Promise((r) => setTimeout(r, 0));
  };
  return { input, value, calls, warned, drag, settle, push: (v) => push(v) };
}

test("the saved value shows on the slider, its label and its spoken value", () => {
  const s = setup();
  s.push(45);
  assert.equal(s.input.value, "45");
  assert.equal(s.value.textContent, "45%");
  assert.equal(s.input.attrs["aria-valuetext"], "45%");
});

test("each new step is saved once; a move within a step is not", () => {
  const s = setup();
  s.push(80);
  s.drag(76); // snaps to 75
  s.drag(74); // still 75
  s.drag(70);
  assert.deepEqual(s.calls, [["set_gauge_opacity", { opacity: 75 }], ["set_gauge_opacity", { opacity: 70 }]]);
  assert.equal(s.value.textContent, "70%");
});

test("an echo of an earlier step during a drag never pulls the thumb back", async () => {
  const s = setup();
  s.push(80);
  s.drag(75);
  s.drag(50);
  s.push(75); // the app's echo of the first save arrives late
  assert.equal(s.input.value, "50", "held while saves are in flight");
  s.push(50);
  await s.settle();
  assert.equal(s.input.value, "50");
  await s.settle();
  assert.equal(s.input.value, "50", "once all settle, the last value the app said");
});

test("a failed save says why and puts the slider back to the saved value", async () => {
  const s = setup({ fail: true });
  s.push(80);
  s.drag(40);
  s.push(80); // the app republishes what prefs.json still holds
  await s.settle();
  assert.equal(s.input.value, "80");
  assert.equal(s.value.textContent, "80%");
  assert.match(s.warned[0], /could not be saved at 40%/);
});
